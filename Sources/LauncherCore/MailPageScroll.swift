import Foundation

/// What Space and ⇧Space do in an open message: scroll one page, or go to the next message once
/// the end shows. Offsets are points from the top of the message.
public enum MailPageScroll {
    public enum Step: Equatable, Sendable {
        /// Scroll so the top of the view is at this offset.
        case scroll(to: Double)
        /// The end of the message shows: Space goes to the next message.
        case next
        /// Already at the top: ⇧Space does nothing.
        case stay
    }

    /// Points of the old page that stay in view after a page, so the eye keeps its place.
    public static let overlap = 40.0
    /// Distance from the end that still counts as the end, for rounding in the scroll view.
    public static let slack = 2.0

    public static func step(offset: Double, viewport: Double, content: Double, down: Bool) -> Step {
        let page = max(viewport - overlap, viewport * 0.5, 1)
        let end = max(content - viewport, 0)
        if down {
            if offset >= end - slack { return .next }
            return .scroll(to: min(offset + page, end))
        }
        if offset <= slack { return .stay }
        return .scroll(to: max(offset - page, 0))
    }
}
