import test from 'node:test';
import assert from 'node:assert/strict';
import { createHarness, deviceToken, fakeCiphertext, validate, decodeJwt, verifyJwt, relay, channelModule } from './helpers.js';
import { DurableObject } from './cloudflare-workers-shim.js';
import { createHash } from 'node:crypto';

const { LIMITS } = validate;
const DEVICE_A = '6F1D2C3B-4A59-4E8F-9A0B-1C2D3E4F5A6B';
const DEVICE_B = 'A1B2C3D4-E5F6-4711-8899-AABBCCDDEEFF';

function sha256(text) {
  return createHash('sha256').update(text).digest('hex');
}

// ---------------------------------------------------------------------------
// Module shape
// ---------------------------------------------------------------------------

test('the main module exports only the fetch handler and the Durable Object class', () => {
  // workerd refuses to start when the main module exports anything else
  // ("Incorrect type for map entry ...: not of type 'function or ExportedHandler'").
  assert.deepEqual(Object.keys(relay).sort(), ['Channel', 'default']);
  assert.equal(typeof relay.default.fetch, 'function');
  assert.ok(relay.Channel.prototype instanceof DurableObject, 'Channel extends DurableObject (needed for RPC)');
});

// ---------------------------------------------------------------------------
// Public routes
// ---------------------------------------------------------------------------

test('health reports the protocol and whether APNs is configured', async (t) => {
  const h = createHarness(t);
  const res = await h.request('GET', '/v1/health');
  assert.equal(res.status, 200);
  assert.deepEqual(res.json, { ok: true, service: 'orbit-push-relay', protocol: 1, apns: 'configured' });
  assert.equal(res.headers.get('cache-control'), 'no-store');
  const bare = createHarness(t, { withApns: false });
  assert.equal((await bare.request('GET', '/')).json.apns, 'not_configured');
});

test('unknown routes are 404 and wrong methods are 405 with Allow', async (t) => {
  const h = createHarness(t);
  assert.equal((await h.request('GET', '/v2/whatever')).status, 404);
  assert.equal((await h.request('GET', '/v1/c/0123456789abcdef0123456789abcdef/nope')).status, 404);
  const create = await h.request('GET', '/v1/channels');
  assert.equal(create.status, 405);
  assert.equal(create.headers.get('allow'), 'POST');
  const hb = await h.request('GET', '/v1/c/0123456789abcdef0123456789abcdef/hb');
  assert.equal(hb.status, 405);
  assert.equal(hb.headers.get('allow'), 'POST');
  const device = await h.request('POST', `/v1/c/0123456789abcdef0123456789abcdef/devices/${DEVICE_A}`);
  assert.equal(device.headers.get('allow'), 'PUT, DELETE');
  assert.equal((await h.request('POST', '/v1/health')).status, 405);
  assert.equal(h.ns.objects.size, 0, 'none of this touched a Durable Object');
});

test('plain HTTP is refused for secret-bearing routes (except localhost)', async (t) => {
  const h = createHarness(t);
  const res = await h.request('POST', '/v1/channels', { base: 'http://relay.example.workers.dev' });
  assert.equal(res.status, 426);
  assert.equal(res.json.error, 'https_required');
  assert.equal(h.ns.objects.size, 0);
  const local = await h.request('POST', '/v1/channels', { base: 'http://localhost:8787' });
  assert.equal(local.status, 201);
  assert.equal((await h.request('GET', '/v1/health', { base: 'http://relay.example.workers.dev' })).status, 200);
});

// ---------------------------------------------------------------------------
// Channel creation
// ---------------------------------------------------------------------------

test('creating a channel returns an id and secret; only the hash is stored', async (t) => {
  const h = createHarness(t);
  const res = await h.request('POST', '/v1/channels');
  assert.equal(res.status, 201);
  const { channelId, pcSecret, heartbeatSeconds, offlineAfterSeconds } = res.json;
  assert.match(channelId, /^[0-9a-f]{32}$/);
  assert.match(pcSecret, /^[A-Za-z0-9_-]{43}$/);
  assert.equal(heartbeatSeconds, 300);
  assert.equal(offlineAfterSeconds, 900);
  assert.equal(res.headers.get('cache-control'), 'no-store');

  const storage = h.ns.storage(channelId);
  const meta = storage.data.get('meta');
  assert.equal(meta.secretHash, sha256(pcSecret));
  assert.equal(meta.state, 'new');
  assert.ok(!JSON.stringify([...storage.data.values()]).includes(pcSecret), 'the secret itself is never stored');
  // A channel that never sends a heartbeat is purged after 7 days.
  assert.equal(storage.alarmAt, h.clock.now + 7 * 24 * 3600 * 1000);

  const other = await h.createChannel();
  assert.notEqual(other.channelId, channelId);
  assert.notEqual(other.pcSecret, pcSecret);
});

