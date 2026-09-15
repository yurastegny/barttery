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

Right now, in my region it's not possible to get an Apple Developer account. Without it, Apple does not trust the app. macOS will block the first launch until you allow it.

**macOS 13–14:** Control-click **Barttery** → **Open** → **Open**.

**macOS 15 and later:**

1. Double-click **Barttery**. You'll get a warning such as **"Apple could not verify "Barttery" is free of malware"** or **"Barttery" can't be opened because the developer cannot be verified**.
2. Click **Done** — not **Move to Trash**.
3. Open **System Settings → Privacy & Security** and scroll down to **Security**.
4. Click **Open Anyway** next to the message that Barttery was blocked, then enter your password (or use Touch ID) and click **Open**.

After this, macOS remembers the exception and the app launches normally.

## License

Barttery is licensed under the **GPL-2.0-or-later** license. The following third-party components are bundled:

| Component | License |
|---|---|
| [libimobiledevice](https://github.com/libimobiledevice/libimobiledevice) (`ideviceinfo`, `idevice_id`, `comptest`, `bartbeat`) | GPL-2.0+ |
| [libimobiledevice-glue](https://github.com/libimobiledevice/libimobiledevice-glue) | LGPL-2.1+ |
| [libplist](https://github.com/libimobiledevice/libplist) | LGPL-2.1+ |
| [libusbmuxd](https://github.com/libimobiledevice/libusbmuxd) | LGPL-2.1+ |
| [OpenSSL 3](https://github.com/openssl/openssl) (`libssl`, `libcrypto`) | Apache-2.0 |

