// LFI team console — v1: member invites.
//
// An invite = a single-use, expiring, email-bound token. Accepting it creates
// (or updates) the Ghost member with the Équipe tier comped, which is what the
// patched DoG SSO gate requires for forum access. The invite email is sent
// through the same Mailjet SMTP account Ghost uses.
//
// Routes (Caddy proxies landes-insoumises.fr/equipe/* and /ghost/console* here).
// Admin routes live under /ghost/console so the browser sends the Ghost Admin
// session cookie (scoped to path /ghost); auth = a valid Ghost staff session
// with an allowed role. No separate password.
//   GET  /ghost/console             admin page: invite form + invite list
//   POST /ghost/console/invite      create invite + send email
//   POST /ghost/console/resend      re-send email, extend expiry
//   POST /ghost/console/revoke      revoke a pending invite
//   GET  /equipe/admin              301 → /ghost/console (legacy URL)
//   GET  /equipe/invite/<token>     public accept page
//   POST /equipe/invite/<token>     accept: comp tier + trigger magic-link
//   GET  /equipe/reserve            "forum reserved" landing (DoG denied redirect)
//   GET  /equipe/health             liveness probe

const crypto = require('crypto');
const fs = require('fs');
const http = require('http');
const path = require('path');
const nodemailer = require('nodemailer');

const config = {
  port: Number(process.env.CONSOLE_PORT || 3300),
  publicUrl: (process.env.CONSOLE_PUBLIC_URL || 'https://landes-insoumises.fr').replace(/\/$/, ''),
  siteName: process.env.SITE_NAME || 'Dax insoumise',
  forumUrl: process.env.FORUM_URL || 'https://forum.landes-insoumises.fr',
  ghostUrl: (process.env.GHOST_ADMIN_URL || 'http://ghost:2368').replace(/\/$/, ''),
  ghostToken: process.env.GHOST_ADMIN_TOKEN,
  tierId: process.env.EQUIPE_TIER_ID,
  allowedRoles: (process.env.CONSOLE_ALLOWED_ROLES || 'Owner,Administrator').split(',').map((r) => r.trim()),
  invitesFile: process.env.INVITES_FILE || '/data/invites.json',
  inviteTtlDays: Number(process.env.INVITE_TTL_DAYS || 7),
  mailFrom: process.env.MAIL_FROM,
  smtp: {
    host: process.env.SMTP_HOST,
    port: Number(process.env.SMTP_PORT || 465),
    secure: String(process.env.SMTP_SECURE || 'true') === 'true',
    auth: { user: process.env.SMTP_USER, pass: process.env.SMTP_PASS },
  },
};

for (const key of ['ghostToken', 'tierId', 'mailFrom']) {
  if (!config[key]) {
    console.error(`Missing required config: ${key}`);
    process.exit(1);
  }
}

const mailer = nodemailer.createTransport(config.smtp);

// ---------------------------------------------------------------- invite store

function loadInvites() {
  try {
    return JSON.parse(fs.readFileSync(config.invitesFile, 'utf8'));
  } catch {
    return [];
  }
}

function saveInvites(invites) {
  const tmp = `${config.invitesFile}.tmp`;
  fs.mkdirSync(path.dirname(config.invitesFile), { recursive: true });
  fs.writeFileSync(tmp, JSON.stringify(invites, null, 2));
  fs.renameSync(tmp, config.invitesFile);
}

function inviteState(invite) {
  if (invite.status !== 'pending') return invite.status; // accepted | revoked
  if (Date.now() > invite.expires_at) return 'expired';
  return 'pending';
}

// ---------------------------------------------------------------- ghost admin

function ghostJwt() {
  const [id, secret] = config.ghostToken.split(':');
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const now = Math.floor(Date.now() / 1000);
  const head = b64({ alg: 'HS256', typ: 'JWT', kid: id });
  const body = b64({ iat: now, exp: now + 300, aud: '/admin/' });
  const sig = crypto.createHmac('sha256', Buffer.from(secret, 'hex'))
    .update(`${head}.${body}`).digest('base64url');
  return `${head}.${body}.${sig}`;
}

