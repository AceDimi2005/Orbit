// Heartbeats, the dead-man switch, planned offline and retention.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHarness, deviceToken, fakeCiphertext, flushTasks, verifyJwt, channelModule, MINUTE, DAY } from './helpers.js';

const { CHANNEL_CONSTANTS } = channelModule;
const DEVICE_A = 'DEVICE-A-0001';
const DEVICE_B = 'DEVICE-B-0002';
const DEVICE_C = 'DEVICE-C-0003';

async function setupOnline(t, options) {
  const h = createHarness(t, options);
  const channel = await h.createChannel();
  const tokens = { [DEVICE_A]: deviceToken(), [DEVICE_B]: deviceToken(), [DEVICE_C]: deviceToken() };
  const offline = { [DEVICE_A]: fakeCiphertext(), [DEVICE_B]: fakeCiphertext() };
  await h.putDevice(channel, DEVICE_A, { token: tokens[DEVICE_A], env: 'production', offlineCt: offline[DEVICE_A] });
  await h.putDevice(channel, DEVICE_B, { token: tokens[DEVICE_B], env: 'sandbox', offlineCt: offline[DEVICE_B] });
  // Device C never uploaded an offline ciphertext: it gets no offline alert.
  await h.putDevice(channel, DEVICE_C, { token: tokens[DEVICE_C], env: 'production' });
  const hb = await h.heartbeat(channel);
  assert.equal(hb.status, 200);
  const storage = h.ns.storage(channel.channelId);
  return { h, channel, tokens, offline, storage };
}

function meta(storage) {
  return storage.data.get('meta');
}

test('heartbeat arms the alarm 15 minutes ahead and reports the state', async (t) => {
  const h = createHarness(t);
  const channel = await h.createChannel();
  const res = await h.heartbeat(channel);
  assert.equal(res.status, 200);
  assert.deepEqual(res.json, {
    status: 'ok',
    state: 'online',
    previousState: 'new',
    offlineAlertSent: false,
    offlineAfterSeconds: 900,
    offlineAt: '2026-10-23T18:15:00Z',
    heartbeatSeconds: 300,
  });
  const storage = h.ns.storage(channel.channelId);
  assert.equal(storage.alarmAt, h.clock.now + 15 * MINUTE);
  assert.equal(meta(storage).alarm, 'offline');
  assert.equal(meta(storage).state, 'online');
});

test('a steady-state heartbeat costs exactly one write (the alarm)', async (t) => {
  const h = createHarness(t);
  const channel = await h.createChannel();
  await h.heartbeat(channel);
  const storage = h.ns.storage(channel.channelId);
  for (let i = 0; i < 3; i++) {
    h.advance(5 * MINUTE);
    const writesBefore = storage.writes;
    const res = await h.heartbeat(channel);
    assert.equal(res.json.previousState, 'online');
    assert.equal(storage.writes - writesBefore, 1);
    assert.equal(storage.alarmAt, h.clock.now + 15 * MINUTE);
  }
});

test('heartbeat accepts a custom offline window within limits', async (t) => {
  const h = createHarness(t);
  const channel = await h.createChannel();
  const res = await h.heartbeat(channel, { offlineAfterSeconds: 1800 });
  assert.equal(res.json.offlineAfterSeconds, 1800);
  assert.equal(h.ns.storage(channel.channelId).alarmAt, h.clock.now + 30 * MINUTE);
  for (const bad of [299, 3601, 900.5, '900']) {
    assert.equal((await h.heartbeat(channel, { offlineAfterSeconds: bad })).status, 400, String(bad));
  }
  assert.equal((await h.request('POST', `/v1/c/${channel.channelId}/hb`, { secret: channel.pcSecret, raw: '[]' })).status, 400);
});

