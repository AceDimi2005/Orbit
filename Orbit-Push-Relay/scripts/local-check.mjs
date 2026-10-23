#!/usr/bin/env node
// Pre-deploy check of the relay in the real Workers runtime (workerd, through
// `wrangler dev --local`) against a mock APNs server on 127.0.0.1. Nothing is
// deployed and no Cloudflare account is needed.
//
//   node scripts/local-check.mjs               # about 15 seconds
//   node scripts/local-check.mjs --with-alarm  # also waits ~5 minutes for a real dead-man alarm
//
// Wrangler comes from $WRANGLER if set, otherwise `npx --yes wrangler@4`.

import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { mkdtempSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import { generateKeyPairSync, verify as cryptoVerify, randomBytes } from 'node:crypto';
import assert from 'node:assert/strict';

const relayDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const withAlarm = process.argv.includes('--with-alarm');
const ALARM_WINDOW = 300; // the relay's minimum offlineAfterSeconds
const relayPort = 20000 + Math.floor(Math.random() * 20000);
const BASE = `http://127.0.0.1:${relayPort}`;
const stateDir = mkdtempSync(path.join(os.tmpdir(), 'orbit-relay-check-'));

const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
const keyBody = privateKey.export({ type: 'pkcs8', format: 'pem' }).replace(/-----[A-Z ]+-----/g, '').replace(/\s+/g, '');

// ---- mock APNs (HTTP/1.1 is fine for a local mock) ----
const apnsCalls = [];
const goneTokens = new Set();
const apns = http.createServer((req, res) => {
  let body = '';
  req.on('data', (chunk) => (body += chunk));
  req.on('end', () => {
    const token = req.url.split('/').pop();
    apnsCalls.push({ url: req.url, headers: req.headers, json: JSON.parse(body) });
    if (goneTokens.has(token)) {
      res.writeHead(410, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ reason: 'Unregistered', timestamp: Date.now() }));
      return;
    }
    res.writeHead(200, { 'apns-id': `mock-${apnsCalls.length}` });
    res.end();
  });
});
await new Promise((resolve) => apns.listen(0, '127.0.0.1', resolve));
const apnsOrigin = `http://127.0.0.1:${apns.address().port}`;

// ---- wrangler dev ----
const devArgs = [
  'dev', '--local', '--ip', '127.0.0.1', '--port', String(relayPort), '--persist-to', stateDir,
  '--var', `APNS_KEY_P8:${keyBody}`,
  '--var', 'APNS_KEY_ID:KEY1234567',
  '--var', 'APNS_TEAM_ID:TEAM123456',
  '--var', `APNS_TEST_ORIGIN:${apnsOrigin}`,
];
const [command, args] = process.env.WRANGLER
  ? [process.env.WRANGLER, devArgs]
  : ['npx', ['--yes', 'wrangler@4', ...devArgs]];
const child = spawn(command, args, {
  cwd: relayDir,
  env: { ...process.env, WRANGLER_SEND_METRICS: 'false', NO_COLOR: '1' },
  stdio: ['ignore', 'pipe', 'pipe'],
});
let output = '';
child.stdout.on('data', (d) => (output += d));
child.stderr.on('data', (d) => (output += d));
let stopped = false;
function stop() {
  if (stopped) return;
  stopped = true;
  try { child.kill('SIGTERM'); } catch { /* already gone */ }
  apns.close();
  rmSync(stateDir, { recursive: true, force: true });
}
process.on('exit', stop);

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function waitFor(check, timeoutMs, label) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (await check()) return;
    await sleep(500);
  }
  throw new Error(`timed out waiting for ${label}`);
}