async function ghostApi(method, apiPath, payload) {
  const res = await fetch(`${config.ghostUrl}/ghost/api/admin${apiPath}`, {
    method,
    headers: {
      Authorization: `Ghost ${ghostJwt()}`,
      'Content-Type': 'application/json',
      'Accept-Version': 'v5.0',
    },
    body: payload ? JSON.stringify(payload) : undefined,
  });
  const text = await res.text();
  let body;
  try { body = JSON.parse(text); } catch { body = text; }
  if (!res.ok) {
    const message = body?.errors?.[0]?.message || res.statusText;
    throw new Error(`Ghost ${method} ${apiPath} -> ${res.status}: ${message}`);
  }
  return body;
}

// Authenticate an admin request against the caller's Ghost Admin session: the
// admin UI is served under /ghost so the browser sends the ghost-admin-api-session
// cookie; forwarding it to the (canonical, public) Admin API tells us who it is.
async function ghostStaffFromCookie(req) {
  const cookie = req.headers.cookie || '';
  if (!cookie.includes('ghost-admin-api-session=')) return null;
  try {
    const res = await fetch(`${config.publicUrl}/ghost/api/admin/users/me/?include=roles`, {
      headers: { cookie, 'Accept-Version': 'v5.0' },
    });
    if (!res.ok) return null;
    const user = (await res.json()).users?.[0];
    const roles = (user?.roles || []).map((r) => r.name);
    return roles.some((r) => config.allowedRoles.includes(r)) ? user : null;
  } catch (error) {
    console.error('ghost session check failed:', error.message);
    return null;
  }
}

// Create the member with the Équipe tier comped, or add the tier if the member
// already exists (e.g. was already a newsletter subscriber).
async function compMember(email, name) {
  const filter = encodeURIComponent(`email:'${email.replace(/'/g, '')}'`);
  const found = await ghostApi('GET', `/members/?filter=${filter}&include=tiers,newsletters`);
  const existing = found.members?.[0];

  if (existing) {
    if ((existing.tiers || []).some((t) => t.id === config.tierId)) return existing.id;
    // Ghost 6 without Stripe silently ignores `tiers` on member *updates*
    // (member-repository.js: needsProducts = stripeConfigured && data.products),
    // but honors them on *creation* — so recreate the member with the tier.
    await ghostApi('DELETE', `/members/${existing.id}/`);
    const recreated = await ghostApi('POST', '/members/', {
      members: [{
        email,
        name: name || existing.name || null,
        note: existing.note || null,
        labels: mergedLabels(existing),
        newsletters: (existing.newsletters || []).map((n) => ({ id: n.id })),
        tiers: [{ id: config.tierId }],
      }],
    });
    return recreated.members[0].id;
  }

  const created = await ghostApi('POST', '/members/', {
    members: [{
      email,
      name: name || null,
      labels: [{ name: 'equipe' }],
      tiers: [{ id: config.tierId }],
    }],
  });
  return created.members[0].id;
}

function mergedLabels(member) {
  const labels = (member.labels || []).map((l) => ({ name: l.name }));
  if (!labels.some((l) => l.name === 'equipe')) labels.push({ name: 'equipe' });
  return labels;
}

// Ask Ghost to email a sign-in magic link (public members endpoint; newer Ghost
// versions require an integrity token first).
async function sendMagicLink(email) {
  let integrityToken;
  try {
    const res = await fetch(`${config.ghostUrl}/members/api/integrity-token/`, {
      headers: { 'app-pragma': 'no-cache' },
    });
    if (res.ok) integrityToken = await res.text();
  } catch { /* older Ghost: endpoint absent */ }

  const res = await fetch(`${config.ghostUrl}/members/api/send-magic-link/`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, emailType: 'signin', ...(integrityToken ? { integrityToken } : {}) }),
  });
  if (!res.ok) throw new Error(`send-magic-link -> ${res.status}: ${await res.text()}`);
}

