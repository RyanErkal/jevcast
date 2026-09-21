import CoreGraphics

/// The action identifiers used by the launcher and its key bindings.
///
/// The raw values are stable IDs. Keep them independent from the display title so
/// that changing copy does not invalidate saved shortcuts.
public enum WindowAction: String, CaseIterable, Identifiable, Sendable {
    case leftHalf = "left-half"
    case rightHalf = "right-half"
    case topHalf = "top-half"
    case bottomHalf = "bottom-half"

    case topLeftQuarter = "top-left-quarter"
    case topRightQuarter = "top-right-quarter"
    case bottomLeftQuarter = "bottom-left-quarter"
    case bottomRightQuarter = "bottom-right-quarter"

    case leftThird = "left-third"
    case centerThird = "center-third"
    case rightThird = "right-third"
    case leftTwoThirds = "left-two-thirds"
    case rightTwoThirds = "right-two-thirds"

    case topLeftSixth = "top-left-sixth"
    case topCenterSixth = "top-center-sixth"
    case topRightSixth = "top-right-sixth"
    case bottomLeftSixth = "bottom-left-sixth"
    case bottomCenterSixth = "bottom-center-sixth"
    case bottomRightSixth = "bottom-right-sixth"

    case maximize = "maximize"
    case center = "center"
    case larger = "larger"
    case smaller = "smaller"
    case restore = "restore"
    case nextDisplay = "next-display"
    case previousDisplay = "previous-display"
    case fullscreen = "fullscreen"
    case tileAll = "tile-all"
    case cascadeAll = "cascade-all"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .leftHalf: return "Left Half"
        case .rightHalf: return "Right Half"
        case .topHalf: return "Top Half"
        case .bottomHalf: return "Bottom Half"
        case .topLeftQuarter: return "Top Left Quarter"
        case .topRightQuarter: return "Top Right Quarter"
        case .bottomLeftQuarter: return "Bottom Left Quarter"
        case .bottomRightQuarter: return "Bottom Right Quarter"
        case .leftThird: return "Left Third"
        case .centerThird: return "Center Third"
        case .rightThird: return "Right Third"
        case .leftTwoThirds: return "Left Two Thirds"
        case .rightTwoThirds: return "Right Two Thirds"
        case .topLeftSixth: return "Top Left Sixth"
        case .topCenterSixth: return "Top Center Sixth"
        case .topRightSixth: return "Top Right Sixth"
        case .bottomLeftSixth: return "Bottom Left Sixth"
        case .bottomCenterSixth: return "Bottom Center Sixth"
        case .bottomRightSixth: return "Bottom Right Sixth"
        case .maximize: return "Maximize"
        case .center: return "Center"
        case .larger: return "Larger"
        case .smaller: return "Smaller"
        case .restore: return "Restore"
        case .nextDisplay: return "Next Display"
        case .previousDisplay: return "Previous Display"
        case .fullscreen: return "Fullscreen"
        case .tileAll: return "Tile All"
        case .cascadeAll: return "Cascade All"
        }
    }

    /// Common spellings accepted by command/search lookup. The stable ID is
    /// always included by callers separately through ``rawValue``.
    public var aliases: [String] {
        switch self {
        case .leftHalf: return ["left", "left side"]
        case .rightHalf: return ["right", "right side"]
        case .topHalf: return ["top"]
        case .bottomHalf: return ["bottom"]
        case .topLeftQuarter: return ["top left", "upper left"]
        case .topRightQuarter: return ["top right", "upper right"]
        case .bottomLeftQuarter: return ["bottom left", "lower left"]
        case .bottomRightQuarter: return ["bottom right", "lower right"]
        case .leftThird: return ["left 1/3", "one third left"]
        case .centerThird: return ["center 1/3", "middle third"]
        case .rightThird: return ["right 1/3", "one third right"]
        case .leftTwoThirds: return ["left 2/3"]
        case .rightTwoThirds: return ["right 2/3"]
        case .topLeftSixth: return ["top left 1/6"]
        case .topCenterSixth: return ["top center 1/6"]
        case .topRightSixth: return ["top right 1/6"]
        case .bottomLeftSixth: return ["bottom left 1/6"]
        case .bottomCenterSixth: return ["bottom center 1/6"]
        case .bottomRightSixth: return ["bottom right 1/6"]
        case .maximize: return ["max", "fill"]
        case .center: return ["centre", "middle"]
        case .larger: return ["grow", "increase"]
        case .smaller: return ["shrink", "decrease"]
        case .restore: return ["undo", "reset"]
        case .nextDisplay: return ["next monitor", "next screen"]
        case .previousDisplay: return ["previous monitor", "previous screen"]
        case .fullscreen: return ["full screen"]
        case .tileAll: return ["tile windows"]
        case .cascadeAll: return ["cascade windows"]
        }
    }

    public var symbol: String {
        switch self {
        case .leftHalf: return "rectangle.lefthalf.inset.filled"
        case .rightHalf: return "rectangle.righthalf.inset.filled"
        case .topHalf: return "rectangle.tophalf.inset.filled"
        case .bottomHalf: return "rectangle.bottomhalf.inset.filled"
        case .topLeftQuarter: return "rectangle.inset.topleft.filled"
        case .topRightQuarter: return "rectangle.inset.topright.filled"
        case .bottomLeftQuarter: return "rectangle.inset.bottomleft.filled"
        case .bottomRightQuarter: return "rectangle.inset.bottomright.filled"
        case .leftThird: return "rectangle.split.3x1.fill"
        case .centerThird: return "rectangle.split.3x1.fill"
        case .rightThird: return "rectangle.split.3x1.fill"
        case .leftTwoThirds: return "rectangle.split.2x1.fill"
        case .rightTwoThirds: return "rectangle.split.2x1.fill"
        case .topLeftSixth, .topCenterSixth, .topRightSixth,
             .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth:
            return "rectangle.split.3x2.fill"
        case .maximize: return "rectangle.inset.filled"
        case .center: return "rectangle.center.inset.filled"
        case .larger: return "arrow.up.left.and.arrow.down.right"
        case .smaller: return "arrow.down.right.and.arrow.up.left"
        case .restore: return "arrow.uturn.backward"
        case .nextDisplay: return "rectangle.on.rectangle"
        case .previousDisplay: return "rectangle.on.rectangle"
        case .fullscreen: return "arrow.up.left.and.arrow.down.right"
        case .tileAll: return "square.grid.2x2"
        case .cascadeAll: return "square.stack.3d.up"
        }
    }

}

