// APNs sender: ES256 provider tokens (JWT) signed with WebCrypto, and one
// HTTP request per device to POST /3/device/<token>.
//
// Everything Apple-specific lives here so the sender can move to another host
// if Cloudflare ever stops upgrading outbound requests to HTTP/2 (see README).

import { base64UrlEncode, textEncoder, utf8Length } from './util.js';

export const APNS_HOSTS = Object.freeze({
  production: 'https://api.push.apple.com',
  sandbox: 'https://api.sandbox.push.apple.com',
});

// APNS_TEST_ORIGIN (local integration tests with `wrangler dev` and a mock
// APNs server) is honoured only for loopback HTTP origins, which a deployed
// Worker cannot reach anyway.
const TEST_ORIGIN_RE = /^http:\/\/(127\.0\.0\.1|localhost|\[::1\])(:\d{1,5})?$/;

export const DEFAULT_TOPIC = 'com.dimitrie.orbit';

// Apple: refresh the provider token no more than once every 20 minutes and no
// less than once every 60 minutes. The token's iat is the start of the current
// 30-minute window (UTC), so every isolate and machine running this Worker
// signs with the same iat and switches to a new one at the same moment, even
// if Cloudflare pools the upstream APNs connections. Tokens are 0-30 minutes
// old when used.
export const JWT_REFRESH_SECONDS = 30 * 60;

export const MAX_PAYLOAD_BYTES = 4096;

export const REQUEST_TIMEOUT_MS = 10_000;
// The ExpiredProviderToken retry is skipped when less time than this is left
// before the caller's deadline.
export const MIN_RETRY_BUDGET_MS = 2_000;

// The only text Apple (and the lock screen, if decryption fails) ever sees.
// The Notification Service Extension replaces it with the decrypted text.
export const GENERIC_ALERT = Object.freeze({ title: 'Orbit', body: 'New alert from your PC' });

// APNs interruption levels the relay accepts. "critical" needs an entitlement
// Orbit does not have, so it is not offered.
export const INTERRUPTION_LEVELS = Object.freeze(['passive', 'active', 'time-sensitive']);

export class ApnsConfigError extends Error {
  constructor(message) {
    super(message);
    this.name = 'ApnsConfigError';
  }
}

function clean(value) {
  return typeof value === 'string' ? value.trim() : '';
}

// Reads the APNs settings from the Worker environment. Returns null when the
// required secrets are missing. APNS_SANDBOX_KEY_P8 / APNS_SANDBOX_KEY_ID are
// optional: set them when your production key is not valid for the sandbox.
export function apnsConfig(env) {
  if (!env) return null;
  const teamId = clean(env.APNS_TEAM_ID);
  const keyId = clean(env.APNS_KEY_ID);
  const keyP8 = clean(env.APNS_KEY_P8);
  if (!teamId || !keyId || !keyP8) return null;
  const production = { keyId, keyP8 };
  const sandboxKeyId = clean(env.APNS_SANDBOX_KEY_ID);
  const sandboxKeyP8 = clean(env.APNS_SANDBOX_KEY_P8);
  const sandbox = sandboxKeyId && sandboxKeyP8 ? { keyId: sandboxKeyId, keyP8: sandboxKeyP8 } : production;
  const testOrigin = clean(env.APNS_TEST_ORIGIN);
  return {
    teamId,
    topic: clean(env.APNS_TOPIC) || DEFAULT_TOPIC,
    keys: { production, sandbox },
    origins: TEST_ORIGIN_RE.test(testOrigin) ? { production: testOrigin, sandbox: testOrigin } : APNS_HOSTS,
  };
}

export function buildAlertPayload({ ciphertext, level, threadId }) {
  return {
    aps: {
      alert: { title: GENERIC_ALERT.title, body: GENERIC_ALERT.body },
      'mutable-content': 1,
      sound: 'default',
      'interruption-level': level,
      'thread-id': threadId,
    },
    o: ciphertext,
    v: 1,
  };
}

// ---------------------------------------------------------------------------
// Provider token (JWT)
// ---------------------------------------------------------------------------

const signingKeys = new Map(); // keyP8 text -> Promise<CryptoKey>
const tokenCache = new Map(); // team + key -> { jwt, iat }
const tokenBuilds = new Map(); // team + key -> Promise<string>

// Test hook: forget cached keys and tokens.
export function resetApnsState() {
  signingKeys.clear();
  tokenCache.clear();
  tokenBuilds.clear();
}

