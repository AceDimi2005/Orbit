import test from 'node:test';
import assert from 'node:assert/strict';
import {
  apns,
  captureConsole,
  createSigningKey,
  decodeJwt,
  deviceToken,
  fakeCiphertext,
  installFetchMock,
  verifyJwt,
  START_TIME,
  MINUTE,
} from './helpers.js';

const {
  apnsConfig,
  buildAlertPayload,
  providerToken,
  providerTokenIssuedAt,
  sendAlert,
  pemToDer,
  ApnsConfigError,
  resetApnsState,
  JWT_REFRESH_SECONDS,
} = apns;

function setup(t, extraEnv = {}) {
  resetApnsState();
  captureConsole(t);
  const key = createSigningKey();
  const env = { APNS_KEY_P8: key.pem, APNS_KEY_ID: 'KEY1234567', APNS_TEAM_ID: 'TEAM123456', ...extraEnv };
  const fetchMock = installFetchMock();
  t.after(() => fetchMock.restore());
  const clock = { now: START_TIME };
  return { key, env, config: apnsConfig(env), fetchMock, clock, now: () => clock.now };
}

function message(overrides = {}) {
  return {
    token: deviceToken(),
    environment: 'production',
    ciphertext: fakeCiphertext(),
    level: 'active',
    threadId: '0123456789abcdef0123456789abcdef',
    priority: 10,
    expiration: Math.floor(START_TIME / 1000) + 3600,
    ...overrides,
  };
}

test('payload is exactly the generic alert plus the ciphertext', () => {
  const payload = buildAlertPayload({ ciphertext: 'Q0lQSEVSVEVYVA==', level: 'time-sensitive', threadId: 'thread-1' });
  assert.equal(
    JSON.stringify(payload),
    JSON.stringify({
      aps: {
        alert: { title: 'Orbit', body: 'New alert from your PC' },
        'mutable-content': 1,
        sound: 'default',
        'interruption-level': 'time-sensitive',
        'thread-id': 'thread-1',
      },
      o: 'Q0lQSEVSVEVYVA==',
      v: 1,
    }),
  );
});

test('apnsConfig needs all three secrets and defaults the topic', () => {
  assert.equal(apnsConfig({}), null);
  assert.equal(apnsConfig({ APNS_KEY_P8: 'x', APNS_KEY_ID: 'y' }), null);
  assert.equal(apnsConfig({ APNS_KEY_P8: 'x', APNS_TEAM_ID: 'z' }), null);
  const config = apnsConfig({ APNS_KEY_P8: ' x ', APNS_KEY_ID: ' KID ', APNS_TEAM_ID: 'TEAM' });
  assert.equal(config.topic, 'com.dimitrie.orbit');
  assert.equal(config.keys.production.keyId, 'KID');
  assert.equal(config.keys.sandbox, config.keys.production, 'the sandbox reuses the key unless a sandbox key is set');
  const split = apnsConfig({
    APNS_KEY_P8: 'x',
    APNS_KEY_ID: 'KID',
    APNS_TEAM_ID: 'TEAM',
    APNS_SANDBOX_KEY_P8: 's',
    APNS_SANDBOX_KEY_ID: 'SKID',
    APNS_TOPIC: 'com.example.other',
  });
  assert.equal(split.keys.sandbox.keyId, 'SKID');
  assert.equal(split.topic, 'com.example.other');
});

test('the provider token is an ES256 JWT that node:crypto verifies', async (t) => {
  const { key, config, now } = setup(t);
  const jwt = await providerToken(config, 'production', { now });
  const { header, claims, signature } = decodeJwt(jwt);
  assert.deepEqual(header, { alg: 'ES256', kid: 'KEY1234567' });
  assert.deepEqual(claims, { iss: 'TEAM123456', iat: Math.floor(START_TIME / 1000) });
  assert.equal(signature.length, 64, 'raw r||s, not DER');
  assert.ok(verifyJwt(jwt, key.publicKey), 'signature verifies with the public key');
  assert.ok(!verifyJwt(jwt, createSigningKey().publicKey), 'and not with another key');
});

test('the provider token is kept for its 30-minute window, then rebuilt', async (t) => {
  const { key, config, clock, now } = setup(t);
  assert.equal(JWT_REFRESH_SECONDS, 30 * 60);
  // START_TIME is 18:00:00 UTC, the start of a window.
  const first = await providerToken(config, 'production', { now });
  assert.equal(decodeJwt(first).claims.iat, START_TIME / 1000);
  clock.now += 29 * MINUTE + 59 * 1000;
  assert.equal(await providerToken(config, 'production', { now }), first, 'reused within the window');
  clock.now += 1000; // 18:30:00
  const second = await providerToken(config, 'production', { now });
  assert.notEqual(second, first);
  assert.equal(decodeJwt(second).claims.iat, START_TIME / 1000 + 30 * 60);
  assert.ok(verifyJwt(second, key.publicKey));
});

