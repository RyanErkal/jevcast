import AppKit
import GhosttyKit

/// One libghostty surface. It runs your login shell in your home folder and draws with Metal into
/// this view. Keys, mouse, and size go to libghostty; Jevcast never types into it.
/// No input method support yet, so dead keys and composed text (such as Japanese) do not type.
@MainActor
final class TerminalView: NSView {
    private(set) var surface: ghostty_surface_t?
    /// The shell exited or libghostty asked to close. Runs on a later main-queue turn.
    var onClose: (() -> Void)?
    var onTitle: ((String) -> Void)?

    init?(app: ghostty_app_t) {
        super.init(frame: NSRect(x: 0, y: 0, width: 820, height: 520))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: pointer))
        config.userdata = pointer
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        // libghostty copies the folder during the call.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        surface = home.withCString { folder in
            config.working_directory = folder
            return ghostty_surface_new(app, &config)
        }
        if surface == nil { return nil }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func from(_ userdata: UnsafeMutableRawPointer?) -> TerminalView? {
        userdata.map { Unmanaged<TerminalView>.fromOpaque($0).takeUnretainedValue() }
    }

    /// Frees the surface, which ends the shell.
    func close() {
        guard let surface else { return }
        self.surface = nil
        ghostty_surface_free(surface)
    }
    /// libghostty asks from inside its own call, so the surface is freed after it returns.
    func closeLater() {
        DispatchQueue.main.async { [weak self] in self?.onClose?() }
    }

    // MARK: Size and focus

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { setFocused(true) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { setFocused(false) }
        return accepted
    }
    /// The one surface is the whole app, and the launcher never activates Jevcast, so app focus
    /// follows the surface.
    func setFocused(_ focused: Bool) {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, focused)
        ghostty_app_set_focus(ghostty_surface_app(surface), focused)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSize()
    }
    /// In the launcher it takes the keys from the search field. Out of it, libghostty stops drawing.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let surface else { return }
        ghostty_surface_set_occlusion(surface, window != nil)
        guard let window else { setFocused(false); return }
        window.makeFirstResponder(self)
        screenChanged()
    }
    /// The display sets the refresh rate; its scale sets the pixel size.
    func screenChanged() {
        guard let surface, let number = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return }
        ghostty_surface_set_display_id(surface, number.uint32Value)
        viewDidChangeBackingProperties()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            // libghostty scales its own drawing; the layer must not scale it again.
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        guard let surface, bounds.width > 0, bounds.height > 0 else { return }
        let backing = convertToBacking(bounds)
        ghostty_surface_set_content_scale(surface, backing.width / bounds.width, backing.height / bounds.height)
        updateSize()
    }
    private func updateSize() {
        guard let surface, bounds.width > 0, bounds.height > 0 else { return }
        let size = convertToBacking(bounds).size
        ghostty_surface_set_size(surface, UInt32(size.width), UInt32(size.height))
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        sendKey(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS, text: Self.text(of: event))
    }
    override func keyUp(with event: NSEvent) {
        sendKey(event, action: GHOSTTY_ACTION_RELEASE, text: nil)
    }
    override func flagsChanged(with event: NSEvent) {
        let mod: ghostty_input_mods_e
        switch event.keyCode {
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER
        default: return
        }
        let held = Self.mods(event.modifierFlags).rawValue & mod.rawValue != 0
        sendKey(event, action: held ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE, text: nil)
    }

    private func sendKey(_ event: NSEvent, action: ghostty_input_action_e, text: String?) {
        guard let surface else { return }
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.mods = Self.mods(event.modifierFlags)
        // Control and Command never change the typed character; the others may have.
        key.consumed_mods = Self.mods(event.modifierFlags.subtracting([.control, .command]))
        if event.type != .flagsChanged, let scalar = event.characters(byApplyingModifiers: [])?.unicodeScalars.first {
            key.unshifted_codepoint = scalar.value
        }
        // libghostty encodes control characters itself.
        guard let text, let first = text.utf8.first, first >= 0x20 else { _ = ghostty_surface_key(surface, key); return }
        text.withCString { pointer in
            key.text = pointer
            _ = ghostty_surface_key(surface, key)
        }
    }

    /// The characters a key types, as Ghostty's own app reads them: Control is left out of a
    /// control character, and the function-key range carries no text.
    private static func text(of event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 { return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control)) }
            if (0xF700...0xF8FF).contains(scalar.value) { return nil }
        }
        return characters
    }

    private static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(mods)
    }

    // MARK: Edit menu: ⌘C, ⌘V, and ⌘A reach the terminal through the main menu.

    @objc func copy(_ sender: Any?) { binding("copy_to_clipboard") }
    @objc func paste(_ sender: Any?) { binding("paste_from_clipboard") }
    @objc override func selectAll(_ sender: Any?) { binding("select_all") }
    private func binding(_ action: String) {
        guard let surface else { return }
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    // MARK: Clipboard requests from libghostty

    func readClipboard(_ location: ghostty_clipboard_e, state: UnsafeMutableRawPointer?) -> Bool {
        guard let surface, location == GHOSTTY_CLIPBOARD_STANDARD,
              let text = NSPasteboard.general.string(forType: .string) else { return false }
        text.withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, false) }
        return true
    }

    /// A paste with line breaks could run commands, so it asks first. A program's request to read
    /// the clipboard is refused.
    func confirmClipboard(_ text: String, state: UnsafeMutableRawPointer?, request: ghostty_clipboard_request_e) {
        guard request == GHOSTTY_CLIPBOARD_REQUEST_PASTE, let window else { complete("", state: state); return }
        let alert = NSAlert()
        alert.messageText = "Paste text with line breaks?"
        alert.informativeText = "Each line can run as a command."
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.complete(response == .alertFirstButtonReturn ? text : "", state: state)
        }
    }
    /// Empty text refuses the request.
    private func complete(_ text: String, state: UnsafeMutableRawPointer?) {
        guard let surface else { return }
        text.withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, true) }
    }

    // MARK: Mouse

    override func resetCursorRects() { addCursorRect(bounds, cursor: .iBeam) }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
    override func mouseDown(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT) }
    override func mouseUp(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT) }
    override func rightMouseDown(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT) }
    override func rightMouseUp(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT) }
    override func otherMouseDown(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE) }
    override func otherMouseUp(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE) }
    override func mouseMoved(with event: NSEvent) { mousePosition(event) }
    override func mouseDragged(with event: NSEvent) { mousePosition(event) }
    override func rightMouseDragged(with event: NSEvent) { mousePosition(event) }
    override func otherMouseDragged(with event: NSEvent) { mousePosition(event) }

    private func mouseButton(_ event: NSEvent, _ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e) {
        guard let surface else { return }
        mousePosition(event)
        _ = ghostty_surface_mouse_button(surface, state, button, Self.mods(event.modifierFlags))
    }
    /// libghostty measures from the top left.
    private func mousePosition(_ event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, Self.mods(event.modifierFlags))
    }
    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        let precise = event.hasPreciseScrollingDeltas
        // Trackpad deltas are doubled, as in Ghostty's own app.
        let factor = precise ? 2.0 : 1.0
        // Bit 0 marks precise deltas; bits 1 to 3 hold the momentum phase.
        let mods = Int32(precise ? 1 : 0) | Int32(Self.momentum(event.momentumPhase).rawValue) << 1
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX * factor, event.scrollingDeltaY * factor, mods)
    }
    private static func momentum(_ phase: NSEvent.Phase) -> ghostty_input_mouse_momentum_e {
        switch phase {
        case .began: return GHOSTTY_MOUSE_MOMENTUM_BEGAN
        case .stationary: return GHOSTTY_MOUSE_MOMENTUM_STATIONARY
        case .changed: return GHOSTTY_MOUSE_MOMENTUM_CHANGED
        case .ended: return GHOSTTY_MOUSE_MOMENTUM_ENDED
        case .cancelled: return GHOSTTY_MOUSE_MOMENTUM_CANCELLED
        case .mayBegin: return GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN
        default: return GHOSTTY_MOUSE_MOMENTUM_NONE
        }
    }
}