// ---------------------------------------------------------------- invite email

async function sendInviteEmail(invite) {
  const link = `${config.publicUrl}/equipe/invite/${invite.token}`;
  const expiry = new Date(invite.expires_at).toLocaleDateString('fr-FR', { day: 'numeric', month: 'long', year: 'numeric' });
  const hello = invite.name ? `Bonjour ${escapeHtml(invite.name)},` : 'Bonjour,';
  await mailer.sendMail({
    from: `"${config.siteName}" <${config.mailFrom.replace(/^.*<|>.*$/g, '')}>`,
    to: invite.email,
    subject: `Invitation — espace équipe ${config.siteName}`,
    text: `${invite.name ? `Bonjour ${invite.name},` : 'Bonjour,'}\n\n`
      + `Vous êtes invité·e à rejoindre l'espace équipe de ${config.siteName} `
      + `(forum privé + accès membre).\n\nActivez votre accès ici (lien valable jusqu'au ${expiry}) :\n${link}\n\n`
      + `Si vous n'attendiez pas cette invitation, ignorez simplement ce message.`,
    html: emailHtml(hello, link, expiry),
  });
}

function emailHtml(hello, link, expiry) {
  return `<!doctype html><html lang="fr"><body style="margin:0;padding:0;background:#fffcf4;font-family:-apple-system,BlinkMacSystemFont,Roboto,Helvetica,Arial,sans-serif;color:#212320;">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:40px 16px;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:520px;background:#ffffff;border-radius:8px;padding:32px;">
      <tr><td style="font-size:20px;font-weight:700;color:#4c0297;padding-bottom:16px;">${escapeHtml(config.siteName)}</td></tr>
      <tr><td style="font-size:16px;line-height:1.5;padding-bottom:8px;">${hello}</td></tr>
      <tr><td style="font-size:16px;line-height:1.5;padding-bottom:24px;">
        Vous êtes invité·e à rejoindre <strong>l'espace équipe</strong> de ${escapeHtml(config.siteName)} :
        forum privé et accès membre.
      </td></tr>
      <tr><td align="center" style="padding-bottom:24px;">
        <a href="${link}" style="background:#4c0297;color:#ffffff;text-decoration:none;font-size:16px;font-weight:700;padding:12px 28px;border-radius:6px;display:inline-block;">Activer mon accès</a>
      </td></tr>
      <tr><td style="font-size:13px;line-height:1.5;color:#6b6f68;">
        Ce lien est personnel et valable jusqu'au ${expiry}.
        Si vous n'attendiez pas cette invitation, ignorez simplement ce message.
      </td></tr>
    </table>
  </td></tr></table></body></html>`;
}

