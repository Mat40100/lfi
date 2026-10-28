#!/usr/bin/env node
/**
 * social-publisher — shares Ghost posts on a Facebook Page.
 *
 * Ghost POSTs its "post.published" webhook (signed with the webhook secret) to
 * /webhooks/ghost. We answer within milliseconds — Ghost gives up after 2 s and
 * never retries a POST — then, in the background, publish "title + excerpt" with
 * the article link on the Page through the Graph API (POST /{page-id}/feed).
 * Older posts are shared after the fact by tagging them (#facebook): Ghost then
 * sends "post.published.edited", which is honoured only when that tag is present.
 * Facebook builds the link preview from the article's Open Graph tags, which
 * Ghost renders from the post's feature image.
 *
 * Sub-commands:  serve (default) | check | token     — see docs/social-facebook.md
 * No npm dependencies: Node 22's http / crypto / fs / fetch only.
 */
'use strict';

const http = require('node:http');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const SIGNATURE_RE = /^sha256=([0-9a-f]{64}),\s*t=(\d{1,16})$/i;
// Graph API error codes worth retrying (rate limits, transient failures).
const TRANSIENT_FB_CODES = new Set([1, 2, 4, 17, 32, 341, 368, 613]);

function loadConfig(env = process.env) {
  return {
    port: Number(env.PORT || 8080),
    webhookSecret: env.GHOST_WEBHOOK_SECRET || '',
    pageId: env.FACEBOOK_PAGE_ID || '',
    pageToken: env.FACEBOOK_PAGE_ACCESS_TOKEN || '',
    graphVersion: env.FACEBOOK_GRAPH_VERSION || 'v26.0',
    graphUrl: (env.FACEBOOK_GRAPH_URL || 'https://graph.facebook.com').replace(/\/+$/, ''),
    dryRun: /^(1|true|yes|on)$/i.test(env.FACEBOOK_DRY_RUN || ''),
    skipTag: env.SOCIAL_SKIP_TAG || 'hash-no-facebook',
    // Internal tag that shares an already-published post when it is edited.
    shareTag: env.SOCIAL_SHARE_TAG || 'hash-facebook',
    stateDir: env.STATE_DIR || '/data',
    // Let Ghost's URL service / cache catch up with the event before Facebook scrapes the page.
    publishDelayMs: Number(env.PUBLISH_DELAY_MS ?? 5000),
    excerptMaxChars: Number(env.EXCERPT_MAX_CHARS || 280),
    signatureToleranceMs: 5 * 60 * 1000,
    maxBodyBytes: 8 * 1024 * 1024, // a webhook carries the post's html + plaintext
    retryDelaysMs: [15_000, 60_000, 300_000],
  };
}

function isConfigured(cfg) {
  return Boolean(cfg.pageId && cfg.pageToken);
}

