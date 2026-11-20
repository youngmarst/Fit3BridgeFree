# Status, decisions & next steps

_Last updated: 2026-10-17_

## TL;DR

| Area | State |
|---|---|
| Protocol (SAP over BLE) | ✅ ported, unit-checked against real captured packets (Swift 59 checks, JS 29) |
| **Verified on the real band** (via `web/` page in Bluefy on the iPhone) | ✅ connect + handshake + first-run setup, ✅ notifications show, ✅ **call ringing via call service (SAP 3)**, ✅ answer/hang-up → missed call, battery, time sync |
| Native iOS app (`App/`) | ✅ **installed & verified on the iPhone 17 (iOS 27.0)** — on-device: connect + notifications, incoming-call ringing, background reconnect, battery/time sync (2026-10-17). IPA still published as release `latest` |
| Installing the app on the iPhone | ✅ **solved** – Xcode on the personal Mac + free Personal Team; re-sign every ~7 days via `scripts/reinstall.sh` |
| SMS via Shortcuts | implemented (App Intent), untested on device |
| Gmail | planned (iCloud-forward trick), not implemented |
| Watch face switching | implemented (app + web); **user actually wants installing new faces** → later |
| WhatsApp messages | ❌ not possible on iOS without extra hardware — deferred by user |

## Timeline of what happened

1. Research: Galaxy Fit3 is Android-only. iOS apps **cannot read other apps' notifications**; the only system
   path is ANCS, which the Fit3 firmware does not implement (stock firmware is compressed — scan inconclusive,
   but behaviour confirms: iPhone pairs, no notifications).
2. Found **yuriyurin/Fit3-App** (GPL-3.0 Android companion) → protocol is Samsung **SAP over plain BLE GATT**,
   no crypto. Ported framing/OOBE/battery/notifications to Swift (`Fit3Kit`) and JS (`web/fit3.js`).
3. Built native app `App/` + XcodeGen project + CI that produces an unsigned IPA.
4. Built the **Bluefy web test page** so the protocol could be tested without installing anything.
   First run failed with `Error: 2` → fixed by using the **full 128-bit service UUID** string in Web Bluetooth
   plus per-step logging/retries (web v3). After that: connect + notifications worked on the real band.
5. Calls initially sent as a normal notification → only a short buzz. **Decompiled Samsung's official
   Fit3 plugin** (`com.samsung.wearable.fit3plugin`, from apkpure, `jadx`) and found the dedicated
   **call agent = SAP service 3** (`providers/sacall/*`). Implemented it (web v5 + app) → band now rings
   continuously; user confirmed "all the things are working as expected".
6. User got Xcode (27.0) on the work Mac, but the Mac's corporate endpoint security **blocks the iPhone's USB
   data channel** (`usbmuxd: start failed ((iokit/common) not permitted)`), so Finder/Xcode never see the phone
   and Developer Mode never appears. Decided: wait for the user's **personal laptop**.
7. **2026-10-17 — installed & verified on the phone.** Xcode 27.1 on the user's MacBook Pro (macOS 27.0.1;
   no corporate blockers here, `usbmuxd` runs fine). Personal Team `DX6K78B9BF` + bundle id
   `com.gokularumugam.fit3bridge.app` set in `project.yml` (survives `xcodegen generate`). The Developer Mode
   toggle did not appear until Xcode's **Device Hub** had been opened once with the phone attached
   (force-closing Settings + replugging the cable also helps). Signed build via
   `xcodebuild -allowProvisioningUpdates` created the team provisioning profile automatically; installed with
   `xcrun devicectl device install app`; the Apple Development certificate was trusted in iOS Settings.
   **User verified all P0 items on the real band: notifications, incoming-call ringing, background
   reconnect, battery/time sync.** Weekly refresh: `scripts/reinstall.sh`.

## Installation (solved 2026-10-17)

