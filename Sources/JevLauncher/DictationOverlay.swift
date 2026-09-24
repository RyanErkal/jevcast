import AppKit
import SwiftUI

/// A small pill near the bottom of the screen while dictation records or transcribes.
/// Non-activating, so the app in front keeps focus and receives the paste.
@MainActor
final class DictationOverlay {
    enum Phase: Equatable {
        case recording, transcribing
        case message(String)
        case error(String)
    }
    private final class State: ObservableObject { @Published var phase: Phase = .recording }
    private let state = State()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ phase: Phase) {
        hideTask?.cancel()
        state.phase = phase
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
        switch phase {
        case .error, .message:
            hideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard !Task.isCancelled else { return }
                self?.hide()
            }
        case .recording, .transcribing: break
        }
    }

    func hide() {
        hideTask?.cancel()
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 40),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: Pill(state: state))
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: screen.midX - panel.frame.width / 2, y: screen.minY + 48))
    }

    private struct Pill: View {
        @ObservedObject var state: State
        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(text).lineLimit(1).font(.callout)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        private var symbol: String {
            switch state.phase {
            case .recording: return "mic.fill"
            case .transcribing: return "waveform"
            case .message: return "doc.on.clipboard"
            case .error: return "exclamationmark.triangle.fill"
            }
        }
        private var tint: Color {
            switch state.phase {
            case .recording: return .red
            case .error: return .orange
            default: return .secondary
            }
        }
        private var text: String {
            switch state.phase {
            case .recording: return "Listening…"
            case .transcribing: return "Transcribing…"
            case .message(let text), .error(let text): return text
            }
        }
    }
}