/// Pure window geometry in Accessibility coordinates.
///
/// Accessibility coordinates have a top-left global origin and a downward
/// growing y axis. This type deliberately has no AppKit or Accessibility
/// dependencies, which keeps layout behavior deterministic and testable.
public enum WindowLayout {
    /// Returns the target rectangle for a grid action in ``display``.
    public static func frame(for action: WindowAction, in display: CGRect, gap: CGFloat = 8) -> CGRect? {
        guard isUsable(display) else { return nil }
        let safeGap = normalizedGap(gap, for: display)
        let grid = Grid(display: display, gap: safeGap)

        switch action {
        case .leftHalf: return grid.cell(column: 0, row: 0, columns: 2, rows: 1)
        case .rightHalf: return grid.cell(column: 1, row: 0, columns: 2, rows: 1)
        case .topHalf: return grid.cell(column: 0, row: 0, columns: 1, rows: 2)
        case .bottomHalf: return grid.cell(column: 0, row: 1, columns: 1, rows: 2)
        case .topLeftQuarter: return grid.cell(column: 0, row: 0, columns: 2, rows: 2)
        case .topRightQuarter: return grid.cell(column: 1, row: 0, columns: 2, rows: 2)
        case .bottomLeftQuarter: return grid.cell(column: 0, row: 1, columns: 2, rows: 2)
        case .bottomRightQuarter: return grid.cell(column: 1, row: 1, columns: 2, rows: 2)
        case .leftThird: return grid.cell(column: 0, row: 0, columns: 3, rows: 1)
        case .centerThird: return grid.cell(column: 1, row: 0, columns: 3, rows: 1)
        case .rightThird: return grid.cell(column: 2, row: 0, columns: 3, rows: 1)
        case .leftTwoThirds: return grid.span(column: 0, width: 2, columns: 3)
        case .rightTwoThirds: return grid.span(column: 1, width: 2, columns: 3)
        case .topLeftSixth: return grid.cell(column: 0, row: 0, columns: 3, rows: 2)
        case .topCenterSixth: return grid.cell(column: 1, row: 0, columns: 3, rows: 2)
        case .topRightSixth: return grid.cell(column: 2, row: 0, columns: 3, rows: 2)
        case .bottomLeftSixth: return grid.cell(column: 0, row: 1, columns: 3, rows: 2)
        case .bottomCenterSixth: return grid.cell(column: 1, row: 1, columns: 3, rows: 2)
        case .bottomRightSixth: return grid.cell(column: 2, row: 1, columns: 3, rows: 2)
        case .maximize: return inset(display, by: safeGap)
        case .center, .larger, .smaller, .restore, .nextDisplay,
             .previousDisplay, .fullscreen, .tileAll, .cascadeAll:
            return nil
        }
    }

