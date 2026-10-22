# Orbit — Privacy Policy

**Last Updated:** October 2026

Orbit ("the App") is a local-network hardware telemetry and remote power companion for Windows PCs. We are committed to protecting your privacy.

## 1. Local-Only Communication
Orbit communicates directly between your iPhone/iPad and your Windows PC over your own network (for example your home LAN) using encrypted HTTPS/TLS and a locally generated pairing token. **No telemetry data, hardware statistics, processes, files, or commands are ever transmitted to any external cloud servers.**

## 2. Data Collection & Third Parties
- **No Personal Data Collected:** Orbit does not require creating an account and does not collect, store, or transmit personal information, usage analytics, or crash tracking to any third-party servers.
- **No Advertising or Tracking:** Orbit contains zero advertising SDKs and does not track you across apps or websites.

## 3. On-Device Storage
Connection profiles (PC name, local IP address, port, MAC address for Wake-on-LAN, and pairing status), appearance preferences, and widget configurations are stored strictly on your device using Apple's local `UserDefaults` and `App Group` container (`group.com.dimitrie.orbit`) so that Home Screen Widgets, Control Center Widgets, Live Activities, and Siri Shortcuts can communicate with your PC.

## 4. Permissions Used
- **Local Network:** Used exclusively to connect to the Orbit Windows Companion running on your PC (`port 8765`) and to broadcast Wake-on-LAN magic packets (`UDP port 9`).
- **Photo Library (Add Only):** Used only when you explicitly choose to save a captured PC screenshot or downloaded media file to your iPhone's Photos library.
- **Siri & Shortcuts:** Used to execute voice commands (such as waking or shutting down your PC) locally on your device.
- **In-App Purchases:** Processed securely through Apple StoreKit 2. Orbit only verifies your local receipt entitlement (`com.dimitrie.orbit.pro`) on-device.

## 5. Contact
If you have any questions about this Privacy Policy or Orbit, please open an issue on our GitHub repository:
https://github.com/AceDimi2005/Orbit
