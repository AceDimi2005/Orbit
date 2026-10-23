# Orbit push relay: HTTP protocol (version 1)

This is the contract between the **Windows agent** (`Orbit-Windows-Agent/orbit_push.py`) and the
**push relay** in this folder. The iPhone never talks to the relay. It registers with the agent over the
existing pinned-TLS connection (`POST /api/push/register`, see DESIGN F1). The agent then manages the
relay on the phone's behalf.

```
iPhone ──(pinned TLS, /api/push/register)──▶ Windows agent ──(HTTPS, this protocol)──▶ relay ──▶ APNs ──▶ iPhone (NSE decrypts)
```

The relay only ever handles ciphertext. It cannot read titles, bodies, PC names or event kinds.

## 1. Transport

| Item | Rule |
|---|---|
| Base URL | `DEFAULT_RELAY_URL` in `orbit_push.py`, overridden by the env var `ORBIT_PUSH_RELAY_URL`, then by settings `push.relayURL`. It has no trailing slash, for example `https://orbit-push-relay.example.workers.dev`. An empty URL disables the relay. The agent still records events, and the apps poll `/api/events`. |
| Scheme | **HTTPS only.** Secret-bearing routes over plain `http://` answer `426 https_required`. The only exception is `localhost`/`127.0.0.1`, for `wrangler dev`. |
| Body | UTF-8 JSON, `Content-Type: application/json`. `hb`, `offline-expected` and `POST /v1/channels` also accept an empty body. |
| Responses | Always JSON with `Cache-Control: no-store`. |
| User-Agent | Send `User-Agent: OrbitAgent/<AGENT_VERSION>`. Some Cloudflare security settings reject the default `Python-urllib/3.x`. |
| Timeout | Use 10 s per request. Use 3 s for `offline-expected` right before a power action. |
| HTTP client | `urllib.request` is enough, because the relay speaks HTTP/1.1 to the agent. |

## 2. Identifiers and secrets

| Name | Format | Notes |
|---|---|---|
| `channelId` | 32 lowercase hex characters (128 bits) | One per PC, created by the relay. |
| `pcSecret` | 43 base64url characters (256 bits, no padding) | Returned **once** by `POST /v1/channels`. The relay keeps only `SHA-256(pcSecret)`. |
| `deviceId` | 1–64 characters `[A-Za-z0-9][A-Za-z0-9._-]*`, **case-sensitive** | This is the app's `deviceID` (an uppercase UUID string). Use exactly the same string as the AES-GCM AAD. |
| `token` | APNs device token as hex, 64–200 hex digits, even length | Stored lowercase. |
| `env` | `"sandbox"` or `"production"` | Comes from the app's `environment` field. Debug builds use sandbox; TestFlight and App Store builds use production. |

The agent stores `{"relayURL", "channelId", "pcSecret"}` in `data_directory()/push-secrets.json`, with mode
0600 and next to the per-device keys (DESIGN §1.2). If the configured relay URL changes, create a new
channel at the new relay. First call `DELETE /v1/c/{channelId}` on the old relay if you still can (§5.9), so
the old channel does not later report the PC as offline.

## 3. Authentication

Every `/v1/c/{channelId}/…` route requires:

```
Authorization: Bearer <pcSecret>
```

The relay hashes the presented secret with SHA-256 and compares it in constant time with the stored hash.

## 4. Errors

Errors use the same body shape on every route:

```json
{"error": "bad_request", "message": "env must be \"sandbox\" or \"production\"."}
```

The `message` is a human sentence, so log it. Branch on `error` and the HTTP status.

| Status | `error` | Meaning | What the agent does |
|---|---|---|---|
| 400 | `bad_request` | Invalid JSON, field or path parameter. | A bug. Log it and do not retry. |
| 401 | `unauthorized` | Missing, malformed or wrong secret. | Recover the channel (§7). |
| 404 | `channel_not_found` | Unknown channel. It may have been deleted, purged by retention, or the relay was reset. | Recover the channel (§7). |
| 404 | `not_found` | Unknown route. | A bug or the wrong base URL. |
| 405 | `method_not_allowed` | Wrong HTTP method (see the `Allow` header). | A bug. |
| 409 | `device_limit` | The channel already has 20 devices. | Tell the user to remove a device. |
| 413 | `payload_too_large` | The body is over the route's limit (§8). | A bug. Ciphertexts are too big. |
| 426 | `https_required` | The relay URL uses `http://`. | Fix the URL. |
| 429 | `rate_limited` | Too many requests from this IP address. The response has `Retry-After` and `retryAfterSeconds`. | Wait `Retry-After` seconds. |
| 500 | `internal_error` / `misconfigured` | Relay bug or a broken deployment. | Retry with backoff (§7). |
| 503 | `apns_not_configured` | The relay has no APNs key, or cannot use it. This only happens on `notify`. | Keep the event; retry with backoff, at most once every 10 min. |