function log(level, message, extra) {
  const line = `${new Date().toISOString()} ${level.toUpperCase().padEnd(5)} ${message}`;
  const out = level === 'error' || level === 'warn' ? console.error : console.log;
  out(extra === undefined ? line : `${line} ${JSON.stringify(extra)}`);
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// ---------------------------------------------------------------- Ghost webhook

/**
 * Ghost signs `X-Ghost-Signature: sha256=<hex HMAC-SHA256(secret, rawBody + ts)>, t=<ts>`
 * (core/server/services/webhooks/webhook-trigger.js, Ghost 6). Verified on the raw
 * bytes, constant-time, with a replay window on the timestamp.
 */
function verifySignature({ rawBody, header, secret, now = Date.now(), toleranceMs = 5 * 60 * 1000 }) {
  if (!secret) return { ok: false, reason: 'GHOST_WEBHOOK_SECRET is not set' };
  if (!header) return { ok: false, reason: 'missing X-Ghost-Signature header' };
  const match = SIGNATURE_RE.exec(String(header).trim());
  if (!match) return { ok: false, reason: 'malformed X-Ghost-Signature header' };
  const [, hex, ts] = match;
  const age = Math.abs(now - Number(ts));
  if (age > toleranceMs) return { ok: false, reason: `timestamp ${ts} is ${Math.round(age / 1000)} s away from now` };
  const expected = crypto.createHmac('sha256', secret).update(rawBody).update(ts).digest();
  const given = Buffer.from(hex, 'hex');
  if (given.length !== expected.length || !crypto.timingSafeEqual(given, expected)) {
    return { ok: false, reason: 'signature mismatch' };
  }
  return { ok: true };
}

function truncate(text, max) {
  if (text.length <= max) return text;
  const slice = text.slice(0, max + 1);
  const space = slice.lastIndexOf(' ');
  const cut = space > max * 0.6 ? slice.slice(0, space) : slice.slice(0, max);
  return `${cut.replace(/[\s,;:.!?…–-]+$/u, '')}…`;
}

/** Text of the Facebook post: the title, then the excerpt (custom excerpt verbatim, else the auto-excerpt trimmed). */
function buildMessage(post, { excerptMaxChars = 280 } = {}) {
  const title = String(post.title || '').trim();
  const custom = String(post.custom_excerpt || '').replace(/\s+/g, ' ').trim();
  let excerpt = custom || String(post.excerpt || post.plaintext || '').replace(/\s+/g, ' ').trim();
  if (!custom) excerpt = truncate(excerpt, excerptMaxChars);
  return [title, excerpt].filter(Boolean).join('\n\n');
}

/**
 * What to do with a webhook payload: share | skip | ignore | invalid (+ reason).
 *   post.published         → share, unless opted out (skip tag) / email-only / already shared
 *   post.published.edited  → share only when the post carries the share tag (the
 *                            "send this older post now" button); other edits are
 *                            ignored quietly (Ghost sends one per edit)
 */
function decide(body, { skipTag, shareTag, canShare, alreadyShared }) {
  const event = body && body.event;
  if (event !== 'post.published' && event !== 'post.published.edited') {
    return { action: 'ignore', reason: `event ${event || 'unknown'}` };
  }
  const post = body.post && body.post.current;
  if (!post || !post.id || !post.url) return { action: 'invalid', reason: 'payload has no post.current.id / url' };
  const tags = Array.isArray(post.tags) ? post.tags : [];
  const hasTag = (slug) => Boolean(slug) && tags.some((t) => t && t.slug === slug);
  if (event === 'post.published.edited' && !hasTag(shareTag)) {
    return { action: 'ignore', reason: `edit without the ${shareTag} tag`, quiet: true };
  }
  const summary = {
    id: post.id,
    title: String(post.title || '').trim(),
    url: post.url,
    custom_excerpt: post.custom_excerpt || '',
    excerpt: post.excerpt || '',
    plaintext: post.plaintext || '',
  };
  if (post.status !== 'published') return { action: 'skip', reason: `status is ${post.status}`, post: summary };
  if (post.email_only) return { action: 'skip', reason: 'email-only post (no public page)', post: summary };
  if (hasTag(skipTag)) return { action: 'skip', reason: `tagged ${skipTag}`, post: summary };
  if (alreadyShared(post.id)) return { action: 'skip', reason: 'already shared on Facebook', post: summary };
  if (!canShare) return { action: 'skip', reason: 'publisher not configured (FACEBOOK_PAGE_ID / FACEBOOK_PAGE_ACCESS_TOKEN)', post: summary };
  return { action: 'share', post: summary };
}

// ---------------------------------------------------------------- Facebook Graph API

function describeGraphError(status, json, text) {
  const fb = json && json.error;
  if (fb) {
    const bits = [`(#${fb.code}${fb.error_subcode ? `/${fb.error_subcode}` : ''})`, fb.message];
    if (fb.code === 190) bits.push('— the Page access token is invalid or expired: run `make facebook-token` and update .env');
    if (fb.code === 200 || fb.code === 10) bits.push('— missing permission (pages_manage_posts) or not a Page token: run `make facebook-token`');
    return `Graph API ${bits.join(' ')}`;
  }
  return `Graph API HTTP ${status}: ${String(text || '').slice(0, 200)}`;
}

/** One Graph API call. `params` are form fields (POST) or query params (GET). Never logs the URL (it carries the token). */
async function graph(cfg, method, endpoint, params, { timeoutMs = 30_000 } = {}) {
  const url = new URL(`${cfg.graphUrl}/${cfg.graphVersion}/${String(endpoint).replace(/^\/+/, '')}`);
  const form = new URLSearchParams(params);
  let res;
  try {
    if (method === 'GET') {
      url.search = form.toString();
      res = await fetch(url, { signal: AbortSignal.timeout(timeoutMs) });
    } else {
      res = await fetch(url, { method, body: form, signal: AbortSignal.timeout(timeoutMs) });
    }
  } catch (err) {
    const e = new Error(`Graph API unreachable: ${(err.cause && err.cause.code) || err.name || err.message}`);
    e.transient = true;
    throw e;
  }
  const text = await res.text();
  let json = null;
  try { json = JSON.parse(text); } catch { /* not JSON */ }
  if (!res.ok || !json || json.error) {
    const e = new Error(describeGraphError(res.status, json, text));
    e.status = res.status;
    e.fb = json && json.error;
    e.transient = res.status >= 500 || Boolean(e.fb && TRANSIENT_FB_CODES.has(e.fb.code));
    throw e;
  }
  return json;
}

async function shareOnFacebook(cfg, post) {
  const message = buildMessage(post, cfg);
  if (cfg.dryRun) {
    log('info', `[dry-run] would share "${post.title}"`, { page: cfg.pageId || '(unset)', link: post.url, message });
    return { dryRun: true };
  }
  return graph(cfg, 'POST', `${cfg.pageId}/feed`, { message, link: post.url, access_token: cfg.pageToken });
}

// ---------------------------------------------------------------- state (dedupe)

class State {
  constructor(dir) {
    this.dir = dir;
    this.file = path.join(dir, 'shared-posts.json');
    this.data = { posts: {} };
    this.writable = true;
    try {
      this.data = JSON.parse(fs.readFileSync(this.file, 'utf8'));
      if (!this.data || typeof this.data.posts !== 'object') this.data = { posts: {} };
    } catch (err) {
      if (err.code !== 'ENOENT') log('warn', `could not read ${this.file}: ${err.message} — starting with an empty share list`);
    }
    try {
      fs.mkdirSync(dir, { recursive: true });
      fs.accessSync(dir, fs.constants.W_OK);
    } catch {
      this.writable = false;
      log('warn', `${dir} is not writable: the list of shared posts will not survive a restart (fix the owner of data/social-publisher)`);
    }
  }

  has(postId) {
    return Boolean(this.data.posts[postId]);
  }

  count() {
    return Object.keys(this.data.posts).length;
  }

  record(post, facebookPostId) {
    this.data.posts[post.id] = {
      facebook_post_id: facebookPostId,
      title: post.title,
      url: post.url,
      shared_at: new Date().toISOString(),
    };
    if (!this.writable) return;
    try {
      const tmp = `${this.file}.tmp`;
      fs.writeFileSync(tmp, `${JSON.stringify(this.data, null, 2)}\n`);
      fs.renameSync(tmp, this.file);
    } catch (err) {
      log('warn', `could not write ${this.file}: ${err.message}`);
    }
  }
}

// ---------------------------------------------------------------- background publisher

class Publisher {
  constructor(cfg, state) {
    this.cfg = cfg;
    this.state = state;
    this.chain = Promise.resolve();
    this.pending = 0;
  }

  enqueue(post) {
    this.pending += 1;
    this.chain = this.chain
      .then(() => this.process(post))
      .catch((err) => log('error', `unexpected failure while sharing "${post.title}": ${err.stack || err.message}`))
      .finally(() => { this.pending -= 1; });
    return this.chain;
  }

  /** Best effort: Facebook scrapes the article right away, so make sure Ghost serves it first. */
  async waitForArticle(url) {
    for (let attempt = 1; attempt <= 5; attempt += 1) {
      let status;
      try {
        const res = await fetch(url, { method: 'HEAD', redirect: 'manual', signal: AbortSignal.timeout(10_000) });
        status = res.status;
      } catch (err) {
        log('warn', `cannot check ${url} (${(err.cause && err.cause.code) || err.name}) — sharing without the check`);
        return false;
      }
      if (status >= 200 && status < 400) return true;
      log('warn', `${url} answered HTTP ${status} (attempt ${attempt}/5) — waiting for Ghost to serve it`);
      await sleep(5000);
    }
    return false;
  }

  async process(post) {
    if (this.cfg.publishDelayMs > 0) await sleep(this.cfg.publishDelayMs);
    await this.waitForArticle(post.url);
    if (this.state.has(post.id)) {
      log('info', `skipping "${post.title}": already shared on Facebook`);
      return;
    }
    for (let attempt = 0; ; attempt += 1) {
      try {
        const result = await shareOnFacebook(this.cfg, post);
        if (!result.dryRun) {
          this.state.record(post, result.id);
          log('info', `shared "${post.title}" → https://www.facebook.com/${result.id}`, { link: post.url });
        }
        return;
      } catch (err) {
        const delay = this.cfg.retryDelaysMs[attempt];
        if (!err.transient || delay === undefined) {
          log('error', `giving up on "${post.title}" (${post.url}): ${err.message}`);
          return;
        }
        log('warn', `${err.message} — retry ${attempt + 1}/${this.cfg.retryDelaysMs.length} for "${post.title}" in ${delay / 1000} s`);
        await sleep(delay);
      }
    }
  }
}

// ---------------------------------------------------------------- HTTP server

function sendJson(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) });
  res.end(payload);
}