test('channel creation accepts an empty or {} body and rejects junk', async (t) => {
  const h = createHarness(t);
  assert.equal((await h.request('POST', '/v1/channels', { body: {} })).status, 201);
  assert.equal((await h.request('POST', '/v1/channels', { raw: 'not json' })).status, 400);
  assert.equal((await h.request('POST', '/v1/channels', { body: [1, 2] })).status, 400);
  assert.equal((await h.request('POST', '/v1/channels', { raw: 'x'.repeat(2000) })).status, 413);
});

test('channel creation is rate limited per IP (memory fallback)', async (t) => {
  const h = createHarness(t);
  for (let i = 0; i < 5; i++) assert.equal((await h.request('POST', '/v1/channels')).status, 201);
  const limited = await h.request('POST', '/v1/channels');
  assert.equal(limited.status, 429);
  assert.equal(limited.json.error, 'rate_limited');
  assert.equal(limited.headers.get('retry-after'), '60');
  assert.equal((await h.request('POST', '/v1/channels', { ip: '198.51.100.1' })).status, 201, 'other addresses are not affected');
});

test('channel creation uses the CREATE_LIMITER binding when present', async (t) => {
  const keys = [];
  let allow = true;
  const h = createHarness(t, {
    env: { CREATE_LIMITER: { limit: async ({ key }) => (keys.push(key), { success: allow }) } },
  });
  assert.equal((await h.request('POST', '/v1/channels', { ip: '192.0.2.44' })).status, 201);
  assert.deepEqual(keys, ['192.0.2.44']);
  allow = false;
  assert.equal((await h.request('POST', '/v1/channels', { ip: '192.0.2.44' })).status, 429);
  const objectsBefore = h.ns.objects.size;
  assert.equal(objectsBefore, 1, 'a rate-limited request creates no channel');
});

test('a failing rate limiter binding fails open', async (t) => {
  const h = createHarness(t, {
    env: { CREATE_LIMITER: { limit: async () => { throw new Error('limiter down'); } } },
  });
  assert.equal((await h.request('POST', '/v1/channels')).status, 201);
});

test('channel routes are rate limited per IP through API_LIMITER', async (t) => {
  let allow = true;
  const h = createHarness(t, { env: { API_LIMITER: { limit: async () => ({ success: allow }) } } });
  const channel = await h.createChannel();
  assert.equal((await h.heartbeat(channel)).status, 200);
  allow = false;
  const res = await h.heartbeat(channel);
  assert.equal(res.status, 429);
  assert.equal(res.json.retryAfterSeconds, 60);
});

// ---------------------------------------------------------------------------
// Authentication
// ---------------------------------------------------------------------------

test('auth failures: missing, malformed, wrong secret, unknown channel', async (t) => {
  const h = createHarness(t);
  const channel = await h.createChannel();
  const other = await h.createChannel();
  const path = `/v1/c/${channel.channelId}`;
  const requestsBefore = h.ns.stubRequests;

  const missing = await h.request('GET', path);
  assert.equal(missing.status, 401);
  assert.equal(missing.json.error, 'unauthorized');
  assert.equal(missing.headers.get('www-authenticate'), 'Bearer');
  assert.equal((await h.request('GET', path, { headers: { authorization: `Basic ${channel.pcSecret}` } })).status, 401);
  assert.equal((await h.request('GET', path, { headers: { authorization: 'Bearer short' } })).status, 401);
  assert.equal((await h.request('GET', path, { headers: { authorization: `Bearer ${channel.pcSecret}x` } })).status, 401);
  assert.equal(h.ns.stubRequests, requestsBefore, 'malformed credentials never reach the Durable Object');

  const wrong = await h.request('GET', path, { secret: other.pcSecret });
  assert.equal(wrong.status, 401);
  assert.equal(wrong.json.error, 'unauthorized');

  const flipped = channel.pcSecret.slice(0, -1) + (channel.pcSecret.endsWith('A') ? 'B' : 'A');
  assert.equal((await h.request('POST', `${path}/hb`, { secret: flipped })).status, 401);

  const unknown = await h.request('GET', '/v1/c/ffffffffffffffffffffffffffffffff', { secret: channel.pcSecret });
  assert.equal(unknown.status, 404);
  assert.equal(unknown.json.error, 'channel_not_found');
  assert.equal(h.ns.storage('ffffffffffffffffffffffffffffffff').data.size, 0, 'probing an id stores nothing');

  const before = h.ns.stubRequests;
  const badId = await h.request('GET', '/v1/c/NOT-A-CHANNEL', { secret: channel.pcSecret });
  assert.equal(badId.status, 404);
  assert.equal(h.ns.stubRequests, before, 'malformed channel ids never reach a Durable Object');

  // Bearer scheme is case-insensitive.
  assert.equal((await h.request('GET', path, { headers: { authorization: `bearer ${channel.pcSecret}` } })).status, 200);
});

