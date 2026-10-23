// Orbit push relay: Cloudflare Worker entry point.
//
// Routing, authentication and request validation start here (rate limits in
// ratelimit.js, limits in validate.js). Each channel (one per Windows PC) is a
// SQLite-backed Durable Object (channel.js) that holds the devices and the
// dead-man switch; APNs requests are built in apns.js.
//
// Authentication: the PC sends "Authorization: Bearer <pcSecret>". The Worker
// hashes it with SHA-256 and the channel's Durable Object compares that hash
// in constant time with the one stored when the channel was created. The
// relay never stores the secret itself.
//
// The HTTP contract is documented in PROTOCOL.md.

import { Channel } from './channel.js';
import { apnsConfig } from './apns.js';
import {
  CHANNEL_ID_RE,
  DEVICE_ID_RE,
  LIMITS,
  PC_SECRET_RE,
  parseCreateChannel,
  parseDevicePut,
  parseHeartbeat,
  parseNotify,
  parseOfflineExpected,
} from './validate.js';
import { RATE_LIMITS, allowRequest } from './ratelimit.js';
import { base64UrlEncode, errorResponse, jsonResponse, randomBytes, randomHex, sha256Hex } from './util.js';

// The main module may only export the fetch handler and Durable Object
// classes; workerd refuses to start on any other export.
export { Channel };

const PROTOCOL_VERSION = 1;

const LOCAL_HOSTS = new Set(['localhost', '127.0.0.1', '[::1]']);

class HttpError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

function rateLimited(rule) {
  return errorResponse(
    429,
    'rate_limited',
    'Too many requests from this address. Wait a minute and try again.',
    { 'retry-after': String(rule.periodSeconds) },
    { retryAfterSeconds: rule.periodSeconds },
  );
}

// ---------------------------------------------------------------------------
// Request helpers
// ---------------------------------------------------------------------------

function clientAddress(request) {
  return request.headers.get('cf-connecting-ip') || 'unknown';
}

function bearerSecret(request) {
  const header = request.headers.get('authorization') || '';
  const match = /^Bearer\s+(\S+)\s*$/i.exec(header);
  if (!match || !PC_SECRET_RE.test(match[1])) return null;
  return match[1];
}

// Reads at most maxBytes of the body and parses it as JSON. An empty body is
// {} when allowEmpty is set.
async function readJson(request, maxBytes, { allowEmpty }) {
  const declared = request.headers.get('content-length');
  if (declared !== null && Number(declared) > maxBytes) {
    throw new HttpError(413, 'payload_too_large', `The request body is larger than ${maxBytes} bytes.`);
  }
  let text = '';
  if (request.body) {
    const reader = request.body.getReader();
    const chunks = [];
    let total = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maxBytes) {
        await reader.cancel().catch(() => {});
        throw new HttpError(413, 'payload_too_large', `The request body is larger than ${maxBytes} bytes.`);
      }
      chunks.push(value);
    }
    const bytes = new Uint8Array(total);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.byteLength;
    }
    try {
      text = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
    } catch {
      throw new HttpError(400, 'bad_request', 'The request body must be UTF-8 JSON.');
    }
  }
  if (text.trim() === '') {
    if (allowEmpty) return {};
    throw new HttpError(400, 'bad_request', 'The request body must be a JSON object.');
  }
  try {
    return JSON.parse(text);
  } catch {
    throw new HttpError(400, 'bad_request', 'The request body is not valid JSON.');
  }
}

function validated(parsed) {
  if (!parsed.ok) throw new HttpError(400, 'bad_request', parsed.message);
  return parsed.value;
}

function channelStub(env, channelId) {
  if (!env?.CHANNELS) {
    throw new HttpError(500, 'misconfigured', 'The relay is missing its CHANNELS Durable Object binding.');
  }
  return env.CHANNELS.get(env.CHANNELS.idFromName(channelId));
}

function fromChannel(result) {
  return jsonResponse(result.status, result.body);
}

