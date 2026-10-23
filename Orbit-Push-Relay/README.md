# Orbit push relay

Orbit can alert your iPhone while the app is closed: a download finished, the GPU is too hot, the PC
stopped responding. Apple only delivers those pushes for whoever holds Orbit's APNs signing key. That key
must never ship inside the Windows agent. This folder is the small server that holds the key and forwards
pushes.

It is a **Cloudflare Worker** with **one SQLite-backed Durable Object per PC**, written in plain JavaScript
(ES modules, no build step, no npm dependencies).

```
iPhone ──pinned TLS──▶ Windows agent ──HTTPS──▶ relay (Worker + Durable Object) ──HTTP/2──▶ APNs ──▶ iPhone
         registers            encrypts each event       adds the generic alert,                  Notification Service
         token + key          for each device            signs the APNs request                  Extension decrypts
```

- **`PROTOCOL.md`** is the exact HTTP contract for the Windows agent: routes, JSON, errors, limits and
  retry advice.
- **`src/index.js`** handles routing and Bearer authentication (`SHA-256(pcSecret)`, compared in
  constant time by the channel's object).
- **`src/ratelimit.js`** has the per-IP limits.
- **`src/channel.js`** is the Durable Object per PC. It holds the devices and the offline ciphertexts, and
  runs the heartbeat dead-man switch, the offline alerts and retention.
- **`src/apns.js`** builds the ES256 provider token (WebCrypto, cached about 40 minutes) and makes the
  APNs requests.
- **`src/validate.js`** validates requests and holds the limits. **`src/util.js`** has small helpers.
- **`test/`** holds the tests, which run with `node --test Orbit-Push-Relay/test`.
- **`scripts/local-check.mjs`** runs the same flow in the real Workers runtime against a mock APNs.

## Privacy properties

**End-to-end encrypted.**

- Each iPhone gives the PC a random 256-bit key over Orbit's existing pinned TLS connection.
- The PC encrypts every alert for every device with AES-256-GCM, bound to the device id.
- Only the iPhone's Notification Service Extension can decrypt it.

**What the relay never sees:** notification titles or bodies, PC names, event kinds, file or game names,
and anything else from the PC.

**What Apple sees:** only the generic text "Orbit — New alert from your PC" plus an opaque blob.

**What the relay can see:**

- the PC's IP address while it makes a request,
- the APNs device tokens and their environment,
- the random channel id,
- when alerts are sent and their interruption level and TTL,
- the padded ciphertext size (plaintexts are padded to 128-byte blocks),
- the agent-chosen collapse ids. These are generic, like `temperature.cpu` or `download.steam:620`.

**What it stores, per PC:**

- `SHA-256(pcSecret)`; the secret itself is never stored,
- the channel state and timestamps,
- per device: APNs token, environment, the encrypted "PC offline" message, and the last delivery
  time and error.

It stores no IP addresses and no request logs. Workers Logs are disabled in `wrangler.toml`, and the code
never logs tokens, ciphertexts or secrets (a test checks this).

**Retention:**

- A PC that has been offline (or announced offline) for **90 days** has its channel and device tokens
  deleted automatically (`RETENTION_DAYS`).
- A channel that never sends a heartbeat is deleted after **7 days**.
- The agent deletes its channel when notifications are turned off (`DELETE /v1/c/{id}`).
- APNs answer 410 for an uninstalled app, so those devices are deleted at once.

**Opt-in.** Nothing reaches the relay until the user enables notifications in Orbit. With no relay URL
configured, the agent still records events, and the apps poll them over the local network.

Cloudflare (hosting) and Apple (APNs) process this metadata as part of delivering the push. `PRIVACY.md` at
the repository root has to say so before release.

## Deploying

You need:

- a Cloudflare account (the Free plan works),
- Node.js 22.15 or newer,
- the Apple Developer account that owns `com.dimitrie.orbit`.

Wrangler 4.36 or newer is required for the `[[ratelimits]]` bindings; `npx wrangler` fetches the
current one.

### 1. Create the APNs key (once)

1. Go to [developer.apple.com](https://developer.apple.com/account/resources/authkeys/list) and open
   **Certificates, Identifiers & Profiles → Keys → +**.
2. Name it, e.g. "Orbit push relay", and tick **Apple Push Notifications service (APNs)**.
   - If the portal asks for an **environment**, choose **Sandbox & Production**.
   - If it only offers one environment per key, create a production key and a sandbox key. Set the
     sandbox one as `APNS_SANDBOX_KEY_P8` / `APNS_SANDBOX_KEY_ID` in step 4.
   - If it asks for a key restriction, team-scoped or topic-specific for `com.dimitrie.orbit` both work.
3. Download `AuthKey_XXXXXXXXXX.p8`. **Apple lets you download it only once.**
   - Keep it in a password manager, never in this repository. `*.p8` is git-ignored here as a
     safety net.
4. Note the **Key ID** (the 10 characters in the file name) and your **Team ID** (top right of the
   developer portal, `W3Q78RNLD6` for Orbit).
5. On the App ID `com.dimitrie.orbit`, enable **Push Notifications** and **Time Sensitive Notifications**.
   Then regenerate the provisioning profiles. This is the app side, see DESIGN F1.

### 2. Log in to Cloudflare

```sh
cd Orbit-Push-Relay
npx wrangler login
```

The first time, the dashboard asks you to pick a `workers.dev` subdomain. Your relay will live at
`https://orbit-push-relay.<subdomain>.workers.dev`.

### 3. Deploy the Worker

```sh
npx wrangler deploy
```

Wrangler creates the `Channel` Durable Object class (SQLite-backed, migration `v1`) and the two rate
limiters, then prints the URL. Until the secrets exist, `/v1/health` reports `"apns":"not_configured"`
and `notify` answers 503. Nothing breaks.

### 4. Add the APNs secrets

```sh
npx wrangler secret put APNS_KEY_P8  < ~/Secure/AuthKey_XXXXXXXXXX.p8
npx wrangler secret put APNS_KEY_ID           # type the 10-character Key ID
npx wrangler secret put APNS_TEAM_ID          # type the 10-character Team ID
# only for separate sandbox/production keys:
npx wrangler secret put APNS_SANDBOX_KEY_P8 < ~/Secure/AuthKey_YYYYYYYYYY.p8
npx wrangler secret put APNS_SANDBOX_KEY_ID
```

The key may be pasted as the whole PEM file, as one line with `\n` escapes, or as just the base64 body.
Every `secret put` takes effect immediately; there is no need to redeploy.

### 5. Check it

```sh
RELAY=https://orbit-push-relay.<subdomain>.workers.dev
curl -s $RELAY/v1/health
# {"ok":true,"service":"orbit-push-relay","protocol":1,"apns":"configured"}

# Optional round trip without a phone:
CH=$(curl -s -X POST $RELAY/v1/channels -H 'content-type: application/json' -d '{}')
echo "$CH"   # {"channelId":"…","pcSecret":"…",…}
ID=$(echo "$CH" | python3 -c 'import json,sys; print(json.load(sys.stdin)["channelId"])')
SECRET=$(echo "$CH" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pcSecret"])')
curl -s -X POST $RELAY/v1/c/$ID/hb -H "authorization: Bearer $SECRET"
curl -s $RELAY/v1/c/$ID -H "authorization: Bearer $SECRET"
curl -s -X DELETE $RELAY/v1/c/$ID -H "authorization: Bearer $SECRET"
```

### 6. Test a real push

**APNs needs HTTP/2.** Local `wrangler dev` (workerd on your Mac) cannot speak it. Cloudflare's network
upgrades the Worker's outbound `fetch` to HTTP/2, so test on Cloudflare: either the deployed relay or a
remote dev session:

```sh
# .dev.vars (git-ignored) holds the secrets for dev sessions:
#   APNS_KEY_P8="-----BEGIN PRIVATE KEY-----\nMIGTAgEAMBMG…\n-----END PRIVATE KEY-----"
#   APNS_KEY_ID="XXXXXXXXXX"
#   APNS_TEAM_ID="W3Q78RNLD6"
npx wrangler dev --remote
```

1. Use a **Debug** build of Orbit on a real iPhone. It produces a **sandbox** token.
2. Point a test PC's agent at the relay with `ORBIT_PUSH_RELAY_URL` (next section).
3. Enable notifications in Orbit, then trigger an event, or stop the agent for 15 minutes to see "PC
   offline".

You can also do it by hand: create a channel and PUT a device with the sandbox token and `"env":"sandbox"`.
Then `notify` with any valid base64 blob of at least 29 bytes. The phone shows "Your PC sent an alert. Open
Orbit.", the extension's fallback when it cannot decrypt, which proves delivery.

TestFlight and App Store builds produce **production** tokens. A sandbox token sent as `production` (or
the reverse) fails with `BadDeviceToken`.

### 7. Point the Windows agent at the relay

The agent reads the relay URL in this order:

1. **Settings `push.relayURL`**, for advanced users.
2. **Environment variable `ORBIT_PUSH_RELAY_URL`**, per PC. Use it for testing:
   `setx ORBIT_PUSH_RELAY_URL https://orbit-push-relay.<subdomain>.workers.dev`, then restart the agent.
3. **The built-in default `DEFAULT_RELAY_URL`** in `Orbit-Windows-Agent/orbit_push.py`. It is `""`
   (disabled) until you set it to the URL above. This is what ships to every user, so change it only
   when the relay is ready for everyone.

Use `https://` and no trailing slash.

## Cloudflare Free plan limits

| Resource | Free plan | Relay usage |
|---|---|---|
| Worker requests | 100,000 / day | 1 per heartbeat, notify or device call |
| Durable Object requests | 100,000 / day (alarms count) | 1 per call that passes validation, plus 1 per alarm |
| SQLite rows written | 100,000 / day | 1 per steady-state heartbeat (the alarm move), plus a few per notify |
| SQLite rows read | 5,000,000 / day | a few per call |
| SQLite storage | 5 GB total | about 1–5 KB per PC (at most ~70 KB with 20 devices) |
| CPU per request | 10 ms | ES256 signing is native WebCrypto, well under 1 ms |
| Subrequests per request | 50 | ≤ 20 devices × 2 (one token-refresh retry) |

With a 5-minute heartbeat a PC uses 288 Worker requests, 288 Durable Object requests and 288 rows written
per day. The Free plan carries about **300 PCs**, leaving room for notifications.

- **Heartbeat interval:** the agent can send `offlineAfterSeconds` up to 3600 with a longer heartbeat
  interval (at least a third of it). That trades offline-alert speed for capacity.
- **Paid plan ($5/month):** 10 million Worker requests/month, 1 million Durable Object requests/month
  (then $0.15/million), and 50 million rows written/month (then $1/million). It carries thousands of PCs.
- **Rate limits:** channel creation 5/min per IP; channel routes 60/min per IP. The rate-limit
  binding is approximate and counts per Cloudflare location. If your plan does not offer it, delete the
  `[[ratelimits]]` blocks: the Worker falls back to per-isolate counters.

## Operations

- **Watch live:** `npx wrangler tail` streams logs while debugging (nothing is stored). The relay logs
  APNs failures (status and reason only), offline events and purges, using the first 8 characters of the
  channel id.
- **Rotate the APNs key:** create a new key, run `secret put` for `APNS_KEY_P8` and `APNS_KEY_ID`, then
  revoke the old key. Provider tokens are rebuilt automatically.
- **APNs reasons:**
  - `BadDeviceToken`: the sandbox/production mix-up above.
  - `InvalidProviderToken`: wrong Key ID, Team ID or key.
  - `DeviceTokenNotForTopic`: the token is from another app; check `APNS_TOPIC`.
  - `TooManyProviderTokenUpdates`: the token is being refreshed too often (should not happen).
- **Delete everything:** `npx wrangler delete` removes the Worker and all channel data.
- **Main dependency risk:** Cloudflare upgrades outbound requests to HTTP/2, but this is stated in a
  [workerd issue](https://github.com/cloudflare/workerd/issues/4841), not in its documentation. If it ever
  stops, move `src/apns.js` behind any HTTP/2-capable host; the rest of the relay does not change.
- **Alarm semantics:** Durable Object alarms run at least once. A rare duplicate "PC offline" push
  replaces the previous one on the phone, because both carry the same collapse id.

## Tests

```sh
node --test Orbit-Push-Relay/test      # from the repository root
npm test                               # from this folder
```

The tests run on Node 22.15+ with no dependencies. They mock `fetch` (APNs), Durable Object storage and
alarms, and map `cloudflare:workers` to a small shim.

- A throwaway P-256 key is generated and every provider token is verified with `node:crypto`.
- They cover:
  - auth failures,
  - device CRUD,
  - notify fan-out across sandbox and production,
  - size limits,
  - 410 clean-up,
  - the heartbeat/alarm offline flow with retries,
  - offline-expected,
  - retention,
  - races between alarms and heartbeats,
  - the "no secrets in logs" rule.

### Check in the real Workers runtime before deploying

```sh
node scripts/local-check.mjs               # ~15 s
node scripts/local-check.mjs --with-alarm  # + ~5 min: waits for a real dead-man alarm
```

The script needs no Cloudflare account and deploys nothing.

1. It starts `wrangler dev --local`, which runs workerd on your Mac. Wrangler comes from `$WRANGLER`,
   otherwise `npx --yes wrangler@4`.
2. It starts a mock APNs server on `127.0.0.1` and points the relay at it with
   `--var APNS_TEST_ORIGIN:http://127.0.0.1:<port>`. That variable is honoured only for loopback
   origins.
3. It drives the whole flow: channel, auth, devices, notify fan-out with token verification, 410
   clean-up, heartbeat, offline-expected, optionally the alarm, deletion and the rate limit.

It catches problems the Node tests cannot see, such as a main-module export that workerd refuses to start
with.