test('missed heartbeats: the alarm sends the stored offline ciphertexts', async (t) => {
  const { h, channel, tokens, offline, storage } = await setupOnline(t);
  h.advance(15 * MINUTE);
  await h.ns.fireAlarm(channel.channelId);

  assert.equal(h.fetchMock.calls.length, 2, 'only devices with an offline ciphertext are alerted');
  const byToken = Object.fromEntries(h.fetchMock.calls.map((c) => [c.url.split('/').pop(), c]));
  assert.ok(!byToken[tokens[DEVICE_C]]);
  const callA = byToken[tokens[DEVICE_A]];
  const callB = byToken[tokens[DEVICE_B]];
  assert.equal(callA.url, `https://api.push.apple.com/3/device/${tokens[DEVICE_A]}`);
  assert.equal(callB.url, `https://api.sandbox.push.apple.com/3/device/${tokens[DEVICE_B]}`);
  assert.equal(callA.json.o, offline[DEVICE_A]);
  assert.equal(callB.json.o, offline[DEVICE_B]);
  for (const call of [callA, callB]) {
    assert.equal(call.json.aps['interruption-level'], 'time-sensitive');
    assert.equal(call.json.aps['thread-id'], channel.channelId);
    assert.equal(call.json.aps.alert.title, 'Orbit');
    assert.equal(call.json.aps['mutable-content'], 1);
    assert.equal(call.headers['apns-priority'], '10');
    assert.equal(call.headers['apns-push-type'], 'alert');
    assert.equal(call.headers['apns-collapse-id'], `${channel.channelId.slice(0, 12)}.offline`);
    assert.equal(
      call.headers['apns-expiration'],
      String(Math.floor(h.clock.now / 1000) + CHANNEL_CONSTANTS.OFFLINE_ALERT_TTL_SECONDS),
    );
    assert.ok(verifyJwt(call.headers.authorization.slice(7), h.key.publicKey));
  }

  assert.equal(meta(storage).state, 'offline');
  assert.equal(meta(storage).alarm, 'purge');
  assert.equal(storage.alarmAt, h.clock.now + 90 * DAY, 'retention clean-up scheduled');
  const status = (await h.status(channel)).json;
  assert.equal(status.state, 'offline');
  assert.equal(status.stateSince, '2026-10-23T18:15:00Z');
  assert.deepEqual(status.lastOfflineAlert, { at: '2026-10-23T18:15:00Z', sent: 2, failed: 0 });
  assert.deepEqual(status.alarm, { kind: 'purge', at: '2027-01-21T18:15:00Z' });
  assert.ok(status.devices.find((d) => d.deviceId === DEVICE_A).lastDeliveryAt);
});

test('the next heartbeat after an offline alert says so', async (t) => {
  const { h, channel, storage } = await setupOnline(t);
  h.advance(20 * MINUTE);
  await h.ns.fireAlarm(channel.channelId);
  h.advance(10 * MINUTE);
  const res = await h.heartbeat(channel);
  assert.equal(res.json.previousState, 'offline');
  assert.equal(res.json.offlineAlertSent, true);
  assert.equal(meta(storage).state, 'online');
  assert.equal(meta(storage).alarm, 'offline');
  assert.equal(storage.alarmAt, h.clock.now + 15 * MINUTE);
  // And the switch works again.
  h.fetchMock.reset();
  h.advance(15 * MINUTE);
  await h.ns.fireAlarm(channel.channelId);
  assert.equal(h.fetchMock.calls.length, 2);
});

test('offline alerts that fail with retryable errors are retried with backoff', async (t) => {
  const { h, channel, tokens, storage } = await setupOnline(t);
  let unavailable = true;
  h.fetchMock.respond((call) =>
    unavailable && call.url.endsWith(tokens[DEVICE_B]) ? { status: 503, reason: 'ServiceUnavailable' } : { status: 200 },
  );
  h.advance(15 * MINUTE);
  await h.ns.fireAlarm(channel.channelId);
  assert.equal(meta(storage).state, 'alerting');
  assert.equal(meta(storage).alarm, 'alert-retry');
  assert.deepEqual(meta(storage).alert.pending, [DEVICE_B]);
  assert.equal(storage.alarmAt, h.clock.now + 30 * 1000);

  // Second attempt still fails -> 2 minutes.
  h.fetchMock.reset();
  h.fetchMock.respond(() => ({ status: 503, reason: 'ServiceUnavailable' }));
  h.advance(30 * 1000);
  await h.ns.fireAlarm(channel.channelId);
  assert.equal(h.fetchMock.calls.length, 1, 'only the failed device is retried');
  assert.ok(h.fetchMock.calls[0].url.endsWith(tokens[DEVICE_B]));
  assert.equal(storage.alarmAt, h.clock.now + 120 * 1000);

  // Third attempt succeeds.
  h.fetchMock.reset();
  unavailable = false;
  h.fetchMock.respond(() => ({ status: 200 }));
  h.advance(120 * 1000);
  await h.ns.fireAlarm(channel.channelId);
  assert.equal(meta(storage).state, 'offline');
  assert.equal(meta(storage).alarm, 'purge');
  assert.deepEqual(meta(storage).lastOfflineAlert, { at: meta(storage).stateSince, sent: 2, failed: 0 });
});

