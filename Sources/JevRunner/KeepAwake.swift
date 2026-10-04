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
    /// The error of the current failure streak, so a failure that repeats every tick is logged once.
    private var lastFailure: IOReturn?

    var isHeld: Bool { assertion != nil }

    func update(wanted: Bool, now: Date = Date()) {
        switch KeepAwakePolicy.step(wanted: wanted, heldSince: heldSince, now: now) {
        case .none: break
        case .create:
            switch Self.create() {
            case .success(let id):
                assertion = id; heldSince = now; lastFailure = nil
                log("Keeping the Mac awake on power for automations.")
            case .failure(let error):
                failed(error.code, "Could not keep the Mac awake for automations")
            }
        case .renew:
            // The new one is made before the old one goes, so there is no gap.
            let old = assertion
            switch Self.create() {
            case .success(let id):
                if lastFailure != nil { log("Renewed the keep-awake assertion for automations.") }
                assertion = id; heldSince = now; lastFailure = nil
                if let old { IOPMAssertionRelease(old) }
            case .failure(let error):
                failed(error.code, "Could not renew the keep-awake assertion for automations")
                // `heldSince` stays the old one's start, so the next tick tries again or makes a new one.
                if let since = heldSince, !KeepAwakePolicy.keepsOldAfterFailedRenew(heldSince: since, now: now) { release() }
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

    /// Logs a failure once per streak: again only after a success or a different error.
    private func failed(_ code: IOReturn, _ message: String) {
        guard lastFailure != code else { return }
        lastFailure = code
        log(message + String(format: " (IOKit error 0x%08x).", UInt32(bitPattern: code)))
    }

    private static func create() -> Result<IOPMAssertionID, IOReturnError> {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithDescription(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            "Jevcast automations" as CFString,
            "Scheduled automations are on and the Mac is on power." as CFString,
            "Jevcast keeps the Mac awake on power so scheduled automations run on time." as CFString,
            nil, KeepAwakePolicy.assertionTimeout, kIOPMAssertionTimeoutActionRelease as CFString, &id)
        return result == kIOReturnSuccess ? .success(id) : .failure(IOReturnError(code: result))
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

/// An IOKit error code, so `create` can return a `Result`.
struct IOReturnError: Error { let code: IOReturn }
