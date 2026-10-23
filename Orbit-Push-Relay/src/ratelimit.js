// Per-IP rate limiting: Workers rate-limit bindings when configured (see
// wrangler.toml), otherwise a best-effort counter per isolate (local
// development, tests, or plans without the binding).
//
// Kept out of index.js on purpose: the Worker's main module may only export
// handlers and Durable Object classes, or workerd refuses to start.

// Per client IP, per Cloudflare location (the rate-limit binding is approximate).
export const RATE_LIMITS = Object.freeze({
  create: Object.freeze({ binding: 'CREATE_LIMITER', limit: 5, periodSeconds: 60 }),
  api: Object.freeze({ binding: 'API_LIMITER', limit: 60, periodSeconds: 60 }),
});

const memoryBuckets = new Map();

export function resetRateLimitMemory() {
  memoryBuckets.clear();
}

export async function allowRequest(env, rule, key) {
  const binding = env?.[rule.binding];
  if (binding && typeof binding.limit === 'function') {
    try {
      const outcome = await binding.limit({ key });
      return outcome?.success !== false;
    } catch (error) {
      // Fail open: a broken limiter must not take the relay down.
      console.warn(JSON.stringify({ event: 'rate_limiter_error', binding: rule.binding, message: String(error?.message ?? error) }));
      return true;
    }
  }
  const now = Date.now();
  const bucketKey = `${rule.binding}:${key}`;
  let bucket = memoryBuckets.get(bucketKey);
  if (!bucket || now - bucket.start >= rule.periodSeconds * 1000) {
    if (memoryBuckets.size > 10_000) memoryBuckets.clear();
    bucket = { start: now, count: 0 };
    memoryBuckets.set(bucketKey, bucket);
  }
  bucket.count += 1;
  return bucket.count <= rule.limit;
}
