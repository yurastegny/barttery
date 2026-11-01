<p align="center">
  <img src="./img/appicon.png" width="256" height="256" alt="Barttery's icon"/>
</p>

# Barttery

A macOS menu bar app that shows battery levels for all your devices in one place.

## Features

- MacBook — battery percentage with charging state icon, time to full / time remaining, cycle count
- iPhone & iPad — battery level via USB or Wi-Fi
- Apple Watch — battery level via paired iPhone
- AirPods — headphones and case battery levels with charging indicators
- Magic Keyboard, Mouse & Trackpad — battery levels via Bluetooth
- Logitech mice — MX Master 2S/3/3S/4, MX Anywhere 2S/3/3S, MX Ergo, M720 Triathlon, MX Vertical — battery level and charging indicator via HID++ 2.0
- Logitech keyboards — MX Keys, MX Keys Mini, MX Keys S, K380, K780, K850 — battery level via HID++ 2.0
- Bluetooth headphones — battery level via Bluetooth
- BLE devices — any Bluetooth LE peripheral with a standard Battery Service

Notifications — get alerted when any device drops to 20%, or reaches 80% / 100% while charging. Configure per device.

> **Logitech devices** require Input Monitoring permission (System Settings → Privacy & Security → Input Monitoring). Without it, Logitech devices still appear via Bluetooth with approximate battery level.

Logitech HID++ battery and charging status are polled every 15 seconds, as well as
when opening the popup and after wake. A Developer ID signature does not bypass
Input Monitoring: grant access to the installed Barttery app, then quit and reopen
it if macOS requests a restart. If access stops working after switching from an
ad-hoc build to Developer ID signing (or changing the bundle identifier), remove
the old Barttery entry in Input Monitoring and add the new app from Applications.
Keep the same bundle identifier and signing team for subsequent releases.

If a HID++ query fails, recent readings are retained for up to two minutes, then
available BLE readings are used instead. BLE charging is only inferred from rising
battery level, so it cannot reliably detect a charging cable being plugged in or
removed. The HID++ charging indicator represents active charging, not simply an
attached cable; a fully charged device is not marked as charging.

## Screenshot

<img src="./img/screen2.png" alt="Screenshot" width="549"/>

## Requirements

- macOS 13 Ventura or later (including macOS 27)
- For iPhone / iPad / Apple Watch: connect via USB cable to Mac and enable Wi-Fi sync in Finder. On the first USB connection, you'll need to **Trust** the computer.

## Installation