    /// Divides a display into a small, deterministic grid for bulk actions.
    /// The returned rectangles are in row-major order in Accessibility
    /// coordinates. A count of zero or an invalid display returns an empty
    /// array.
    public static func gridFrames(count: Int, in display: CGRect, gap: CGFloat = 8) -> [CGRect] {
        guard count > 0, isUsable(display) else { return [] }
        let columns = max(1, Int(ceil(sqrt(Double(count)))))
        let rows = max(1, Int(ceil(Double(count) / Double(columns))))
        let safeGap = normalizedGap(gap, for: display)
        let grid = Grid(display: display, gap: safeGap)
        return (0..<count).map { index in
            grid.cell(column: index % columns, row: index / columns, columns: columns, rows: rows)
        }
    }

    /// Computes a centered target while preserving the current window size.
    public static func centeredFrame(current: CGRect, in display: CGRect, gap: CGFloat = 8) -> CGRect? {
        guard isUsable(current), isUsable(display) else { return nil }
        let safeGap = normalizedGap(gap, for: display)
        let usable = inset(display, by: safeGap)
        let size = clampedSize(current.size, to: usable.size)
        let origin = CGPoint(x: usable.midX - size.width / 2, y: usable.midY - size.height / 2)
        return clamped(CGRect(origin: origin, size: size), to: usable)
    }

    /// Scales a window around its center by ``factor`` and keeps it on screen.
    public static func resizedFrame(current: CGRect, in display: CGRect, factor: CGFloat, gap: CGFloat = 8) -> CGRect? {
        guard isUsable(current), isUsable(display), factor.isFinite, factor > 0 else { return nil }
        let safeGap = normalizedGap(gap, for: display)
        let usable = inset(display, by: safeGap)
        let size = clampedSize(
            CGSize(width: current.width * factor, height: current.height * factor),
            to: usable.size
        )
        let origin = CGPoint(x: current.midX - size.width / 2, y: current.midY - size.height / 2)
        return clamped(CGRect(origin: origin, size: size), to: usable)
    }

    /// Returns the nearest display index in a deterministic left-to-right order.
    public static func adjacentDisplayIndex(for frame: CGRect, displays: [CGRect], offset: Int) -> Int? {
        guard !displays.isEmpty, offset != 0 else { return nil }
        let ordered = displays.enumerated().sorted {
            if $0.element.minX == $1.element.minX { return $0.element.minY < $1.element.minY }
            return $0.element.minX < $1.element.minX
        }
        let current = ordered.indices.max { lhs, rhs in
            let left = ordered[lhs].element
            let right = ordered[rhs].element
            let lhsArea = overlapArea(frame, left)
            let rhsArea = overlapArea(frame, right)
            if lhsArea != rhsArea { return lhsArea < rhsArea }
            let lhsDistance = hypot(frame.midX - left.midX, frame.midY - left.midY)
            let rhsDistance = hypot(frame.midX - right.midX, frame.midY - right.midY)
            if lhsDistance != rhsDistance { return lhsDistance > rhsDistance }
            return lhs > rhs
        }
        guard let current else { return nil }
        let destination = (current + (offset % ordered.count) + ordered.count) % ordered.count
        // Return the caller's original array index. NSScreen order is not a
        // stable API and can be unsorted with negative monitor origins.
        return ordered[destination].offset
    }