// ---------------------------------------------------------------- html helpers

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function page(title, body) {
  return `<!doctype html><html lang="fr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex">
<title>${escapeHtml(title)} — ${escapeHtml(config.siteName)}</title>
<style>
  :root{color-scheme:light}
  body{margin:0;background:#fffcf4;color:#212320;font-family:-apple-system,BlinkMacSystemFont,Roboto,Helvetica,Arial,sans-serif;line-height:1.5}
  .wrap{max-width:720px;margin:0 auto;padding:48px 20px}
  h1{color:#4c0297;font-size:28px;margin:0 0 8px;text-transform:uppercase}
  h2{font-size:18px;margin:32px 0 12px}
  .card{background:#fff;border-radius:8px;padding:24px;box-shadow:0 1px 4px rgba(33,35,32,.08);margin-bottom:24px}
  label{display:block;font-size:14px;font-weight:600;margin:12px 0 4px}
  input[type=email],input[type=text]{width:100%;box-sizing:border-box;padding:10px;border:1px solid #d9d5c9;border-radius:6px;font-size:15px}
  button{background:#4c0297;color:#fff;border:0;border-radius:6px;padding:10px 22px;font-size:15px;font-weight:700;cursor:pointer;margin-top:16px}
  button.small{padding:4px 10px;font-size:13px;margin:0}
  button.ghostbtn{background:transparent;color:#4c0297;border:1px solid #4c0297}
  table{width:100%;border-collapse:collapse;font-size:14px}
  th,td{text-align:left;padding:8px 6px;border-bottom:1px solid #eee9dc;vertical-align:middle}
  .badge{display:inline-block;padding:2px 8px;border-radius:10px;font-size:12px;font-weight:600}
  .b-pending{background:#fdf3d0;color:#7a5b00}.b-accepted{background:#dcf2e4;color:#186139}
  .b-expired{background:#eee;color:#666}.b-revoked{background:#fbdcda;color:#8c1810}
  .notice{padding:12px 16px;border-radius:6px;margin-bottom:16px;font-size:14px}
  .ok{background:#dcf2e4;color:#186139}.err{background:#fbdcda;color:#8c1810}
  .muted{color:#6b6f68;font-size:13px}
  a{color:#4c0297}
</style></head><body><div class="wrap">${body}</div></body></html>`;
}

const statusLabels = { pending: 'En attente', accepted: 'Acceptée', expired: 'Expirée', revoked: 'Révoquée' };

function adminPage(invites, flash, staff) {
  const rows = invites
    .slice()
    .sort((a, b) => b.created_at - a.created_at)
    .map((invite) => {
      const state = inviteState(invite);
      const actions = state === 'pending' || state === 'expired'
        ? `<form method="post" action="/ghost/console/resend" style="display:inline"><input type="hidden" name="id" value="${invite.id}"><button class="small ghostbtn">Renvoyer</button></form>
           <form method="post" action="/ghost/console/revoke" style="display:inline"><input type="hidden" name="id" value="${invite.id}"><button class="small ghostbtn">Révoquer</button></form>`
        : '';
      return `<tr><td>${escapeHtml(invite.email)}</td><td>${escapeHtml(invite.name || '—')}</td>
        <td><span class="badge b-${state}">${statusLabels[state]}</span></td>
        <td class="muted">${new Date(invite.created_at).toLocaleDateString('fr-FR')}</td>
        <td class="muted">${new Date(invite.expires_at).toLocaleDateString('fr-FR')}</td>
        <td>${actions}</td></tr>`;
    })
    .join('');

  return page('Console équipe', `
    <h1>Console équipe</h1>
    <p class="muted">Invitez quelqu'un : il ou elle reçoit un e-mail avec un lien personnel qui active
    son compte membre et l'accès au <a href="${config.forumUrl}">forum</a>.
    ${staff ? `<br>Connecté·e en tant que <strong>${escapeHtml(staff.name || staff.email)}</strong> (session Ghost Admin).` : ''}</p>
    ${flash || ''}
    <div class="card">
      <h2 style="margin-top:0">Nouvelle invitation</h2>
      <form method="post" action="/ghost/console/invite">
        <label for="email">E-mail</label>
        <input type="email" id="email" name="email" required placeholder="prenom@exemple.fr">
        <label for="name">Prénom / nom (optionnel, utilisé dans l'e-mail)</label>
        <input type="text" id="name" name="name" placeholder="Prénom Nom">
        <button>Inviter</button>
      </form>
    </div>
    <div class="card">
      <h2 style="margin-top:0">Invitations</h2>
      ${invites.length ? `<div style="overflow-x:auto"><table>
        <tr><th>E-mail</th><th>Nom</th><th>Statut</th><th>Créée</th><th>Expire</th><th></th></tr>${rows}
      </table></div>` : '<p class="muted">Aucune invitation pour le moment.</p>'}
    </div>`);
}