test('every channel route requires the secret', async (t) => {
  const h = createHarness(t);
  const channel = await h.createChannel();
  const base = `/v1/c/${channel.channelId}`;
  const routes = [
    ['GET', base],
    ['DELETE', base],
    ['PUT', `${base}/devices/${DEVICE_A}`, { token: deviceToken(), env: 'sandbox' }],
    ['DELETE', `${base}/devices/${DEVICE_A}`],
    ['POST', `${base}/notify`, { items: { [DEVICE_A]: fakeCiphertext() } }],
    ['POST', `${base}/hb`],
    ['POST', `${base}/offline-expected`],
  ];
  for (const [method, path, body] of routes) {
    const res = await h.request(method, path, { body });
    assert.equal(res.status, 401, `${method} ${path}`);
  }
  assert.equal(h.fetchMock.calls.length, 0);
});

// ---------------------------------------------------------------------------
// Devices
// ---------------------------------------------------------------------------

test('device CRUD: register, update, list, delete', async (t) => {
  const h = createHarness(t);
  const channel = await h.createChannel();
  const tokenA = deviceToken();
  const offlineA = fakeCiphertext();

  const created = await h.putDevice(channel, DEVICE_A, { token: tokenA.toUpperCase(), env: 'sandbox', offlineCt: offlineA });
  assert.equal(created.status, 200);
  assert.deepEqual(created.json, { status: 'registered', created: true, hasOfflineCiphertext: true, replaced: [] });
  const stored = h.ns.storage(channel.channelId).data.get(`device:${DEVICE_A}`);
  assert.equal(stored.token, tokenA, 'tokens are stored lower-case');
  assert.equal(stored.offlineCt, offlineA);

  h.advance(60_000);
  const updated = await h.putDevice(channel, DEVICE_A, { token: tokenA, env: 'sandbox' });
  assert.equal(updated.json.created, false);
  assert.equal(updated.json.hasOfflineCiphertext, true, 'omitting offlineCt keeps the stored one');

  await h.putDevice(channel, DEVICE_B, { token: deviceToken(), env: 'production', offlineCt: null });

  const status = await h.status(channel);
  assert.equal(status.status, 200);
  assert.equal(status.json.channelId, channel.channelId);
  assert.equal(status.json.state, 'new');
  assert.equal(status.json.maxDevices, LIMITS.maxDevicesPerChannel);
  const devices = Object.fromEntries(status.json.devices.map((d) => [d.deviceId, d]));
  assert.deepEqual(Object.keys(devices).sort(), [DEVICE_A, DEVICE_B].sort());
  assert.equal(devices[DEVICE_A].env, 'sandbox');
  assert.equal(devices[DEVICE_A].hasOfflineCiphertext, true);
  assert.equal(devices[DEVICE_A].registeredAt, '2026-10-23T18:00:00Z');
  assert.equal(devices[DEVICE_A].updatedAt, '2026-10-23T18:01:00Z');
  assert.equal(devices[DEVICE_A].lastDeliveryAt, null);
  assert.equal(devices[DEVICE_B].hasOfflineCiphertext, false);
  assert.ok(!status.text.includes(tokenA), 'status never echoes device tokens');
  assert.ok(!status.text.includes(offlineA), 'or ciphertexts');

  const cleared = await h.putDevice(channel, DEVICE_A, { token: tokenA, env: 'sandbox', offlineCt: null });
  assert.equal(cleared.json.hasOfflineCiphertext, false, 'offlineCt: null removes it');

  const del = await h.request('DELETE', `/v1/c/${channel.channelId}/devices/${DEVICE_A}`, { secret: channel.pcSecret });
  assert.deepEqual(del.json, { status: 'deleted', existed: true });
  const again = await h.request('DELETE', `/v1/c/${channel.channelId}/devices/${DEVICE_A}`, { secret: channel.pcSecret });
  assert.equal(again.status, 200);
  assert.deepEqual(again.json, { status: 'deleted', existed: false });
  assert.deepEqual((await h.status(channel)).json.devices.map((d) => d.deviceId), [DEVICE_B]);
});