test('offline alerts give up after four attempts', async (t) => {
  const { h, channel, storage } = await setupOnline(t);
  h.fetchMock.respond(() => ({ status: 503, reason: 'ServiceUnavailable' }));
  h.advance(15 * MINUTE);
  await h.ns.fireAlarm(channel.channelId);
  for (const delay of CHANNEL_CONSTANTS.ALERT_RETRY_DELAYS_SECONDS) {
    assert.equal(meta(storage).alarm, 'alert-retry');
    h.advance(delay * 1000);
    await h.ns.fireAlarm(channel.channelId);
  }
  assert.equal(h.fetchMock.calls.length, 2 * 4);
  assert.equal(meta(storage).state, 'offline');
  assert.equal(meta(storage).lastOfflineAlert.failed, 2);
  assert.equal(meta(storage).alarm, 'purge');
});

test('a 410 during the offline alert removes that device for good', async (t) => {
  const { h, channel, tokens, storage } = await setupOnline(t);
  h.fetchMock.respond((call) => (call.url.endsWith(tokens[DEVICE_A]) ? { status: 410, reason: 'Unregistered' } : { status: 200 }));
  h.advance(15 * MINUTE);
  await h.ns.fireAlarm(channel.channelId);
  assert.equal(storage.data.has(`device:${DEVICE_A}`), false);
  assert.equal(meta(storage).state, 'offline');
  assert.deepEqual(meta(storage).lastOfflineAlert, { at: meta(storage).stateSince, sent: 1, failed: 1 });

  // The agent never saw that 410. When the PC comes back it PUTs every
  // device it knows again: the dead token is refused instead of coming back
  // and failing at every future offline alert.
  h.advance(60 * MINUTE);
  await h.heartbeat(channel);
  const replay = await h.putDevice(channel, DEVICE_A, { token: tokens[DEVICE_A], env: 'production', offlineCt: fakeCiphertext() });
  assert.equal(replay.status, 410);
  assert.equal(replay.json.error, 'token_unregistered');
  assert.equal(replay.json.unregisteredAt, '2026-10-23T18:15:00Z');
  const status = (await h.status(channel)).json;
  assert.deepEqual(status.unregisteredDevices, [{ deviceId: DEVICE_A, unregisteredAt: '2026-10-23T18:15:00Z' }]);
  h.fetchMock.reset();
  h.advance(15 * MINUTE);
  await h.ns.fireAlarm(channel.channelId);
  assert.ok(!h.fetchMock.calls.some((c) => c.url.endsWith(tokens[DEVICE_A])), 'no more pushes to the dead token');
});

test('a heartbeat that arrives while offline alerts are in flight wins', async (t) => {
  const { h, channel, storage } = await setupOnline(t);
  let hbResponse = null;
  h.fetchMock.respond(async (_call, n) => {
    if (n === 1) hbResponse = await h.heartbeat(channel);
    return { status: 503, reason: 'ServiceUnavailable' };
  });
  h.advance(15 * MINUTE);
  await h.ns.fireAlarm(channel.channelId);
  assert.equal(hbResponse.json.previousState, 'alerting');
  assert.equal(hbResponse.json.offlineAlertSent, true);
  assert.equal(meta(storage).state, 'online', 'the alarm did not overwrite the heartbeat');
  assert.equal(meta(storage).alarm, 'offline');
  assert.equal(meta(storage).alert, null);
  assert.equal(storage.alarmAt, h.clock.now + 15 * MINUTE, 'no retry was scheduled over the new dead-man alarm');
});

