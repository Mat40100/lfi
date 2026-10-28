'use strict';
// Unit + in-process integration tests (node --test, no network beyond localhost).
//   make social-test      → docker run … node:22-alpine node --test
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');

const app = require('./server');

const SECRET = 'test-secret';

// Exactly what Ghost 6 does in webhook-trigger.js.
function ghostSign(body, secret, ts = Date.now()) {
  const hex = crypto.createHmac('sha256', secret).update(`${body}${ts}`).digest('hex');
  return `sha256=${hex}, t=${ts}`;
}

function webhookBody(overrides = {}) {
  return JSON.stringify({
    event: 'post.published',
    post: {
      current: {
        id: 'post-1',
        title: 'Un article de test',
        url: 'http://127.0.0.1:1/un-article/',
        status: 'published',
        email_only: false,
        custom_excerpt: 'Résumé rédigé à la main.',
        plaintext: 'Texte complet de l’article.',
        tags: [{ slug: 'actu', visibility: 'public' }],
        ...overrides,
      },
      previous: { status: 'draft' },
    },
  });
}

test('verifySignature accepts a Ghost signature and rejects tampering', () => {
  const body = Buffer.from(webhookBody());
  const header = ghostSign(body.toString(), SECRET);
  assert.equal(app.verifySignature({ rawBody: body, header, secret: SECRET }).ok, true);
  assert.equal(app.verifySignature({ rawBody: body, header, secret: 'other' }).ok, false);
  assert.equal(app.verifySignature({ rawBody: Buffer.from(`${body}x`), header, secret: SECRET }).ok, false);
  assert.match(app.verifySignature({ rawBody: body, header: undefined, secret: SECRET }).reason, /missing/);
  assert.match(app.verifySignature({ rawBody: body, header: 'sha256=abc', secret: SECRET }).reason, /malformed/);
  assert.match(app.verifySignature({ rawBody: body, header, secret: '' }).reason, /not set/);
  const old = ghostSign(body.toString(), SECRET, Date.now() - 10 * 60 * 1000);
  assert.match(app.verifySignature({ rawBody: body, header: old, secret: SECRET }).reason, /away from now/);
});

test('verifySignature works on multi-byte bodies (hash over raw bytes)', () => {
  const body = Buffer.from(JSON.stringify({ event: 'x', t: 'été — ça marche ✓' }));
  const header = ghostSign(body.toString('utf8'), SECRET);
  assert.equal(app.verifySignature({ rawBody: body, header, secret: SECRET }).ok, true);
});

test('buildMessage: custom excerpt verbatim, auto-excerpt trimmed at a word boundary', () => {
  assert.equal(app.buildMessage({ title: ' Titre ', custom_excerpt: 'Résumé.' }), 'Titre\n\nRésumé.');
  const long = Array.from({ length: 80 }, (_, i) => `mot${i}`).join(' ');
  const msg = app.buildMessage({ title: 'T', excerpt: long }, { excerptMaxChars: 50 });
  const excerpt = msg.split('\n\n')[1];
  assert.ok(excerpt.endsWith('…'), excerpt);
  assert.ok(excerpt.length <= 52, excerpt);
  assert.equal(app.buildMessage({ title: 'Seul' }), 'Seul');
  assert.equal(app.truncate('court', 10), 'court');
  assert.equal(app.buildMessage({ title: 'T', plaintext: 'ligne 1\n\n  ligne   2 ' }), 'T\n\nligne 1 ligne 2');
});

test('decide: share / skip / ignore rules', () => {
  const opts = { skipTag: 'hash-no-facebook', shareTag: 'hash-facebook', canShare: true, alreadyShared: () => false };
  const parse = (s) => JSON.parse(s);
  assert.equal(app.decide(parse(webhookBody()), opts).action, 'share');
  assert.equal(app.decide({ event: 'post.edited', post: { current: {} } }, opts).action, 'ignore');
  assert.equal(app.decide({ event: 'post.published' }, opts).action, 'invalid');
  assert.match(app.decide(parse(webhookBody({ email_only: true })), opts).reason, /email-only/);
  assert.match(app.decide(parse(webhookBody({ status: 'draft' })), opts).reason, /status/);
  assert.match(app.decide(parse(webhookBody({ tags: [{ slug: 'hash-no-facebook', visibility: 'internal' }] })), opts).reason, /tagged/);
  assert.match(app.decide(parse(webhookBody()), { ...opts, alreadyShared: () => true }).reason, /already/);
  assert.match(app.decide(parse(webhookBody()), { ...opts, canShare: false }).reason, /not configured/);
  const d = app.decide(parse(webhookBody()), opts);
  assert.deepEqual(Object.keys(d.post).sort(), ['custom_excerpt', 'excerpt', 'id', 'plaintext', 'title', 'url']);

  // "share this older post now": an edit of a published post carrying the share tag
  const edited = (tags) => ({ ...parse(webhookBody({ tags })), event: 'post.published.edited' });
  const plainEdit = app.decide(edited([{ slug: 'actu' }]), opts);
  assert.equal(plainEdit.action, 'ignore');
  assert.equal(plainEdit.quiet, true);
  assert.equal(app.decide(edited([{ slug: 'hash-facebook', visibility: 'internal' }]), opts).action, 'share');
  assert.match(app.decide(edited([{ slug: 'hash-facebook' }, { slug: 'hash-no-facebook' }]), opts).reason, /tagged hash-no-facebook/);
  assert.match(app.decide(edited([{ slug: 'hash-facebook' }]), { ...opts, alreadyShared: () => true }).reason, /already/);
  // the share tag at publish time changes nothing
  assert.equal(app.decide(parse(webhookBody({ tags: [{ slug: 'hash-facebook' }] })), opts).action, 'share');
});