Done on the owner's MacBook Pro with a free Apple ID (Personal Team `DX6K78B9BF`):
1. Plug in the iPhone → **Trust**. Developer Mode: Settings → Privacy & Security → **Developer Mode**
   (the toggle only appears after Xcode has seen the phone — open **Xcode → Open Developer Tool → Device Hub**
   with the cable attached; force-close Settings on the phone / replug the cable if it's still missing).
2. Build + install: **`scripts/reinstall.sh`** (signs + creates the provisioning profile automatically).
3. First launch only: trust the certificate — Settings → General → VPN & Device Management →
   "Apple Development: …" → **Trust**.

Free-account apps expire after **7 days** — re-run `scripts/reinstall.sh` (phone plugged in + unlocked) or
press ▶ in Xcode. Alternatives kept for reference: **SideStore** (re-signs on the phone; one-time pairing-file
setup from any computer) and paid Apple Developer + TestFlight (no computer needed; CI signing not built).

## Next steps (roadmap)

**P0 — get the native app running** — ✅ DONE 2026-10-17 (installed + verified on the real phone/band)
- [x] Install via Xcode on the personal Mac (free Personal Team) — refresh every ~7 days: `scripts/reinstall.sh`.
- [x] First run on device: connect + first-run setup, notifications.
- [x] Verified on device: handshake, notifications, **incoming-call ringing** (keep-alive on), background
      reconnect, battery, time sync. (Not measured: state restoration after an iOS kill, keep-alive drain.)
- [ ] Set up SMS automation (Shortcuts → Automation → Message → "Send to Galaxy Fit3") and verify it runs
      in the background (App Intent `openAppWhenRun = false`).
- [ ] Collect the in-app Protocol log (share icon) if anything fails.

**P1 — Gmail**
- Plan: Gmail → auto-forward to an **@icloud.com** address → Apple Mail app (iCloud has push) →
  Shortcuts **Email** automation → "Send to Galaxy Fit3" (App = Mail). Write in-app help + test.

**P2 — polish**
- Notification **app icons**: band asks for icons (`parseIconCapability`, `APP_ICON_<id>` request, large icons
  use chunked transfer with message 62). See Fit3-App `Fit3NotificationIconSender.kt` / `encodeNotificationIcon`.
- Handle band → phone call buttons on iOS (Decline can't decline on iOS; currently we just stop the band ringing).
- Missed-call clearing (`missedCallDeleteFromMobile`), DND sync.

**P3 — data**
- Health (steps/HR/sleep) → HealthKit: port `Fit3HealthCodec`, `Fit3HealthLargeDataReceiver`,
  `Fit3HealthAcceptance` from Fit3-App. Band sends GM capability requests on service 10 that need replies.
- Weather (`Fit3WeatherCodec`, Open-Meteo), band settings (`Fit3SettingsCodec`), find-my-band.

**P4 — installing new watch faces (user wants this, lowest priority)**
- Fit3-App installs faces / media / firmware over **Bluetooth Classic RFCOMM**
  (SPP UUID `db764ac8-4b08-7f25-aafe-59d03c27bae3`) — **iOS apps cannot open RFCOMM** without MFi.
- Research: does the band offer a BLE path (L2CAP CoC PSM → CoreBluetooth `openL2CAPChannel`, or file
  transfer over SAP service 30 `OTA_TRANSFER` on GATT)? Look in the Samsung plugin for L2CAP / BLE file transfer.
  If not possible, say so clearly.

**Parked**
- WhatsApp messages: needs ANCS or a hardware bridge (ESP32 acting as ANCS client + SAP host). User deferred.
- Caller name on calls: iOS gives third-party apps no caller ID (CXCallObserver has no number/name).

## Known limitations (iOS)

- No access to other apps' notifications (WhatsApp/Gmail app) — only via Shortcuts triggers (Messages, Mail).
- CallKit observer only fires while the app runs → `KeepAlive` (silent audio, mixWithOthers) toggle.
- Force-quitting the app from the app switcher stops background reconnection until it's opened again.
- Bluefy (web page) only works in the foreground — testing tool, not for daily use.

---

## Fit3BridgeFree fork note (2026-11-20)

This repo was forked as **Fit3BridgeFree** (bundle id `com.fit3bridgefree.ios`, Chinese UI).
Changes on top of the original project:

- Added **health data sync** (SAP service 10 → HealthKit): GM/wearable capability handshake,
  SYNC_DATA ack, pedometer minute-bin parsing with dedupe, heart-rate vitals, large-data
  chunk reassembly. Ported from yuriyurin/Fit3-App (GPL-3.0) into `Fit3Kit/Fit3Health.swift`;
  verified by `swift run Fit3KitChecks` (94 checks, includes real AZA3 packet vectors).
  **Not yet verified on a real band.**
- Chinese UI, permission explanations, help screens; app renamed Fit3BridgeFree.
- HealthKit entitlement + usage descriptions added; bundle id changed.

Everything below this line is the original project's status log and remains accurate for the
inherited call/notification/reconnect code paths.
