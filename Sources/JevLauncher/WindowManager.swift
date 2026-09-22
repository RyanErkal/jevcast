import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import LauncherCore

public enum WindowManagerError: Error, LocalizedError, Sendable {
    case accessibilityPermissionRequired
    case noTargetWindow
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

    private var capturedTarget: CapturedTarget?
    private var undoFrames: [WindowKey: [CGRect]] = [:]
    private var edgeMonitor: Any?
    private var edgeDrag: (pid: pid_t, window: AXUIElement, original: CGRect, startedAt: NSPoint)?
    private var visibleSnapshot: [[String: Any]]?
    private var lastBulk: [WindowRecord]?
    private var shortcutCycle: (key: WindowKey, action: WindowAction, index: Int, time: TimeInterval)?


    public init() {}

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
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.15)
        guard let window = axElement(attribute(application, AXAttribute.focusedWindow)) else { return }
        // Eligibility is checked again on execution. Avoid repeated AX/CG reads on open.
        capturedTarget = CapturedTarget(pid: pid, application: application, window: window)
    }

    public func execute(_ requestedAction: WindowAction, appPID: pid_t? = nil, cycle: Bool = false) throws {
        guard Self.hasPermission else { throw WindowManagerError.accessibilityPermissionRequired }

        visibleSnapshot = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        defer { visibleSnapshot = nil }
        let target = try target(for: appPID)
        var action = requestedAction
        if cycle && [.leftHalf, .rightHalf].contains(requestedAction) {
            let now = Date.timeIntervalSinceReferenceDate
            let previous = shortcutCycle
            let same = previous?.key == target.key && previous?.action == requestedAction && now - (previous?.time ?? 0) < 1.5
            let index = same ? ((previous?.index ?? 0) + 1) % 3 : 0
            let steps: [WindowAction] = requestedAction == .leftHalf ? [.leftHalf, .leftTwoThirds, .leftThird] : [.rightHalf, .rightTwoThirds, .rightThird]
            action = steps[index]
            shortcutCycle = (target.key, requestedAction, index, now)
        } else { shortcutCycle = nil }
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
            try arrange(target, action: action)
        }
    }

    /// Snaps only on release after a hit-tested title/toolbar drag moved
    /// the actual window without changing its size.
    public func startEdgeSnapping() {
        guard edgeMonitor == nil else { return }
        edgeMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
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
        edgeDrag = nil
    }

    deinit {
        if let edgeMonitor {
            NSEvent.removeMonitor(edgeMonitor)
        }
    }

    private func arrange(_ target: WindowRecord, action: WindowAction) throws {
        guard let current = frame(of: target.element) else {
            throw WindowManagerError.frameUnavailable
        }
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
        try saveAndSet(targetFrame, target: target, action: action)
    }

    private func restore(_ target: WindowRecord) throws {
        if let records = lastBulk, records.contains(where: { $0.key == target.key }) {
            for record in records {
                try setFrame(record.frame, on: record.element, action: .restore)
                _ = undoFrames[record.key]?.popLast()
            }
            lastBulk = nil
            return
        }
        guard var stack = undoFrames[target.key], let previous = stack.popLast() else {
            throw WindowManagerError.noTargetWindow
        }
        undoFrames[target.key] = stack.isEmpty ? nil : stack
        do {
            try setFrame(previous, on: target.element, action: .restore)
        } catch {
            undoFrames[target.key, default: []].append(previous)
            throw error
        }
    }

    private func move(_ target: WindowRecord, direction: Int, action: WindowAction) throws {
        guard let current = frame(of: target.element) else {
            throw WindowManagerError.frameUnavailable
        }
        let displays = screenDisplays()
        guard !displays.isEmpty, let currentDisplay = display(containing: current, in: displays) else {
            throw WindowManagerError.noDisplay
        }
        guard let currentIndex = displays.firstIndex(where: { $0.screen == currentDisplay.screen }) else {
            throw WindowManagerError.noDisplay
        }
        guard displays.count > 1 else { throw WindowManagerError.noAdjacentDisplay }
        let destinationIndex = (currentIndex + direction + displays.count) % displays.count
        let destination = displays[destinationIndex]
        let sourceArea = currentDisplay.axVisibleFrame
        let destinationArea = destination.axVisibleFrame
        let relative = CGRect(
            x: destinationArea.minX + (current.minX - sourceArea.minX) / sourceArea.width * destinationArea.width,
            y: destinationArea.minY + (current.minY - sourceArea.minY) / sourceArea.height * destinationArea.height,
            width: min(destinationArea.width, current.width / sourceArea.width * destinationArea.width),
            height: min(destinationArea.height, current.height / sourceArea.height * destinationArea.height)
        )
        let destinationFrame = CGRect(
            x: min(max(relative.minX, destinationArea.minX), destinationArea.maxX - relative.width),
            y: min(max(relative.minY, destinationArea.minY), destinationArea.maxY - relative.height),
            width: relative.width, height: relative.height
        )
        try saveAndSet(destinationFrame, target: target, action: action)
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

    private func saveAndSet(_ targetFrame: CGRect, target: WindowRecord, action: WindowAction) throws {
        guard !approximatelyEqual(target.frame, targetFrame) else { return }
        lastBulk = nil
        undoFrames[target.key, default: []].append(target.frame)
        if undoFrames[target.key]!.count > 24 {
            undoFrames[target.key]!.removeFirst()
        }
        do {
            try setFrame(targetFrame, on: target.element, action: action)
        } catch {
            // A size write can succeed before a position write fails. Keep
            // the original frame available whenever the window changed.
            if let actual = frame(of: target.element), approximatelyEqual(actual, target.frame) {
                _ = undoFrames[target.key]?.popLast()
            }
            throw error
        }
    }

    private func arrangeAll(target: WindowRecord, cascade: Bool, action: WindowAction) throws {
        let displays = screenDisplays()
        guard let destination = display(containing: target.frame, in: displays) else { throw WindowManagerError.noDisplay }
        let records = NSWorkspace.shared.runningApplications.filter { $0.processIdentifier != getpid() && !$0.isHidden }.flatMap { app in
            visibleWindows(in: AXUIElementCreateApplication(app.processIdentifier), pid: app.processIdentifier)
        }.filter { record in
            display(containing: record.frame, in: displays)?.screen == destination.screen
                && canSetAttribute(record.element, AXAttribute.size)
                && canSetAttribute(record.element, AXAttribute.position)
                && !((attribute(record.element, AXAttribute.fullScreen) as? NSNumber)?.boolValue ?? false)
        }
        guard !records.isEmpty else { throw WindowManagerError.noTargetWindow }
        let frames = cascade ? cascadeFrames(count: records.count, in: destination.axVisibleFrame)
            : WindowLayout.gridFrames(count: records.count, in: destination.axVisibleFrame, gap: CGFloat(gap))
        let jobs = Array(zip(records, frames))
        let history = undoFrames
        do {
            for (record, targetFrame) in jobs {
                guard !approximatelyEqual(record.frame, targetFrame) else { continue }
                undoFrames[record.key, default: []].append(record.frame)
                try setFrame(targetFrame, on: record.element, action: action)
            }
            lastBulk = records
        } catch {
            undoFrames = history
            // Roll back every write that succeeded in this transaction. The
            // original frame is in the transaction's immutable records list.
            for record in records {
                guard let expected = jobs.first(where: { $0.0.key == record.key })?.0.frame else { continue }
                _ = try? setFrame(expected, on: record.element, action: action)
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
            let application = AXUIElementCreateApplication(pid)
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
              frame(of: window) != nil else { return false }

        guard let windowFrame = frame(of: window) else { return false }
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

    private func setFrame(_ expectedFrame: CGRect, on window: AXUIElement, action: WindowAction) throws {
        var size = expectedFrame.size
        var position = expectedFrame.origin
        guard let sizeValue = AXValueCreate(.cgSize, &size),
              let positionValue = AXValueCreate(.cgPoint, &position) else {
            throw WindowManagerError.frameUnavailable
        }
        let sizeError = AXUIElementSetAttributeValue(window, AXAttribute.size as CFString, sizeValue)
        guard sizeError == .success else {
            throw WindowManagerError.accessibilityFailure(action: action, code: sizeError.rawValue)
        }
        let positionError = AXUIElementSetAttributeValue(window, AXAttribute.position as CFString, positionValue)
        guard positionError == .success else {
            throw WindowManagerError.accessibilityFailure(action: action, code: positionError.rawValue)
        }

        // Apps can enforce a minimum size or adjust the origin while resizing.
        // Read back once and report the actual result with a small pixel
        // tolerance for display scaling and AX rounding.
        guard let actual = self.frame(of: window), approximatelyEqual(actual, expectedFrame, tolerance: 3) else {
            throw WindowManagerError.resizeFailed(action: action, expected: expectedFrame, actual: self.frame(of: window))
        }
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
        guard Self.hasPermission else { return }
        switch event.type {
        case .leftMouseDown:
            guard let hit = titleBarWindow(at: NSEvent.mouseLocation), let original = frame(of: hit.window) else { edgeDrag = nil; return }
            edgeDrag = (hit.pid, hit.window, original, NSEvent.mouseLocation)
        case .leftMouseUp:
            guard let drag = edgeDrag else { return }
            edgeDrag = nil
            let point = NSEvent.mouseLocation
            guard hypot(point.x - drag.startedAt.x, point.y - drag.startedAt.y) >= 12,
                  let current = frame(of: drag.window),
                  hypot(current.minX - drag.original.minX, current.minY - drag.original.minY) >= 8,
                  abs(current.width - drag.original.width) < 4, abs(current.height - drag.original.height) < 4,
                  let action = edgeAction(at: point), isEligible(drag.window, pid: drag.pid) else { return }
            let record = WindowRecord(pid: drag.pid, application: AXUIElementCreateApplication(drag.pid), element: drag.window, frame: current, key: key(for: drag.window, pid: drag.pid, frame: current))
            do { try arrange(record, action: action) } catch { NSSound.beep() }
        default: break
        }
    }

    private func titleBarWindow(at appKitPoint: NSPoint) -> (pid: pid_t, window: AXUIElement)? {
        let system = AXUIElementCreateSystemWide()
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

    private func edgeAction(at point: NSPoint) -> WindowAction? {
        guard let display = screenDisplays().first(where: { $0.appKitFrame.contains(point) }) else { return nil }
        let threshold: CGFloat = 6
        let nearLeft = abs(point.x - display.appKitFrame.minX) <= threshold
        let nearRight = abs(point.x - display.appKitFrame.maxX) <= threshold
        let nearTop = abs(point.y - display.appKitFrame.maxY) <= threshold
        let nearBottom = abs(point.y - display.appKitFrame.minY) <= threshold
        if nearLeft && nearTop { return .topLeftQuarter }
        if nearRight && nearTop { return .topRightQuarter }
        if nearLeft && nearBottom { return .bottomLeftQuarter }
        if nearRight && nearBottom { return .bottomRightQuarter }
        if nearLeft { return .leftHalf }
        if nearRight { return .rightHalf }
        if nearTop { return .topHalf }
        if nearBottom { return .bottomHalf }
        return nil
    }
}