## 5. Routes

### 5.1 `GET /v1/health` (also `GET /`)

No auth. Use it to check a configured URL.

```json
{"ok": true, "service": "orbit-push-relay", "protocol": 1, "apns": "configured"}
```

`apns` is `"configured"` or `"not_configured"`.

### 5.2 `POST /v1/channels`

Creates a channel. No auth. Body: `{}` or empty. Limited to **5 per minute per IP**.

`201 Created`:

```json
{"channelId": "5f0c…32 hex…", "pcSecret": "43 base64url chars", "heartbeatSeconds": 300, "offlineAfterSeconds": 900}
```

Save the response **before** using it. The secret cannot be retrieved again. A new channel that receives no
heartbeat within 7 days is deleted.

Errors: `400`, `413`, `426`, `429`, `500`.

### 5.3 `PUT /v1/c/{channelId}/devices/{deviceId}`

Registers or updates a device (an upsert). Body:

```json
{"token": "a1b2…64 hex…", "env": "production", "offlineCt": "base64(nonce‖ciphertext‖tag)"}
```

- `offlineCt` is the device's **"PC offline"** message, encrypted for that device (§6). The relay sends it
  when the PC stops sending heartbeats.
  - Omitting the field keeps the stored ciphertext.
  - `null` removes it, so that device gets no offline alert.
  - A string replaces it.
- If another `deviceId` in this channel has the same `token`, the relay deletes that one. It is an old
  registration of the same app install, for example after a reinstall. Its id is listed in `replaced`.

`200 OK`:

```json
{"status": "registered", "created": true, "hasOfflineCiphertext": true, "replaced": []}
```

Drop every id in `replaced` from the agent's own device list.

Errors: `400`, `401`, `404`, `409 device_limit`, `413` (body over 8 KiB), `429`.

### 5.4 `DELETE /v1/c/{channelId}/devices/{deviceId}`

Removes a device and its offline ciphertext. It is idempotent.

```json
{"status": "deleted", "existed": true}
```

### 5.5 `POST /v1/c/{channelId}/notify`

Sends one event to one or more devices. Body:

```json
{
  "items": {"6F1D2C3B-4A59-4E8F-9A0B-1C2D3E4F5A6B": "base64…", "A1B2C3D4-…": "base64…"},
  "level": "active",
  "collapseId": "download.steam:620",
  "ttl": 21600
}
```

| Field | Required | Rule |
|---|---|---|
| `items` | yes | Maps `deviceId` to that device's ciphertext of the **same** event (§6). Allows 1–20 entries, each ≤ 3072 base64 characters. |
| `level` | no | `"passive"`, `"active"` (the default) or `"timeSensitive"`. `"time-sensitive"` is also accepted. Use the event's `level`. |
| `collapseId` | no | 1–48 characters of `A-Z a-z 0-9 . _ : -`. A newer push with the same id replaces the older one on the phone. The relay prefixes it with the first 12 characters of the channel id, so two PCs never collide. **It is visible to the relay and to Apple.** Never put names or content in it. |
| `ttl` | no | Seconds APNs keeps trying while the phone is unreachable. Range 0–604800, default 3600. `0` means try once. |

The relay sends one APNs request per device, in parallel:

- Interruption level comes from `level`.
- `apns-priority` is 5 for `passive` and 10 otherwise.
- `apns-expiration` is now + `ttl`.

`200 OK` is returned even when some or all devices failed:

```json
{
  "results": {
    "6F1D2C3B-…": {"status": "sent", "apnsId": "…"},
    "A1B2C3D4-…": {"status": "unregistered", "apnsStatus": 410, "reason": "Unregistered", "retryable": false},
    "0000AAAA-…": {"status": "unknown_device", "retryable": false},
    "1111BBBB-…": {"status": "failed", "apnsStatus": 503, "reason": "ServiceUnavailable", "retryable": true}
  },
  "sent": 1,
  "failed": 3
}
```