test('an offline alert cut off mid-delivery resumes when the runtime retries the alarm', async (t) => {
  const { h, channel, tokens, storage } = await setupOnline(t);
  // The first delivery record fails to save: the handler throws and the real
  // runtime resets the object (a deploy or `wrangler secret put` does the same).
  storage.failPutOnce((key) => key.startsWith('device:'));
  h.advance(15 * MINUTE);
  await assert.rejects(h.ns.fireAlarm(channel.channelId), /simulated storage failure/);
  await flushTasks();
  assert.equal(meta(storage).state, 'alerting');
  assert.equal(meta(storage).alarm, 'alert-retry', 'a resumable marker was saved before the first push');
  assert.equal(h.fetchMock.calls.length, 2);

  h.fetchMock.reset();
  h.advance(2000);
  await h.ns.retryAlarm(channel.channelId);
  const sentTo = h.fetchMock.calls.map((c) => c.url.split('/').pop()).sort();
  assert.deepEqual(sentTo, [tokens[DEVICE_A], tokens[DEVICE_B]].sort(), 'the offline pushes went out on the retry');
  assert.equal(meta(storage).state, 'offline');
  assert.equal(meta(storage).alarm, 'purge');
  assert.equal(storage.alarmAt, h.clock.now + 90 * DAY, 'the retention clean-up is scheduled again');
  assert.equal(meta(storage).lastOfflineAlert.sent, 2);
  const hb = await h.heartbeat(channel);
  assert.equal(hb.json.offlineAlertSent, true);
});

test('an alerting channel whose alarm marker was lost still resumes its alert', async (t) => {
  const { h, channel, storage } = await setupOnline(t);
  h.advance(15 * MINUTE);
  // An inconsistent record: alerting, alert pending, but no alarm kind.
  const record = meta(storage);
  storage.data.set('meta', {
    ...record,
    state: 'alerting',
    stateSince: h.clock.now,
    alarm: null,
    alert: { id: 'feedfacecafebeef', startedAt: h.clock.now, pending: [DEVICE_A, DEVICE_B], attempts: 0, sent: 0, failed: 0 },
  });
  await h.ns.retryAlarm(channel.channelId);
  assert.equal(h.fetchMock.calls.length, 2);
  assert.equal(meta(storage).state, 'offline');
  assert.equal(meta(storage).alarm, 'purge');
  assert.equal(storage.alarmAt, h.clock.now + 90 * DAY);
});

test('offlineAlertSent is false when no offline push was delivered', async (t) => {
  // No device has an offline ciphertext: nothing to deliver.
  const h = createHarness(t);
  const channel = await h.createChannel();
  await h.putDevice(channel, DEVICE_A, { token: deviceToken(), env: 'production' });
  await h.heartbeat(channel);
  h.advance(15 * MINUTE);
  await h.ns.fireAlarm(channel.channelId);
  assert.equal(meta(h.ns.storage(channel.channelId)).state, 'offline');
  h.advance(5 * MINUTE);
  const back = await h.heartbeat(channel);
  assert.equal(back.json.previousState, 'offline');
  assert.equal(back.json.offlineAlertSent, false, 'no "PC offline" reached the phone, so no "back online" either');
});

test('offlineAlertSent is false when every offline push failed', async (t) => {
  const { h, channel, storage } = await setupOnline(t);
  h.fetchMock.respond(() => ({ status: 400, reason: 'BadDeviceToken' }));
  h.advance(15 * MINUTE);
  await h.ns.fireAlarm(channel.channelId);
  assert.equal(meta(storage).state, 'offline');
  assert.deepEqual(meta(storage).lastOfflineAlert, { at: meta(storage).stateSince, sent: 0, failed: 2 });
  assert.equal((await h.heartbeat(channel)).json.offlineAlertSent, false);
});

test('offlineAlertSent during retries reflects what was delivered so far', async (t) => {
  const { h, channel, tokens, storage } = await setupOnline(t);
  // All retryable failures: nothing delivered yet, a retry is scheduled.
  h.fetchMock.respond(() => ({ status: 503, reason: 'ServiceUnavailable' }));
  h.advance(15 * MINUTE);
  await h.ns.fireAlarm(channel.channelId);
  assert.equal(meta(storage).alarm, 'alert-retry');
  let hb = await h.heartbeat(channel);
  assert.equal(hb.json.previousState, 'alerting');
  assert.equal(hb.json.offlineAlertSent, false);

  // One device delivered, the other is being retried.
  h.advance(15 * MINUTE);
  h.fetchMock.respond((call) => (call.url.endsWith(tokens[DEVICE_B]) ? { status: 503, reason: 'ServiceUnavailable' } : { status: 200 }));
  await h.ns.fireAlarm(channel.channelId);
  assert.equal(meta(storage).alarm, 'alert-retry');
  assert.equal(meta(storage).alert.sent, 1);
  hb = await h.heartbeat(channel);
  assert.equal(hb.json.offlineAlertSent, true);
});

