import AppKit

/// Keep passive alerts out of a locked or inactive login session.
@MainActor
final class NotchSession {
    private var workspaceObservers: [NSObjectProtocol] = []
    private var screenObservers: [NSObjectProtocol] = []

    init(changed: @escaping (Bool) -> Void) {
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { changed(false) }
            },
            workspace.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { changed(Self.isAvailable) }
            }
        ]
        let distributed = DistributedNotificationCenter.default()
        screenObservers = [
            distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { changed(false) }
            },
            distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { changed(Self.isAvailable) }
            }
        ]
    }

    static var isAvailable: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool != true
    }

    deinit {
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        screenObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
    }
}