function methodNotAllowed(allowed) {
  return errorResponse(405, 'method_not_allowed', `Use ${allowed.join(' or ')} for this path.`, { allow: allowed.join(', ') });
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

function health(env) {
  return jsonResponse(200, {
    ok: true,
    service: 'orbit-push-relay',
    protocol: PROTOCOL_VERSION,
    apns: apnsConfig(env) ? 'configured' : 'not_configured',
  });
}

async function createChannel(request, env) {
  if (!(await allowRequest(env, RATE_LIMITS.create, clientAddress(request)))) return rateLimited(RATE_LIMITS.create);
  validated(parseCreateChannel(await readJson(request, LIMITS.bodyBytes.small, { allowEmpty: true })));
  for (let attempt = 0; attempt < 3; attempt++) {
    const channelId = randomHex(16);
    const pcSecret = base64UrlEncode(randomBytes(32));
    const secretHash = await sha256Hex(pcSecret);
    const result = await channelStub(env, channelId).initChannel({ channelId, secretHash });
    if (result.status === 201) {
      return jsonResponse(201, {
        channelId,
        pcSecret,
        heartbeatSeconds: LIMITS.heartbeatSeconds,
        offlineAfterSeconds: LIMITS.defaultOfflineAfterSeconds,
      });
    }
    if (result.status !== 409) return fromChannel(result);
  }
  throw new HttpError(500, 'internal_error', 'Could not allocate a channel id. Try again.');
}

async function channelRoute(request, env, channelId, rest) {
  // rest: [] | ['devices', id] | ['notify'] | ['hb'] | ['offline-expected']
  const method = request.method;
  let action = null;
  let allowed;
  let deviceId = null;
  if (rest.length === 0) {
    allowed = ['GET', 'DELETE'];
    if (method === 'GET') action = 'status';
    else if (method === 'DELETE') action = 'destroy';
  } else if (rest.length === 2 && rest[0] === 'devices') {
    allowed = ['PUT', 'DELETE'];
    deviceId = rest[1];
    if (method === 'PUT') action = 'putDevice';
    else if (method === 'DELETE') action = 'deleteDevice';
  } else if (rest.length === 1 && ['notify', 'hb', 'offline-expected'].includes(rest[0])) {
    allowed = ['POST'];
    if (method === 'POST') action = rest[0];
  } else {
    return errorResponse(404, 'not_found', 'There is no such route on the relay.');
  }
  if (!action) return methodNotAllowed(allowed);

  if (!(await allowRequest(env, RATE_LIMITS.api, clientAddress(request)))) return rateLimited(RATE_LIMITS.api);

  const secret = bearerSecret(request);
  if (!secret) {
    return errorResponse(401, 'unauthorized', 'Send the channel secret as "Authorization: Bearer <pcSecret>".', {
      'www-authenticate': 'Bearer',
    });
  }
  if (!CHANNEL_ID_RE.test(channelId)) {
    return errorResponse(404, 'channel_not_found', 'This channel does not exist. Create a new channel and register your devices again.');
  }
  if (deviceId !== null && !DEVICE_ID_RE.test(deviceId)) {
    throw new HttpError(400, 'bad_request', 'deviceId must be 1 to 64 characters of A-Z, a-z, 0-9, ".", "_" or "-".');
  }

  // Validate before touching the Durable Object.
  let args;
  switch (action) {
    case 'putDevice':
      args = validated(parseDevicePut(await readJson(request, LIMITS.bodyBytes.device, { allowEmpty: false })));
      break;
    case 'notify':
      args = validated(parseNotify(await readJson(request, LIMITS.bodyBytes.notify, { allowEmpty: false })));
      break;
    case 'hb':
      args = validated(parseHeartbeat(await readJson(request, LIMITS.bodyBytes.small, { allowEmpty: true })));
      break;
    case 'offline-expected':
      args = validated(parseOfflineExpected(await readJson(request, LIMITS.bodyBytes.small, { allowEmpty: true })));
      break;
    default:
      break;
  }

  const secretHash = await sha256Hex(secret);
  const stub = channelStub(env, channelId);
  switch (action) {
    case 'status':
      return fromChannel(await stub.getStatus(secretHash));
    case 'destroy':
      return fromChannel(await stub.destroyChannel(secretHash));
    case 'putDevice':
      return fromChannel(await stub.putDevice(secretHash, deviceId, args));
    case 'deleteDevice':
      return fromChannel(await stub.deleteDevice(secretHash, deviceId));
    case 'notify':
      return fromChannel(await stub.notify(secretHash, args));
    case 'hb':
      return fromChannel(await stub.heartbeat(secretHash, args));
    case 'offline-expected':
      return fromChannel(await stub.offlineExpected(secretHash, args));
    default:
      throw new HttpError(500, 'internal_error', 'Unhandled route.');
  }
}

async function route(request, env) {
  const url = new URL(request.url);
  const path = url.pathname.replace(/\/+$/, '') || '/';
  const segments = path.split('/').filter(Boolean);

  if (path === '/' || path === '/v1/health') {
    if (request.method !== 'GET') return methodNotAllowed(['GET']);
    return health(env);
  }

  const isChannels = path === '/v1/channels';
  const isChannelRoute = segments[0] === 'v1' && segments[1] === 'c' && segments.length >= 3;
  if (!isChannels && !isChannelRoute) {
    return errorResponse(404, 'not_found', 'There is no such route on the relay.');
  }

  // Secrets travel in these requests and responses: refuse plain HTTP
  // (except for wrangler dev on this machine).
  if (url.protocol !== 'https:' && !LOCAL_HOSTS.has(url.hostname)) {
    return errorResponse(426, 'https_required', 'Use https:// for the relay URL.', { upgrade: 'TLS/1.2' });
  }

  if (isChannels) {
    if (request.method !== 'POST') return methodNotAllowed(['POST']);
    return createChannel(request, env);
  }
  return channelRoute(request, env, segments[2], segments.slice(3));
}

export default {
  async fetch(request, env) {
    try {
      return await route(request, env);
    } catch (error) {
      if (error instanceof HttpError) return errorResponse(error.status, error.code, error.message);
      console.error(JSON.stringify({ event: 'unhandled_error', message: String(error?.message ?? error) }));
      return errorResponse(500, 'internal_error', 'The relay hit an unexpected error. Try again later.');
    }
  },
};
