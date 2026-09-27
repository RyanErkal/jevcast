import AppKit

/// Where the notch is, and how big the panel must be for each mode. Width 0 means the screen has none.
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    static let cardWidth: CGFloat = 380
    static let cardBody: CGFloat = 92
    /// Extra width on each side of the notch for the running pill: name on the left, time on the right.
    static let pillWing: CGFloat = 96
    /// Pill height on a screen without a notch.
    static let pillBody: CGFloat = 32
    /// One row of an expanded stack.
    static let rowHeight: CGFloat = 52
    static let maxRows = 4
    /// The running detail: latest activity and Cancel.
    static let detailBody: CGFloat = 132
    /// The reply field under the card.
    static let replyBody: CGFloat = 44
    /// Room around the shape for its shadow.
    static let margin: CGFloat = 24

    init(screenFrame: CGRect, notchWidth: CGFloat, notchHeight: CGFloat) {
        self.screenFrame = screenFrame; self.notchWidth = notchWidth; self.notchHeight = notchHeight
    }

    init(screen: NSScreen) {
        var width: CGFloat = 0
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            width = max(0, screen.frame.width - left.width - right.width)
        }
        self.init(screenFrame: screen.frame, notchWidth: width, notchHeight: width > 0 ? screen.safeAreaInsets.top : 0)
    }

    var hasNotch: Bool { notchWidth > 0 }

    /// Width of the black shape in this mode.
    func width(_ mode: NotchState.Mode) -> CGFloat {
        switch mode {
        case .pill: return hasNotch ? notchWidth + 2 * Self.pillWing : 260
        case .card, .detail, .reply: return max(Self.cardWidth, notchWidth)
        }
    }

    /// Height below the notch in this mode. A stack in detail mode lists up to `maxRows` rows.
    func bodyHeight(_ mode: NotchState.Mode, alert: NotchAlert?) -> CGFloat {
        switch mode {
        case .pill: return hasNotch ? 0 : Self.pillBody
        case .card: return Self.cardBody
        case .reply: return Self.cardBody + Self.replyBody
        case .detail:
            guard let alert, alert.isStack else { return Self.detailBody }
            return Self.cardBody + CGFloat(min(alert.stackCount, Self.maxRows)) * Self.rowHeight
        }
    }

    /// The panel covers the notch and the shape below it, and nothing else, so clicks elsewhere pass through.
    func panelFrame(_ mode: NotchState.Mode, alert: NotchAlert?) -> CGRect {
        let width = width(mode) + Self.margin
        let height = notchHeight + bodyHeight(mode, alert: alert) + (hasNotch ? 0 : 10) + Self.margin
        return CGRect(x: screenFrame.midX - width / 2, y: screenFrame.maxY - height, width: width, height: height)
    }

    /// The card frame, as before modes existed.
    var panelFrame: CGRect { panelFrame(.card, alert: nil) }
}
