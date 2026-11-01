import Foundation
import IOKit.ps

extension BatteryStatus {
    // Public read-only status remains available before privileged control is enabled.
    static func readPublicStatus() -> BatteryStatus? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let value = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  value[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            return BatteryStatus(level: value[kIOPSCurrentCapacityKey] as? Int,
                                 charging: value[kIOPSIsChargingKey] as? Bool,
                                 connected: value[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                                 current: nil, updated: nil, source: "IOPowerSources")
        }
        return nil
    }
}
