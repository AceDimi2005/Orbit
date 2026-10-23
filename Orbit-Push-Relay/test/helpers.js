// Test support: maps "cloudflare:workers" to a shim, and provides mocks for
// Durable Object storage/alarms, the DO namespace (with RPC-like structured
// cloning), APNs (globalThis.fetch) and a throwaway P-256 signing key.
//
// Import this file before importing anything from ../src (use a dynamic
// import), because the hook has to be registered before channel.js resolves.

import { registerHooks } from 'node:module';
import { generateKeyPairSync, verify as cryptoVerify, randomBytes as nodeRandomBytes } from 'node:crypto';
import assert from 'node:assert/strict';

const shimUrl = new URL('./cloudflare-workers-shim.js', import.meta.url).href;
if (!globalThis.__orbitRelayHooks) {
  globalThis.__orbitRelayHooks = registerHooks({
    resolve(specifier, context, nextResolve) {
      if (specifier === 'cloudflare:workers') return { url: shimUrl, shortCircuit: true };
      return nextResolve(specifier, context);
    },
  });
}

const relay = await import('../src/index.js');
const apns = await import('../src/apns.js');
const validate = await import('../src/validate.js');
const channelModule = await import('../src/channel.js');
const ratelimit = await import('../src/ratelimit.js');

export const worker = relay.default;
export const { Channel } = relay;
export { relay, apns, validate, channelModule, ratelimit };

export const START_TIME = Date.UTC(2026, 9, 23, 18, 0, 0);
export const MINUTE = 60 * 1000;
export const DAY = 24 * 60 * MINUTE;

// ---------------------------------------------------------------------------
// Random test data
// ---------------------------------------------------------------------------

export function deviceToken() {
  return nodeRandomBytes(32).toString('hex');
}

// base64(nonce || ciphertext || tag) shaped like the agent's output.
export function fakeCiphertext(plaintextBytes = 128) {
  return nodeRandomBytes(12 + plaintextBytes + 16).toString('base64');
}

export function createSigningKey() {
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  return { pem: privateKey.export({ type: 'pkcs8', format: 'pem' }), publicKey };
}

export function decodeJwt(jwt) {
  const parts = jwt.split('.');
  assert.equal(parts.length, 3, 'a JWT has three parts');
  const json = (part) => JSON.parse(Buffer.from(part, 'base64url').toString('utf8'));
  return { header: json(parts[0]), claims: json(parts[1]), signature: Buffer.from(parts[2], 'base64url'), signingInput: `${parts[0]}.${parts[1]}` };
}

// Verifies an ES256 JWT with node:crypto. ES256 signatures are raw r||s
// (IEEE P1363), not DER.
export function verifyJwt(jwt, publicKey) {
  const { signature, signingInput } = decodeJwt(jwt);
  assert.equal(signature.length, 64, 'ES256 signatures are 64 raw bytes');
  return cryptoVerify('sha256', Buffer.from(signingInput), { key: publicKey, dsaEncoding: 'ieee-p1363' }, signature);
}

// ---------------------------------------------------------------------------
// Durable Object storage mock (KV API + alarms)
// ---------------------------------------------------------------------------

export class MockStorage {
  constructor() {
    this.data = new Map();
    this.alarmAt = null;
    this.writes = 0;
    this.reads = 0;
    this.log = [];
  }

  async get(keyOrKeys) {
    await null;
    if (Array.isArray(keyOrKeys)) {
      this.reads += keyOrKeys.length;
      const result = new Map();
      for (const key of keyOrKeys) {
        if (this.data.has(key)) result.set(key, structuredClone(this.data.get(key)));
      }
      return result;
    }
    this.reads += 1;
    return this.data.has(keyOrKeys) ? structuredClone(this.data.get(keyOrKeys)) : undefined;
  }

