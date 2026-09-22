import SwiftUI
import AppKit

struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject var speech: SpeechService
    @ObservedObject var catalogue: AppCatalogue
    let actions: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// An empty query with no favourites or recent items shows the search bar alone.
    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if !model.rows.isEmpty {
                Divider()
                results
            } else if showsEmptyMessage {
                Divider()
                emptyMessage
            }
            if let notice = model.notice {
                Divider()
                StatusStrip(notice: notice) { model.perform($0) }
            }
            if showsFooter {
                Divider()
                footer
            }
        }
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var searchBar: some View {
        // Glyph width and spacing match the row icon column, so query text lines up with row titles.
        HStack(spacing: LauncherMetrics.iconSpacing) {
            Image(systemName: speech.isListening ? "waveform" : "magnifyingglass")
                .font(.system(size: LauncherMetrics.searchGlyphSize, weight: .regular))
                .foregroundStyle(speech.isListening ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .frame(width: LauncherMetrics.iconSize)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .accessibilityHidden(true)
            LauncherSearchField(model: model)
            // Voice setup lives in Settings › Voice; the button appears only once voice can work.
            if speech.permissionsGranted { MicButton(speech: speech) { model.toggleListening() } }
        }
        .padding(.horizontal, LauncherMetrics.gutter)
        .frame(height: LauncherMetrics.searchBarHeight)
    }

    /// The list is exactly as tall as its rows, so the panel follows the result count.
    private var results: some View {
        ResultList(model: model, actions: actions)
            .frame(height: LauncherSections.listHeight(model.rows))
            .padding(.horizontal, LauncherMetrics.listInset)
            .padding(.vertical, LauncherMetrics.listPadding)
    }

    /// The footer appears only when it has something to say: an action for the
    /// selection, listening, or loading. A collapsed panel never shows it.
    private var showsFooter: Bool {
        guard !model.isCollapsed else { return false }
        return model.primaryActionTitle != nil || speech.isListening || speech.isStarting || model.loadingStatus != nil
    }

    /// A typed query with nothing to show, once any search has finished.
    private var showsEmptyMessage: Bool { !model.query.isEmpty && model.loadingStatus == nil }

    private var emptyMessage: some View {
        Text(model.emptyMessage)
            .font(.system(size: 13)).foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity).padding(.horizontal, LauncherMetrics.gutter).padding(.vertical, 22)
    }

    /// Left: listening or loading only. Right: what Return does, then the actions menu.
    private var footer: some View {
        HStack(spacing: 10) {
            if speech.isListening || speech.isStarting {
                ListeningIndicator(starting: !speech.isListening)
            } else if let loading = model.loadingStatus {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(loading).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 10)
            if let primary = model.primaryActionTitle {
                KeyHint(primary, "↩")
                Rectangle().fill(.quaternary).frame(width: 1, height: 12).accessibilityHidden(true)
                Button(action: actions) { KeyHint("Actions", "⌘K") }
                    .buttonStyle(.plain)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, LauncherMetrics.gutter)
        .frame(height: LauncherMetrics.footerHeight)
    }
}

/// A filled dot and a word, so the state does not depend on colour alone.
private struct ListeningIndicator: View {
    let starting: Bool
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(starting ? Color.secondary : Color.green).frame(width: 6, height: 6)
            Text(starting ? "Starting…" : "Listening").foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MicButton: View {
    @ObservedObject var speech: SpeechService
    let toggle: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: toggle) {
            Image(systemName: speech.isListening ? "mic.fill" : "mic")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(speech.isListening ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .frame(width: 28, height: 28)
                .background(Circle().fill(hovering ? Color.primary.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(active ? "Stop Listening" : "Start Listening")
        .accessibilityLabel(active ? "Stop listening" : "Start listening")
    }
    private var active: Bool { speech.isListening || speech.isStarting }
}

private struct StatusStrip: View {
    let notice: Notice
    let perform: (Notice.Action) -> Void
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: notice.symbol).foregroundStyle(notice.tone.symbolStyle).accessibilityHidden(true)
            Text(notice.text).foregroundStyle(notice.tone.textStyle).lineLimit(2)
            Spacer()
            if let action = notice.action { Button(action.title) { perform(action) }.controlSize(.small) }
        }
        .font(.system(size: 12)).padding(.horizontal, LauncherMetrics.gutter).padding(.vertical, 9)
    }
}

/// Tone to style. The model chooses the tone; the symbol carries the meaning as well as the colour.
private extension Notice.Tone {
    var symbolStyle: Color {
        switch self { case .warning: return .orange; case .info: return .secondary }
    }
    var textStyle: HierarchicalShapeStyle {
        switch self { case .warning: return .primary; case .info: return .secondary }
    }
}

extension Notification.Name { static let launcherDidOpen = Notification.Name("launcherDidOpen") }
