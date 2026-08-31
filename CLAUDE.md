# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build commands

```bash
make build      # compile Swift + copy/sign all resources into Barttery.app/
make install    # build + copy to /Applications/Barttery.app
make run        # build + open the app
make dmg        # build + package Barttery-<version>.dmg
make clean      # remove .build/, Barttery.app/, Sources/Resources/bartbeat

make bartbeat   # recompile only the C daemon (bridge/bartbeat.c)
```

`make build` produces an **arm64-only** release binary (no Intel). The `SIGN` variable defaults to `Apple Development: yura@yura.me (69Z678PHDM)` but can be overridden.

There are no tests. There is no linter configured.

To restart the app during development:
```bash
pkill -x Barttery; pkill -x bartbeat; open /Applications/Barttery.app
```

To watch `bartbeat` output live (keep stdin open via FIFO):
```bash
mkfifo /tmp/bb_fifo
DYLD_LIBRARY_PATH=/Applications/Barttery.app/Contents/Resources \
  /Applications/Barttery.app/Contents/Resources/bartbeat < /tmp/bb_fifo > /tmp/bb_out.txt 2>/tmp/bb_err.txt &
exec 3>/tmp/bb_fifo   # keep fifo open
# later: exec 3>&-    # close stdin → bartbeat exits
```

## Architecture

### Two-layer design

The app is a `MenuBarExtra` SwiftUI app. All state lives in `DeviceBatteryMonitor` (an `ObservableObject`). Readers are created once in `init()` and push updates via callbacks; `DeviceBatteryMonitor` never polls readers, they call back.

```
BartteryApp (SwiftUI @main)
  └── DeviceBatteryMonitor (ObservableObject, single source of truth)
        ├── MacBatteryReader      — IOKit power source
        ├── IDeviceReader         — iPhone/iPad/Watch (via bartbeat + comptest)
        ├── AirPodsReader         — CoreBluetooth / IOBluetooth
        ├── AccessoryReader       — Magic Keyboard/Mouse/Trackpad via IOBluetooth
        ├── BLEDeviceReader       — generic BLE Battery Service (UUID 0x180F)
        └── LogitechReader        — HID++ 2.0 via IOKit
```

`DeviceBatteryMonitor.refresh()` triggers Mac, Apple accessories, BLE, and Logi readers. iPhone/iPad/Watch are **not** triggered from `refresh()` — `IDeviceReader` manages its own schedule via `bartbeat`.

### bartbeat — the C daemon

`bridge/bartbeat.c` compiles to `Sources/Resources/bartbeat` (bundled in the app). It is launched by `IDeviceReader.launchBartbeat()` as a persistent subprocess with stdin/stdout pipes.

- Subscribes to `usbmuxd` events for device connect/disconnect
- For each device, opens **two separate** lockdownd connections:
  - `ld_bat` — kept alive for repeated `lockdownd_get_value` battery polls (never passed to `lockdownd_start_service`)
  - `ld_hb` — used only to call `lockdownd_start_service(HEARTBEAT_SERVICE_NAME)`, then freed
- The heartbeat thread (`hb_run`) receives Marco/sends Polo every ~30 s to keep the Wi-Fi connection alive
- Battery is polled every `POLL_S = 30` seconds using `ld_bat`
- Outputs newline-delimited JSON to stdout: `connected`, `disconnected`, `phone`, `pad`
- Exits when stdin closes (parent process dies)

**Critical**: do NOT use the same lockdownd client for both `lockdownd_start_service` (heartbeat) and `lockdownd_get_value` (battery) — this causes the battery session to hang. Always use two separate clients.

The dylibs in `Sources/Resources/lib/` are resolved at runtime via `DYLD_LIBRARY_PATH` set by Swift before launching bartbeat.

### IDeviceReader

Parses bartbeat's JSON output line-by-line. Key callbacks:
- `onPhoneUpdate(level, charging, name)` — called for every `"phone"` JSON line
- `onPadUpdate(level, charging, name)` — called for every `"pad"` JSON line  
- `onWatchUpdate(watch)` — called after `comptest <udid>` completes

Apple Watch is queried via `comptest` (a bundled binary that runs `companionproxy`) every time a phone battery update arrives, using the phone's UDID. Watch is never queried from iPad UDIDs.

`checkStale()` runs on a 60-second timer and clears phone/pad/watch data after 24 hours of no updates.

### NotificationManager

Singleton. `BatteryDevice` enum (in `NotificationManager.swift`) is the canonical device type used everywhere. State (`lastLevel`, `notifiedThresholds`) is persisted to UserDefaults under keys `nm.<device>.level` and `nm.<device>.notified` so notifications survive app restarts.

Thresholds: 20% (discharge warning), 80% (charging target), 100% (full). Configurable per device in `AppSettings` (persisted as `notificationThresholds` in UserDefaults).

### Resource bundle layout

The SPM target has **no** `.process("Resources")` — resources are copied flat into `Barttery.app/Contents/Resources/` by the Makefile. Use `Bundle.main.resourceURL` to locate them at runtime (not `Bundle.module`).

Binaries in `Sources/Resources/` that are **pre-built** and checked in:
- `bartbeat` — rebuilt via `make bartbeat`; requires Homebrew libimobiledevice headers at `/opt/homebrew/include`
- `comptest`, `idevice_id`, `ideviceinfo` — pre-built, do not modify
- `lib/*.dylib` — bundled libimobiledevice stack (arm64 only)

### Version and release

Version is in `Info.plist` (`CFBundleShortVersionString`). To release: bump version, `make dmg`, commit the DMG.