test('device registration validates every field', async (t) => {
  const h = createHarness(t);
  const channel = await h.createChannel();
  const token = deviceToken();
  const bad = [
    [{ env: 'sandbox' }, /token/],
    [{ token: 'xyz', env: 'sandbox' }, /token/],
    [{ token: token.slice(0, 62), env: 'sandbox' }, /token/],
    [{ token: `${token}a`, env: 'sandbox' }, /token/],
    [{ token, env: 'development' }, /env/],
    [{ token, env: 'sandbox', offlineCt: 'not base64!' }, /offlineCt/],
    [{ token, env: 'sandbox', offlineCt: 'QUJD' }, /too short/],
    [{ token, env: 'sandbox', offlineCt: 'A'.repeat(LIMITS.maxCiphertextChars + 4) }, /too long/],
    [{ token, env: 'sandbox', offlineCt: 42 }, /offlineCt/],
    [{ token, env: 'sandbox', reregistered: 'yes' }, /reregistered/],
  ];
  for (const [body, pattern] of bad) {
    const res = await h.putDevice(channel, DEVICE_A, body);
    assert.equal(res.status, 400, JSON.stringify(body).slice(0, 80));
    assert.equal(res.json.error, 'bad_request');
    assert.match(res.json.message, pattern);
  }
  const noBody = await h.request('PUT', `/v1/c/${channel.channelId}/devices/${DEVICE_A}`, { secret: channel.pcSecret });
  assert.equal(noBody.status, 400);
  const badJson = await h.request('PUT', `/v1/c/${channel.channelId}/devices/${DEVICE_A}`, { secret: channel.pcSecret, raw: '{' });
  assert.equal(badJson.status, 400);
  const badId = await h.putDevice(channel, '-starts-with-dash', { token, env: 'sandbox' });
  assert.equal(badId.status, 400);
  const longId = await h.putDevice(channel, 'a'.repeat(65), { token, env: 'sandbox' });
  assert.equal(longId.status, 400);
  const huge = await h.request('PUT', `/v1/c/${channel.channelId}/devices/${DEVICE_A}`, {
    secret: channel.pcSecret,
    raw: JSON.stringify({ token, env: 'sandbox', padding: 'x'.repeat(LIMITS.bodyBytes.device) }),
  });
  assert.equal(huge.status, 413);
  assert.equal((await h.status(channel)).json.devices.length, 0);
});

test('a channel holds at most 20 devices', async (t) => {
  const h = createHarness(t);
  const channel = await h.createChannel();
  for (let i = 0; i < LIMITS.maxDevicesPerChannel; i++) {
    assert.equal((await h.putDevice(channel, `device-${i}`, { token: deviceToken(), env: 'production' })).status, 200);
  }
  const over = await h.putDevice(channel, 'device-extra', { token: deviceToken(), env: 'production' });
  assert.equal(over.status, 409);
  assert.equal(over.json.error, 'device_limit');
  // Updating an existing device still works at the limit.
  assert.equal((await h.putDevice(channel, 'device-3', { token: deviceToken(), env: 'sandbox' })).status, 200);
});

test('re-registering the same APNs token under a new deviceId replaces the old one', async (t) => {
  const h = createHarness(t);
  const channel = await h.createChannel();
  const token = deviceToken();
  await h.putDevice(channel, DEVICE_A, { token, env: 'production', offlineCt: fakeCiphertext() });
  const res = await h.putDevice(channel, DEVICE_B, { token, env: 'production', offlineCt: fakeCiphertext() });
  assert.deepEqual(res.json.replaced, [DEVICE_A]);
  assert.deepEqual((await h.status(channel)).json.devices.map((d) => d.deviceId), [DEVICE_B]);
});

// ---------------------------------------------------------------------------
// Notify
// ---------------------------------------------------------------------------

test('notify fans out one push per device with its own ciphertext and host', async (t) => {
  const h = createHarness(t);
  const channel = await h.createChannel();
  const tokenA = deviceToken();
  const tokenB = deviceToken();
  await h.putDevice(channel, DEVICE_A, { token: tokenA, env: 'sandbox' });
  await h.putDevice(channel, DEVICE_B, { token: tokenB, env: 'production' });
  const ctA = fakeCiphertext();
  const ctB = fakeCiphertext();

  const res = await h.notify(channel, {
    items: { [DEVICE_A]: ctA, [DEVICE_B]: ctB },
    level: 'timeSensitive',
    collapseId: 'c.Xq3v9TzL0bWk2dPa',
    ttl: 600,
  });
  assert.equal(res.status, 200);
  assert.equal(res.json.sent, 2);
  assert.equal(res.json.failed, 0);
  assert.equal(res.json.results[DEVICE_A].status, 'sent');
  assert.match(res.json.results[DEVICE_B].apnsId, /^apns-\d$/);

  assert.equal(h.fetchMock.calls.length, 2);
  const byUrl = Object.fromEntries(h.fetchMock.calls.map((c) => [c.url, c]));
  const callA = byUrl[`https://api.sandbox.push.apple.com/3/device/${tokenA}`];
  const callB = byUrl[`https://api.push.apple.com/3/device/${tokenB}`];
  assert.ok(callA && callB, 'sandbox device -> sandbox host, production device -> production host');
  assert.equal(callA.json.o, ctA);
  assert.equal(callB.json.o, ctB);
  for (const call of [callA, callB]) {
    assert.deepEqual(call.json.aps, {
      alert: { title: 'Orbit', body: 'New alert from your PC' },
      'mutable-content': 1,
      sound: 'default',
      'interruption-level': 'time-sensitive',
      'thread-id': channel.channelId,
    });
    assert.equal(call.json.v, 1);
    assert.equal(call.headers['apns-priority'], '10');
    assert.equal(call.headers['apns-expiration'], String(Math.floor(h.clock.now / 1000) + 600));
    assert.equal(call.headers['apns-collapse-id'], `${channel.channelId.slice(0, 12)}.c.Xq3v9TzL0bWk2dPa`);
    assert.equal(call.headers['apns-topic'], 'com.dimitrie.orbit');
    const jwt = call.headers.authorization.slice('bearer '.length);
    assert.ok(verifyJwt(jwt, h.key.publicKey));
    assert.equal(decodeJwt(jwt).claims.iss, 'TEAM123456');
  }

  const devices = (await h.status(channel)).json.devices;
  assert.ok(devices.every((d) => d.lastDeliveryAt === '2026-10-23T18:00:00Z' && d.lastError === null));
});

