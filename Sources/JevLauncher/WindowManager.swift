import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import LauncherCore

public enum WindowManagerError: Error, LocalizedError, Sendable {
    case accessibilityPermissionRequired
    case noTargetWindow
    case nothingToRestore
    case noAdjacentDisplay
    case noDisplay
    case unsupportedAction(WindowAction)
    case frameUnavailable
    case fullscreenUnsupported
    case resizeFailed(action: WindowAction, expected: CGRect, actual: CGRect?)
    case accessibilityFailure(action: WindowAction, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .accessibilityPermissionRequired:
            return "Accessibility access is required to control windows."
        case .noTargetWindow:
            return "No eligible visible window is selected."
        case .nothingToRestore:
            return "Nothing to restore for this window."
        case .noAdjacentDisplay:
            return "There is no adjacent display in that direction."
        case .noDisplay:
            return "No display is available for this window action."
        case .unsupportedAction(let action):
            return "Window action \(action.title) is not supported here."
        case .frameUnavailable:
            return "The selected window does not expose a usable frame."
        case .fullscreenUnsupported:
            return "The selected application does not support native fullscreen."
        case .resizeFailed(let action, let expected, let actual):
            let received = actual.map { " received \(Self.describe($0))" } ?? ""
            return "Could not apply \(action.title) (wanted \(Self.describe(expected))\(received))."
        case .accessibilityFailure(let action, let code):
            return "Accessibility could not apply \(action.title) (error \(code))."
        }
    }

    private static func describe(_ rect: CGRect) -> String {
        "(\(Int(rect.minX)), \(Int(rect.minY)), \(Int(rect.width)) × \(Int(rect.height)))"
    }
}

/// Owns the small amount of Accessibility state needed for window actions.
/// All mutation is main-actor isolated because AXUIElement and AppKit display
/// state are process-bound objects.
@MainActor
public final class WindowManager {
    public var gap: Double = 8

    public static var hasPermission: Bool {
        AXIsProcessTrusted()
    }

    private struct CapturedTarget {
        let pid: pid_t
        let application: AXUIElement
        let window: AXUIElement
    }

    private struct WindowKey: Hashable {
        let pid: pid_t
        let number: Int
        let fallback: Int
    }

    private struct Display {
        let screen: NSScreen
        let appKitFrame: CGRect
        let appKitVisibleFrame: CGRect
        let axFrame: CGRect
        let axVisibleFrame: CGRect
    }

    private struct WindowRecord {
        let pid: pid_t
        let application: AXUIElement
        let element: AXUIElement
        let frame: CGRect
        let key: WindowKey
    }

    private enum AXAttribute {
        static let focusedApplication = "AXFocusedApplication"
        static let focusedWindow = "AXFocusedWindow"
        static let windows = "AXWindows"
        static let role = "AXRole"
        static let subrole = "AXSubrole"
        static let standardWindow = "AXStandardWindow"
        static let windowRole = "AXWindow"
        static let hidden = "AXHidden"
        static let minimized = "AXMinimized"
        static let position = "AXPosition"
        static let size = "AXSize"
        static let title = "AXTitle"
        static let windowNumber = "AXWindowNumber"
        static let fullScreen = "AXFullScreen"
        static let children = "AXChildren"
        static let parent = "AXParent"
    }

    /// Upper bound for one Accessibility message. The system default is
    /// about six seconds, which freezes the main thread on a hung app.
    private nonisolated static let messagingTimeout: Float = 0.35
    /// Pointer travel after mouse-down that counts as the start of a drag.
    private nonisolated static let dragStartDistance: CGFloat = 4

    private var capturedTarget: CapturedTarget?
    private var history = WindowUndoHistory<WindowKey, AXUIElement>()
    private var edgeMonitor: Any?
    private var edgeDragMonitor: Any?
    private var edgePress: NSPoint?
    private var edgeDrag: (pid: pid_t, window: AXUIElement, original: CGRect, startedAt: NSPoint)?
    private var visibleSnapshot: [[String: Any]]?
    private var shortcutCycle: (key: WindowKey, action: WindowAction, index: Int, time: TimeInterval)?

    public init() {
        // The system-wide element sets the process-wide default timeout.
        _ = systemWideElement()
    }