    private struct Grid {
        let display: CGRect
        let gap: CGFloat

        func cell(column: Int, row: Int, columns: Int, rows: Int) -> CGRect {
            span(column: column, width: 1, columns: columns, row: row, rows: rows)
        }

        func span(column: Int, width: Int, columns: Int) -> CGRect {
            span(column: column, width: width, columns: columns, row: 0, rows: 1)
        }

        func span(column: Int, width: Int, columns: Int, row: Int, rows: Int) -> CGRect {
            let columnWidth = display.width / CGFloat(columns)
            let rowHeight = display.height / CGFloat(rows)
            let raw = CGRect(
                x: display.minX + CGFloat(column) * columnWidth,
                y: display.minY + CGFloat(row) * rowHeight,
                width: columnWidth * CGFloat(width),
                height: rowHeight
            )
            let leftGap = column == 0 ? gap : gap / 2
            let rightGap = column + width == columns ? gap : gap / 2
            let topGap = row == 0 ? gap : gap / 2
            let bottomGap = row + 1 == rows ? gap : gap / 2
            return boundedInset(raw, left: leftGap, top: topGap, right: rightGap, bottom: bottomGap)
        }
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }

    private static func normalizedGap(_ gap: CGFloat, for display: CGRect) -> CGFloat {
        guard gap.isFinite, gap > 0 else { return 0 }
        // Keep at least a one-point rectangle even on small synthetic displays.
        return min(gap, max(0, min((display.width - 1) / 2, (display.height - 1) / 2)))
    }

    private static func inset(_ rect: CGRect, by amount: CGFloat) -> CGRect {
        boundedInset(rect, left: amount, top: amount, right: amount, bottom: amount)
    }

    private static func boundedInset(_ rect: CGRect, left: CGFloat, top: CGFloat, right: CGFloat, bottom: CGFloat) -> CGRect {
        let horizontalScale = min(1, max(0, rect.width - 1) / max(0.0001, left + right))
        let verticalScale = min(1, max(0, rect.height - 1) / max(0.0001, top + bottom))
        let boundedLeft = left * horizontalScale
        let boundedRight = right * horizontalScale
        let boundedTop = top * verticalScale
        let boundedBottom = bottom * verticalScale
        return CGRect(
            x: rect.minX + boundedLeft,
            y: rect.minY + boundedTop,
            width: max(1, rect.width - boundedLeft - boundedRight),
            height: max(1, rect.height - boundedTop - boundedBottom)
        )
    }

    private static func clampedSize(_ size: CGSize, to bounds: CGSize) -> CGSize {
        CGSize(width: min(max(1, size.width), bounds.width), height: min(max(1, size.height), bounds.height))
    }

    private static func clamped(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        let width = min(rect.width, bounds.width)
        let height = min(rect.height, bounds.height)
        let x = min(max(rect.minX, bounds.minX), bounds.maxX - width)
        let y = min(max(rect.minY, bounds.minY), bounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func distance(from lhs: CGRect, to rhs: CGRect) -> CGFloat {
        let dx = max(rhs.minX - lhs.maxX, lhs.minX - rhs.maxX, 0)
        let dy = max(rhs.minY - lhs.maxY, lhs.minY - rhs.maxY, 0)
        return hypot(dx, dy)
    }

    private static func overlapArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let width = max(0, min(lhs.maxX, rhs.maxX) - max(lhs.minX, rhs.minX))
        let height = max(0, min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY))
        return width * height
    }
}