test('notify defaults: active level, priority 10, one hour TTL, no collapse id', async (t) => {
  const h = createHarness(t);
  const channel = await h.createChannel();
  await h.putDevice(channel, DEVICE_A, { token: deviceToken(), env: 'production' });
  await h.notify(channel, { items: { [DEVICE_A]: fakeCiphertext() } });
  const call = h.fetchMock.calls[0];
  assert.equal(call.json.aps['interruption-level'], 'active');
  assert.equal(call.headers['apns-priority'], '10');
  assert.equal(call.headers['apns-expiration'], String(Math.floor(h.clock.now / 1000) + 3600));
  assert.equal(call.headers['apns-collapse-id'], undefined);

  h.fetchMock.reset();
  await h.notify(channel, { items: { [DEVICE_A]: fakeCiphertext() }, level: 'passive', ttl: 0 });
  assert.equal(h.fetchMock.calls[0].json.aps['interruption-level'], 'passive');
  assert.equal(h.fetchMock.calls[0].headers['apns-priority'], '5');
  assert.equal(h.fetchMock.calls[0].headers['apns-expiration'], '0');
});

test('two PCs never share a collapse id on the same phone', async (t) => {
  const h = createHarness(t);
  const token = deviceToken();
  const pcs = [await h.createChannel(), await h.createChannel()];
  for (const pc of pcs) {
    await h.putDevice(pc, DEVICE_A, { token, env: 'production' });
    await h.notify(pc, { items: { [DEVICE_A]: fakeCiphertext() }, collapseId: 'offline' });
  }
  const ids = h.fetchMock.calls.map((c) => c.headers['apns-collapse-id']);
  assert.equal(new Set(ids).size, 2);
  assert.ok(ids.every((id) => new TextEncoder().encode(id).length <= 64));
});

test('notify validates items, level, collapseId, ttl and sizes', async (t) => {
  const h = createHarness(t);
  const channel = await h.createChannel();
  await h.putDevice(channel, DEVICE_A, { token: deviceToken(), env: 'production' });
  const ct = fakeCiphertext();
  const tooMany = Object.fromEntries(Array.from({ length: LIMITS.maxDevicesPerChannel + 1 }, (_, i) => [`d${i}`, ct]));
  const bad = [
    {},
    { items: [] },
    { items: {} },
    { items: tooMany },
    { items: { [DEVICE_A]: 'A'.repeat(LIMITS.maxCiphertextChars + 4) } },
    { items: { [DEVICE_A]: 'bad base64?' } },
    { items: { 'bad id!': ct } },
    { items: { [DEVICE_A]: ct }, level: 'critical' },
    { items: { [DEVICE_A]: ct }, level: 'TIMESENSITIVE' },
    { items: { [DEVICE_A]: ct }, collapseId: 'x'.repeat(LIMITS.maxCollapseIdChars + 1) },
    { items: { [DEVICE_A]: ct }, collapseId: 'has space' },
    { items: { [DEVICE_A]: ct }, collapseId: '' },
    { items: { [DEVICE_A]: ct }, ttl: -1 },
    { items: { [DEVICE_A]: ct }, ttl: LIMITS.maxTtlSeconds + 1 },
    { items: { [DEVICE_A]: ct }, ttl: 1.5 },
    { items: { [DEVICE_A]: ct }, ttl: '60' },
  ];
  for (const body of bad) {
    const res = await h.notify(channel, body);
    assert.equal(res.status, 400, JSON.stringify(body).slice(0, 100));
    assert.equal(res.json.error, 'bad_request');
  }
  const maxCt = 'A'.repeat(LIMITS.maxCiphertextChars);
  const ok = await h.notify(channel, { items: { [DEVICE_A]: maxCt }, level: 'time-sensitive', collapseId: 'x'.repeat(48), ttl: LIMITS.maxTtlSeconds });
  assert.equal(ok.status, 200, 'the largest allowed values are accepted');
  assert.equal(ok.json.sent, 1);

  const huge = await h.request('POST', `/v1/c/${channel.channelId}/notify`, {
    secret: channel.pcSecret,
    raw: JSON.stringify({ items: { [DEVICE_A]: ct }, padding: 'x'.repeat(LIMITS.bodyBytes.notify) }),
  });
  assert.equal(huge.status, 413);
  assert.equal(huge.json.error, 'payload_too_large');
  assert.equal(h.fetchMock.calls.length, 1, 'only the valid request reached APNs');
});

