import CoreFoundation
import Foundation

/// A Darwin notification that says "automation files changed". It has no payload and can be lost,
/// so it is only a wake hint: readers always rescan the files.
public enum AutomationSignal {
    public static let name = "com.ryanerkal.jevlauncher.automations.changed"

    public static func post() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(name as CFString), nil, nil, true)
    }

    /// Calls `handler` on the main queue after each signal, from any process. Keep the token alive; it stops observing when released.
    public static func observe(_ handler: @escaping @Sendable () -> Void) -> Observer { Observer(handler) }

    public final class Observer: @unchecked Sendable {
        private let handler: @Sendable () -> Void

        fileprivate init(_ handler: @escaping @Sendable () -> Void) {
            self.handler = handler
            let center = CFNotificationCenterGetDarwinNotifyCenter()
            CFNotificationCenterAddObserver(center, Unmanaged.passUnretained(self).toOpaque(), { _, observer, _, _, _ in
                guard let observer else { return }
                let me = Unmanaged<Observer>.fromOpaque(observer).takeUnretainedValue()
                let handler = me.handler
                DispatchQueue.main.async { handler() }
            }, AutomationSignal.name as CFString, nil, .deliverImmediately)
        }

        deinit {
            CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
                                               CFNotificationName(AutomationSignal.name as CFString), nil)
        }
    }
}