export function pemToDer(p8) {
  let text = String(p8 ?? '');
  // Secrets pasted as one line often carry literal "\n" sequences.
  text = text.replace(/\\r/g, '').replace(/\\n/g, '\n');
  if (/-----BEGIN EC PRIVATE KEY-----/.test(text)) {
    throw new ApnsConfigError(
      'APNS_KEY_P8 is a SEC1 "EC PRIVATE KEY". Use the PKCS#8 .p8 file from Apple ' +
        '(or convert it with: openssl pkcs8 -topk8 -nocrypt -in key.pem).',
    );
  }
  const body = text
    .replace(/-----BEGIN [A-Z ]+-----/g, '')
    .replace(/-----END [A-Z ]+-----/g, '')
    .replace(/\s+/g, '');
  if (!body || !/^[A-Za-z0-9+/]+={0,2}$/.test(body)) {
    throw new ApnsConfigError('APNS_KEY_P8 is not a PEM-encoded private key.');
  }
  let binary;
  try {
    binary = atob(body);
  } catch {
    throw new ApnsConfigError('APNS_KEY_P8 is not valid base64.');
  }
  const der = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) der[i] = binary.charCodeAt(i);
  return der;
}

function importSigningKey(keyP8) {
  let pending = signingKeys.get(keyP8);
  if (!pending) {
    pending = (async () => {
      const der = pemToDer(keyP8);
      try {
        return await crypto.subtle.importKey('pkcs8', der, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
      } catch (error) {
        throw new ApnsConfigError(`APNS_KEY_P8 could not be imported as a P-256 key (${error?.message ?? error}).`);
      }
    })();
    signingKeys.set(keyP8, pending);
    // Do not cache failures: a fixed secret should work without a redeploy.
    pending.catch(() => signingKeys.delete(keyP8));
  }
  return pending;
}

export function providerTokenIssuedAt(nowSeconds) {
  return Math.floor(nowSeconds / JWT_REFRESH_SECONDS) * JWT_REFRESH_SECONDS;
}

export async function signProviderToken({ keyP8, keyId, teamId, iat }) {
  const key = await importSigningKey(keyP8);
  const header = base64UrlEncode(JSON.stringify({ alg: 'ES256', kid: keyId }));
  const claims = base64UrlEncode(JSON.stringify({ iss: teamId, iat }));
  const signingInput = `${header}.${claims}`;
  // WebCrypto ECDSA returns the raw IEEE P1363 signature (r || s, 64 bytes for
  // P-256), which is exactly what JWS ES256 needs. Never DER-encode it.
  const signature = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, textEncoder.encode(signingInput));
  if (signature.byteLength !== 64) {
    throw new ApnsConfigError(`Unexpected ES256 signature length ${signature.byteLength}.`);
  }
  return `${signingInput}.${base64UrlEncode(signature)}`;
}

// Returns the provider token for the current 30-minute window, building it
// once per window. Pass staleToken (the token APNs just rejected with
// ExpiredProviderToken) to force a rebuild; concurrent callers share one build
// so a burst of rejections produces a single new token.
export async function providerToken(config, environment, { now = Date.now, staleToken } = {}) {
  const key = config.keys[environment] ?? config.keys.production;
  // The key text is part of the cache key so a replaced secret is never
  // signed around with a token minted from the old key.
  const cacheKey = `${config.teamId}\n${key.keyId}\n${key.keyP8}`;
  const iat = providerTokenIssuedAt(Math.floor(now() / 1000));
  const cached = tokenCache.get(cacheKey);
  if (cached) {
    if (staleToken) {
      if (cached.jwt !== staleToken) return cached.jwt; // someone already refreshed
    } else if (cached.iat === iat) {
      return cached.jwt;
    }
  }
  const inFlight = tokenBuilds.get(cacheKey);
  if (inFlight) return inFlight;
  const build = (async () => {
    const jwt = await signProviderToken({ keyP8: key.keyP8, keyId: key.keyId, teamId: config.teamId, iat });
    tokenCache.set(cacheKey, { jwt, iat });
    return jwt;
  })();
  tokenBuilds.set(cacheKey, build);
  try {
    return await build;
  } finally {
    tokenBuilds.delete(cacheKey);
  }
}

// ---------------------------------------------------------------------------
// Sending
// ---------------------------------------------------------------------------

function timeoutSignal(ms) {
  return typeof AbortSignal !== 'undefined' && typeof AbortSignal.timeout === 'function'
    ? AbortSignal.timeout(ms)
    : undefined;
}

