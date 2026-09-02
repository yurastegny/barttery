import IOKit
import IOKit.ps
import Foundation

enum ChargeState {
    case discharging
    case charging
    case paused   // optimized charging hold
    case plugged  // on AC, fully charged
}

struct MacBattery {
    let level: Int
    let state: ChargeState
    let cycleCount: Int
    let minutesToFull: Int?
    let minutesToEmpty: Int?
}

class MacBatteryReader {
    var onUpdate: ((MacBattery?) -> Void)?
    private var runLoopSource: CFRunLoopSource?

    nonisolated(unsafe) static weak var shared: MacBatteryReader?

    func start() {
        MacBatteryReader.shared = self

        let src = IOPSNotificationCreateRunLoopSource({ _ in
            MacBatteryReader.shared?.publish()
        }, nil)

        if let src = src?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            runLoopSource = src
        }
        publish()
    }

    func read() -> MacBattery? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let props = propsRef?.takeRetainedValue() as? [String: Any]
        else { return nil }

        // Use the system-computed percentage from IOPowerSources — the same value
        // the macOS menu bar shows. Raw capacity math diverges by 1-2% because
        // Apple applies temperature compensation and charge hysteresis on top.
        guard let psBlob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let psList = IOPSCopyPowerSourcesList(psBlob)?.takeRetainedValue() as? [CFTypeRef],
              let psSource = psList.first,
              let psDesc = IOPSGetPowerSourceDescription(psBlob, psSource)
                               .takeUnretainedValue() as? [String: Any],
              let level = psDesc[kIOPSCurrentCapacityKey] as? Int
        else { return nil }
        let isCharging  = props["IsCharging"]         as? Bool ?? false
        let acConnected = props["ExternalConnected"]  as? Bool ?? false

        let state: ChargeState = isCharging ? .charging : acConnected ? (level >= 100 ? .plugged : .paused) : .discharging
        let cycleCount = props["CycleCount"] as? Int ?? 0

        func validMinutes(_ key: String) -> Int? {
            guard let v = props[key] as? Int, v > 0, v < 65535 else { return nil }
            return v
        }

        var minutesToFull: Int? = nil
        var minutesToEmpty: Int? = nil

        if state == .charging {
            minutesToFull = validMinutes("AvgTimeToFull")
        } else if state == .discharging {
            minutesToEmpty = validMinutes("TimeRemaining")
        }

        return MacBattery(level: level, state: state, cycleCount: cycleCount,
                          minutesToFull: minutesToFull, minutesToEmpty: minutesToEmpty)
    }

    func readNow() { publish() }

    private func publish() {
        let battery = read()
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(battery)
        }
    }

    deinit {
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode)
        }
    }
}
