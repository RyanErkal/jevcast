import AppKit
import SwiftUI

/// First-launch guide. A menu-bar app shows no window of its own, and a full
/// menu bar can hide its icon behind the notch, so this is the first contact.
/// It opens once by itself; Help › Welcome Guide opens it again.
@MainActor
final class WelcomeWindow: NSWindowController, NSWindowDelegate {
    static let size = NSSize(width: 540, height: 600)

    init(preferences: Preferences, model: LauncherModel, status: LauncherStatus, page: WelcomePage = .welcome,
         changed: @escaping () -> Void, openSettings: @escaping (SettingsWindow.Tab) -> Void, tryQuery: @escaping (String) -> Void) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Welcome to \(AppIdentity.name)"
        super.init(window: window)
        let view = WelcomeView(preferences: preferences, model: model, speech: model.speech, status: status, page: page,
                               changed: changed,
                               openSettings: { [weak self] tab in self?.close(); openSettings(tab) },
                               tryQuery: tryQuery,
                               done: { [weak self] in self?.close() })
        // A short screen gets a shorter window; each step's form scrolls inside it, and the footer stays visible.
        let height = min(Self.size.height, (NSScreen.main?.visibleFrame.height ?? 800) - 80)
        window.contentView = NSHostingView(rootView: view.frame(width: Self.size.width, height: height))
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// The guide's steps, in order.
enum WelcomePage: String, CaseIterable {
    case welcome, shortcut, tour, permissions, ai, finish
    var next: WelcomePage? { Self.allCases.firstIndex(of: self).flatMap { Self.allCases.indices.contains($0 + 1) ? Self.allCases[$0 + 1] : nil } }
    var previous: WelcomePage? { Self.allCases.firstIndex(of: self).flatMap { $0 > 0 ? Self.allCases[$0 - 1] : nil } }
}

struct WelcomeView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var model: LauncherModel
    @ObservedObject var speech: SpeechService
    @ObservedObject var status: LauncherStatus
    @State var page: WelcomePage
    let changed: () -> Void
    let openSettings: (SettingsWindow.Tab) -> Void
    let tryQuery: (String) -> Void
    let done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case .welcome: WelcomeIntroPage()
                case .shortcut: WelcomeShortcutPage(preferences: preferences, status: status, changed: changed)
                case .tour: WelcomeTourPage(tryQuery: tryQuery)
                case .permissions: WelcomePermissionsPage(preferences: preferences, model: model, speech: speech)
                case .ai: WelcomeAIPage(preferences: preferences, openSettings: openSettings)
                case .finish: WelcomeFinishPage(preferences: preferences)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            footer
        }
    }

    private var footer: some View {
        HStack {
            if let previous = page.previous { Button("Back") { page = previous } }
            Spacer()
            // No step is required, so Continue always moves on.
            if let next = page.next {
                Button("Continue") { page = next }.keyboardShortcut(.defaultAction)
            } else {
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        // The dots sit in an overlay, so they stay centred with or without Back.
        .overlay {
            HStack(spacing: 6) {
                ForEach(WelcomePage.allCases, id: \.self) { step in
                    Circle().fill(step == page ? Color.accentColor : Color.secondary.opacity(0.35)).frame(width: 6, height: 6)
                }
            }
            .accessibilityElement().accessibilityLabel("Step \((WelcomePage.allCases.firstIndex(of: page) ?? 0) + 1) of \(WelcomePage.allCases.count)")
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 20)
    }
}
