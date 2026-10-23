// Request validation for the public API. The Worker validates every request
// before it reaches a Durable Object, so bad input never costs a DO request.
// PROTOCOL.md documents the same limits; keep the two in sync.

import { base64DecodedLength } from './util.js';

export const LIMITS = Object.freeze({
  maxDevicesPerChannel: 20,
  maxCiphertextChars: 3072,
  minCiphertextBytes: 29, // 12-byte nonce + 16-byte tag + at least 1 byte
  maxCollapseIdChars: 48,
  defaultTtlSeconds: 3600,
  maxTtlSeconds: 7 * 24 * 3600,
  heartbeatSeconds: 300,
  defaultOfflineAfterSeconds: 900,
  minOfflineAfterSeconds: 300,
  maxOfflineAfterSeconds: 3600,
  minBackWithinSeconds: 60,
  maxBackWithinSeconds: 24 * 3600,
  bodyBytes: Object.freeze({ small: 1024, device: 8 * 1024, notify: 64 * 1024 }),
});

export const CHANNEL_ID_RE = /^[0-9a-f]{32}$/;
export const PC_SECRET_RE = /^[A-Za-z0-9_-]{43}$/;
export const DEVICE_ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const TOKEN_RE = /^[0-9a-fA-F]{64,200}$/;
const BASE64_RE = /^[A-Za-z0-9+/]+={0,2}$/;
const COLLAPSE_ID_RE = /^[A-Za-z0-9._:-]+$/;

// Accepted notify levels -> APNs interruption-level.
const LEVELS = Object.freeze({
  passive: 'passive',
  active: 'active',
  timeSensitive: 'time-sensitive',
  'time-sensitive': 'time-sensitive',
});

function fail(message) {
  return { ok: false, message };
}

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

export function validateCiphertext(value, field) {
  if (typeof value !== 'string' || value.length === 0) return `${field} must be a base64 string.`;
  if (value.length > LIMITS.maxCiphertextChars) {
    return `${field} is too long (${value.length} characters, the limit is ${LIMITS.maxCiphertextChars}).`;
  }
  if (value.length % 4 !== 0 || !BASE64_RE.test(value)) {
    return `${field} must be standard base64 with padding (nonce + ciphertext + tag).`;
  }
  if (base64DecodedLength(value) < LIMITS.minCiphertextBytes) {
    return `${field} is too short to be an AES-GCM message.`;
  }
  return null;
}

function optionalInteger(body, field, min, max, fallback) {
  const value = body[field];
  if (value === undefined || value === null) return { value: fallback };
  if (!Number.isInteger(value) || value < min || value > max) {
    return { error: `${field} must be a whole number of seconds from ${min} to ${max}.` };
  }
  return { value };
}

export function parseDevicePut(body) {
  if (!isPlainObject(body)) return fail('The body must be a JSON object.');
  const { token, env } = body;
  if (typeof token !== 'string' || !TOKEN_RE.test(token) || token.length % 2 !== 0) {
    return fail('token must be the APNs device token as hex (64 to 200 hex digits).');
  }
  if (env !== 'sandbox' && env !== 'production') {
    return fail('env must be "sandbox" or "production".');
  }
  // offlineCt: omitted -> keep the stored one, null -> remove it, string -> replace.
  let offlineCt;
  if (body.offlineCt === null) {
    offlineCt = null;
  } else if (body.offlineCt !== undefined) {
    const problem = validateCiphertext(body.offlineCt, 'offlineCt');
    if (problem) return fail(problem);
    offlineCt = body.offlineCt;
  }
  return { ok: true, value: { token: token.toLowerCase(), env, offlineCt } };
}

export function parseNotify(body) {
  if (!isPlainObject(body)) return fail('The body must be a JSON object.');
  const { items } = body;
  if (!isPlainObject(items)) return fail('items must be an object of deviceId -> ciphertext.');
  const deviceIds = Object.keys(items);
  if (deviceIds.length === 0) return fail('items must name at least one device.');
  if (deviceIds.length > LIMITS.maxDevicesPerChannel) {
    return fail(`items names ${deviceIds.length} devices; the limit is ${LIMITS.maxDevicesPerChannel}.`);
  }
  const cleanItems = {};
  for (const deviceId of deviceIds) {
    if (!DEVICE_ID_RE.test(deviceId)) return fail(`"${deviceId.slice(0, 80)}" is not a valid deviceId.`);
    const problem = validateCiphertext(items[deviceId], `items["${deviceId}"]`);
    if (problem) return fail(problem);
    cleanItems[deviceId] = items[deviceId];
  }

  let level = 'active';
  if (body.level !== undefined && body.level !== null) {
    if (typeof body.level !== 'string' || !Object.hasOwn(LEVELS, body.level)) {
      return fail('level must be "passive", "active" or "timeSensitive".');
    }
    level = LEVELS[body.level];
  }

  let collapseId = null;
  if (body.collapseId !== undefined && body.collapseId !== null) {
    const value = body.collapseId;
    if (
      typeof value !== 'string' ||
      value.length === 0 ||
      value.length > LIMITS.maxCollapseIdChars ||
      !COLLAPSE_ID_RE.test(value)
    ) {
      return fail(`collapseId must be 1 to ${LIMITS.maxCollapseIdChars} characters of A-Z, a-z, 0-9, ".", "_", ":" or "-".`);
    }
    collapseId = value;
  }

  const ttl = optionalInteger(body, 'ttl', 0, LIMITS.maxTtlSeconds, LIMITS.defaultTtlSeconds);
  if (ttl.error) return fail(ttl.error);

  return { ok: true, value: { items: cleanItems, level, collapseId, ttl: ttl.value } };
}

export function parseHeartbeat(body) {
  if (!isPlainObject(body)) return fail('The body must be a JSON object (or empty).');
  const offlineAfter = optionalInteger(
    body,
    'offlineAfterSeconds',
    LIMITS.minOfflineAfterSeconds,
    LIMITS.maxOfflineAfterSeconds,
    LIMITS.defaultOfflineAfterSeconds,
  );
  if (offlineAfter.error) return fail(offlineAfter.error);
  return { ok: true, value: { offlineAfterSeconds: offlineAfter.value } };
}

export function parseOfflineExpected(body) {
  if (!isPlainObject(body)) return fail('The body must be a JSON object (or empty).');
  const value = body.backWithinSeconds;
  if (value === undefined || value === null || value === 0) return { ok: true, value: { backWithinSeconds: null } };
  if (!Number.isInteger(value) || value < LIMITS.minBackWithinSeconds || value > LIMITS.maxBackWithinSeconds) {
    return fail(
      `backWithinSeconds must be 0 or a whole number of seconds from ${LIMITS.minBackWithinSeconds} to ${LIMITS.maxBackWithinSeconds}.`,
    );
  }
  return { ok: true, value: { backWithinSeconds: value } };
}

export function parseCreateChannel(body) {
  if (!isPlainObject(body)) return fail('The body must be a JSON object (or empty).');
  return { ok: true, value: {} };
}