async function postToApns({ fetchImpl, url, headers, body, timeoutMs }) {
  try {
    const response = await fetchImpl(url, { method: 'POST', headers, body, signal: timeoutSignal(timeoutMs) });
    let reason = null;
    const text = await response.text().catch(() => '');
    if (text) {
      try {
        const parsed = JSON.parse(text);
        if (parsed && typeof parsed.reason === 'string') reason = parsed.reason;
      } catch {
        // APNs always answers JSON on errors; ignore anything else.
      }
    }
    return { status: response.status, reason, apnsId: response.headers.get('apns-id') };
  } catch (error) {
    const timedOut = error?.name === 'TimeoutError' || error?.name === 'AbortError';
    return { status: 0, reason: timedOut ? 'Timeout' : 'NetworkError', apnsId: null };
  }
}

function classify(response) {
  const { status, reason, apnsId } = response;
  if (status === 200) return { ok: true, status, reason: null, apnsId, retryable: false, unregistered: false };
  // 410: the token is no longer valid for this topic (app removed, token rotated).
  if (status === 410) return { ok: false, status, reason: reason ?? 'Unregistered', apnsId, retryable: false, unregistered: true };
  // 429 (too many requests to this device / token updates), 5xx and network
  // problems are worth retrying later. Everything else will fail again.
  const retryable = status === 0 || status === 429 || status >= 500;
  return { ok: false, status, reason: reason ?? `HTTP ${status}`, apnsId, retryable, unregistered: false };
}

// Sends one alert push. Never throws for APNs or network failures; throws
// ApnsConfigError when the configured key cannot be used at all.
//
// message: { token, environment: 'sandbox'|'production', ciphertext,
//            level: 'passive'|'active'|'time-sensitive', threadId,
//            priority: 5|10, expiration: epoch seconds or 0, collapseId? }
// options: now      clock for the JWT iat (ms)
//          deadline optional time (ms, on `clock`) by which sendAlert must
//                   return: it bounds each request's timeout and skips the
//                   ExpiredProviderToken retry when too little time is left
//          clock    real elapsed time for the deadline (ms)
export async function sendAlert(
  config,
  message,
  { fetch: fetchImpl = globalThis.fetch, now = Date.now, deadline = null, clock = Date.now } = {},
) {
  const environment = message.environment === 'sandbox' ? 'sandbox' : 'production';
  const body = JSON.stringify(
    buildAlertPayload({ ciphertext: message.ciphertext, level: message.level, threadId: message.threadId }),
  );
  if (utf8Length(body) > MAX_PAYLOAD_BYTES) {
    return { ok: false, status: 413, reason: 'PayloadTooLarge', apnsId: null, retryable: false, unregistered: false };
  }
  const origin = (config.origins ?? APNS_HOSTS)[environment];
  const url = `${origin}/3/device/${message.token}`;
  const headersFor = (jwt) => {
    const headers = {
      authorization: `bearer ${jwt}`,
      'apns-push-type': 'alert',
      'apns-topic': config.topic,
      'apns-priority': String(message.priority ?? 10),
      'apns-expiration': String(message.expiration ?? 0),
      'content-type': 'application/json',
    };
    if (message.collapseId) headers['apns-collapse-id'] = message.collapseId;
    return headers;
  };

  const timeLeft = () => (deadline === null ? REQUEST_TIMEOUT_MS : Math.min(REQUEST_TIMEOUT_MS, deadline - clock()));

  let jwt = await providerToken(config, environment, { now });
  let response = await postToApns({ fetchImpl, url, headers: headersFor(jwt), body, timeoutMs: Math.max(1, timeLeft()) });
  let retrySkipped = false;
  if (response.status === 403 && response.reason === 'ExpiredProviderToken') {
    jwt = await providerToken(config, environment, { now, staleToken: jwt });
    if (timeLeft() >= MIN_RETRY_BUDGET_MS) {
      response = await postToApns({ fetchImpl, url, headers: headersFor(jwt), body, timeoutMs: timeLeft() });
    } else {
      // No time to retry before the caller's deadline. The token is already
      // rebuilt, so the caller's own retry will carry the new one.
      retrySkipped = true;
    }
  }
  const result = classify(response);
  if (retrySkipped) result.retryable = true;
  if (!result.ok) {
    // Never log device tokens or ciphertexts.
    console.warn(JSON.stringify({ event: 'apns_error', environment, status: result.status, reason: result.reason }));
    if (result.reason === 'TooManyProviderTokenUpdates') {
      // Should never happen (see JWT_REFRESH_SECONDS). If it does, APNs sees
      // tokens from several isolates on one pooled connection: see README,
      // "Provider tokens".
      console.error(JSON.stringify({ event: 'apns_too_many_token_updates', environment, status: result.status }));
    }
  }
  return result;
}