async function call(method, route, { secret, body } = {}) {
  const headers = { 'user-agent': 'OrbitAgent/local-check' };
  if (secret) headers.authorization = `Bearer ${secret}`;
  if (body !== undefined) headers['content-type'] = 'application/json';
  const res = await fetch(BASE + route, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
  const text = await res.text();
  let json = null;
  try { json = JSON.parse(text); } catch { /* not JSON */ }
  return { status: res.status, json, text };
}

function verifyJwt(authorization) {
  const [h, c, s] = authorization.replace(/^bearer /, '').split('.');
  const signature = Buffer.from(s, 'base64url');
  assert.equal(signature.length, 64, 'ES256 signature is raw r||s');
  assert.ok(cryptoVerify('sha256', Buffer.from(`${h}.${c}`), { key: publicKey, dsaEncoding: 'ieee-p1363' }, signature), 'JWT verifies');
  return { header: JSON.parse(Buffer.from(h, 'base64url')), claims: JSON.parse(Buffer.from(c, 'base64url')) };
}

const ok = (message) => console.log(`✓ ${message}`);

try {
  await waitFor(async () => {
    if (child.exitCode !== null) throw new Error('wrangler dev exited');
    try { return (await fetch(`${BASE}/v1/health`)).ok; } catch { return false; }
  }, 180_000, 'wrangler dev to start');

  const health = await call('GET', '/v1/health');
  assert.deepEqual(health.json, { ok: true, service: 'orbit-push-relay', protocol: 1, apns: 'configured' });
  ok('the Worker starts in workerd and reports APNs as configured');

  const created = await call('POST', '/v1/channels', { body: {} });
  assert.equal(created.status, 201, created.text);
  const { channelId, pcSecret } = created.json;
  ok('channel created');

  assert.equal((await call('GET', `/v1/c/${channelId}`)).status, 401);
  assert.equal((await call('GET', `/v1/c/${channelId}`, { secret: 'A'.repeat(43) })).status, 401);
  assert.equal((await call('GET', `/v1/c/${'f'.repeat(32)}`, { secret: pcSecret })).status, 404);
  ok('wrong or missing secrets are refused');

  const tokens = { A: randomBytes(32).toString('hex'), B: randomBytes(32).toString('hex'), C: randomBytes(32).toString('hex') };
  const offline = { A: randomBytes(156).toString('base64'), B: randomBytes(156).toString('base64') };
  goneTokens.add(tokens.C);
  for (const [id, body] of [
    ['DEV-A', { token: tokens.A, env: 'sandbox', offlineCt: offline.A }],
    ['DEV-B', { token: tokens.B, env: 'production', offlineCt: offline.B }],
    ['DEV-C', { token: tokens.C, env: 'production' }],
  ]) {
    const res = await call('PUT', `/v1/c/${channelId}/devices/${id}`, { secret: pcSecret, body });
    assert.equal(res.status, 200, res.text);
  }
  assert.equal((await call('PUT', `/v1/c/${channelId}/devices/DEV-D`, { secret: pcSecret, body: { token: 'nothex', env: 'sandbox' } })).status, 400);
  ok('devices registered in the SQLite-backed Durable Object');

  const events = { A: randomBytes(284).toString('base64'), B: randomBytes(284).toString('base64'), C: randomBytes(284).toString('base64') };
  const notified = await call('POST', `/v1/c/${channelId}/notify`, {
    secret: pcSecret,
    body: { items: { 'DEV-A': events.A, 'DEV-B': events.B, 'DEV-C': events.C }, level: 'timeSensitive', collapseId: 'temperature.cpu', ttl: 900 },
  });
  assert.equal(notified.status, 200, notified.text);
  assert.equal(notified.json.results['DEV-A'].status, 'sent');
  assert.equal(notified.json.results['DEV-B'].status, 'sent');
  assert.equal(notified.json.results['DEV-C'].status, 'unregistered');
  assert.equal(apnsCalls.length, 3);
  for (const request of apnsCalls) {
    assert.equal(request.headers['apns-push-type'], 'alert');
    assert.equal(request.headers['apns-topic'], 'com.dimitrie.orbit');
    assert.equal(request.headers['apns-priority'], '10');
    assert.equal(request.headers['apns-collapse-id'], `${channelId.slice(0, 12)}.temperature.cpu`);
    assert.equal(request.json.aps['interruption-level'], 'time-sensitive');
    assert.deepEqual(request.json.aps.alert, { title: 'Orbit', body: 'New alert from your PC' });
    const { header, claims } = verifyJwt(request.headers.authorization);
    assert.deepEqual([header.alg, header.kid, claims.iss], ['ES256', 'KEY1234567', 'TEAM123456']);
  }
  const sentBody = Object.fromEntries(apnsCalls.map((r) => [r.url.split('/').pop(), r.json.o]));
  assert.equal(sentBody[tokens.A], events.A);
  assert.equal(sentBody[tokens.B], events.B);
  ok('notify fan-out with a WebCrypto ES256 token that node:crypto verifies');

  let status = await call('GET', `/v1/c/${channelId}`, { secret: pcSecret });
  assert.deepEqual(status.json.devices.map((d) => d.deviceId).sort(), ['DEV-A', 'DEV-B']);
  ok('the 410 device was deleted');

  let hb = await call('POST', `/v1/c/${channelId}/hb`, { secret: pcSecret, body: { offlineAfterSeconds: ALARM_WINDOW } });
  assert.equal(hb.status, 200, hb.text);
  status = await call('GET', `/v1/c/${channelId}`, { secret: pcSecret });
  assert.equal(status.json.alarm.kind, 'offline');
  const expected = await call('POST', `/v1/c/${channelId}/offline-expected`, { secret: pcSecret });
  assert.equal(expected.json.state, 'expected-offline');
  status = await call('GET', `/v1/c/${channelId}`, { secret: pcSecret });
  assert.equal(status.json.alarm.kind, 'purge');
  hb = await call('POST', `/v1/c/${channelId}/hb`, { secret: pcSecret, body: { offlineAfterSeconds: ALARM_WINDOW } });
  assert.equal(hb.json.previousState, 'expected-offline');
  ok('heartbeat and offline-expected move the alarm');

  if (withAlarm) {
    console.log(`… waiting ${ALARM_WINDOW} s for the dead-man alarm`);
    apnsCalls.length = 0;
    await waitFor(() => apnsCalls.length >= 2, (ALARM_WINDOW + 120) * 1000, 'the offline alerts');
    for (const request of apnsCalls) {
      assert.equal(request.json.aps['interruption-level'], 'time-sensitive');
      assert.equal(request.headers['apns-collapse-id'], `${channelId.slice(0, 12)}.offline`);
      verifyJwt(request.headers.authorization);
    }
    const offlineBody = Object.fromEntries(apnsCalls.map((r) => [r.url.split('/').pop(), r.json.o]));
    assert.equal(offlineBody[tokens.A], offline.A);
    assert.equal(offlineBody[tokens.B], offline.B);
    await sleep(1000);
    status = await call('GET', `/v1/c/${channelId}`, { secret: pcSecret });
    assert.equal(status.json.state, 'offline');
    hb = await call('POST', `/v1/c/${channelId}/hb`, { secret: pcSecret });
    assert.equal(hb.json.offlineAlertSent, true);
    ok('the alarm sent the stored offline ciphertexts and the next heartbeat reported it');
  }

  assert.deepEqual((await call('DELETE', `/v1/c/${channelId}`, { secret: pcSecret })).json, { status: 'deleted' });
  assert.equal((await call('POST', `/v1/c/${channelId}/hb`, { secret: pcSecret })).status, 404);
  ok('channel deleted');

  const codes = [];
  for (let i = 0; i < 8; i++) codes.push((await call('POST', '/v1/channels')).status);
  assert.ok(codes.includes(429), `expected a 429 among ${codes.join(',')}`);
  ok('channel creation is rate limited');

  console.log('\nLocal check passed.');
  stop();
  process.exit(0);
} catch (error) {
  console.error(`\nLocal check FAILED: ${error.message}`);
  console.error('--- wrangler output (last lines) ---');
  console.error(output.replace(/\x1b\[[0-9;]*m/g, '').split('\n').slice(-40).join('\n'));
  stop();
  process.exit(1);
}