function readBody(req, maxBytes) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > maxBytes) {
        const err = new Error('payload too large');
        err.code = 'E_TOO_LARGE';
        req.destroy(err);
        reject(err);
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function createServer(cfg, publisher, state) {
  const canShare = isConfigured(cfg) || cfg.dryRun;

  async function handleWebhook(req, res) {
    const rawBody = await readBody(req, cfg.maxBodyBytes);
    const sig = verifySignature({
      rawBody, header: req.headers['x-ghost-signature'], secret: cfg.webhookSecret, toleranceMs: cfg.signatureToleranceMs,
    });
    if (!sig.ok) {
      log('warn', `rejected webhook from ${req.socket.remoteAddress}: ${sig.reason}`);
      sendJson(res, 401, { error: sig.reason });
      return;
    }
    let body;
    try {
      body = JSON.parse(rawBody.toString('utf8'));
    } catch {
      sendJson(res, 400, { error: 'invalid JSON' });
      return;
    }
    const decision = decide(body, {
      skipTag: cfg.skipTag, shareTag: cfg.shareTag, canShare, alreadyShared: (id) => state.has(id),
    });
    switch (decision.action) {
      case 'ignore':
        if (!decision.quiet) log('info', `ignored webhook: ${decision.reason}`);
        sendJson(res, 202, { ignored: decision.reason });
        return;
      case 'invalid':
        log('warn', `invalid webhook payload: ${decision.reason}`);
        sendJson(res, 400, { error: decision.reason });
        return;
      case 'skip':
        log('info', `skipping "${decision.post.title}": ${decision.reason}`);
        sendJson(res, 202, { skipped: decision.reason });
        return;
      default:
        log('info', `queued "${decision.post.title}" (${body.event})`, { link: decision.post.url });
        publisher.enqueue(decision.post);
        sendJson(res, 202, { queued: true });
    }
  }

  return http.createServer((req, res) => {
    const pathname = (req.url || '/').split('?')[0];
    if (req.method === 'GET' && (pathname === '/healthz' || pathname === '/')) {
      sendJson(res, 200, {
        ok: true, configured: isConfigured(cfg), dry_run: cfg.dryRun, pending: publisher.pending, shared: state.count(),
      });
      return;
    }
    if (req.method === 'POST' && pathname === '/webhooks/ghost') {
      handleWebhook(req, res).catch((err) => {
        if (err.code === 'E_TOO_LARGE') {
          if (!res.headersSent) sendJson(res, 413, { error: 'payload too large' });
          return;
        }
        log('error', `webhook handling failed: ${err.stack || err.message}`);
        if (!res.headersSent) sendJson(res, 500, { error: 'internal error' });
      });
      return;
    }
    sendJson(res, 404, { error: 'not found' });
  });
}

// ---------------------------------------------------------------- commands

async function serve(cfg) {
  const state = new State(cfg.stateDir);
  const publisher = new Publisher(cfg, state);
  const server = createServer(cfg, publisher, state);

  log('info', 'social-publisher starting', {
    graph: `${cfg.graphUrl}/${cfg.graphVersion}`,
    page: cfg.pageId || '(unset)',
    token: cfg.pageToken ? 'set' : 'MISSING',
    webhook_secret: cfg.webhookSecret ? 'set' : 'MISSING',
    dry_run: cfg.dryRun,
    skip_tag: cfg.skipTag,
    share_tag: cfg.shareTag,
    shared_so_far: state.count(),
  });
  if (!cfg.webhookSecret) log('warn', 'GHOST_WEBHOOK_SECRET is empty: every webhook will be rejected (401) until SOCIAL_WEBHOOK_SECRET is set in .env');
  if (!isConfigured(cfg) && !cfg.dryRun) log('warn', 'FACEBOOK_PAGE_ID / FACEBOOK_PAGE_ACCESS_TOKEN missing: posts will be acknowledged but not shared');

  await new Promise((resolve) => server.listen(cfg.port, '0.0.0.0', resolve));
  log('info', `listening on :${cfg.port} (POST /webhooks/ghost, GET /healthz)`);

  if (isConfigured(cfg) && !cfg.dryRun) {
    graph(cfg, 'GET', cfg.pageId, { fields: 'id,name', access_token: cfg.pageToken })
      .then((page) => log('info', `posting as Facebook Page "${page.name}" (${page.id})`))
      .catch((err) => log('warn', `Facebook Page check failed: ${err.message}`));
  }

  const shutdown = (signal) => {
    log('info', `${signal} received — finishing ${publisher.pending} pending share(s) then exiting`);
    server.close();
    const grace = sleep(25_000).then(() => log('warn', 'shutdown grace period over, exiting with work pending'));
    Promise.race([publisher.chain, grace]).finally(() => process.exit(0));
  };
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
}

/** `check`: validate the Page token against the Graph API. Exit 0 when posting would work. */
async function check(cfg) {
  console.log(`Graph API:      ${cfg.graphUrl}/${cfg.graphVersion}`);
  console.log(`Page id:        ${cfg.pageId || '(unset)'}`);
  console.log(`Page token:     ${cfg.pageToken ? `set (${cfg.pageToken.length} chars)` : 'MISSING'}`);
  console.log(`Webhook secret: ${cfg.webhookSecret ? 'set' : 'MISSING'}`);
  console.log(`Dry run:        ${cfg.dryRun}`);
  console.log(`Skip tag:       ${cfg.skipTag}   share-later tag: ${cfg.shareTag}`);
  if (!isConfigured(cfg)) {
    console.error('\nFACEBOOK_PAGE_ID / FACEBOOK_PAGE_ACCESS_TOKEN missing in .env — run `make facebook-token` (docs/social-facebook.md).');
    return 1;
  }
  // A token can inspect itself: type (PAGE/USER), target, scopes, expiry.
  const dbg = (await graph(cfg, 'GET', 'debug_token', { input_token: cfg.pageToken, access_token: cfg.pageToken })).data || {};
  const scopes = dbg.scopes || [];
  const fmtExpiry = (t) => (t === 0 || t === undefined ? 'never' : new Date(t * 1000).toISOString().slice(0, 10));
  console.log(`\nToken type:     ${dbg.type || '?'} (app ${dbg.app_id || '?'}, target ${dbg.profile_id || '?'})`);
  console.log(`Token expires:  ${fmtExpiry(dbg.expires_at)}   data access: ${fmtExpiry(dbg.data_access_expires_at)}`);
  console.log(`Scopes:         ${scopes.join(', ') || '(none)'}`);
  let bad = 0;
  if (dbg.is_valid === false) { console.error('✗ token is INVALID (expired or revoked) — run `make facebook-token`'); bad += 1; }
  if (dbg.type !== 'PAGE') { console.error(`✗ this is a ${dbg.type || 'non-Page'} token — posting needs the PAGE token printed by \`make facebook-token\``); bad += 1; }
  if (dbg.profile_id && dbg.profile_id !== cfg.pageId) { console.error(`✗ token is for Page ${dbg.profile_id}, but FACEBOOK_PAGE_ID=${cfg.pageId}`); bad += 1; }
  for (const scope of ['pages_manage_posts', 'pages_read_engagement']) {
    if (!scopes.includes(scope)) {
      console.error(`✗ missing permission ${scope} — add it to the app's use case ("Manage everything on your Page" → Customize → Permissions), regenerate the user token in the Graph API Explorer with it ticked, then \`make facebook-token\` again`);
      bad += 1;
    }
  }
  if (bad) return 1;
  const page = await graph(cfg, 'GET', cfg.pageId, { fields: 'id,name,link', access_token: cfg.pageToken });
  console.log(`\nPage:           ${page.name} — ${page.link || ''}`);
  console.log('✓ Page access token OK (posting as the Page)');
  return 0;
}

/**
 * `token`: turn a short-lived user token (Graph API Explorer) into the never-expiring
 * Page access token to put in .env. Interactive, or FB_APP_ID / FB_APP_SECRET /
 * FB_USER_TOKEN in the environment.
 */
async function token(cfg, env = process.env) {
  const readline = require('node:readline/promises');
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  const ask = async (label, envName, fallback = '') => {
    if (env[envName]) return env[envName].trim();
    const answer = (await rl.question(fallback ? `${label} [${fallback}]: ` : `${label}: `)).trim();
    return answer || fallback;
  };
  try {
    console.log('Meta app (developers.facebook.com → your app → App settings → Basic) and a short-lived USER token\n'
      + 'from the Graph API Explorer with pages_show_list, pages_read_engagement, pages_manage_posts, pages_manage_metadata.\n');
    const appId = await ask('App ID', 'FB_APP_ID', env.FACEBOOK_APP_ID || '');
    const appSecret = await ask('App secret', 'FB_APP_SECRET');
    const userToken = await ask('Short-lived user token', 'FB_USER_TOKEN');
    if (!appId || !appSecret || !userToken) {
      console.error('all three values are required');
      return 1;
    }
    const longLived = await graph(cfg, 'GET', 'oauth/access_token', {
      grant_type: 'fb_exchange_token', client_id: appId, client_secret: appSecret, fb_exchange_token: userToken,
    });
    const accounts = await graph(cfg, 'GET', 'me/accounts', { fields: 'id,name,tasks,access_token', access_token: longLived.access_token });
    const pages = (accounts && accounts.data) || [];
    if (!pages.length) {
      console.error('\nNo Facebook Page found for this user. The API only publishes to Pages: a personal profile — even in'
        + ' "professional mode" — cannot be used. Create a Page (or get admin rights on it) and retry.');
      return 1;
    }
    console.log(`\n${pages.length} Page(s):`);
    for (const page of pages) {
      let expiry = 'unknown';
      let scopes = [];
      try {
        const dbg = await graph(cfg, 'GET', 'debug_token', { input_token: page.access_token, access_token: `${appId}|${appSecret}` });
        expiry = dbg.data.expires_at === 0 ? 'never' : new Date(dbg.data.expires_at * 1000).toISOString();
        scopes = dbg.data.scopes || [];
      } catch (err) {
        expiry = `unknown (${err.message})`;
      }
      const tasks = page.tasks || [];
      console.log(`\n--- ${page.name} (${page.id})`);
      console.log(`    tasks: ${tasks.join(', ') || 'none'}${tasks.includes('CREATE_CONTENT') ? '' : '   ← no CREATE_CONTENT task: this user cannot post on it'}`);
      console.log(`    token expires: ${expiry}${expiry === 'never' ? '' : '   ← expected "never" (long-lived user token → Page token)'}`);
      if (scopes.length && !scopes.includes('pages_manage_posts')) console.log('    ← pages_manage_posts is NOT granted: re-create the user token with that permission');
      console.log('    .env lines:');
      console.log(`FACEBOOK_PAGE_ID=${page.id}`);
      console.log(`FACEBOOK_PAGE_ACCESS_TOKEN=${page.access_token}`);
    }
    console.log('\nPaste the two lines of the Page you want into .env (never commit them), then: make social-check');
    return 0;
  } finally {
    rl.close();
  }
}

function main() {
  const cmd = process.argv[2] || 'serve';
  const cfg = loadConfig();
  const run = { serve, check, token }[cmd];
  if (!run) {
    console.error('usage: server.js [serve|check|token]');
    process.exit(2);
  }
  run(cfg).then((code) => {
    if (cmd !== 'serve') process.exit(code || 0);
  }).catch((err) => {
    console.error(err.message || err);
    process.exit(1);
  });
}

module.exports = {
  loadConfig, verifySignature, buildMessage, truncate, decide, graph, State, Publisher, createServer, isConfigured,
};

if (require.main === module) main();