test('the alarm without APNs secrets retries, then marks the PC offline', async (t) => {
  const { h, channel, storage } = await setupOnline(t, { withApns: false });
  h.advance(15 * MINUTE);
  await h.ns.fireAlarm(channel.channelId);
  assert.equal(meta(storage).alarm, 'alert-retry');
  for (const delay of CHANNEL_CONSTANTS.ALERT_RETRY_DELAYS_SECONDS) {
    h.advance(delay * 1000);
    await h.ns.fireAlarm(channel.channelId);
  }
  assert.equal(h.fetchMock.calls.length, 0);
  assert.equal(meta(storage).state, 'offline');
});

test('a channel with no offline ciphertexts just goes offline quietly', async (t) => {
  const h = createHarness(t);
  const channel = await h.createChannel();
  await h.putDevice(channel, DEVICE_A, { token: deviceToken(), env: 'production' });
  await h.heartbeat(channel);
  h.advance(15 * MINUTE);
  await h.ns.fireAlarm(channel.channelId);
  assert.equal(h.fetchMock.calls.length, 0);
  assert.equal(meta(h.ns.storage(channel.channelId)).state, 'offline');
});

test('offline-expected stops the dead-man switch: no alert when heartbeats stop', async (t) => {
  const { h, channel, storage } = await setupOnline(t);
  h.advance(2 * MINUTE);
  const res = await h.request('POST', `/v1/c/${channel.channelId}/offline-expected`, { secret: channel.pcSecret });
  assert.equal(res.status, 200);
  assert.deepEqual(res.json, { status: 'ok', state: 'expected-offline', offlineAt: null });
  assert.ok(storage.log.some(([op]) => op === 'deleteAlarm'), 'deleteAlarm() was called');
  assert.equal(meta(storage).state, 'expected-offline');
  assert.equal(meta(storage).alarm, 'purge');
  assert.equal(storage.alarmAt, h.clock.now + 90 * DAY, 'only the retention clean-up is left');

  // Hours pass without heartbeats: nothing is sent.
  h.advance(6 * 60 * MINUTE);
  await assert.rejects(h.ns.fireAlarm(channel.channelId), /not due yet/);
  assert.equal(h.fetchMock.calls.length, 0);

  // The PC wakes up.
  const hb = await h.heartbeat(channel);
  assert.equal(hb.json.previousState, 'expected-offline');
  assert.equal(hb.json.offlineAlertSent, false);
  assert.equal(meta(storage).alarm, 'offline');
});

test('offline-expected with RETENTION_DAYS=0 leaves no alarm at all', async (t) => {
  const { h, channel, storage } = await setupOnline(t, { env: { RETENTION_DAYS: '0' } });
  const res = await h.request('POST', `/v1/c/${channel.channelId}/offline-expected`, { secret: channel.pcSecret, body: {} });
  assert.equal(res.status, 200);
  assert.equal(storage.alarmAt, null);
  assert.equal(meta(storage).alarm, null);
});

test('offline-expected with backWithinSeconds alerts if the PC does not return', async (t) => {
  const { h, channel, storage } = await setupOnline(t);
  const res = await h.request('POST', `/v1/c/${channel.channelId}/offline-expected`, {
    secret: channel.pcSecret,
    body: { backWithinSeconds: 1200 },
  });
  assert.equal(res.json.offlineAt, '2026-10-23T18:20:00Z');
  assert.equal(storage.alarmAt, h.clock.now + 20 * MINUTE);
  h.advance(20 * MINUTE);
  await h.ns.fireAlarm(channel.channelId);
  assert.equal(h.fetchMock.calls.length, 2);
  assert.equal(meta(storage).state, 'offline');

  for (const bad of [30, 86401, -5, 'soon']) {
    const r = await h.request('POST', `/v1/c/${channel.channelId}/offline-expected`, { secret: channel.pcSecret, body: { backWithinSeconds: bad } });
    assert.equal(r.status, 400, String(bad));
  }
});

