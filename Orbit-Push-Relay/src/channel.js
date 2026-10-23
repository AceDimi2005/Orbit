// One SQLite-backed Durable Object per channel (= one Windows PC).
//
// It stores the channel's secret hash, the registered devices with their APNs
// tokens and the "PC offline" ciphertexts the PC uploaded, and runs the
// dead-man switch: every heartbeat pushes the alarm 15 minutes forward; if the
// alarm ever fires, the PC stopped responding and the stored offline
// ciphertexts go out to every device.
//
// The Worker (index.js) is the only caller. It validates every request and
// passes SHA-256(pcSecret); this object compares it in constant time against
// the stored hash before doing anything.
//
// Storage uses the Durable Object KV API, which SQLite-backed objects store in
// SQLite (rows read / rows written billing):
//   "meta"              channel record (see initChannel)
//   "device:<deviceId>" { deviceId, token, env, offlineCt, registeredAt,
//                         updatedAt, lastDeliveryAt, lastError, lastErrorAt }
//   "gone:<sha256(token)>" { deviceId, at }: APNs answered 410 for this token.
//                         A PUT of the same token is refused (410
//                         token_unregistered) unless the phone registered
//                         again, so an agent restart cannot bring a dead token
//                         back. Kept 30 days, at most 40 per channel.
//
// Alarm kinds (meta.alarm):
//   "offline"     dead-man switch: the PC missed its heartbeats
//   "alert-retry" offline alert in progress: (re)send to meta.alert.pending.
//                 Saved before the first push, so an alarm the runtime retries
//                 after a reset (deploy, secret change, storage error) resumes
//                 the alert instead of losing it.
//   "purge"       retention: delete the whole channel
//
// Network calls (APNs) let other requests interleave, so every write after a
// fetch re-reads what it is about to change.

import { DurableObject } from 'cloudflare:workers';
import { apnsConfig, providerToken, sendAlert, ApnsConfigError } from './apns.js';
import { LIMITS } from './validate.js';
import { isoTime, randomHex, sha256Hex, timingSafeEqualHex } from './util.js';

const META_KEY = 'meta';
const DEVICE_PREFIX = 'device:';
const GONE_PREFIX = 'gone:';

const DAY_MS = 24 * 3600 * 1000;
const DEFAULT_RETENTION_DAYS = 90;
const NEW_CHANNEL_PURGE_DAYS = 7;
const OFFLINE_ALERT_TTL_SECONDS = 12 * 3600;
const OFFLINE_COLLAPSE_SUFFIX = 'offline';
// Initial attempt + one retry per delay.
const ALERT_RETRY_DELAYS_SECONDS = Object.freeze([30, 120, 600]);
// A notify answers within this budget even when APNs is slow, so the agent
// (30 s timeout, PROTOCOL.md section 1) never gives up on a request the relay
// is still delivering.
const NOTIFY_DEADLINE_MS = 20_000;
// Tokens APNs reported as unregistered (410) are remembered this long.
const UNREGISTERED_MEMORY_DAYS = 30;
const MAX_UNREGISTERED = 40;

export const CHANNEL_CONSTANTS = Object.freeze({
  DEFAULT_RETENTION_DAYS,
  NEW_CHANNEL_PURGE_DAYS,
  OFFLINE_ALERT_TTL_SECONDS,
  ALERT_RETRY_DELAYS_SECONDS,
  NOTIFY_DEADLINE_MS,
  UNREGISTERED_MEMORY_DAYS,
  MAX_UNREGISTERED,
});

const deviceKey = (deviceId) => `${DEVICE_PREFIX}${deviceId}`;
const goneKey = (tokenHash) => `${GONE_PREFIX}${tokenHash}`;

function reply(status, body) {
  return { status, body };
}

function failure(status, error, message, extra = {}) {
  return { status, body: { error, message, ...extra } };
}

function apnsPriority(level) {
  return level === 'passive' ? 5 : 10;
}

// Collapse IDs are per app on the phone, so two PCs must never share one.
function collapseIdFor(channelId, collapseId) {
  return `${channelId.slice(0, 12)}.${collapseId}`;
}

