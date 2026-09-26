import AppKit
import SwiftUI

/// System Settings-style window: toolbar tabs, title follows the tab, and the
/// window height animates to each pane's measured content height. A pane taller
/// than `maxHeight` (or the screen) scrolls inside its Form.
@MainActor
final class SettingsWindow: NSWindowController, NSToolbarDelegate {
    enum Tab: String, CaseIterable {
        case general, search, library, windows, voice, dictation, ai, automations, mail
        var title: String {
            switch self {
            case .general: return "General"; case .search: return "Search"
            case .library: return "Library"; case .windows: return "Windows"
            case .voice: return "Voice"; case .dictation: return "Dictation"; case .ai: return "AI"; case .mail: return "Mail"
            case .automations: return "Automations"
            }
        }
        var symbol: String {
            switch self {
            case .general: return "gearshape"; case .search: return "magnifyingglass"
            case .library: return "books.vertical"; case .windows: return "macwindow"
            case .voice: return "waveform"; case .dictation: return "mic"; case .ai: return "sparkles"; case .mail: return "envelope"
            case .automations: return "bolt.badge.clock"
            }
        }
        var identifier: NSToolbarItem.Identifier { NSToolbarItem.Identifier(rawValue) }
        /// Dictation needs macOS 26, so its tab is hidden on older systems.
        static var shown: [Tab] { allCases.filter { $0 != .dictation || DictationEngines.isSupported } }
    }
    static let width: CGFloat = 600
    static let minHeight: CGFloat = 200
    static let maxHeight: CGFloat = 720

    private let preferences: Preferences
    private let model: LauncherModel
    private let catalogue: AppCatalogue
    private let status: LauncherStatus
    private let updates: UpdateChecker
    private let dictation: DictationController
    private let automations: AutomationCenter
    private let hyper: HyperKeyController
    private let changed: () -> Void
    private let openMail: () -> Void
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    private var current: Tab = .general

    init(preferences: Preferences, model: LauncherModel, catalogue: AppCatalogue, status: LauncherStatus, updates: UpdateChecker,
         dictation: DictationController, automations: AutomationCenter, hyper: HyperKeyController, changed: @escaping () -> Void, openMail: @escaping () -> Void) {
        self.preferences = preferences; self.model = model; self.catalogue = catalogue; self.status = status; self.updates = updates
        self.dictation = dictation; self.automations = automations; self.hyper = hyper; self.changed = changed; self.openMail = openMail
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        window.titlebarSeparatorStyle = .automatic
        super.init(window: window)
        let toolbar = NSToolbar(identifier: "JevSettings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        hosting.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = hosting
        toolbar.selectedItemIdentifier = current.identifier
        select(current, animate: false)
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func select(_ tab: Tab) {
        window?.toolbar?.selectedItemIdentifier = tab.identifier
        select(tab, animate: false)
    }
    private func select(_ tab: Tab, animate: Bool) {
        current = tab
        window?.title = tab.title
        hosting.rootView = AnyView(pane(for: tab).frame(width: Self.width))
        fit(animate: animate)
    }
    /// Sizes the window to the pane's content, keeping the top edge in place.
    private func fit(animate: Bool) {
        guard let window else { return }
        let height = min(max(contentHeight(for: current), Self.minHeight), maxHeight(for: window))
        var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: Self.width, height: height))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        guard abs(frame.height - window.frame.height) >= 1 else { return }
        window.setFrame(frame, display: true, animate: animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
    /// A grouped Form scrolls, so its fitting size is not its content height.
    /// Measure the same pane unscrolled at its ideal height instead.
    func contentHeight(for tab: Tab) -> CGFloat {
        let probe = NSHostingView(rootView: pane(for: tab).scrollDisabled(true).frame(width: Self.width).fixedSize(horizontal: false, vertical: true))
        return ceil(probe.fittingSize.height)
    }
    private func maxHeight(for window: NSWindow) -> CGFloat {
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? Self.maxHeight
        let chrome = window.frame.height - window.contentLayoutRect.height
        return min(Self.maxHeight, screen - chrome - 40)
    }
    @ViewBuilder private func pane(for tab: Tab) -> some View {
        switch tab {
        case .general: GeneralSettings(preferences: preferences, status: status, updates: updates, speech: model.speech, windows: model.windows, keys: model.keys, history: model.clipboard, changed: changed, resized: resized)
        case .search: SearchSettings(preferences: preferences, catalogue: catalogue)
        case .windows: WindowSettings(preferences: preferences, model: model, hyper: hyper, changed: changed, resized: resized)
        case .library: CommandSettings(preferences: preferences, catalogue: catalogue, resized: resized)
        case .voice: VoiceSettings(preferences: preferences, speech: model.speech)
        case .dictation: DictationSettings(preferences: preferences, dictation: dictation, openQuill: { [weak self] in self?.select(.ai) })
        case .ai: AISettings(preferences: preferences, model: model, resized: resized)
        case .automations: AutomationSettingsPane(preferences: preferences, center: automations, resized: resized)
        case .mail: MailSettings(preferences: preferences, openMail: openMail)
        }
    }

    /// A pane that switches between parts asks for its new height here.
    private var resized: () -> Void { { [weak self] in DispatchQueue.main.async { self?.fit(animate: true) } } }

    @objc private func selectTab(_ sender: NSToolbarItem) {
        guard let tab = Tab(rawValue: sender.itemIdentifier.rawValue), tab != current else { return }
        select(tab, animate: true)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let tab = Tab(rawValue: identifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = tab.title
        item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
        item.target = self
        item.action = #selector(selectTab(_:))
        return item
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Tab.shown.map(\.identifier) }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Tab.shown.map(\.identifier) }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Tab.shown.map(\.identifier) }
}