test('notify reports devices the relay does not know', async (t) => {
  const h = createHarness(t);
  const channel = await h.createChannel();
  await h.putDevice(channel, DEVICE_A, { token: deviceToken(), env: 'production' });
  const res = await h.notify(channel, { items: { [DEVICE_A]: fakeCiphertext(), [DEVICE_B]: fakeCiphertext() } });
  assert.equal(res.status, 200);
  assert.deepEqual(res.json.results[DEVICE_B], { status: 'unknown_device', retryable: false });
  assert.equal(res.json.sent, 1);
  assert.equal(res.json.failed, 1);
  assert.equal(h.fetchMock.calls.length, 1);
});

test('410 from APNs deletes the device', async (t) => {
  const h = createHarness(t);
  const channel = await h.createChannel();
  const tokenA = deviceToken();
  await h.putDevice(channel, DEVICE_A, { token: tokenA, env: 'production', offlineCt: fakeCiphertext() });
  await h.putDevice(channel, DEVICE_B, { token: deviceToken(), env: 'production' });
  h.fetchMock.respond((call) => (call.url.endsWith(tokenA) ? { status: 410, reason: 'Unregistered' } : { status: 200 }));

  const res = await h.notify(channel, { items: { [DEVICE_A]: fakeCiphertext(), [DEVICE_B]: fakeCiphertext() } });
  assert.deepEqual(res.json.results[DEVICE_A], { status: 'unregistered', apnsStatus: 410, reason: 'Unregistered', retryable: false });
  assert.equal(res.json.results[DEVICE_B].status, 'sent');
  assert.equal(h.ns.storage(channel.channelId).data.has(`device:${DEVICE_A}`), false);
  assert.deepEqual((await h.status(channel)).json.devices.map((d) => d.deviceId), [DEVICE_B]);

  h.fetchMock.reset();
  const next = await h.notify(channel, { items: { [DEVICE_A]: fakeCiphertext() } });
  assert.equal(next.json.results[DEVICE_A].status, 'unknown_device');
  assert.equal(h.fetchMock.calls.length, 0);
});

test('a token APNs unregistered cannot be re-registered unless the phone registered again', async (t) => {
  const h = createHarness(t);
  const channel = await h.createChannel();
  const tokenA = deviceToken();
  await h.putDevice(channel, DEVICE_A, { token: tokenA, env: 'production', offlineCt: fakeCiphertext() });
  h.fetchMock.respond(() => ({ status: 410, reason: 'Unregistered' }));
  await h.notify(channel, { items: { [DEVICE_A]: fakeCiphertext() } });
  const storage = h.ns.storage(channel.channelId);
  assert.ok(![...storage.data.values()].some((v) => JSON.stringify(v).includes(tokenA)), 'only a hash of the dead token is kept');

  let status = (await h.status(channel)).json;
  assert.deepEqual(status.devices, []);
  assert.deepEqual(status.unregisteredDevices, [{ deviceId: DEVICE_A, unregisteredAt: '2026-10-23T18:00:00Z' }]);

  // The agent restarts and PUTs every device it knows: refused, no loop.
  h.advance(60 * 60 * 1000);
  const again = await h.putDevice(channel, DEVICE_A, { token: tokenA.toUpperCase(), env: 'production', offlineCt: fakeCiphertext() });
  assert.equal(again.status, 410);
  assert.equal(again.json.error, 'token_unregistered');
  assert.equal(again.json.unregisteredAt, '2026-10-23T18:00:00Z');
  // Under another deviceId too (it is the token that is dead).
  assert.equal((await h.putDevice(channel, DEVICE_B, { token: tokenA, env: 'production' })).status, 410);
  assert.equal((await h.status(channel)).json.devices.length, 0);

  // A new token for the same device is fine (the app was reinstalled).
  assert.equal((await h.putDevice(channel, DEVICE_B, { token: deviceToken(), env: 'production' })).status, 200);

  // The phone registers the old token again with the agent.
  const back = await h.putDevice(channel, DEVICE_A, { token: tokenA, env: 'production', reregistered: true });
  assert.equal(back.status, 200);
  assert.equal(back.json.created, true);
  status = (await h.status(channel)).json;
  assert.deepEqual(status.unregisteredDevices, []);
  assert.equal((await h.putDevice(channel, DEVICE_A, { token: tokenA, env: 'production' })).status, 200, 'the memory was cleared');
});