- Download the latest DMG file from the [releases page](https://github.com/yurastegny/barttery/releases)
- Open the DMG file
- Drag the Barttery app to your Applications folder
- Launch Barttery — it appears in the menu bar
- On first launch, macOS may ask for Bluetooth and notification permissions — allow both

### How to run

Older, ad-hoc-signed releases may require the steps below. Developer ID-signed and
notarized releases do not normally require a Gatekeeper exception.

**macOS 13–14:** Control-click **Barttery** → **Open** → **Open**.

**macOS 15 and later:**

1. Double-click **Barttery**. You'll get a warning such as **"Apple could not verify "Barttery" is free of malware"** or **"Barttery" can't be opened because the developer cannot be verified**.
2. Click **Done** — not **Move to Trash**.
3. Open **System Settings → Privacy & Security** and scroll down to **Security**.
4. Click **Open Anyway** next to the message that Barttery was blocked, then enter your password (or use Touch ID) and click **Open**.

After this, macOS remembers the exception and the app launches normally.

## Desktop widget (macOS 14+)

Barttery includes four WidgetKit variants: a small square with one device, a small
square with four devices (2×2), the original medium rectangle with four devices,
and a table with device icons, names, percentages, and charging/paused status.
The table shows up to four devices in medium size or eight in large size and
replaces the old eight-ring widget. Remove any old eight-ring widget and add
**Batteries · Table** from the gallery. The ring layouts show device names except
for the compact 2×2 layout. They use real readings from the running menu bar app;
the extension does not access Bluetooth or USB itself. After 30 minutes without a
measurement, a device is marked as out of date. WidgetKit controls refresh timing,
so updates are not instantaneous.

The automatic order is Mac, iPhone, iPad, AirPods, AirPods case, Apple Watch, then
accessories. The first one, four, or eight available entries are shown, depending
on the variant. The single-device widget currently uses the first available device.

### Build with the widget

The `make build` / `make dmg` workflow **does not include the widget**. The widget
build uses Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

1. Install Xcode and XcodeGen (`brew install xcodegen`).
2. Run `xcodegen generate`, then open `Barttery.xcodeproj`.
3. Choose your Apple Developer team for **both** targets in Signing & Capabilities.
   Register/enable `group.me.yura.barttery` for both app identifiers using your
   team's provisioning profiles. If using your own identifiers, update them in
   `project.yml`, both `Widgets/*.entitlements`, and `Sources/WidgetSnapshot.swift`.
4. Build the **Barttery** scheme. The host stays unsandboxed; only the widget
   extension is sandboxed. Signing and App Group access must work for both targets.
5. Quit any older Barttery instance, copy the signed app to Applications, and launch
   it. Right-click the desktop → **Edit Widgets** → search for **Barttery** and add
   **Batteries**. Keep Barttery running for fresh readings.

Command-line signed build: `make widgets TEAM=YOUR_TEAM_ID` (Apple Silicon, matching
the bundled device helpers). Output: `.build/xcode/Build/Products/Release/Barttery.app`.
The `make dmg` recipe builds the non-widget version; it does not package this Xcode
output. For public widget distribution, use appropriate Developer ID signing,
App Group provisioning, and notarization.

Checks without a signing account: `make widgets-check`, `swift test`, and
`make widget-preview` (renders fresh, stale, and empty states into
`.build/widget-preview.png`). An unsigned build only checks compilation; it does
not verify widget registration or cross-process App Group access.

## Signed releases outside the App Store

`make build` remains a local development build. `make dmg` (also `make release`)
requires a **Developer ID Application** certificate with its private key in your
Keychain, Xcode command-line tools, and an Apple Developer membership.

Find your signing identity:

```sh
security find-identity -v -p codesigning
```

Store notarization credentials once (the command prompts for credentials; use an
app-specific password, not your Apple Account password):

```sh
xcrun notarytool store-credentials Barttery-notary
```

Increase `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist` for each
SwiftPM release, then run:

```sh
make dmg SIGN="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=Barttery-notary
```

The release signs all bundled helpers/libraries and the app with Hardened Runtime
and a secure timestamp, notarizes and staples the app, then signs, notarizes, and
staples the DMG. Gatekeeper checks must pass before `Barttery-<version>.dmg` is
published in the project directory. An existing DMG is replaced only on success.
Internet access is required. If Apple rejects a submission, retrieve its detailed
log with `xcrun notarytool log <submission-id> --keychain-profile Barttery-notary`.
Never distribute the local Apple Development build as a public release.

This workflow does **not** package the widget; that requires the separate Xcode
build and Developer ID-compatible App Group provisioning for both targets.

## License

Barttery is licensed under the **GPL-2.0-or-later** license. The following third-party components are bundled:

| Component | License |
|---|---|
| [libimobiledevice](https://github.com/libimobiledevice/libimobiledevice) (`ideviceinfo`, `idevice_id`, `comptest`, `bartbeat`) | GPL-2.0+ |
| [libimobiledevice-glue](https://github.com/libimobiledevice/libimobiledevice-glue) | LGPL-2.1+ |
| [libplist](https://github.com/libimobiledevice/libplist) | LGPL-2.1+ |
| [libusbmuxd](https://github.com/libimobiledevice/libusbmuxd) | LGPL-2.1+ |
| [OpenSSL 3](https://github.com/openssl/openssl) (`libssl`, `libcrypto`) | Apache-2.0 |