test('every isolate signs with the same iat: the start of the current window', async (t) => {
  const { config, clock, now } = setup(t);
  assert.equal(providerTokenIssuedAt(Date.UTC(2026, 9, 23, 18, 47, 13) / 1000), Date.UTC(2026, 9, 23, 18, 30, 0) / 1000);
  assert.equal(providerTokenIssuedAt(Date.UTC(2026, 9, 23, 18, 30, 0) / 1000), Date.UTC(2026, 9, 23, 18, 30, 0) / 1000);
  const iats = [];
  for (const offset of [31 * MINUTE, 44 * MINUTE + 7000, 59 * MINUTE + 59 * 1000]) {
    resetApnsState(); // a fresh isolate on another machine
    clock.now = START_TIME + offset;
    iats.push(decodeJwt(await providerToken(config, 'production', { now })).claims.iat);
  }
  assert.deepEqual(iats, [iats[0], iats[0], iats[0]]);
  assert.equal(iats[0], START_TIME / 1000 + 30 * 60);
  // Token age when used stays below the 60-minute APNs limit.
  assert.ok(START_TIME / 1000 + 59 * 60 + 59 - iats[0] < 30 * 60);
});

test('a clock that jumps backwards does not keep a token from the future', async (t) => {
  const { config, clock, now } = setup(t);
  const first = await providerToken(config, 'production', { now });
  clock.now -= 10 * MINUTE;
  const second = await providerToken(config, 'production', { now });
  assert.notEqual(second, first);
});

test('the .p8 key is accepted with CRLF, escaped newlines or without armour', async (t) => {
  const { key, now } = setup(t);
  const pem = key.pem;
  const variants = {
    crlf: pem.replace(/\n/g, '\r\n'),
    escaped: pem.trim().replace(/\n/g, '\\n'),
    padded: `\n\n   ${pem}   \n`,
    bare: pem.replace(/-----[A-Z ]+-----/g, '').replace(/\s+/g, ''),
  };
  for (const [name, variant] of Object.entries(variants)) {
    resetApnsState();
    const config = apnsConfig({ APNS_KEY_P8: variant, APNS_KEY_ID: 'KEY1234567', APNS_TEAM_ID: 'TEAM123456' });
    const jwt = await providerToken(config, 'production', { now });
    assert.ok(verifyJwt(jwt, key.publicKey), `${name} key signs valid tokens`);
  }
});

test('a broken key raises ApnsConfigError (and is not cached)', async (t) => {
  const { now } = setup(t);
  assert.throws(() => pemToDer('-----BEGIN EC PRIVATE KEY-----\nAAAA\n-----END EC PRIVATE KEY-----'), ApnsConfigError);
  assert.throws(() => pemToDer('not a key at all!'), ApnsConfigError);
  const config = apnsConfig({ APNS_KEY_P8: 'AAAABBBB', APNS_KEY_ID: 'KEY1234567', APNS_TEAM_ID: 'TEAM123456' });
  await assert.rejects(providerToken(config, 'production', { now }), ApnsConfigError);
  await assert.rejects(providerToken(config, 'production', { now }), ApnsConfigError);
});

test('sendAlert posts to the production host with every APNs header', async (t) => {
  const { key, config, fetchMock, now } = setup(t);
  const msg = message({ collapseId: 'abc123def456.temp' });
  const result = await sendAlert(config, msg, { now });
  assert.equal(result.ok, true);
  assert.equal(result.apnsId, 'apns-1');
  assert.equal(fetchMock.calls.length, 1);
  const call = fetchMock.calls[0];
  assert.equal(call.method, 'POST');
  assert.equal(call.url, `https://api.push.apple.com/3/device/${msg.token}`);
  assert.equal(call.headers['apns-push-type'], 'alert');
  assert.equal(call.headers['apns-topic'], 'com.dimitrie.orbit');
  assert.equal(call.headers['apns-priority'], '10');
  assert.equal(call.headers['apns-expiration'], String(msg.expiration));
  assert.equal(call.headers['apns-collapse-id'], 'abc123def456.temp');
  assert.equal(call.headers['content-type'], 'application/json');
  assert.match(call.headers.authorization, /^bearer [\w-]+\.[\w-]+\.[\w-]+$/);
  assert.ok(verifyJwt(call.headers.authorization.slice('bearer '.length), key.publicKey));
  assert.deepEqual(call.json, buildAlertPayload({ ciphertext: msg.ciphertext, level: 'active', threadId: msg.threadId }));
});