test('remembered 410s expire after 30 days and are capped per channel', async (t) => {
  const h = createHarness(t);
  const channel = await h.createChannel();
  const storage = h.ns.storage(channel.channelId);
  const goneCount = () => [...storage.data.keys()].filter((k) => k.startsWith('gone:')).length;
  h.fetchMock.respond(() => ({ status: 410, reason: 'Unregistered' }));
  const firstToken = deviceToken();
  await h.putDevice(channel, 'first', { token: firstToken, env: 'production' });
  await h.notify(channel, { items: { first: fakeCiphertext() } });
  assert.equal(goneCount(), 1);

  // Two full batches of 20 more dead devices: 41 remembered -> capped at 40,
  // and the oldest one goes first.
  for (let batch = 0; batch < 2; batch++) {
    h.advance(60_000);
    const items = {};
    for (let i = 0; i < LIMITS.maxDevicesPerChannel; i++) {
      const id = `b${batch}-${i}`;
      await h.putDevice(channel, id, { token: deviceToken(), env: 'production' });
      items[id] = fakeCiphertext();
    }
    await h.notify(channel, { items });
  }
  assert.equal(goneCount(), channelModule.CHANNEL_CONSTANTS.MAX_UNREGISTERED);
  assert.equal((await h.putDevice(channel, 'first', { token: firstToken, env: 'production' })).status, 200, 'the oldest was dropped');

  // 31 days later every entry has expired.
  const deadToken = deviceToken();
  await h.putDevice(channel, 'late', { token: deadToken, env: 'production' });
  await h.notify(channel, { items: { late: fakeCiphertext() } });
  assert.equal((await h.putDevice(channel, 'late', { token: deadToken, env: 'production' })).status, 410);
  h.advance(31 * 24 * 60 * 60 * 1000);
  assert.deepEqual((await h.status(channel)).json.unregisteredDevices, []);
  assert.equal((await h.putDevice(channel, 'late', { token: deadToken, env: 'production' })).status, 200);
});

test('retryable and permanent APNs failures are reported per device and recorded', async (t) => {
  const h = createHarness(t);
  const channel = await h.createChannel();
  const tokenA = deviceToken();
  await h.putDevice(channel, DEVICE_A, { token: tokenA, env: 'production' });
  await h.putDevice(channel, DEVICE_B, { token: deviceToken(), env: 'sandbox' });
  h.fetchMock.respond((call) =>
    call.url.endsWith(tokenA) ? { status: 503, reason: 'ServiceUnavailable' } : { status: 400, reason: 'BadDeviceToken' },
  );
  const res = await h.notify(channel, { items: { [DEVICE_A]: fakeCiphertext(), [DEVICE_B]: fakeCiphertext() } });
  assert.deepEqual(res.json.results[DEVICE_A], { status: 'failed', apnsStatus: 503, reason: 'ServiceUnavailable', retryable: true });
  assert.deepEqual(res.json.results[DEVICE_B], { status: 'failed', apnsStatus: 400, reason: 'BadDeviceToken', retryable: false });
  assert.equal(res.json.sent, 0);
  assert.equal(res.json.failed, 2);
  const devices = Object.fromEntries((await h.status(channel)).json.devices.map((d) => [d.deviceId, d]));
  assert.equal(devices[DEVICE_A].lastError, 'ServiceUnavailable');
  assert.equal(devices[DEVICE_B].lastError, 'BadDeviceToken');
  assert.equal(devices[DEVICE_B].lastErrorAt, '2026-10-23T18:00:00Z');
});