function deliveryResult(result) {
  if (result.ok) return { status: 'sent', apnsId: result.apnsId ?? null };
  return {
    status: result.unregistered ? 'unregistered' : 'failed',
    apnsStatus: result.status,
    reason: result.reason,
    retryable: Boolean(result.retryable),
  };
}

export class Channel extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.ctx = ctx;
    this.env = env;
    this.storage = ctx.storage;
    this.metaCache = undefined; // undefined = not loaded, null = no channel
    // Offline-alert pushes currently waiting for APNs. In memory only: a
    // reset object has none in flight.
    this.offlineSendsInFlight = 0;
  }

  // Overridden in tests (a fake clock for timestamps, alarms and JWT iat).
  now() {
    return Date.now();
  }

  // Real elapsed time for request deadlines. Overridden in tests.
  deadlineClock() {
    return Date.now();
  }

  // ---------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------

  async loadMeta() {
    if (this.metaCache === undefined) {
      this.metaCache = (await this.storage.get(META_KEY)) ?? null;
    }
    return this.metaCache;
  }

  async saveMeta(meta) {
    await this.storage.put(META_KEY, meta);
    this.metaCache = meta;
  }

  async authorize(secretHash) {
    const meta = await this.loadMeta();
    if (!meta) {
      return { error: failure(404, 'channel_not_found', 'This channel does not exist. Create a new channel and register your devices again.') };
    }
    if (!timingSafeEqualHex(meta.secretHash, secretHash)) {
      return { error: failure(401, 'unauthorized', 'The channel secret is wrong.') };
    }
    return { meta };
  }

  retentionDays() {
    const raw = this.env?.RETENTION_DAYS;
    if (raw === undefined || raw === null || String(raw).trim() === '') return DEFAULT_RETENTION_DAYS;
    const days = Number(raw);
    if (!Number.isFinite(days) || days <= 0) return 0; // 0 disables automatic deletion
    return Math.min(days, 3650);
  }

  retentionPurgeAt(now) {
    const days = this.retentionDays();
    return days > 0 ? now + days * DAY_MS : null;
  }

  async listDevices() {
    return this.storage.list({ prefix: DEVICE_PREFIX });
  }

  unregisteredExpired(entry, now) {
    return !entry || !Number.isFinite(entry.at) || now - entry.at > UNREGISTERED_MEMORY_DAYS * DAY_MS;
  }

  // Remembered 410s that have not expired, newest first.
  async listUnregistered(now) {
    const entries = await this.storage.list({ prefix: GONE_PREFIX });
    return [...entries]
      .filter(([, entry]) => !this.unregisteredExpired(entry, now))
      .sort(([, a], [, b]) => b.at - a.at);
  }

  // Drops expired entries and keeps at most MAX_UNREGISTERED.
  async pruneUnregistered(now) {
    const entries = await this.storage.list({ prefix: GONE_PREFIX });
    const sorted = [...entries].sort(([, a], [, b]) => (b.at ?? 0) - (a.at ?? 0));
    const drop = sorted
      .filter(([, entry], index) => index >= MAX_UNREGISTERED || this.unregisteredExpired(entry, now))
      .map(([key]) => key);
    if (drop.length) await this.storage.delete(drop);
  }

  // Stores the outcome of one APNs request on the device record. The device
  // may have been deleted or re-registered with another token while the
  // request was in flight: then the result is about a stale token and is
  // dropped.
  async recordDelivery(deviceId, token, result) {
    const meta = await this.loadMeta();
    if (!meta) return;
    const key = deviceKey(deviceId);
    const tokenHash = result.unregistered ? await sha256Hex(token) : null;
    const current = await this.storage.get(key);
    if (!current || current.token !== token) return;
    if (result.unregistered) {
      // APNs says the app is gone from that phone (or the token changed).
      // Delete the device and remember the token (hashed) so that an agent
      // re-registering every known device does not bring it back.
      const now = this.now();
      await this.storage.delete(key);
      await this.storage.put(goneKey(tokenHash), { deviceId, at: now });
      await this.pruneUnregistered(now);
      return;
    }
    const now = this.now();
    const updated = result.ok
      ? { ...current, lastDeliveryAt: now, lastError: null, lastErrorAt: null }
      : { ...current, lastError: result.reason ?? `HTTP ${result.status}`, lastErrorAt: now };
    await this.storage.put(key, updated);
  }

  async purge() {
    // deleteAll() only removes the alarm on newer compatibility dates.
    await this.storage.deleteAlarm();
    await this.storage.deleteAll();
    this.metaCache = null;
  }

  // ---------------------------------------------------------------------
  // RPC methods, called by the Worker only
  // ---------------------------------------------------------------------

  async initChannel({ channelId, secretHash }) {
    if (await this.loadMeta()) {
      return failure(409, 'channel_exists', 'A channel with this id already exists.');
    }
    const now = this.now();
    // A channel that never sends a heartbeat is dropped after a week.
    const purgeAt = this.retentionDays() > 0 ? now + NEW_CHANNEL_PURGE_DAYS * DAY_MS : null;
    if (purgeAt) await this.storage.setAlarm(purgeAt);
    await this.saveMeta({
      v: 1,
      channelId,
      secretHash,
      createdAt: now,
      state: 'new',
      stateSince: now,
      alarm: purgeAt ? 'purge' : null,
      offlineAfter: LIMITS.defaultOfflineAfterSeconds,
      alert: null,
      lastOfflineAlert: null,
    });
    return reply(201, { status: 'created' });
  }

  async getStatus(secretHash) {
    const { meta, error } = await this.authorize(secretHash);
    if (error) return error;
    const devices = [...(await this.listDevices()).values()].map((device) => ({
      deviceId: device.deviceId,
      env: device.env,
      hasOfflineCiphertext: typeof device.offlineCt === 'string',
      registeredAt: isoTime(device.registeredAt),
      updatedAt: isoTime(device.updatedAt),
      lastDeliveryAt: isoTime(device.lastDeliveryAt),
      lastError: device.lastError ?? null,
      lastErrorAt: isoTime(device.lastErrorAt),
    }));
    const alarmAt = await this.storage.getAlarm();
    const last = meta.lastOfflineAlert;
    const unregisteredDevices = (await this.listUnregistered(this.now())).map(([, entry]) => ({
      deviceId: entry.deviceId,
      unregisteredAt: isoTime(entry.at),
    }));
    return reply(200, {
      channelId: meta.channelId,
      state: meta.state,
      stateSince: isoTime(meta.stateSince),
      createdAt: isoTime(meta.createdAt),
      offlineAfterSeconds: meta.offlineAfter,
      alarm: alarmAt !== null && alarmAt !== undefined ? { kind: meta.alarm, at: isoTime(alarmAt) } : null,
      lastOfflineAlert: last ? { at: isoTime(last.at), sent: last.sent, failed: last.failed } : null,
      devices,
      unregisteredDevices,
      maxDevices: LIMITS.maxDevicesPerChannel,
    });
  }

  async putDevice(secretHash, deviceId, { token, env, offlineCt, reregistered = false }) {
    const { error } = await this.authorize(secretHash);
    if (error) return error;
    const tokenHash = await sha256Hex(token);
    const gone = await this.storage.get(goneKey(tokenHash));
    if (gone && !this.unregisteredExpired(gone, this.now()) && !reregistered) {
      return failure(
        410,
        'token_unregistered',
        'APNs reported this device token as no longer valid (Orbit was removed from the phone or the token changed). ' +
          'The device has to register again from the phone.',
        { unregisteredAt: isoTime(gone.at) },
      );
    }
    const devices = await this.listDevices();
    const key = deviceKey(deviceId);
    const existing = devices.get(key) ?? null;
    // The same APNs token under another deviceId is an old registration of
    // the same app install (e.g. after a reinstall). Keep only the newest so
    // the phone does not get every alert twice.
    const replaced = [];
    for (const device of devices.values()) {
      if (device.deviceId !== deviceId && device.token === token) replaced.push(device.deviceId);
    }
    if (!existing && devices.size - replaced.length >= LIMITS.maxDevicesPerChannel) {
      return failure(409, 'device_limit', `A channel can hold at most ${LIMITS.maxDevicesPerChannel} devices. Remove one first.`);
    }
    const now = this.now();
    const sameTarget = existing && existing.token === token && existing.env === env;
    const record = {
      deviceId,
      token,
      env,
      offlineCt: offlineCt === undefined ? (existing?.offlineCt ?? null) : offlineCt,
      registeredAt: existing?.registeredAt ?? now,
      updatedAt: now,
      lastDeliveryAt: sameTarget ? (existing.lastDeliveryAt ?? null) : null,
      lastError: sameTarget ? (existing.lastError ?? null) : null,
      lastErrorAt: sameTarget ? (existing.lastErrorAt ?? null) : null,
    };
    await this.storage.put(key, record);
    if (replaced.length) await this.storage.delete(replaced.map(deviceKey));
    if (gone) await this.storage.delete(goneKey(tokenHash));
    return reply(200, {
      status: 'registered',
      created: !existing,
      hasOfflineCiphertext: typeof record.offlineCt === 'string',
      replaced,
    });
  }

  async deleteDevice(secretHash, deviceId) {
    const { error } = await this.authorize(secretHash);
    if (error) return error;
    const existed = await this.storage.delete(deviceKey(deviceId));
    return reply(200, { status: 'deleted', existed: Boolean(existed) });
  }

  async notify(secretHash, { items, level, collapseId, ttl }) {
    const { meta, error } = await this.authorize(secretHash);
    if (error) return error;
    const config = apnsConfig(this.env);
    if (!config) {
      return failure(503, 'apns_not_configured', 'The relay has no APNs key configured yet.');
    }
    const now = () => this.now();
    const deviceIds = Object.keys(items);
    const records = await this.storage.get(deviceIds.map(deviceKey));
    const targets = deviceIds.filter((id) => records.has(deviceKey(id)));
    const environments = new Set(targets.map((id) => records.get(deviceKey(id)).env));
    try {
      // Build (or reuse) the provider tokens up front so a broken key fails
      // the whole request instead of every device separately.
      for (const environment of environments) await providerToken(config, environment, { now });
    } catch (err) {
      if (err instanceof ApnsConfigError) {
        console.error(JSON.stringify({ event: 'apns_config_error', message: err.message }));
        return failure(503, 'apns_not_configured', 'The relay cannot use its APNs key. The relay operator has to fix it.');
      }
      throw err;
    }

    const expiration = ttl === 0 ? 0 : Math.floor(this.now() / 1000) + ttl;
    const apnsCollapseId = collapseId ? collapseIdFor(meta.channelId, collapseId) : undefined;
    const clock = () => this.deadlineClock();
    const deadline = clock() + NOTIFY_DEADLINE_MS;
    const results = {};
    await Promise.all(
      deviceIds.map(async (deviceId) => {
        const device = records.get(deviceKey(deviceId));
        if (!device) {
          results[deviceId] = { status: 'unknown_device', retryable: false };
          return;
        }
        let result;
        try {
          result = await sendAlert(
            config,
            {
              token: device.token,
              environment: device.env,
              ciphertext: items[deviceId],
              level,
              threadId: meta.channelId,
              priority: apnsPriority(level),
              expiration,
              collapseId: apnsCollapseId,
            },
            { now, deadline, clock },
          );
        } catch (err) {
          result = { ok: false, status: 0, reason: err?.message ?? 'Error', retryable: true, unregistered: false };
        }
        results[deviceId] = deliveryResult(result);
        await this.recordDelivery(deviceId, device.token, result);
      }),
    );
    const sent = Object.values(results).filter((r) => r.status === 'sent').length;
    return reply(200, { results, sent, failed: deviceIds.length - sent });
  }

  // Whether a "PC offline" push reached, or may still be reaching, at least
  // one phone during the outage a heartbeat in this state ends.
  async offlineAlertDelivered(meta) {
    if (meta.state === 'offline') return (meta.lastOfflineAlert?.sent ?? 0) > 0;
    if (meta.state !== 'alerting' || !meta.alert) return false;
    const alert = meta.alert;
    if ((alert.sent ?? 0) > 0) return true;
    // Pushes of the current attempt are still on their way to APNs...
    if (this.offlineSendsInFlight > 0) return true;
    // ...or went out in an attempt whose progress was never saved (the
    // object was reset mid-delivery).
    const pending = new Set(alert.pending ?? []);
    for (const device of (await this.listDevices()).values()) {
      if (pending.has(device.deviceId) && (device.lastDeliveryAt ?? 0) >= alert.startedAt) return true;
    }
    return false;
  }

  async heartbeat(secretHash, { offlineAfterSeconds }) {
    const { meta, error } = await this.authorize(secretHash);
    if (error) return error;
    const offlineAlertSent = await this.offlineAlertDelivered(meta);
    const now = this.now();
    const previousState = meta.state;
    const offlineAt = now + offlineAfterSeconds * 1000;
    // The steady state costs exactly one write: moving the alarm.
    await this.storage.setAlarm(offlineAt);
    if (meta.state !== 'online' || meta.alarm !== 'offline' || meta.offlineAfter !== offlineAfterSeconds || meta.alert) {
      await this.saveMeta({
        ...meta,
        state: 'online',
        stateSince: meta.state === 'online' ? meta.stateSince : now,
        alarm: 'offline',
        offlineAfter: offlineAfterSeconds,
        alert: null,
      });
    }
    return reply(200, {
      status: 'ok',
      state: 'online',
      previousState,
      offlineAlertSent,
      offlineAfterSeconds,
      offlineAt: isoTime(offlineAt),
      heartbeatSeconds: LIMITS.heartbeatSeconds,
    });
  }

  async offlineExpected(secretHash, { backWithinSeconds }) {
    const { meta, error } = await this.authorize(secretHash);
    if (error) return error;
    const now = this.now();
    let alarm;
    let offlineAt = null;
    if (backWithinSeconds) {
      // Planned restart: stay quiet, but alert if the PC is not back in time.
      offlineAt = now + backWithinSeconds * 1000;
      await this.storage.setAlarm(offlineAt);
      alarm = 'offline';
    } else {
      // Planned sleep or shutdown: stop the dead-man switch...
      await this.storage.deleteAlarm();
      // ...and only keep the retention clean-up.
      const purgeAt = this.retentionPurgeAt(now);
      if (purgeAt) await this.storage.setAlarm(purgeAt);
      alarm = purgeAt ? 'purge' : null;
    }
    await this.saveMeta({
      ...meta,
      state: 'expected-offline',
      stateSince: now,
      alarm,
      alert: null,
    });
    return reply(200, { status: 'ok', state: 'expected-offline', offlineAt: isoTime(offlineAt) });
  }

  async destroyChannel(secretHash) {
    const { error } = await this.authorize(secretHash);
    if (error) return error;
    await this.purge();
    return reply(200, { status: 'deleted' });
  }

  // ---------------------------------------------------------------------
  // Alarm
  // ---------------------------------------------------------------------

  async alarm(alarmInfo) {
    const meta = await this.loadMeta();
    if (!meta) {
      // Nothing left to watch (should not happen: purge deletes the alarm).
      await this.storage.deleteAlarm();
      return;
    }
    // An offline alert that has not finished always resumes, whatever alarm
    // kind is recorded: the runtime retries an alarm whose handler was cut
    // off (deploy, secret change, storage error), and the alert must neither
    // be lost nor leave the channel without an alarm (no retention purge).
    if (meta.state === 'alerting' && meta.alert) {
      if (alarmInfo?.isRetry) {
        console.log(JSON.stringify({ event: 'offline_alert_resumed', channel: meta.channelId.slice(0, 8), retryCount: alarmInfo.retryCount ?? null }));
      }
      return this.deliverOfflineAlert(meta.alert);
    }
    switch (meta.alarm) {
      case 'offline':
        return this.startOfflineAlert(meta);
      case 'purge':
        console.log(JSON.stringify({ event: 'channel_purged', channel: meta.channelId.slice(0, 8), state: meta.state }));
        return this.purge();
      default:
        // Nothing to do. Keep the retention promise anyway: a channel left
        // without a dead-man alarm is still deleted eventually.
        return this.ensureRetentionAlarm(meta);
    }
  }

  async ensureRetentionAlarm(meta) {
    if (meta.state === 'online' || meta.state === 'new') return; // a heartbeat or the 7-day purge owns the alarm
    if ((await this.storage.getAlarm()) !== null) return;
    const purgeAt = this.retentionPurgeAt(this.now());
    if (!purgeAt) return;
    await this.storage.setAlarm(purgeAt);
    await this.saveMeta({ ...meta, state: meta.state === 'alerting' ? 'offline' : meta.state, alarm: 'purge', alert: null });
  }

  async startOfflineAlert(meta) {
    const now = this.now();
    const devices = await this.listDevices();
    const pending = [...devices.values()].filter((d) => typeof d.offlineCt === 'string').map((d) => d.deviceId);
    const alert = { id: randomHex(8), startedAt: now, pending, attempts: 0, sent: 0, failed: 0 };
    // Saved (with the resumable marker) before any push goes out.
    await this.saveMeta({ ...meta, state: 'alerting', stateSince: now, alarm: 'alert-retry', alert });
    console.log(JSON.stringify({ event: 'pc_offline', channel: meta.channelId.slice(0, 8), devices: pending.length }));
    return this.deliverOfflineAlert(alert);
  }

  async deliverOfflineAlert(alert) {
    const meta = await this.loadMeta();
    if (!meta || meta.state !== 'alerting' || !alert || meta.alert?.id !== alert.id) return;
    const attempt = alert.attempts + 1;
    let sent = alert.sent;
    let failed = alert.failed ?? 0; // permanent failures (410, bad token, ...)
    const retry = [];
    const config = apnsConfig(this.env);

    if (alert.pending.length) {
      if (!config) {
        console.error(JSON.stringify({ event: 'apns_not_configured', channel: meta.channelId.slice(0, 8) }));
        retry.push(...alert.pending);
      } else {
        const now = () => this.now();
        const records = await this.storage.get(alert.pending.map(deviceKey));
        const expiration = Math.floor(this.now() / 1000) + OFFLINE_ALERT_TTL_SECONDS;
        await Promise.all(
          alert.pending.map(async (deviceId) => {
            const device = records.get(deviceKey(deviceId));
            if (!device || typeof device.offlineCt !== 'string') return; // removed meanwhile
            let result;
            this.offlineSendsInFlight += 1;
            try {
              result = await sendAlert(
                config,
                {
                  token: device.token,
                  environment: device.env,
                  ciphertext: device.offlineCt,
                  level: 'time-sensitive',
                  threadId: meta.channelId,
                  priority: 10,
                  expiration,
                  collapseId: collapseIdFor(meta.channelId, OFFLINE_COLLAPSE_SUFFIX),
                },
                { now },
              );
            } catch (err) {
              result = { ok: false, status: 0, reason: err?.message ?? 'Error', retryable: true, unregistered: false };
            } finally {
              this.offlineSendsInFlight -= 1;
            }
            await this.recordDelivery(deviceId, device.token, result);
            if (result.ok) sent += 1;
            else if (result.retryable) retry.push(deviceId);
            else failed += 1;
          }),
        );
      }
    }

    // A heartbeat, offline-expected or delete may have arrived while the
    // pushes were in flight. Then the PC is back (or gone) and this alert is
    // over: leave the state and the alarm that request set alone.
    const current = await this.loadMeta();
    if (!current || current.state !== 'alerting' || current.alert?.id !== alert.id) return;

    const now = this.now();
    if (retry.length && attempt <= ALERT_RETRY_DELAYS_SECONDS.length) {
      await this.storage.setAlarm(now + ALERT_RETRY_DELAYS_SECONDS[attempt - 1] * 1000);
      await this.saveMeta({
        ...current,
        alarm: 'alert-retry',
        alert: { ...alert, pending: retry, attempts: attempt, sent, failed },
      });
      return;
    }
    const purgeAt = this.retentionPurgeAt(now);
    if (purgeAt) await this.storage.setAlarm(purgeAt);
    await this.saveMeta({
      ...current,
      state: 'offline',
      stateSince: alert.startedAt,
      alarm: purgeAt ? 'purge' : null,
      alert: null,
      lastOfflineAlert: { at: alert.startedAt, sent, failed: failed + retry.length },
    });
  }
}