test('sendAlert uses the sandbox host (and sandbox key) for sandbox devices', async (t) => {
  const sandboxKey = createSigningKey();
  const { config, fetchMock, now } = setup(t, { APNS_SANDBOX_KEY_P8: sandboxKey.pem, APNS_SANDBOX_KEY_ID: 'SANDBOX123' });
  const msg = message({ environment: 'sandbox', priority: 5, expiration: 0 });
  await sendAlert(config, msg, { now });
  const call = fetchMock.calls[0];
  assert.equal(call.url, `https://api.sandbox.push.apple.com/3/device/${msg.token}`);
  assert.equal(call.headers['apns-priority'], '5');
  assert.equal(call.headers['apns-expiration'], '0');
  assert.equal(call.headers['apns-collapse-id'], undefined, 'no collapse id unless asked');
  const jwt = call.headers.authorization.slice('bearer '.length);
  assert.equal(decodeJwt(jwt).header.kid, 'SANDBOX123');
  assert.ok(verifyJwt(jwt, sandboxKey.publicKey));
});

test('403 ExpiredProviderToken rebuilds the token and retries once', async (t) => {
  const { key, config, fetchMock, now } = setup(t);
  fetchMock.respond((_call, n) => (n === 1 ? { status: 403, reason: 'ExpiredProviderToken' } : { status: 200 }));
  const result = await sendAlert(config, message(), { now });
  assert.equal(result.ok, true);
  assert.equal(fetchMock.calls.length, 2);
  const [first, second] = fetchMock.calls.map((c) => c.headers.authorization);
  assert.notEqual(first, second, 'the retry carries a new token');
  assert.ok(verifyJwt(second.slice(7), key.publicKey));
  // The new token is what later requests use.
  assert.equal(await providerToken(config, 'production', { now }), second.slice(7));
});

test('near the caller deadline the ExpiredProviderToken retry is skipped and reported as retryable', async (t) => {
  const { config, fetchMock, now } = setup(t);
  const wall = { now: 1_000_000 };
  fetchMock.respond(() => {
    wall.now += 19_000; // APNs took 19 s to answer
    return { status: 403, reason: 'ExpiredProviderToken' };
  });
  const msg = message();
  const result = await sendAlert(config, msg, { now, deadline: 1_000_000 + 20_000, clock: () => wall.now });
  assert.equal(fetchMock.calls.length, 1, 'no second request after the deadline budget is spent');
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'ExpiredProviderToken');
  assert.equal(result.retryable, true, "the agent's retry will carry the rebuilt token");
  const stale = fetchMock.calls[0].headers.authorization.slice(7);
  assert.notEqual(await providerToken(config, 'production', { now }), stale, 'the token was rebuilt anyway');
});

test('the request timeout never runs past the caller deadline', async (t) => {
  const { config, fetchMock, now } = setup(t);
  // APNs never answers: the request ends when its signal aborts.
  fetchMock.respond(
    (call) =>
      new Promise((resolve) => {
        call.signal.addEventListener('abort', () => resolve(call.signal.reason), { once: true });
      }),
  );
  const started = Date.now();
  const result = await sendAlert(config, message(), { now, deadline: Date.now() + 150 });
  const elapsed = Date.now() - started;
  assert.equal(result.reason, 'Timeout');
  assert.equal(result.retryable, true);
  assert.ok(elapsed < 2000, `stopped after ${elapsed} ms, not the 10 s per-request timeout`);
});

test('TooManyProviderTokenUpdates is retryable and logged as its own event', async (t) => {
  resetApnsState();
  const logs = captureConsole(t);
  const key = createSigningKey();
  const config = apnsConfig({ APNS_KEY_P8: key.pem, APNS_KEY_ID: 'KEY1234567', APNS_TEAM_ID: 'TEAM123456' });
  const fetchMock = installFetchMock();
  t.after(() => fetchMock.restore());
  fetchMock.respond(() => ({ status: 429, reason: 'TooManyProviderTokenUpdates' }));
  const result = await sendAlert(config, message(), { now: () => START_TIME });
  assert.equal(result.retryable, true);
  assert.ok(logs.some((line) => line.includes('"event":"apns_too_many_token_updates"')), logs.join('\n'));
  fetchMock.reset();
  logs.length = 0;
  fetchMock.respond(() => ({ status: 429, reason: 'TooManyRequests' }));
  await sendAlert(config, message(), { now: () => START_TIME });
  assert.ok(!logs.some((line) => line.includes('apns_too_many_token_updates')), 'only for that reason');
});

