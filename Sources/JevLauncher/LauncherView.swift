import SwiftUI
import AppKit

struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject var speech: SpeechService
    @ObservedObject var catalogue: AppCatalogue
    let settings: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "command").font(.system(size: 24, weight: .medium)).foregroundStyle(.secondary)
                TextField("Speak or type an action…", text: Binding(get: { model.query }, set: { model.updateQuery($0, typed: true) }))
                    .textFieldStyle(.plain).font(.system(size: 25, weight: .regular))
                    .focused($focused)
                    .accessibilityIdentifier("launcher-query")
                Button {
                    if speech.isListening { speech.stop() } else { speech.start() }
                } label: {
                    Image(systemName: speech.isListening ? "waveform" : "mic.slash")
                        .font(.system(size: 19)).foregroundStyle(speech.isListening ? Color.accentColor : .secondary)
                        .frame(width: 34, height: 34)
                }.buttonStyle(.plain).help(speech.isListening ? "Stop Listening" : "Start Listening")
            }.padding(.horizontal, 24).padding(.vertical, 22)
            Divider()
            HStack {
                Text(model.query.isEmpty ? "READY WHEN YOU ARE" : "RESULTS")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.5)
                Spacer()
                if catalogue.scanning { ProgressView().controlSize(.mini); Text("Finding apps") }
                else { Text("\(catalogue.entries.count) apps") }
            }.foregroundStyle(.secondary).font(.system(size: 11)).padding(.horizontal, 24).padding(.top, 15).padding(.bottom, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(model.results) { result in
                            ResultRow(result: result, selected: model.selectedID == result.id)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { model.select(result.id); model.execute() }
                                .onTapGesture { model.select(result.id) }
                                .contextMenu {
                                    Button("Run") { model.select(result.id); model.execute() }
                                    if result.path != nil {
                                        Button("Reveal in Finder") { model.select(result.id); model.revealSelected() }
                                        Button("Copy Path") { model.select(result.id); model.copyPath() }
                                    }
                                    if case .app = result.action {
                                        Button(model.preferences.favourites.contains(result.id) ? "Remove Favourite" : "Add Favourite") {
                                            model.preferences.toggleFavourite(result.id); model.rebuild()
                                        }
                                    }
                                }
                                .id(result.id)
                        }
                        if model.results.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "magnifyingglass").font(.title2)
                                Text(catalogue.scanning ? "Building the app catalogue…" : "Type an app, file, or window action")
                            }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(40)
                        }
                    }.padding(.horizontal, 12).padding(.bottom, 10)
                }.onChange(of: model.selectedID) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
            }
            if model.preferences.voiceEnabled && !speech.permissionsGranted {
                HStack {
                    Text("Enable voice once to listen on every open.").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Enable Voice") { Task { await model.enableVoice() } }.controlSize(.small)
                }.padding(.horizontal, 24).padding(.vertical, 8)
            }
            if model.selected?.id.hasPrefix("window:") == true && !WindowManager.hasPermission {
                HStack {
                    Text("Window control needs Accessibility access.").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Enable Window Control") { model.windows.requestPermission() }.controlSize(.small)
                }.padding(.horizontal, 24).padding(.vertical, 8)
            }
            if let message = model.message {
                Text(message).font(.system(size: 12)).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 8)
            }
            Divider()
            HStack(spacing: 9) {
                Circle().fill(speech.isListening ? Color.green : Color.secondary.opacity(0.4)).frame(width: 5, height: 5)
                Text(model.aiStatus.isEmpty ? speech.status : model.aiStatus).lineLimit(1)
                Spacer(minLength: 10)
                Text("↑↓ Select").foregroundStyle(.tertiary)
                Text("↵ Run").foregroundStyle(.secondary)
                Button(action: settings) { Image(systemName: "gearshape") }.buttonStyle(.plain).help("Settings")
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 22).padding(.vertical, 13)
        }
        .background(.regularMaterial)
        .onAppear { focused = true }
        .onReceive(NotificationCenter.default.publisher(for: .launcherDidOpen)) { _ in focused = true }
    }
}

private struct ResultRow: View {
    let result: LauncherResult
    let selected: Bool
    var body: some View {
        HStack(spacing: 13) {
            ResultIcon(path: result.path, symbol: result.symbol)
            VStack(alignment: .leading, spacing: 4) {
                Text(result.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text(result.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if selected { Image(systemName: "return").font(.system(size: 12)).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ResultIcon: View {
    let path: String?
    let symbol: String
    @State private var icon: NSImage?
    var body: some View {
        Group {
            if let icon { Image(nsImage: icon).resizable().interpolation(.high) }
            else { Image(systemName: symbol).resizable().scaledToFit().padding(5).foregroundStyle(.secondary) }
        }.frame(width: 30, height: 30)
        .task(id: path) {
            if let path { icon = IconCache.shared.icon(path) }
        }
    }
}
@MainActor private final class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSString, NSImage>()
    func icon(_ path: String) -> NSImage {
        if let image = cache.object(forKey: path as NSString) { return image }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 32, height: 32)
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}
extension Notification.Name { static let launcherDidOpen = Notification.Name("launcherDidOpen") }