| `status` | Meaning | Agent action |
|---|---|---|
| `sent` | APNs accepted it. | Set `lastDeliveryAt`. |
| `unregistered` | APNs said 410 (app removed or token rotated). **The relay already deleted the device.** | Mark the device inactive locally, with `lastError = "Unregistered"`. It comes back when the app registers again with a new token. Do not re-PUT the old token. |
| `unknown_device` | The relay has no such device. | Treat it like `unregistered`. If you are sure the device is valid, for example right after channel recovery, PUT it once. Never loop. |
| `failed` + `retryable: true` | APNs 429/5xx, a timeout or a network error. | Retry **only these devices** with the same ciphertexts after 30 s, 2 min, then 10 min, until the event's TTL has passed. |
| `failed` + `retryable: false` | A permanent APNs rejection, e.g. `BadDeviceToken` (usually a sandbox token marked `production` or the reverse), `DeviceTokenNotForTopic` or `InvalidProviderToken`. | Store `reason` as the device's `lastError`. Do not retry this event. |

Errors: `400`, `401`, `404`, `413` (body over 64 KiB), `429`, `503 apns_not_configured`.

### 5.6 `POST /v1/c/{channelId}/hb`

The heartbeat, sent every **300 s**. Every heartbeat moves the relay's dead-man alarm to
`now + offlineAfterSeconds`. If no heartbeat arrives before then, the relay sends each device its stored
`offlineCt` (§5.10). Body: `{}` or empty, optionally `{"offlineAfterSeconds": 900}` (300–3600, default 900).
It must be at least 3× your heartbeat interval.

`200 OK`:

```json
{"status": "ok", "state": "online", "previousState": "online", "offlineAlertSent": false,
 "offlineAfterSeconds": 900, "offlineAt": "2026-10-23T18:15:00Z", "heartbeatSeconds": 300}
```

- `previousState` is one of `new`, `online`, `expected-offline`, `alerting` or `offline` (see §5.8).
- `offlineAlertSent: true` means the relay had declared this PC offline and its devices may have
  received "PC offline". This can happen even though the agent never stopped, for example when the
  internet connection dropped for 20 minutes. In that case the agent should emit its `pc.online`
  event (if the user enabled it), so the phone learns the PC is back.

Errors: `400`, `401`, `404`, `429`.

### 5.7 `POST /v1/c/{channelId}/offline-expected`

This is a planned shutdown. `orbit_push.planned_offline()` calls it from `BEFORE_POWER_HOOKS` before
sleep, shutdown or restart. Call it also on Windows suspend (`PBT_APMSUSPEND`). Body: `{}` or empty, or:

```json
{"backWithinSeconds": 900}
```

- **Without `backWithinSeconds`** (sleep, shutdown): the relay deletes the dead-man alarm, so no "PC offline"
  alert is sent. The next heartbeat re-arms it.
- **With `backWithinSeconds`** (60–86400): the relay stays quiet for that long, then alerts if no heartbeat
  has arrived.
  - Use it for **restart**, but only when the agent starts before Windows sign-in (the `--boot`
    scheduled task is installed).
  - Otherwise the agent only returns after someone signs in, and the alert would be a false alarm.

`200 OK`:

```json
{"status": "ok", "state": "expected-offline", "offlineAt": null}
```

`offlineAt` is the ISO time of the alert when `backWithinSeconds` was given.

This call is best effort. Use a 3 s timeout and **never** delay or block the power action if the call fails.

### 5.8 `GET /v1/c/{channelId}`

Returns the channel status, for diagnostics and `GET /api/push/status`. Device tokens and ciphertexts are
never echoed.

```json
{
  "channelId": "5f0c…",
  "state": "online",
  "stateSince": "2026-10-23T18:00:00Z",
  "createdAt": "2026-10-20T09:12:44Z",
  "offlineAfterSeconds": 900,
  "alarm": {"kind": "offline", "at": "2026-10-23T18:15:00Z"},
  "lastOfflineAlert": {"at": "2026-10-22T23:40:00Z", "sent": 2, "failed": 0},
  "devices": [
    {"deviceId": "6F1D2C3B-…", "env": "production", "hasOfflineCiphertext": true,
     "registeredAt": "…", "updatedAt": "…", "lastDeliveryAt": "…", "lastError": null, "lastErrorAt": null}
  ],
  "maxDevices": 20
}
```