test('notify answers within its deadline even when APNs is slow', async (t) => {
  const h = createHarness(t);
  const channel = await h.createChannel();
  await h.putDevice(channel, DEVICE_A, { token: deviceToken(), env: 'production' });
  const wall = { now: 5_000_000 };
  h.ns.entry(channel.channelId).instance.deadlineClock = () => wall.now;
  h.fetchMock.respond(() => {
    wall.now += 19_000; // a slow APNs answer
    return { status: 403, reason: 'ExpiredProviderToken' };
  });
  const res = await h.notify(channel, { items: { [DEVICE_A]: fakeCiphertext() }, collapseId: 'c.Xq3v9TzL0bWk2dPa' });
  assert.equal(res.status, 200);
  assert.deepEqual(res.json.results[DEVICE_A], { status: 'failed', apnsStatus: 403, reason: 'ExpiredProviderToken', retryable: true });
  assert.equal(h.fetchMock.calls.length, 1, 'the token retry did not push the answer past the 20 s budget');
  assert.equal(channelModule.CHANNEL_CONSTANTS.NOTIFY_DEADLINE_MS, 20_000);
});

test('notify without APNs secrets answers 503 and calls nobody', async (t) => {
  const h = createHarness(t, { withApns: false });
  const channel = await h.createChannel();
  await h.putDevice(channel, DEVICE_A, { token: deviceToken(), env: 'production' });
  const res = await h.notify(channel, { items: { [DEVICE_A]: fakeCiphertext() } });
  assert.equal(res.status, 503);
  assert.equal(res.json.error, 'apns_not_configured');
  assert.equal(h.fetchMock.calls.length, 0);
});

test('notify with an unusable APNs key answers 503', async (t) => {
  const h = createHarness(t, { env: { APNS_KEY_P8: 'AAAABBBBCCCC' } });
  const channel = await h.createChannel();
  await h.putDevice(channel, DEVICE_A, { token: deviceToken(), env: 'production' });
  const res = await h.notify(channel, { items: { [DEVICE_A]: fakeCiphertext() } });
  assert.equal(res.status, 503);
  assert.equal(res.json.error, 'apns_not_configured');
  assert.equal(h.fetchMock.calls.length, 0);
});

test('a device deleted while its push is in flight is not brought back', async (t) => {
  const h = createHarness(t);
  const channel = await h.createChannel();
  await h.putDevice(channel, DEVICE_A, { token: deviceToken(), env: 'production' });
  h.fetchMock.respond(async () => {
    const del = await h.request('DELETE', `/v1/c/${channel.channelId}/devices/${DEVICE_A}`, { secret: channel.pcSecret });
    assert.equal(del.json.existed, true);
    return { status: 200 };
  });
  const res = await h.notify(channel, { items: { [DEVICE_A]: fakeCiphertext() } });
  assert.equal(res.json.results[DEVICE_A].status, 'sent');
  assert.equal(h.ns.storage(channel.channelId).data.has(`device:${DEVICE_A}`), false);
});

// ---------------------------------------------------------------------------
// Channel deletion and privacy
// ---------------------------------------------------------------------------

test('DELETE channel wipes devices, ciphertexts and the alarm', async (t) => {
  const h = createHarness(t);
  const channel = await h.createChannel();
  await h.putDevice(channel, DEVICE_A, { token: deviceToken(), env: 'production', offlineCt: fakeCiphertext() });
  await h.heartbeat(channel);
  const res = await h.request('DELETE', `/v1/c/${channel.channelId}`, { secret: channel.pcSecret });
  assert.deepEqual(res.json, { status: 'deleted' });
  const storage = h.ns.storage(channel.channelId);
  assert.equal(storage.data.size, 0);
  assert.equal(storage.alarmAt, null);
  assert.equal((await h.heartbeat(channel)).status, 404);
  assert.equal((await h.status(channel)).json.error, 'channel_not_found');
});

test('logs never contain device tokens, ciphertexts or secrets', async (t) => {
  const h = createHarness(t);
  const channel = await h.createChannel();
  const token = deviceToken();
  const offline = fakeCiphertext();
  const event = fakeCiphertext();
  await h.putDevice(channel, DEVICE_A, { token, env: 'production', offlineCt: offline });
  h.fetchMock.respond(() => ({ status: 400, reason: 'BadDeviceToken' }));
  await h.notify(channel, { items: { [DEVICE_A]: event } });
  await h.heartbeat(channel);
  h.advance(16 * 60 * 1000);
  await h.ns.fireAlarm(channel.channelId);
  const output = h.logs.join('\n');
  assert.ok(h.logs.length > 0, 'something was logged');
  for (const secret of [token, offline, event, channel.pcSecret]) assert.ok(!output.includes(secret));
});

test('state survives the Durable Object being evicted from memory', async (t) => {
  const h = createHarness(t);
  const channel = await h.createChannel();
  await h.putDevice(channel, DEVICE_A, { token: deviceToken(), env: 'production' });
  h.ns.evict(channel.channelId);
  assert.equal((await h.status(channel)).json.devices.length, 1);
  h.ns.evict(channel.channelId);
  assert.equal((await h.request('GET', `/v1/c/${channel.channelId}`, { secret: (await h.createChannel()).pcSecret })).status, 401);
});