    /// Opens the system Accessibility preference prompt. It does not grant
    /// access by itself, so callers should query ``hasPermission`` again.
    public func requestPermission() {
        _ = AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary)
    }

    /// Captures the currently focused application window before the launcher
    /// panel takes focus. The captured target is intentionally a single window,
    /// so later actions cannot accidentally operate on every Space.
    public func clearTarget() { capturedTarget = nil }

    public func captureTarget(appPID: pid_t? = nil) {
        capturedTarget = nil
        guard Self.hasPermission,
              let pid = appPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier else { return }
        let application = applicationElement(pid, timeout: 0.15)
        guard let window = axElement(attribute(application, AXAttribute.focusedWindow)) else { return }
        // Eligibility is checked again on execution. Avoid repeated AX/CG reads on open.
        capturedTarget = CapturedTarget(pid: pid, application: application, window: window)
    }

    public func execute(_ action: WindowAction, appPID: pid_t? = nil, cycle: Bool = false) throws {
        guard Self.hasPermission else { throw WindowManagerError.accessibilityPermissionRequired }

        visibleSnapshot = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        defer { visibleSnapshot = nil }
        let target = try target(for: appPID)
        // Only an uninterrupted run of the same cycling shortcut keeps its step.
        let previousCycle = shortcutCycle
        shortcutCycle = nil
        switch action {
        case .tileAll:
            try arrangeAll(target: target, cascade: false, action: action)
        case .cascadeAll:
            try arrangeAll(target: target, cascade: true, action: action)
        case .fullscreen:
            try toggleFullscreen(target.element, action: action)
        case .restore:
            try restore(target)
        case .nextDisplay:
            try move(target, direction: 1, action: action)
        case .previousDisplay:
            try move(target, direction: -1, action: action)
        default:
            if cycle {
                try arrangeCycling(target, action: action, previous: previousCycle)
            } else {
                try arrange(target, action: action)
            }
        }
    }

    /// Snaps only on release after a hit-tested title/toolbar drag moved
    /// the actual window without changing its size.
    ///
    /// Mouse-down only records the pointer. The Accessibility hit-test runs
    /// once, on the first drag event past a small distance, and drag events
    /// are observed only between mouse-down and that point.
    public func startEdgeSnapping() {
        guard edgeMonitor == nil else { return }
        edgeMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp]
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleEdgeEvent(event)
            }
        }
    }

    public func stopEdgeSnapping() {
        if let edgeMonitor {
            NSEvent.removeMonitor(edgeMonitor)
        }
        edgeMonitor = nil
        stopDragMonitoring()
        edgePress = nil
        edgeDrag = nil
    }

    deinit {
        if let edgeMonitor {
            NSEvent.removeMonitor(edgeMonitor)
        }
        if let edgeDragMonitor {
            NSEvent.removeMonitor(edgeDragMonitor)
        }
    }

    private func arrangeCycling(
        _ target: WindowRecord,
        action: WindowAction,
        previous: (key: WindowKey, action: WindowAction, index: Int, time: TimeInterval)?
    ) throws {
        guard let display = display(containing: target.frame) else {
            throw WindowManagerError.noDisplay
        }
        let frames = WindowLayout.cycleFrames(for: action, in: display.axVisibleFrame, gap: CGFloat(gap))
        guard !frames.isEmpty else {
            try arrange(target, action: action)
            return
        }
        let now = Date.timeIntervalSinceReferenceDate
        let remembered = previous.flatMap { previous in
            previous.key == target.key && previous.action == action && now - previous.time < 1.5 ? previous.index : nil
        }
        let index = WindowLayout.nextCycleIndex(current: target.frame, frames: frames, previousIndex: remembered)
        shortcutCycle = (target.key, action, index, now)
        try saveAndSet(frames[index], target: target, action: action, bounds: display.axVisibleFrame)
    }

    private func arrange(_ target: WindowRecord, action: WindowAction) throws {
        let current = target.frame
        guard let display = display(containing: current) else {
            throw WindowManagerError.noDisplay
        }

        let targetFrame: CGRect?
        switch action {
        case .center:
            targetFrame = WindowLayout.centeredFrame(current: current, in: display.axVisibleFrame, gap: CGFloat(gap))
        case .larger:
            targetFrame = WindowLayout.resizedFrame(current: current, in: display.axVisibleFrame, factor: 1.15, gap: CGFloat(gap))
        case .smaller:
            targetFrame = WindowLayout.resizedFrame(current: current, in: display.axVisibleFrame, factor: 0.85, gap: CGFloat(gap))
        default:
            targetFrame = WindowLayout.frame(for: action, in: display.axVisibleFrame, gap: CGFloat(gap))
        }

        guard let targetFrame else {
            throw WindowManagerError.unsupportedAction(action)
        }
        try saveAndSet(targetFrame, target: target, action: action, bounds: display.axVisibleFrame)
    }

    private func restore(_ target: WindowRecord) throws {
        if let moves = history.bulkMoves(including: target.key) {
            // Reverse only the windows the arrangement moved. Each of them has
            // exactly one undo entry for it; windows that fail keep theirs.
            var restored: [WindowKey] = []
            var firstError: Error?
            for move in moves {
                do {
                    try setFrame(move.original, on: move.element, action: .restore)
                    restored.append(move.key)
                } catch {
                    firstError = firstError ?? error
                }
            }
            history.completeBulkRestore(restored: restored)
            if let firstError { throw firstError }
            return
        }
        guard let previous = history.popLast(for: target.key) else {
            throw WindowManagerError.nothingToRestore
        }
        do {
            try setFrame(previous, on: target.element, action: .restore)
        } catch {
            history.reinstate(previous, for: target.key)
            throw error
        }
    }

    private func move(_ target: WindowRecord, direction: Int, action: WindowAction) throws {
        let current = target.frame
        let displays = screenDisplays()
        let frames = displays.map(\.axFrame)
        guard let sourceIndex = WindowLayout.displayIndex(for: current, displays: frames) else {
            throw WindowManagerError.noDisplay
        }
        guard displays.count > 1,
              let destinationIndex = WindowLayout.adjacentDisplayIndex(for: current, displays: frames, offset: direction),
              destinationIndex != sourceIndex else {
            throw WindowManagerError.noAdjacentDisplay
        }
        let destination = displays[destinationIndex]
        guard let destinationFrame = WindowLayout.frame(
            current,
            movedFrom: displays[sourceIndex].axVisibleFrame,
            to: destination.axVisibleFrame
        ) else {
            throw WindowManagerError.frameUnavailable
        }
        try saveAndSet(destinationFrame, target: target, action: action, bounds: destination.axVisibleFrame)
    }

    private func toggleFullscreen(_ window: AXUIElement, action: WindowAction) throws {
        guard canSetAttribute(window, AXAttribute.fullScreen) else {
            throw WindowManagerError.fullscreenUnsupported
        }
        let current = (attribute(window, AXAttribute.fullScreen) as? NSNumber)?.boolValue ?? false
        let error = AXUIElementSetAttributeValue(window, AXAttribute.fullScreen as CFString, (!current) as CFBoolean)
        guard error == .success else {
            throw WindowManagerError.accessibilityFailure(action: action, code: error.rawValue)
        }
    }

    private func saveAndSet(_ targetFrame: CGRect, target: WindowRecord, action: WindowAction, bounds: CGRect) throws {
        guard !approximatelyEqual(target.frame, targetFrame) else { return }
        history.recordSingle(target.frame, for: target.key)
        do {
            try setFrame(targetFrame, on: target.element, action: action, bounds: bounds)
        } catch {
            // A size write can succeed before a position write fails. Keep
            // the original frame available whenever the window changed.
            if let actual = frame(of: target.element), approximatelyEqual(actual, target.frame) {
                _ = history.popLast(for: target.key)
            }
            throw error
        }
    }

    private func arrangeAll(target: WindowRecord, cascade: Bool, action: WindowAction) throws {
        let displays = screenDisplays()
        guard let destination = display(containing: target.frame, in: displays) else { throw WindowManagerError.noDisplay }
        let ownPID = getpid()
        // Only regular, visible apps own arrangeable windows. Skipping agents
        // and background processes avoids an AX round trip to each of them.
        let applications = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isHidden && $0.processIdentifier != ownPID
        }
        let records = applications.flatMap { app in
            visibleWindows(in: applicationElement(app.processIdentifier), pid: app.processIdentifier)
        }.filter { record in
            display(containing: record.frame, in: displays)?.screen == destination.screen
                && canSetAttribute(record.element, AXAttribute.size)
                && canSetAttribute(record.element, AXAttribute.position)
                && !((attribute(record.element, AXAttribute.fullScreen) as? NSNumber)?.boolValue ?? false)
        }
        guard !records.isEmpty else { throw WindowManagerError.noTargetWindow }
        let frames = cascade ? cascadeFrames(count: records.count, in: destination.axVisibleFrame)
            : WindowLayout.gridFrames(count: records.count, in: destination.axVisibleFrame, gap: CGFloat(gap))
        var moved: [WindowUndoHistory<WindowKey, AXUIElement>.Move] = []
        do {
            for (record, targetFrame) in zip(records, frames) {
                // Windows already in place are not written and get no undo entry.
                guard !approximatelyEqual(record.frame, targetFrame) else { continue }
                // Record before writing: a failed write can still move the window.
                moved.append(.init(key: record.key, original: record.frame, element: record.element))
                try setFrame(targetFrame, on: record.element, action: action, bounds: destination.axVisibleFrame)
            }
            history.recordBulk(members: Set(records.map(\.key)), moved: moved)
        } catch {
            // Roll back every window this transaction wrote. History is only
            // recorded after all writes succeed, so it needs no rollback.
            for move in moved {
                _ = try? setFrame(move.original, on: move.element, action: action)
            }
            throw error
        }
    }

    private func cascadeFrames(count: Int, in display: CGRect) -> [CGRect] {
        guard count > 0 else { return [] }
        let safeGap = max(0, CGFloat(gap))
        let work = CGRect(
            x: display.minX + safeGap,
            y: display.minY + safeGap,
            width: max(1, display.width - safeGap * 2),
            height: max(1, display.height - safeGap * 2)
        )
        let width = max(1, min(work.width, work.width * 0.62))
        let height = max(1, min(work.height, work.height * 0.72))
        let step = min(32, max(1, min(work.width - width, work.height - height) / CGFloat(max(1, count - 1))))
        return (0..<count).map { index in
            let offset = CGFloat(index) * step
            return CGRect(
                x: min(work.maxX - width, work.minX + offset),
                y: min(work.maxY - height, work.minY + offset),
                width: width,
                height: height
            )
        }
    }

    private func target(for pid: pid_t?) throws -> WindowRecord {
        if let pid {
            let application = applicationElement(pid)
            let candidates = visibleWindows(in: application, pid: pid)
            if let focused = axElement(attribute(application, AXAttribute.focusedWindow)),
               let record = candidates.first(where: { $0.element == focused }) {
                return record
            }
            if let first = candidates.first { return first }
            throw WindowManagerError.noTargetWindow
        }

        if let capturedTarget,
           isEligible(capturedTarget.window, pid: capturedTarget.pid),
           let frame = frame(of: capturedTarget.window) {
            return WindowRecord(
                pid: capturedTarget.pid,
                application: capturedTarget.application,
                element: capturedTarget.window,
                frame: frame,
                key: key(for: capturedTarget.window, pid: capturedTarget.pid, frame: frame)
            )
        }

        throw WindowManagerError.noTargetWindow
    }

    private func visibleWindows(in application: AXUIElement, pid: pid_t) -> [WindowRecord] {
        guard let raw = attribute(application, AXAttribute.windows) as? [AXUIElement] else { return [] }
        return raw.compactMap { window in
            guard isEligible(window, pid: pid), let current = frame(of: window) else { return nil }
            return WindowRecord(pid: pid, application: application, element: window, frame: current,
                                key: key(for: window, pid: pid, frame: current))
        }
    }

    private func isEligible(_ window: AXUIElement, pid: pid_t) -> Bool {
        guard (attribute(window, AXAttribute.role) as? String) == AXAttribute.windowRole,
              (attribute(window, AXAttribute.subrole) as? String) == AXAttribute.standardWindow,
              !((attribute(window, AXAttribute.hidden) as? NSNumber)?.boolValue ?? false),
              !((attribute(window, AXAttribute.minimized) as? NSNumber)?.boolValue ?? false),
              let windowFrame = frame(of: window) else { return false }

        let visible = onScreenWindows(for: pid)
        if let number = windowNumber(of: window) { return visible.contains { $0.number == number } }
        // AXWindowNumber is not exposed by every app. Match visible geometry;
        // never infer visibility merely because the CG list is unavailable.
        return visible.contains { approximatelyEqual($0.frame, windowFrame, tolerance: 4) }
    }

    private func onScreenWindows(for pid: pid_t) -> [(number: Int, frame: CGRect)] {
        let values = visibleSnapshot ?? (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]) ?? []
        return values.compactMap { value in
            guard (value[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (value[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (value[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
                  let number = (value[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  let bounds = value[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return (number, rect)
        }
    }

    private func key(for window: AXUIElement, pid: pid_t, frame: CGRect) -> WindowKey {
        let number = windowNumber(of: window) ?? 0
        let fallback = number == 0 ? Int(truncatingIfNeeded: CFHash(window)) : 0
        return WindowKey(pid: pid, number: number, fallback: fallback)
    }

    private func windowNumber(of window: AXUIElement) -> Int? {
        (attribute(window, AXAttribute.windowNumber) as? NSNumber)?.intValue
    }

    private func frame(of window: AXUIElement) -> CGRect? {
        guard let position = axPoint(attribute(window, AXAttribute.position)),
              let size = axSize(attribute(window, AXAttribute.size)),
              position.x.isFinite, position.y.isFinite,
              size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// Writes size, then position, then size again. The first size write
    /// can be limited by the display the window starts on; the second one
    /// applies the size once the window is on the destination display.
    ///
    /// When ``bounds`` is given and the app keeps its own size (a fixed or
    /// minimum size), the window is re-aligned to the target's anchored edge
    /// inside ``bounds``. Reaching that aligned frame counts as success.
    private func setFrame(_ expectedFrame: CGRect, on window: AXUIElement, action: WindowAction, bounds: CGRect? = nil) throws {
        try write(size: expectedFrame.size, to: window, action: action)
        try write(position: expectedFrame.origin, to: window, action: action)
        try write(size: expectedFrame.size, to: window, action: action)

        // Read back with a small tolerance for display scaling and AX rounding.
        guard let actual = self.frame(of: window) else {
            throw WindowManagerError.resizeFailed(action: action, expected: expectedFrame, actual: nil)
        }
        if approximatelyEqual(actual, expectedFrame, tolerance: 3) { return }
        guard let bounds,
              let aligned = WindowLayout.anchoredFrame(size: actual.size, target: expectedFrame, in: bounds) else {
            throw WindowManagerError.resizeFailed(action: action, expected: expectedFrame, actual: actual)
        }
        if !approximatelyEqual(actual, aligned, tolerance: 3) {
            try write(position: aligned.origin, to: window, action: action)
        }
        guard let settled = self.frame(of: window), approximatelyEqual(settled, aligned, tolerance: 3) else {
            throw WindowManagerError.resizeFailed(action: action, expected: expectedFrame, actual: self.frame(of: window))
        }
    }

    private func write(size: CGSize, to window: AXUIElement, action: WindowAction) throws {
        var value = size
        guard let axValue = AXValueCreate(.cgSize, &value) else { throw WindowManagerError.frameUnavailable }
        let error = AXUIElementSetAttributeValue(window, AXAttribute.size as CFString, axValue)
        guard error == .success else {
            throw WindowManagerError.accessibilityFailure(action: action, code: error.rawValue)
        }
    }

    private func write(position: CGPoint, to window: AXUIElement, action: WindowAction) throws {
        var value = position
        guard let axValue = AXValueCreate(.cgPoint, &value) else { throw WindowManagerError.frameUnavailable }
        let error = AXUIElementSetAttributeValue(window, AXAttribute.position as CFString, axValue)
        guard error == .success else {
            throw WindowManagerError.accessibilityFailure(action: action, code: error.rawValue)
        }
    }

    private func applicationElement(_ pid: pid_t, timeout: Float = WindowManager.messagingTimeout) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }

    private func systemWideElement() -> AXUIElement {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        return element
    }

    private func canSetAttribute(_ element: AXUIElement, _ name: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success
            && settable.boolValue
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> Any? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard error == .success else { return nil }
        return value
    }

    private func axPoint(_ value: Any?) -> CGPoint? {
        guard let rawValue = value, CFGetTypeID(rawValue as CFTypeRef) == AXValueGetTypeID() else { return nil }
        let axValue = rawValue as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func axSize(_ value: Any?) -> CGSize? {
        guard let rawValue = value, CFGetTypeID(rawValue as CFTypeRef) == AXValueGetTypeID() else { return nil }
        let axValue = rawValue as! AXValue
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    private func screenDisplays() -> [Display] {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return [] }
        // NSScreen.screens is ordered with the menu-bar (primary) display
        // first. NSScreen.main can change when focus changes and is not a
        // stable AppKit-to-Accessibility coordinate origin.
        let referenceTop = screens.first?.frame.maxY ?? 0
        return screens.map { screen in
            let frame = CGRect(x: screen.frame.minX, y: screen.frame.minY,
                               width: screen.frame.width, height: screen.frame.height)
            let visible = CGRect(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY,
                                 width: screen.visibleFrame.width, height: screen.visibleFrame.height)
            return Display(
                screen: screen,
                appKitFrame: frame,
                appKitVisibleFrame: visible,
                axFrame: axRect(frame, referenceTop: referenceTop),
                axVisibleFrame: axRect(visible, referenceTop: referenceTop)
            )
        }.sorted {
            if $0.appKitFrame.minX == $1.appKitFrame.minX { return $0.appKitFrame.minY < $1.appKitFrame.minY }
            return $0.appKitFrame.minX < $1.appKitFrame.minX
        }
    }

    private func axRect(_ rect: CGRect, referenceTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: referenceTop - rect.maxY, width: rect.width, height: rect.height)
    }

    private func display(containing frame: CGRect, in displays: [Display]? = nil) -> Display? {
        let values = displays ?? screenDisplays()
        guard !values.isEmpty else { return nil }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if let containing = values.first(where: { $0.axFrame.contains(center) }) { return containing }
        return values.min { distance(from: center, to: CGPoint(x: $0.axFrame.midX, y: $0.axFrame.midY))
            < distance(from: center, to: CGPoint(x: $1.axFrame.midX, y: $1.axFrame.midY)) }
    }

    private func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance && abs(lhs.height - rhs.height) <= tolerance
    }

    private func distance(from lhs: CGPoint, to rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    private func handleEdgeEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            // No Accessibility work here: most clicks never become drags.
            edgeDrag = nil
            edgePress = NSEvent.mouseLocation
            startDragMonitoring()
        case .leftMouseDragged:
            guard let press = edgePress else { stopDragMonitoring(); return }
            let point = NSEvent.mouseLocation
            guard hypot(point.x - press.x, point.y - press.y) >= Self.dragStartDistance else { return }
            edgePress = nil
            stopDragMonitoring()
            // The window follows the pointer, so the pointer is still over
            // the grabbed title bar or toolbar.
            guard Self.hasPermission, let hit = titleBarWindow(at: point), let original = frame(of: hit.window) else { return }
            edgeDrag = (hit.pid, hit.window, original, press)
        case .leftMouseUp:
            edgePress = nil
            stopDragMonitoring()
            guard let drag = edgeDrag else { return }
            edgeDrag = nil
            let point = NSEvent.mouseLocation
            guard hypot(point.x - drag.startedAt.x, point.y - drag.startedAt.y) >= 12,
                  let current = frame(of: drag.window),
                  hypot(current.minX - drag.original.minX, current.minY - drag.original.minY) >= 8,
                  abs(current.width - drag.original.width) < 4, abs(current.height - drag.original.height) < 4,
                  let action = edgeAction(at: point), isEligible(drag.window, pid: drag.pid) else { return }
            let record = WindowRecord(pid: drag.pid, application: applicationElement(drag.pid), element: drag.window, frame: current, key: key(for: drag.window, pid: drag.pid, frame: current))
            do { try arrange(record, action: action) } catch { NSSound.beep() }
        default: break
        }
    }

    private func startDragMonitoring() {
        guard edgeDragMonitor == nil else { return }
        edgeDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleEdgeEvent(event)
            }
        }
    }

    private func stopDragMonitoring() {
        if let edgeDragMonitor {
            NSEvent.removeMonitor(edgeDragMonitor)
        }
        edgeDragMonitor = nil
    }

    private func titleBarWindow(at appKitPoint: NSPoint) -> (pid: pid_t, window: AXUIElement)? {
        let system = systemWideElement()
        let point = axPoint(fromAppKit: appKitPoint)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success else { return nil }
        var cursor = hit
        for _ in 0..<12 {
            guard let element = cursor else { return nil }
            if (attribute(element, AXAttribute.role) as? String) == AXAttribute.windowRole {
                guard let pid = processID(of: element), pid != getpid(), isEligible(element, pid: pid),
                      let rect = frame(of: element), point.y >= rect.minY, point.y <= rect.minY + 90 else { return nil }
                // A later frame-motion check distinguishes toolbar/title-bar
                // dragging from selection, tabs, buttons, and content drags.
                return (pid, element)
            }
            cursor = axElement(attribute(element, AXAttribute.parent))
        }
        return nil
    }

    private func axPoint(fromAppKit point: NSPoint) -> CGPoint {
        let referenceTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: point.x, y: referenceTop - point.y)
    }

    private func axElement(_ value: Any?) -> AXUIElement? {
        guard let value, CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func processID(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return pid
    }

    /// Edges shared with another display are not snap edges.
    private func edgeAction(at point: NSPoint) -> WindowAction? {
        WindowLayout.edgeSnapAction(at: axPoint(fromAppKit: point), displays: screenDisplays().map(\.axFrame))
    }
}