| `state` | Meaning |
|---|---|
| `new` | Created, but no heartbeat has arrived yet. |
| `online` | Heartbeats are arriving. |
| `expected-offline` | The PC announced it was going down (§5.7). |
| `alerting` | The relay is delivering "PC offline" (retries included). |
| `offline` | Heartbeats stopped; offline alerts are done. |

`alarm.kind` is `offline` (the dead-man switch), `alert-retry` or `purge` (retention). `alarm` is `null`
when nothing is scheduled. `lastDeliveryAt` and `lastError` also cover offline alerts, which the agent
never sees otherwise.

### 5.9 `DELETE /v1/c/{channelId}`

Deletes the channel with all its devices and ciphertexts, and cancels every alarm.

```json
{"status": "deleted"}
```

Call it when:

- the user turns notifications off on the PC,
- the last device is removed,
- the agent switches to another relay URL, or
- the agent is uninstalled.

Otherwise the dead-man switch sends "PC offline" about 15 minutes after the last heartbeat. Afterwards the
channel answers `404`. Forget the local `channelId`/`pcSecret`.

### 5.10 What happens when heartbeats stop

1. **The alarm fires** `offlineAfterSeconds` after the last heartbeat.
2. **The relay alerts every device that has an `offlineCt`.** It sends that ciphertext with
   interruption level `time-sensitive`, priority 10, a TTL of 12 hours, and collapse id
   `<channelId[:12]>.offline`.
3. **Retryable failures are retried** after 30 s, 2 min and 10 min.
4. **The state becomes `offline`.** The next heartbeat answers `offlineAlertSent: true`.
5. **The relay deletes 410 devices**, as with `notify`.

**Tip:** send the agent's `pc.online` event with `"collapseId": "offline"`. It then *replaces* a stale
"PC offline" notification on the phone instead of stacking under it.

**Retention:** a channel in state `offline` or `expected-offline` is deleted after **90 days**
(`RETENTION_DAYS`, relay setting). When the PC comes back it gets `404` and recovers (§7).

## 6. Ciphertexts (`items[…]` and `offlineCt`)

These are exactly as DESIGN F1 specifies. The relay only checks the base64 shape and the size.

1. **Plaintext.** Compact UTF-8 JSON:
   `{"v":1,"pc":"<hostname>","id":<eventID>,"kind":"<event kind>","title":"…","body":"…","ts":<epoch seconds>,"link":"orbit://notifications"}`.
   - For the offline message use `"id":0,"kind":"pc.offline","title":"PC offline","body":"<hostname> stopped responding."`.
     Its `ts` is the upload time, not the time it is delivered.
2. **Padding.** Right-pad with ASCII spaces to a multiple of **128 bytes**. Keep the padded plaintext
   at or below **2048 bytes**: shorten `body` (then `title`) until it fits.
3. **Encryption.** AES-256-GCM with that device's 32-byte key, a fresh 12-byte random nonce for
   **every** encryption, and AAD = the UTF-8 bytes of `deviceId`.
4. **Wire format.** Standard base64 with padding of `nonce ‖ ciphertext ‖ tag`. That is at most 3072
   characters. The relay refuses anything over 3072 characters or under 29 decoded bytes.

```python
import base64, json, os
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

def seal(key: bytes, device_id: str, message: dict) -> str:
    plain = json.dumps(message, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    plain += b" " * (-len(plain) % 128)                                    # pad to 128-byte blocks
    nonce = os.urandom(12)
    sealed = AESGCM(key).encrypt(nonce, plain, device_id.encode("utf-8"))  # ciphertext || tag
    return base64.b64encode(nonce + sealed).decode("ascii")
```

The phone opens it with `AES.GCM.SealedBox(combined: data)` (`nonce ‖ ciphertext ‖ tag`) and the same AAD.

Re-sending the *same* ciphertext (retries, or the stored offline message) is fine. Never encrypt two
different plaintexts with the same nonce.

### What the phone receives

```json
{"aps": {"alert": {"title": "Orbit", "body": "New alert from your PC"}, "mutable-content": 1,
         "sound": "default", "interruption-level": "active", "thread-id": "<channelId>"},
 "o": "<the ciphertext>", "v": 1}
```

The relay sends these APNs headers:

| Header | Value |
|---|---|
| `apns-push-type` | `alert` |
| `apns-topic` | `com.dimitrie.orbit` |
| `apns-priority` | 5 or 10 |
| `apns-expiration` | now + `ttl` |
| `apns-collapse-id` | `<channelId[:12]>.<collapseId>`, only when the agent gave one |

The Notification Service Extension:

- reads `o`,
- tries each stored key, with AAD = its own `deviceID`,
- replaces the title and body.

If it cannot decrypt, the generic text stays.

## 7. Agent lifecycle

**First device registers** (`POST /api/push/register` on the agent):

1. If the relay URL is empty, store the device locally and answer `"relay":"disabled"`.
2. If there is no channel for this relay URL, call `POST /v1/channels` and save the result.
3. `PUT /devices/{deviceID}` with the token, env and a fresh `offlineCt`.
4. Send `POST /hb` once, then start the heartbeat thread.

**Agent start:**

1. PUT every known device again with a **fresh** `offlineCt` (new nonce, current hostname).
2. Send `POST /hb` immediately.
3. Then send `POST /hb` every 300 s from a daemon thread. Also send one right after resume from sleep.

**Event** (`orbit_events.emit` dispatcher): encrypt the event once per active device and send **one**
`notify` call with all items. Then update each device's `lastDeliveryAt` / `lastError` from `results`.

The levels come from the event. Suggested TTLs and collapse ids:

| Event kind | Level | `ttl` | `collapseId` |
|---|---|---|---|
| `temperature.high` | timeSensitive | 900 | `temperature.cpu` / `temperature.gpu` |
| `download.finished`, `download.failed` | active | 21600 | `download.<item id>` (e.g. `download.steam:620`) |
| `downloads.allFinished` | active | 21600 | `downloads` |
| `task.finished` | active | 21600 | `task.<task id>` |
| `power.scheduled` / `power.executing` / `power.cancelled` | timeSensitive / active / active | the delay / 300 / 600 | `power` |
| `pc.online` | active | 3600 | `offline` |
| `summary.ready` | passive | 604800 | `summary` |
| `webcam.connected` | active | 300 | `webcam` |

**Planned power action:** call `offline-expected` (§5.7) with a 3 s timeout, then go ahead whatever the
answer.

**Device removed** (`DELETE /api/push/devices/{deviceID}` on the agent): call
`DELETE /v1/c/{channelId}/devices/{deviceID}`. If no devices are left, call `DELETE /v1/c/{channelId}` and
forget the channel.

**Channel recovery** (`401` or `404 channel_not_found` on any channel route):

1. Forget the channel and create a new one.
2. PUT every active device with a fresh `offlineCt`.
3. Send a heartbeat.

Do this at most once per 10 minutes. If the old channel still exists (a `401` because the local secret was
lost), it sends one "PC offline" alert about 15 minutes after its last heartbeat. It is then deleted by
retention.

**Retries:**

- **Network errors, `429`, `5xx`:** back off 30 s → 2 min → 10 min → 30 min, and honour `Retry-After`.
- **Heartbeats:** don't queue them. Just try again at the next interval. The 15-minute window tolerates
  two missed heartbeats.
- **Events:** queue them while the relay is unreachable and drop each one once its `ttl` has passed.
- **`400`/`405`/`413`:** bugs. Log them and do not retry.

## 8. Limits

| Limit | Value |
|---|---|
| Devices per channel | 20 |
| Ciphertext (`items[…]`, `offlineCt`) | 29 decoded bytes to 3072 base64 characters; padded plaintext ≤ 2048 bytes recommended |
| `collapseId` | 48 characters, `A-Z a-z 0-9 . _ : -` |
| `ttl` | 0–604800 s, default 3600 |
| `offlineAfterSeconds` | 300–3600 s, default 900 |
| `backWithinSeconds` | 60–86400 s |
| Body size | 1 KiB (`POST /v1/channels`, `hb`, `offline-expected`), 8 KiB (device PUT), 64 KiB (`notify`) |
| Channel creation | 5 per minute per IP (approximate, per Cloudflare location) |
| Channel routes | 60 requests per minute per IP (approximate, per Cloudflare location) |
| New channel without a heartbeat | deleted after 7 days |
| Channel offline / expected-offline | deleted after 90 days (`RETENTION_DAYS`) |

On the Cloudflare Free plan, each heartbeat costs one Worker request, one Durable Object request and one
SQLite row written. At 300 s that is 288 of each per PC per day. See README.md for capacity.