// ---------------------------------------------------------------- integration: webhook → mock Graph API

function listen(server) {
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server.address().port)));
}

function waitFor(predicate, { timeoutMs = 5000 } = {}) {
  const started = Date.now();
  return new Promise((resolve, reject) => {
    (function poll() {
      if (predicate()) return resolve();
      if (Date.now() - started > timeoutMs) return reject(new Error('timeout waiting for condition'));
      setTimeout(poll, 50);
    })();
  });
}

test('end to end: signed webhook → one Facebook post, dedupe, auth', async (t) => {
  const graphRequests = [];
  let graphFailures = 0;
  const graphMock = http.createServer((req, res) => {
    let raw = '';
    req.on('data', (c) => { raw += c; });
    req.on('end', () => {
      const url = new URL(req.url, 'http://x');
      graphRequests.push({ method: req.method, path: url.pathname, query: Object.fromEntries(url.searchParams), form: Object.fromEntries(new URLSearchParams(raw)) });
      if (req.method === 'POST' && url.pathname === '/v26.0/4242/feed') {
        if (graphFailures > 0) {
          graphFailures -= 1;
          res.writeHead(503, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: { message: 'Service temporarily unavailable', code: 2 } }));
          return;
        }
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ id: '4242_777' }));
        return;
      }
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: { message: `unexpected ${req.method} ${url.pathname}`, code: 100 } }));
    });
  });
  const siteHits = [];
  const siteMock = http.createServer((req, res) => { siteHits.push(req.method + ' ' + req.url); res.writeHead(200); res.end(); });
  const graphPort = await listen(graphMock);
  const sitePort = await listen(siteMock);
  const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), 'social-publisher-'));

  const cfg = app.loadConfig({
    GHOST_WEBHOOK_SECRET: SECRET,
    FACEBOOK_PAGE_ID: '4242',
    FACEBOOK_PAGE_ACCESS_TOKEN: 'page-token',
    FACEBOOK_GRAPH_URL: `http://127.0.0.1:${graphPort}/`,
    STATE_DIR: stateDir,
    PUBLISH_DELAY_MS: '0',
  });
  cfg.retryDelaysMs = [10, 10];
  const state = new app.State(stateDir);
  const publisher = new app.Publisher(cfg, state);
  const server = app.createServer(cfg, publisher, state);
  const port = await listen(server);
  t.after(() => { server.close(); graphMock.close(); siteMock.close(); fs.rmSync(stateDir, { recursive: true, force: true }); });

  const post = async (body, headers = {}) => {
    const res = await fetch(`http://127.0.0.1:${port}/webhooks/ghost`, { method: 'POST', body, headers: { 'Content-Type': 'application/json', ...headers } });
    return { status: res.status, json: await res.json() };
  };
  const articleUrl = `http://127.0.0.1:${sitePort}/un-article/`;
  const body = webhookBody({ url: articleUrl });

  // health
  const health = await (await fetch(`http://127.0.0.1:${port}/healthz`)).json();
  assert.deepEqual(health, { ok: true, configured: true, dry_run: false, pending: 0, shared: 0 });

  // unsigned / badly signed
  assert.equal((await post(body)).status, 401);
  assert.equal((await post(body, { 'X-Ghost-Signature': ghostSign(body, 'wrong') })).status, 401);
  assert.equal((await post('{not json', { 'X-Ghost-Signature': ghostSign('{not json', SECRET) })).status, 400);

  // other events are acknowledged and ignored
  const edited = JSON.stringify({ event: 'post.edited', post: { current: { id: 'post-1' } } });
  assert.deepEqual(await post(edited, { 'X-Ghost-Signature': ghostSign(edited, SECRET) }), { status: 202, json: { ignored: 'event post.edited' } });

  // the real thing — with one transient Graph API failure to exercise the retry
  graphFailures = 1;
  assert.deepEqual(await post(body, { 'X-Ghost-Signature': ghostSign(body, SECRET) }), { status: 202, json: { queued: true } });
  await waitFor(() => state.has('post-1'));
  const feedPosts = graphRequests.filter((r) => r.path === '/v26.0/4242/feed');
  assert.equal(feedPosts.length, 2, 'one failed attempt + one success');
  assert.deepEqual(feedPosts[1].form, { message: 'Un article de test\n\nRésumé rédigé à la main.', link: articleUrl, access_token: 'page-token' });
  assert.ok(siteHits.some((h) => h === 'HEAD /un-article/'), `article probed before sharing: ${siteHits}`);
  const saved = JSON.parse(fs.readFileSync(path.join(stateDir, 'shared-posts.json'), 'utf8'));
  assert.equal(saved.posts['post-1'].facebook_post_id, '4242_777');
  assert.equal(saved.posts['post-1'].url, articleUrl);

  // re-publishing the same post is a no-op
  assert.deepEqual(await post(body, { 'X-Ghost-Signature': ghostSign(body, SECRET) }), { status: 202, json: { skipped: 'already shared on Facebook' } });
  await publisher.chain;
  assert.equal(graphRequests.filter((r) => r.path === '/v26.0/4242/feed').length, 2);
  assert.deepEqual(await post(body, { 'X-Ghost-Signature': ghostSign(body, SECRET) }), { status: 202, json: { skipped: 'already shared on Facebook' } });

  // the opt-out tag
  const tagged = webhookBody({ id: 'post-2', url: articleUrl, tags: [{ slug: 'hash-no-facebook', visibility: 'internal' }] });
  assert.deepEqual(await post(tagged, { 'X-Ghost-Signature': ghostSign(tagged, SECRET) }), { status: 202, json: { skipped: 'tagged hash-no-facebook' } });

  // an older post shared after the fact: edit event + share tag
  const plainEdit = JSON.stringify({ ...JSON.parse(webhookBody({ id: 'post-old', url: articleUrl })), event: 'post.published.edited' });
  assert.deepEqual(await post(plainEdit, { 'X-Ghost-Signature': ghostSign(plainEdit, SECRET) }), { status: 202, json: { ignored: 'edit without the hash-facebook tag' } });
  const taggedEdit = JSON.stringify({ ...JSON.parse(webhookBody({ id: 'post-old', url: articleUrl, tags: [{ slug: 'hash-facebook', visibility: 'internal' }] })), event: 'post.published.edited' });
  assert.deepEqual(await post(taggedEdit, { 'X-Ghost-Signature': ghostSign(taggedEdit, SECRET) }), { status: 202, json: { queued: true } });
  await waitFor(() => state.has('post-old'));
  assert.equal(graphRequests.filter((r) => r.path === '/v26.0/4242/feed').length, 3);
  assert.deepEqual(await post(taggedEdit, { 'X-Ghost-Signature': ghostSign(taggedEdit, SECRET) }), { status: 202, json: { skipped: 'already shared on Facebook' } });

  // a permanent Graph API error is logged, not retried, not recorded
  const bad = webhookBody({ id: 'post-3', url: articleUrl });
  const cfgBad = { ...cfg, pageId: '9999' };
  const publisherBad = new app.Publisher(cfgBad, state);
  const serverBad = app.createServer(cfgBad, publisherBad, state);
  const portBad = await listen(serverBad);
  t.after(() => serverBad.close());
  const r = await fetch(`http://127.0.0.1:${portBad}/webhooks/ghost`, { method: 'POST', body: bad, headers: { 'X-Ghost-Signature': ghostSign(bad, SECRET) } });
  assert.equal(r.status, 202);
  await publisherBad.chain;
  assert.equal(graphRequests.filter((x) => x.path === '/v26.0/9999/feed').length, 1, 'no retry on a permanent (#100) error');
  // (the main page received 3 posts so far: post-1, post-old)
  assert.equal(state.has('post-3'), false);

  // dry run: nothing is sent, nothing recorded
  const cfgDry = { ...cfg, dryRun: true };
  const publisherDry = new app.Publisher(cfgDry, state);
  const serverDry = app.createServer(cfgDry, publisherDry, state);
  const portDry = await listen(serverDry);
  t.after(() => serverDry.close());
  const dry = webhookBody({ id: 'post-4', url: articleUrl });
  const rd = await fetch(`http://127.0.0.1:${portDry}/webhooks/ghost`, { method: 'POST', body: dry, headers: { 'X-Ghost-Signature': ghostSign(dry, SECRET) } });
  assert.equal(rd.status, 202);
  await publisherDry.chain;
  assert.equal(graphRequests.filter((x) => x.path === '/v26.0/4242/feed').length, 3);
  assert.equal(state.has('post-4'), false);
});

test('unconfigured publisher acknowledges and skips', async (t) => {
  const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), 'social-publisher-'));
  const cfg = app.loadConfig({ GHOST_WEBHOOK_SECRET: SECRET, STATE_DIR: stateDir });
  const state = new app.State(stateDir);
  const publisher = new app.Publisher(cfg, state);
  const server = app.createServer(cfg, publisher, state);
  const port = await listen(server);
  t.after(() => { server.close(); fs.rmSync(stateDir, { recursive: true, force: true }); });
  const body = webhookBody();
  const res = await fetch(`http://127.0.0.1:${port}/webhooks/ghost`, { method: 'POST', body, headers: { 'X-Ghost-Signature': ghostSign(body, SECRET) } });
  assert.equal(res.status, 202);
  assert.match((await res.json()).skipped, /not configured/);
});