  async put(keyOrEntries, value) {
    await null;
    if (typeof keyOrEntries === 'object' && keyOrEntries !== null) {
      for (const [key, entry] of Object.entries(keyOrEntries)) await this.put(key, entry);
      return;
    }
    if (value === undefined) throw new TypeError('put() needs a value');
    this.writes += 1;
    this.log.push(['put', keyOrEntries]);
    this.data.set(keyOrEntries, structuredClone(value));
  }

  async delete(keyOrKeys) {
    await null;
    if (Array.isArray(keyOrKeys)) {
      let count = 0;
      for (const key of keyOrKeys) if (await this.delete(key)) count += 1;
      return count;
    }
    this.writes += 1;
    this.log.push(['delete', keyOrKeys]);
    return this.data.delete(keyOrKeys);
  }

  async list({ prefix = '' } = {}) {
    await null;
    const keys = [...this.data.keys()].filter((k) => k.startsWith(prefix)).sort();
    this.reads += keys.length;
    return new Map(keys.map((k) => [k, structuredClone(this.data.get(k))]));
  }

  // Like compatibility dates before 2026-02-24: deleteAll() keeps the alarm.
  async deleteAll() {
    await null;
    this.writes += 1;
    this.log.push(['deleteAll']);
    this.data.clear();
  }

  async getAlarm() {
    await null;
    return this.alarmAt;
  }

  async setAlarm(scheduledTime) {
    await null;
    const ms = scheduledTime instanceof Date ? scheduledTime.getTime() : scheduledTime;
    if (!Number.isFinite(ms)) throw new TypeError('setAlarm() needs a time in ms');
    this.writes += 1;
    this.log.push(['setAlarm', ms]);
    this.alarmAt = ms;
  }

  async deleteAlarm() {
    await null;
    this.log.push(['deleteAlarm']);
    this.alarmAt = null;
  }
}

// ---------------------------------------------------------------------------
// Durable Object namespace mock. get() returns an RPC-like stub: arguments and
// results are structured-cloned and every call is async, like real RPC.
// ---------------------------------------------------------------------------

export class MockNamespace {
  constructor(ChannelClass, clock) {
    this.ChannelClass = ChannelClass;
    this.clock = clock;
    this.env = null;
    this.objects = new Map();
    this.stubRequests = 0;
  }

  idFromName(name) {
    return { name, toString: () => `do-${name}` };
  }

  entry(name) {
    let entry = this.objects.get(name);
    if (!entry) {
      entry = { storage: new MockStorage(), instance: null };
      this.objects.set(name, entry);
    }
    if (!entry.instance) {
      const ctx = { id: this.idFromName(name), storage: entry.storage, waitUntil() {}, blockConcurrencyWhile: (fn) => fn() };
      entry.instance = new this.ChannelClass(ctx, this.env);
      entry.instance.now = () => this.clock.now;
    }
    return entry;
  }

  get(id) {
    const name = id.name;
    return new Proxy(
      {},
      {
        get: (_target, method) => {
          if (method === 'then') return undefined; // not a thenable
          return async (...args) => {
            this.stubRequests += 1;
            const instance = this.entry(name).instance;
            const result = await instance[method](...structuredClone(args));
            return structuredClone(result);
          };
        },
      },
    );
  }

  storage(name) {
    return this.objects.get(name)?.storage;
  }

  // Simulates the runtime evicting the object from memory.
  evict(name) {
    const entry = this.objects.get(name);
    if (entry) entry.instance = null;
  }

  // Runs the alarm the way the runtime does: only once its time has come,
  // with getAlarm() returning null inside the handler.
  async fireAlarm(name, alarmInfo = { retryCount: 0, isRetry: false }) {
    const entry = this.entry(name);
    const at = entry.storage.alarmAt;
    assert.notEqual(at, null, `channel ${name} has no alarm scheduled`);
    assert.ok(at <= this.clock.now, `alarm for ${name} is not due yet (due ${new Date(at).toISOString()})`);
    entry.storage.alarmAt = null;
    await entry.instance.alarm(alarmInfo);
  }
}

// ---------------------------------------------------------------------------
// APNs mock: replaces globalThis.fetch.
// ---------------------------------------------------------------------------

