// Small helpers shared by the Worker (index.js), the Durable Object (channel.js)
// and the APNs sender (apns.js). Plain Web APIs only, so the same code runs on
// Cloudflare Workers and in Node's test runner.

export const textEncoder = new TextEncoder();

export function bytesToHex(bytes) {
  const view = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let out = '';
  for (const byte of view) out += byte.toString(16).padStart(2, '0');
  return out;
}

export function randomBytes(length) {
  const bytes = new Uint8Array(length);
  crypto.getRandomValues(bytes);
  return bytes;
}

export function randomHex(byteLength) {
  return bytesToHex(randomBytes(byteLength));
}

export function base64UrlEncode(input) {
  const bytes =
    typeof input === 'string'
      ? textEncoder.encode(input)
      : input instanceof Uint8Array
        ? input
        : new Uint8Array(input);
  let binary = '';
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export async function sha256Hex(text) {
  const digest = await crypto.subtle.digest('SHA-256', textEncoder.encode(text));
  return bytesToHex(digest);
}

// Constant-time comparison of two hex digests. Workers expose
// crypto.subtle.timingSafeEqual; Node does not, so fall back to an XOR loop
// that always walks the whole input. The length of a SHA-256 digest is public,
// so a length mismatch may return early.
export function timingSafeEqualHex(expected, actual) {
  if (typeof expected !== 'string' || typeof actual !== 'string') return false;
  const a = textEncoder.encode(expected);
  const b = textEncoder.encode(actual);
  if (a.length !== b.length || a.length === 0) return false;
  if (typeof crypto.subtle.timingSafeEqual === 'function') {
    return crypto.subtle.timingSafeEqual(a, b);
  }
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

// ISO 8601 in UTC without milliseconds, e.g. 2026-10-23T18:00:00Z.
export function isoTime(ms) {
  if (ms === null || ms === undefined || !Number.isFinite(ms)) return null;
  return new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
}

export function utf8Length(text) {
  return textEncoder.encode(text).length;
}

// Number of bytes a padded standard-base64 string decodes to (no decoding).
export function base64DecodedLength(b64) {
  let padding = 0;
  if (b64.endsWith('==')) padding = 2;
  else if (b64.endsWith('=')) padding = 1;
  return (b64.length / 4) * 3 - padding;
}

export function jsonResponse(status, body, extraHeaders = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      'x-content-type-options': 'nosniff',
      ...extraHeaders,
    },
  });
}

export function errorBody(code, message, extra = {}) {
  return { error: code, message, ...extra };
}

export function errorResponse(status, code, message, extraHeaders = {}, extraBody = {}) {
  return jsonResponse(status, errorBody(code, message, extraBody), extraHeaders);
}
