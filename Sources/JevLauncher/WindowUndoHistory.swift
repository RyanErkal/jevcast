import CoreGraphics

/// Per-window undo stacks for window actions, plus the most recent bulk
/// arrangement (Tile All / Cascade All).
///
/// A bulk entry lists only the windows that the arrangement actually moved.
/// Each of those windows has exactly one pushed frame for the arrangement, so
/// a bulk restore pops exactly one entry per restored window.
struct WindowUndoHistory<Key: Hashable, Element> {
    struct Move {
        let key: Key
        let original: CGRect
        /// The live window handle used to put the window back.
        let element: Element
    }

    struct Bulk {
        /// Every window that took part, including windows already in place.
        let members: Set<Key>
        /// Only the windows whose frame changed, in arrangement order.
        let moved: [Move]
    }

    let limit: Int
    private(set) var stacks: [Key: [CGRect]] = [:]
    private(set) var bulk: Bulk?

    init(limit: Int = 24) {
        self.limit = max(1, limit)
    }

    /// Records the frame before a single-window action. A single action
    /// ends the bulk restore window.
    mutating func recordSingle(_ original: CGRect, for key: Key) {
        bulk = nil
        push(original, for: key)
    }

    /// Records a bulk arrangement. Windows that did not move get no undo
    /// entry. An arrangement that moved nothing leaves no bulk entry.
    mutating func recordBulk(members: Set<Key>, moved: [Move]) {
        for move in moved { push(move.original, for: move.key) }
        bulk = moved.isEmpty ? nil : Bulk(members: members, moved: moved)
    }

    /// The bulk moves to reverse when ``key`` took part in the last bulk
    /// arrangement.
    func bulkMoves(including key: Key) -> [Move]? {
        guard let bulk, bulk.members.contains(key) else { return nil }
        return bulk.moved
    }

    /// Pops one entry for each restored window and ends the bulk entry.
    mutating func completeBulkRestore(restored keys: [Key]) {
        for key in keys { _ = popLast(for: key) }
        bulk = nil
    }

    mutating func popLast(for key: Key) -> CGRect? {
        guard var stack = stacks[key], let last = stack.popLast() else { return nil }
        stacks[key] = stack.isEmpty ? nil : stack
        return last
    }

    /// Puts back a frame after a restore could not be applied.
    mutating func reinstate(_ frame: CGRect, for key: Key) {
        push(frame, for: key)
    }

    private mutating func push(_ frame: CGRect, for key: Key) {
        var stack = stacks[key, default: []]
        stack.append(frame)
        if stack.count > limit { stack.removeFirst(stack.count - limit) }
        stacks[key] = stack
    }
}