export function installFetchMock() {
  const original = globalThis.fetch;
  const calls = [];
  let responder = () => ({ status: 200 });
  globalThis.fetch = async (input, init = {}) => {
    const headers = Object.fromEntries(new Headers(init.headers).entries());
    const call = { url: String(input), method: init.method, headers, body: init.body, json: JSON.parse(init.body) };
    calls.push(call);
    const outcome = await responder(call, calls.length);
    if (outcome instanceof Error) throw outcome;
    const responseHeaders = { 'apns-id': `apns-${calls.length}`, ...(outcome.headers ?? {}) };
    const body = outcome.reason ? JSON.stringify({ reason: outcome.reason }) : (outcome.body ?? '');
    return new Response(body, { status: outcome.status ?? 200, headers: responseHeaders });
  };
  return {
    calls,
    respond(fn) {
      responder = fn;
    },
    reset() {
      calls.length = 0;
      responder = () => ({ status: 200 });
    },
    restore() {
      globalThis.fetch = original;
    },
  };
}

// Captures console output so tests stay quiet and can check what is logged.
export function captureConsole(t) {
  const lines = [];
  for (const level of ['log', 'warn', 'error', 'info']) {
    t.mock.method(console, level, (...args) => lines.push(args.map(String).join(' ')));
  }
  return lines;
}

// ---------------------------------------------------------------------------
// Full relay harness: Worker + mocked namespace + mocked APNs + test key.
// ---------------------------------------------------------------------------

export function createHarness(t, { env: envOverrides = {}, withApns = true } = {}) {
  apns.resetApnsState();
  ratelimit.resetRateLimitMemory();
  const logs = captureConsole(t);
  const clock = { now: START_TIME };
  const key = createSigningKey();
  const env = {
    APNS_TOPIC: 'com.dimitrie.orbit',
    RETENTION_DAYS: '90',
    ...(withApns ? { APNS_KEY_P8: key.pem, APNS_KEY_ID: 'KEY1234567', APNS_TEAM_ID: 'TEAM123456' } : {}),
    ...envOverrides,
  };
  const ns = new MockNamespace(Channel, clock);
  ns.env = env;
  env.CHANNELS = ns;
  const fetchMock = installFetchMock();
  t.after(() => fetchMock.restore());

  async function request(method, path, { body, raw, secret, headers = {}, ip = '203.0.113.7', base = 'https://relay.example.workers.dev' } = {}) {
    const h = new Headers(headers);
    if (secret) h.set('authorization', `Bearer ${secret}`);
    if (ip) h.set('cf-connecting-ip', ip);
    const init = { method, headers: h };
    if (raw !== undefined) init.body = raw;
    else if (body !== undefined) {
      init.body = JSON.stringify(body);
      h.set('content-type', 'application/json');
    }
    const response = await worker.fetch(new Request(base + path, init), env, { waitUntil() {} });
    const text = await response.text();
    let json = null;
    try {
      json = JSON.parse(text);
    } catch {
      json = null;
    }
    return { status: response.status, headers: response.headers, json, text };
  }

  async function createChannel(options = {}) {
    const response = await request('POST', '/v1/channels', options);
    assert.equal(response.status, 201, response.text);
    return response.json;
  }

  async function putDevice(channel, deviceId, body) {
    return request('PUT', `/v1/c/${channel.channelId}/devices/${deviceId}`, { secret: channel.pcSecret, body });
  }

  async function heartbeat(channel, body) {
    return request('POST', `/v1/c/${channel.channelId}/hb`, { secret: channel.pcSecret, body });
  }

  async function notify(channel, body) {
    return request('POST', `/v1/c/${channel.channelId}/notify`, { secret: channel.pcSecret, body });
  }

  async function status(channel) {
    return request('GET', `/v1/c/${channel.channelId}`, { secret: channel.pcSecret });
  }

  function advance(ms) {
    clock.now += ms;
  }

  return { t, env, ns, clock, key, fetchMock, logs, request, createChannel, putDevice, heartbeat, notify, status, advance };
}