test('a second ExpiredProviderToken is reported, not retried forever', async (t) => {
  const { config, fetchMock, now } = setup(t);
  fetchMock.respond(() => ({ status: 403, reason: 'ExpiredProviderToken' }));
  const result = await sendAlert(config, message(), { now });
  assert.equal(result.ok, false);
  assert.equal(result.status, 403);
  assert.equal(result.reason, 'ExpiredProviderToken');
  assert.equal(fetchMock.calls.length, 2);
});

test('parallel ExpiredProviderToken rejections share one rebuilt token', async (t) => {
  const { config, fetchMock, now } = setup(t);
  const stale = await providerToken(config, 'production', { now });
  fetchMock.respond((call) =>
    call.headers.authorization === `bearer ${stale}` ? { status: 403, reason: 'ExpiredProviderToken' } : { status: 200 },
  );
  const results = await Promise.all([1, 2, 3, 4].map(() => sendAlert(config, message(), { now })));
  assert.ok(results.every((r) => r.ok));
  const retried = new Set(fetchMock.calls.slice(4).map((c) => c.headers.authorization));
  assert.equal(retried.size, 1, 'one new token for all retries');
});

test('APNs answers map to clear results', async (t) => {
  const { config, fetchMock, now } = setup(t);
  const cases = [
    [{ status: 410, reason: 'Unregistered' }, { ok: false, unregistered: true, retryable: false, reason: 'Unregistered' }],
    [{ status: 400, reason: 'BadDeviceToken' }, { ok: false, unregistered: false, retryable: false, reason: 'BadDeviceToken' }],
    [{ status: 403, reason: 'InvalidProviderToken' }, { ok: false, unregistered: false, retryable: false, reason: 'InvalidProviderToken' }],
    [{ status: 429, reason: 'TooManyRequests' }, { ok: false, unregistered: false, retryable: true, reason: 'TooManyRequests' }],
    [{ status: 503, reason: 'ServiceUnavailable' }, { ok: false, unregistered: false, retryable: true, reason: 'ServiceUnavailable' }],
    [{ status: 500, reason: 'InternalServerError' }, { ok: false, unregistered: false, retryable: true, reason: 'InternalServerError' }],
    [new TypeError('fetch failed'), { ok: false, unregistered: false, retryable: true, reason: 'NetworkError' }],
    [Object.assign(new Error('timed out'), { name: 'TimeoutError' }), { ok: false, unregistered: false, retryable: true, reason: 'Timeout' }],
  ];
  for (const [answer, expected] of cases) {
    fetchMock.reset();
    fetchMock.respond(() => answer);
    const result = await sendAlert(config, message(), { now });
    for (const [field, value] of Object.entries(expected)) {
      assert.equal(result[field], value, `${answer.status ?? answer.name}: ${field}`);
    }
    assert.equal(fetchMock.calls.length, 1, `${answer.status ?? answer.name} is not retried inside sendAlert`);
  }
});

test('APNS_TEST_ORIGIN only redirects to loopback (local integration tests)', async (t) => {
  const local = setup(t, { APNS_TEST_ORIGIN: 'http://127.0.0.1:9797' });
  const msg = message({ environment: 'sandbox' });
  await sendAlert(local.config, msg, { now: local.now });
  assert.equal(local.fetchMock.calls[0].url, `http://127.0.0.1:9797/3/device/${msg.token}`);

  for (const origin of ['https://evil.example', 'http://10.0.0.5:9797', 'http://127.0.0.1.evil.example', 'http://localhost:80/x']) {
    const remote = apnsConfig({ APNS_KEY_P8: local.key.pem, APNS_KEY_ID: 'K', APNS_TEAM_ID: 'T', APNS_TEST_ORIGIN: origin });
    assert.equal(remote.origins.production, 'https://api.push.apple.com', origin);
    assert.equal(remote.origins.sandbox, 'https://api.sandbox.push.apple.com', origin);
  }
});

test('payloads over 4096 bytes are refused before calling APNs', async (t) => {
  const { config, fetchMock, now } = setup(t);
  const result = await sendAlert(config, message({ ciphertext: 'A'.repeat(4100) }), { now });
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'PayloadTooLarge');
  assert.equal(fetchMock.calls.length, 0);
});

test('the largest accepted ciphertext still fits the APNs payload limit', () => {
  const ciphertext = 'A'.repeat(3072);
  const payload = buildAlertPayload({ ciphertext, level: 'time-sensitive', threadId: 'f'.repeat(32) });
  assert.ok(new TextEncoder().encode(JSON.stringify(payload)).length <= 4096);
});
