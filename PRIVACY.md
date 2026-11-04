# Orbit — Privacy Policy

**Last Updated:** November 2026

Orbit ("the App") is a local-network hardware telemetry and remote power companion for Windows PCs. We are committed to protecting your privacy.

## 1. Local-Only Communication
Orbit communicates directly between your iPhone/iPad and your Windows PC over your own network (for example your home LAN) using encrypted HTTPS/TLS and a locally generated pairing token. **No telemetry data, hardware statistics, processes, files, or commands are ever transmitted to any external cloud servers.** The only exception is the optional instant notifications described in section 2, whose content is end-to-end encrypted.

## 2. Data Collection & Third Parties
- **No Personal Data Collected:** Orbit does not require creating an account and does not collect, store, or transmit personal information, usage analytics, or crash tracking to any third-party servers.
- **No Advertising or Tracking:** Orbit contains zero advertising SDKs and does not track you across apps or websites.
- **Optional Instant Notifications (Orbit 1.1 and later):** If you turn on notifications in Orbit, your PC can alert your iPhone or iPad while Orbit is closed (for example, a download finished or the PC stopped responding). Your PC sends these alerts through the Orbit push relay, a small service hosted on Cloudflare Workers, to the Apple Push Notification service, which delivers them to your device.
  - **End-to-end encrypted:** each alert is encrypted on your PC (AES-256-GCM) with a key that only your device and your PC hold. The relay, Cloudflare, and Apple cannot read alert titles or text, PC names, file or game names, or what kind of event happened.
  - **What the relay keeps:** your device's push token, a random channel ID for your PC, a hash of your PC's secret, the encrypted "PC offline" message, and the time of the last delivery. It does not keep IP addresses or request logs.
  - **What the relay and Apple can see while delivering:** the push token, the random channel ID, when an alert is sent, its priority and expiry, and the size of the encrypted message.
  - **Retention:** the relay deletes your PC's channel and device tokens when you turn notifications off, after 90 days without contact from your PC, after 7 days if the PC never connects, and immediately when Apple reports that Orbit was removed from the device.
  - **Off by default:** nothing is sent to the relay until you turn notifications on. Without them, alerts are shown only when Orbit checks your PC over your network.
  - Cloudflare and Apple process this delivery information only as service providers for sending the notifications.

## 3. On-Device Storage
Connection profiles (PC name, local IP address, port, MAC address for Wake-on-LAN, and pairing status), appearance preferences, and widget configurations are stored on your device using Apple's local `UserDefaults` and `App Group` container (`group.com.dimitrie.orbit`) so that Home Screen Widgets, Control Center Widgets, Live Activities, and Siri Shortcuts can communicate with your PC.

If you are signed in to iCloud, your saved PC profiles (including each PC's pairing token, so your other devices can connect without pairing again) and, in Orbit 1.1 and later, your Orbit settings (such as the theme, overview cards and Live Activity options) are synced between your own iPhone, iPad, Mac, and Apple TV through Apple's iCloud Key-Value Storage in your private iCloud account. This data is stored by Apple under your Apple Account; the developer has no access to it. Streaming identities used to pair with Sunshine never leave each device. You can turn this off with Sync with iCloud in Orbit's Settings (Orbit 1.1 and later) or for Orbit in your device's iCloud settings.

## 4. Permissions Used
- **Local Network:** Used exclusively to connect to the Orbit Windows Companion running on your PC (`port 8765`) and to broadcast Wake-on-LAN magic packets (`UDP port 9`).
- **Notifications (Orbit 1.1 and later):** Used to show alerts from your PC. Instant delivery while Orbit is closed uses the encrypted relay described in section 2.
- **Camera (Orbit 1.1 and later):** Used only on the Webcam screen, to show a preview and send the picture directly to your Windows PC over your network. Orbit does not record it or send it anywhere else.
- **Photo Library (Add Only):** Used only when you explicitly choose to save a captured PC screenshot or downloaded media file to your iPhone's Photos library.
- **Siri & Shortcuts:** Used to execute voice commands (such as waking or shutting down your PC) locally on your device.
- **In-App Purchases:** Processed securely through Apple StoreKit 2. Orbit only verifies your local receipt entitlement (`com.dimitrie.orbit.pro`) on-device.

## 5. Contact
If you have any questions about this Privacy Policy or Orbit, please open an issue on our GitHub repository:
https://github.com/AceDimi2005/Orbit
