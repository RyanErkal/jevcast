import AppKit

/// Finds an open menu at the top of the screen, from any app, so the notch never covers it.
/// Reads only window layers and bounds, which need no permission.
enum NotchMenuGuard {
    /// True while the island's own overflow menu is open, so it does not hide the island.
    nonisolated(unsafe) static var ownMenuOpen = false
    /// When the island's own menu last closed. The press that closes a menu can arrive just after it has gone.
    nonisolated(unsafe) static var ownMenuClosed = Date.distantPast
    /// Seconds after the island's own menu closes in which a press outside still belongs to that menu.
    static let ownMenuGrace: TimeInterval = 0.4

    /// True while the island's own menu is open or has only just closed, so a press that closes the menu does not
    /// also close the island.
    static func ownMenuActive(now: Date) -> Bool {
        ownMenuOpen || now.timeIntervalSince(ownMenuClosed) < ownMenuGrace
    }

    static func menuOpen(over frame: CGRect, screen: CGRect) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        // Window bounds use top-left origin on the main screen; convert the panel frame.
        let top = CGRect(x: frame.minX, y: screen.maxY - frame.maxY, width: frame.width, height: frame.height)
        let own = ProcessInfo.processInfo.processIdentifier
        return list.contains { info in
            guard info[kCGWindowLayer as String] as? Int == menuLevel,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict) else { return false }
            // Our own panel is never at menu level, but skip it anyway.
            if info[kCGWindowOwnerPID as String] as? Int32 == own, bounds == top || ownMenuOpen { return false }
            return bounds.intersects(top)
        }
    }
}

/// A cancelled watcher must not clear the state owned by its replacement.
struct NotchMenuObservation {
    private(set) var owner: UUID?
    private(set) var isOpen = false

    mutating func begin() -> UUID {
        let id = UUID()
        owner = id
        return id
    }

    mutating func update(_ open: Bool, owner id: UUID) -> Bool {
        guard owner == id, isOpen != open else { return false }
        isOpen = open
        return true
    }

    mutating func finish(_ id: UUID) -> Bool {
        guard owner == id else { return false }
        owner = nil
        isOpen = false
        return true
    }
}