test('offline-expected during an offline alert ends the alert', async (t) => {
  const { h, channel, storage } = await setupOnline(t);
  h.fetchMock.respond(async (_call, n) => {
    if (n === 1) await h.request('POST', `/v1/c/${channel.channelId}/offline-expected`, { secret: channel.pcSecret });
    return { status: 503, reason: 'ServiceUnavailable' };
  });
  h.advance(15 * MINUTE);
  await h.ns.fireAlarm(channel.channelId);
  assert.equal(meta(storage).state, 'expected-offline');
  assert.equal(meta(storage).alarm, 'purge');
});

test('retention: a channel offline for 90 days is deleted', async (t) => {
  const { h, channel, storage } = await setupOnline(t);
  h.advance(15 * MINUTE);
  await h.ns.fireAlarm(channel.channelId);
  h.advance(90 * DAY);
  await h.ns.fireAlarm(channel.channelId);
  assert.equal(storage.data.size, 0);
  assert.equal(storage.alarmAt, null);
  const hb = await h.heartbeat(channel);
  assert.equal(hb.status, 404);
  assert.equal(hb.json.error, 'channel_not_found');
});

test('retention: a new channel that never sends a heartbeat is deleted after 7 days', async (t) => {
  const h = createHarness(t);
  const channel = await h.createChannel();
  await h.putDevice(channel, DEVICE_A, { token: deviceToken(), env: 'production', offlineCt: fakeCiphertext() });
  h.advance(7 * DAY);
  await h.ns.fireAlarm(channel.channelId);
  assert.equal(h.fetchMock.calls.length, 0, 'a purge sends nothing');
  assert.equal((await h.status(channel)).status, 404);
});

test('retention: RETENTION_DAYS=0 keeps channels forever', async (t) => {
  const h = createHarness(t, { env: { RETENTION_DAYS: '0' } });
  const channel = await h.createChannel();
  assert.equal(h.ns.storage(channel.channelId).alarmAt, null);
  await h.putDevice(channel, DEVICE_A, { token: deviceToken(), env: 'production', offlineCt: fakeCiphertext() });
  await h.heartbeat(channel);
  h.advance(15 * MINUTE);
  await h.ns.fireAlarm(channel.channelId);
  const storage = h.ns.storage(channel.channelId);
  assert.equal(meta(storage).state, 'offline');
  assert.equal(storage.alarmAt, null);
});

test('the alarm still works after the object was evicted from memory', async (t) => {
  const { h, channel, storage } = await setupOnline(t);
  h.ns.evict(channel.channelId);
  h.advance(15 * MINUTE);
  await h.ns.fireAlarm(channel.channelId);
  assert.equal(h.fetchMock.calls.length, 2);
  assert.equal(meta(storage).state, 'offline');
});

test('an alarm firing on a deleted channel does nothing', async (t) => {
  const h = createHarness(t);
  const channel = await h.createChannel();
  await h.request('DELETE', `/v1/c/${channel.channelId}`, { secret: channel.pcSecret });
  const storage = h.ns.storage(channel.channelId);
  storage.alarmAt = h.clock.now; // a stale alarm the runtime still delivers
  await h.ns.fireAlarm(channel.channelId);
  assert.equal(storage.data.size, 0);
  assert.equal(h.fetchMock.calls.length, 0);
});

test('an alarm with nothing to do still leaves the retention clean-up scheduled', async (t) => {
  const { h, channel, storage } = await setupOnline(t);
  // Inconsistent records an older relay version or a cut-off write could leave.
  for (const broken of [
    { state: 'expected-offline', alarm: null, alert: null },
    { state: 'alerting', alarm: null, alert: null },
  ]) {
    storage.data.set('meta', { ...meta(storage), ...broken });
    storage.alarmAt = null;
    await h.ns.retryAlarm(channel.channelId);
    assert.equal(h.fetchMock.calls.length, 0);
    assert.equal(meta(storage).alarm, 'purge', broken.state);
    assert.equal(meta(storage).state, broken.state === 'alerting' ? 'offline' : broken.state);
    assert.equal(storage.alarmAt, h.clock.now + 90 * DAY);
  }
});
