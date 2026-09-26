import Foundation
import IOKit.hid

/// Sets the Caps Lock light on each keyboard through IOKit HID. It changes only the light,
/// never the Caps Lock state. Opening keyboards may need Input Monitoring.
@MainActor
final class CapsLockLight {
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var opened = false
    /// Called when a keyboard connects, including each one present at start.
    var onKeyboardConnected: (() -> Void)?
    /// The result of opening the keyboards; not `kIOReturnSuccess` means the light cannot be set.
    private(set) var openResult: IOReturn = kIOReturnNotOpen

    var isAvailable: Bool { openResult == kIOReturnSuccess }

    func start() {
        guard !opened else { return }
        opened = true
        let matching: [String: Any] = [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let light = Unmanaged<CapsLockLight>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { light.onKeyboardConnected?() }
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func stop() {
        guard opened else { return }
        opened = false
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        openResult = kIOReturnNotOpen
    }

    /// Turns the light on or off on every keyboard. True when at least one light changed.
    @discardableResult
    func set(_ on: Bool) -> Bool {
        guard isAvailable, let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return false }
        let match: [String: Any] = [kIOHIDElementUsagePageKey: kHIDPage_LEDs, kIOHIDElementUsageKey: kHIDUsage_LED_CapsLock]
        var changed = false
        for device in devices {
            guard let elements = IOHIDDeviceCopyMatchingElements(device, match as CFDictionary, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else { continue }
            for element in elements {
                let value = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, 0, on ? 1 : 0)
                if IOHIDDeviceSetValue(device, element, value) == kIOReturnSuccess { changed = true }
            }
        }
        return changed
    }
}