function acceptPage(invite) {
  return page('Invitation', `
    <h1>${escapeHtml(config.siteName)}</h1>
    <div class="card">
      <h2 style="margin-top:0">Bienvenue${invite.name ? ` ${escapeHtml(invite.name)}` : ''} !</h2>
      <p>Vous êtes invité·e à rejoindre <strong>l'espace équipe</strong> :
      compte membre du site + accès au forum privé.</p>
      <p class="muted">Adresse : ${escapeHtml(invite.email)}</p>
      <form method="post"><button>Activer mon accès</button></form>
    </div>`);
}

function messagePage(title, message, extra = '') {
  return page(title, `<h1>${escapeHtml(config.siteName)}</h1>
    <div class="card"><h2 style="margin-top:0">${escapeHtml(title)}</h2><p>${message}</p>${extra}</div>`);
}

// ---------------------------------------------------------------- http server

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', (chunk) => {
      data += chunk;
      if (data.length > 10_000) { reject(new Error('body too large')); req.destroy(); }
    });
    req.on('end', () => resolve(Object.fromEntries(new URLSearchParams(data))));
    req.on('error', reject);
  });
}

function send(res, status, html, headers = {}) {
  res.writeHead(status, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store', ...headers });
  res.end(html);
}

function redirect(res, location) {
  res.writeHead(303, { Location: location });
  res.end();
}

// Cross-site POSTs could ride on the Ghost Admin session cookie.
function sameOrigin(req) {
  const site = req.headers['sec-fetch-site'];
  if (site && site !== 'same-origin' && site !== 'none') return false;
  const origin = req.headers.origin;
  if (origin && origin !== config.publicUrl) return false;
  return true;
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, config.publicUrl);
  const route = `${req.method} ${url.pathname.replace(/\/$/, '') || '/'}`;

  try {
    if (route === 'GET /equipe/health') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true }));
      return;
    }

    if (route === 'GET /equipe/reserve') {
      send(res, 200, messagePage(
        'Espace réservé',
        `Le forum est réservé à l'équipe de ${escapeHtml(config.siteName)}.
         Si vous en faites partie, demandez une invitation à un·e responsable.`,
        `<p><a href="${config.publicUrl}">← Retour au site</a></p>`,
      ));
      return;
    }

    // Legacy admin URL (was behind Caddy basic_auth).
    if (route === 'GET /equipe/admin') {
      redirect(res, '/ghost/console');
      return;
    }

    if (url.pathname === '/ghost/console' || url.pathname.startsWith('/ghost/console/')) {
      const staff = await ghostStaffFromCookie(req);
      if (!staff) {
        send(res, 401, messagePage(
          'Connexion requise',
          `Cette console est réservée aux administrateur·ices du site.<br>
           Connectez-vous à <a href="${config.publicUrl}/ghost/">Ghost Admin</a>,
           puis <a href="/ghost/console">rechargez cette page</a>.`,
        ));
        return;
      }

      if (route === 'GET /ghost/console') {
        const flashes = {
          invited: '<div class="notice ok">Invitation envoyée ✔</div>',
          resent: '<div class="notice ok">Invitation renvoyée ✔</div>',
          revoked: '<div class="notice ok">Invitation révoquée.</div>',
          mailfail: '<div class="notice err">Invitation créée mais l\'e-mail n\'a pas pu être envoyé — utilisez « Renvoyer ».</div>',
        };
        send(res, 200, adminPage(loadInvites(), flashes[url.searchParams.get('m')], staff));
        return;
      }

      if (!route.startsWith('POST /ghost/console/')) {
        send(res, 404, messagePage('Page introuvable', 'Cette page n\'existe pas.'));
        return;
      }

      if (!sameOrigin(req)) { send(res, 403, messagePage('Refusé', 'Requête inter-site refusée.')); return; }
      const body = await readBody(req);
      const invites = loadInvites();

      if (route === 'POST /ghost/console/invite') {
        const email = String(body.email || '').trim().toLowerCase();
        if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) { send(res, 400, messagePage('Erreur', 'E-mail invalide.')); return; }
        const invite = {
          id: crypto.randomBytes(12).toString('hex'),
          token: crypto.randomBytes(24).toString('hex'),
          email,
          name: String(body.name || '').trim().slice(0, 100),
          status: 'pending',
          created_at: Date.now(),
          expires_at: Date.now() + config.inviteTtlDays * 86_400_000,
        };
        invites.push(invite);
        saveInvites(invites);
        try {
          await sendInviteEmail(invite);
        } catch (error) {
          console.error('invite mail failed:', error.message);
          redirect(res, '/ghost/console?m=mailfail');
          return;
        }
        redirect(res, '/ghost/console?m=invited');
        return;
      }

      const invite = invites.find((i) => i.id === body.id);
      if (!invite) { send(res, 404, messagePage('Erreur', 'Invitation introuvable.')); return; }

      if (route === 'POST /ghost/console/resend') {
        invite.status = 'pending';
        invite.expires_at = Date.now() + config.inviteTtlDays * 86_400_000;
        saveInvites(invites);
        await sendInviteEmail(invite);
        redirect(res, '/ghost/console?m=resent');
        return;
      }

      if (route === 'POST /ghost/console/revoke') {
        invite.status = 'revoked';
        saveInvites(invites);
        redirect(res, '/ghost/console?m=revoked');
        return;
      }
    }

    const inviteMatch = url.pathname.match(/^\/equipe\/invite\/([a-f0-9]{48})\/?$/);
    if (inviteMatch) {
      const invites = loadInvites();
      const invite = invites.find((i) => i.token === inviteMatch[1]);
      const state = invite && inviteState(invite);

      if (!invite || state === 'revoked') {
        send(res, 404, messagePage('Invitation invalide', 'Ce lien d\'invitation n\'est pas ou plus valable.'));
        return;
      }
      if (state === 'expired') {
        send(res, 410, messagePage('Invitation expirée', 'Ce lien a expiré. Demandez une nouvelle invitation à un·e responsable.'));
        return;
      }
      if (state === 'accepted') {
        send(res, 200, messagePage(
          'Invitation déjà utilisée',
          `Votre accès est déjà actif. Connectez-vous sur <a href="${config.publicUrl}">${escapeHtml(config.siteName)}</a>
           puis rendez-vous sur <a href="${config.forumUrl}">le forum</a>.`,
        ));
        return;
      }

      if (req.method === 'GET') {
        send(res, 200, acceptPage(invite));
        return;
      }

      if (req.method === 'POST') {
        await compMember(invite.email, invite.name);
        invite.status = 'accepted';
        invite.accepted_at = Date.now();
        saveInvites(invites);
        let mailNote = `Un e-mail de connexion vient de vous être envoyé à <strong>${escapeHtml(invite.email)}</strong> —
          ouvrez-le et cliquez sur le lien pour vous connecter.`;
        try {
          await sendMagicLink(invite.email);
        } catch (error) {
          console.error('magic link failed:', error.message);
          mailNote = `Connectez-vous sur <a href="${config.publicUrl}">${escapeHtml(config.siteName)}</a>
            avec l'adresse <strong>${escapeHtml(invite.email)}</strong> (bouton « Se connecter »).`;
        }
        send(res, 200, messagePage(
          'Accès activé 🎉',
          `${mailNote}<br><br>Ensuite, le forum vous reconnaîtra automatiquement :
           <a href="${config.forumUrl}">${config.forumUrl.replace('https://', '')}</a>`,
        ));
        return;
      }
    }

    send(res, 404, messagePage('Page introuvable', 'Cette page n\'existe pas.'));
  } catch (error) {
    console.error(`${route} failed:`, error);
    send(res, 500, messagePage('Erreur', 'Une erreur interne est survenue. Réessayez ou contactez un·e responsable.'));
  }
});

server.listen(config.port, '0.0.0.0', () => {
  console.log(`console listening on :${config.port}`);
});
