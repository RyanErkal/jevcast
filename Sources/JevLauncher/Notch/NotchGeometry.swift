import AppKit

/// Where the notch is, and how big the panel must be for each mode. Width 0 means the screen has none.
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    /// The card is at least this wide, and 40 wider than the notch.
    static let cardWidth: CGFloat = 380
    static let cardBody: CGFloat = 90
    /// Success or info with one action: one line.
    static let briefBody: CGFloat = 56
    /// A question's row of answers, above its buttons.
    static let choicesRow: CGFloat = 36
    /// Extra width on each side of the notch for the running pill: icon on the left, time on the right.
    static let pillWing: CGFloat = 66
    /// Pill size on a screen without a notch.
    static let pillBody: CGFloat = 34
    static let pillWidth: CGFloat = 280
    /// Gap above the shape on a screen without a notch.
    static let topGap: CGFloat = 6
    /// A stack as a list: its header, then one row per alert.
    static let listHeader: CGFloat = 38
    static let rowHeight: CGFloat = 46
    static let listBottom: CGFloat = 10
    static let maxRows = 4
    /// The running detail: latest activity, progress, and Cancel.
    static let detailBody: CGFloat = 144
    /// The question and the reply field.
    static let replyBody: CGFloat = 104
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
        case .pill: return hasNotch ? notchWidth + 2 * Self.pillWing : Self.pillWidth
        case .card, .detail, .reply: return max(Self.cardWidth, notchWidth + 40)
        }
    }

    /// Height below the notch in this mode. A stack in detail mode lists up to `maxRows` rows.
    func bodyHeight(_ mode: NotchState.Mode, alert: NotchAlert?) -> CGFloat {
        switch mode {
        case .pill: return hasNotch ? 0 : Self.pillBody
        case .card:
            guard let alert else { return Self.cardBody }
            if alert.presentation.isBrief { return Self.briefBody }
            return Self.cardBody + (alert.presentation.choices.isEmpty ? 0 : Self.choicesRow)
        case .reply: return Self.replyBody
        case .detail:
            guard let alert, alert.isStack else { return Self.detailBody }
            return Self.listHeader + CGFloat(min(alert.stackCount, Self.maxRows)) * Self.rowHeight + Self.listBottom
        }
    }

    /// The shape's full size, the notch included.
    func shapeSize(_ mode: NotchState.Mode, alert: NotchAlert?) -> CGSize {
        CGSize(width: width(mode), height: notchHeight + bodyHeight(mode, alert: alert))
    }

    /// The panel covers the notch and the shape below it, and nothing else, so clicks elsewhere pass through.
    func panelFrame(_ mode: NotchState.Mode, alert: NotchAlert?) -> CGRect {
        let width = width(mode) + Self.margin
        let height = notchHeight + bodyHeight(mode, alert: alert) + (hasNotch ? 0 : Self.topGap) + Self.margin
        return CGRect(x: screenFrame.midX - width / 2, y: screenFrame.maxY - height, width: width, height: height)
    }

    /// The card frame, as before modes existed.
    var panelFrame: CGRect { panelFrame(.card, alert: nil) }
}
