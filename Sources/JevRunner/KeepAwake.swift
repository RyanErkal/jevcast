import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import LauncherCore

/// The runner's "keep awake on power" assertion. `KeepAwakePolicy` decides; this makes the IOKit calls.
/// The assertion type stops idle system sleep only, so the display still sleeps and the screen still locks.
/// Each assertion has an OS timeout and is replaced before it ends, so a stuck runner cannot hold it.
/// The OS also drops it when this process exits. Used only on the runner's queue.
final class KeepAwake {
    private var assertion: IOPMAssertionID?
    private var heldSince: Date?

    var isHeld: Bool { assertion != nil }

    func update(wanted: Bool, now: Date = Date()) {
        switch KeepAwakePolicy.step(wanted: wanted, heldSince: heldSince, now: now) {
        case .none: break
        case .create:
            assertion = Self.create(); heldSince = assertion == nil ? nil : now
            log(assertion == nil ? "Could not keep the Mac awake for automations." : "Keeping the Mac awake on power for automations.")
        case .renew:
            // The new one is made before the old one goes, so there is no gap.
            let old = assertion
            if let renewed = Self.create() {
                assertion = renewed; heldSince = now
                if let old { IOPMAssertionRelease(old) }
            }
        case .release:
            release()
            log("Stopped keeping the Mac awake for automations.")
        }
    }

    func release() {
        if let assertion { IOPMAssertionRelease(assertion) }
        assertion = nil; heldSince = nil
    }

    private static func create() -> IOPMAssertionID? {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithDescription(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            "Jevcast automations" as CFString,
            "Scheduled automations are on and the Mac is on power." as CFString,
            "Jevcast keeps the Mac awake on power so scheduled automations run on time." as CFString,
            nil, KeepAwakePolicy.assertionTimeout, kIOPMAssertionTimeoutActionRelease as CFString, &id)
        return result == kIOReturnSuccess ? id : nil
    }

    /// AC, battery, or unknown, from the providing power source. Desktop Macs report AC.
    static func powerSource() -> KeepAwakePolicy.PowerSource {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return .unknown }
        switch type {
        case kIOPMACPowerKey: return .ac
        case kIOPMBatteryPowerKey, kIOPMUPSPowerKey: return .battery
        default: return .unknown
        }
    }
}
