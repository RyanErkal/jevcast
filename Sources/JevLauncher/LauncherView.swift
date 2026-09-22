import SwiftUI
import AppKit

struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject var speech: SpeechService
    @ObservedObject var catalogue: AppCatalogue
    let settings: () -> Void
    let actions: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "command").font(.system(size: 24, weight: .medium)).foregroundStyle(.secondary)
                LauncherSearchField(model: model).frame(height: 34)
                Button {
                    model.toggleListening()
                } label: {
                    Image(systemName: speech.isListening ? "waveform" : speech.isStarting ? "ellipsis" : "mic.slash")
                        .font(.system(size: 19)).foregroundStyle(speech.isListening ? Color.accentColor : .secondary)
                        .frame(width: 34, height: 34)
                }.buttonStyle(.plain).help(speech.isListening || speech.isStarting ? "Stop Listening" : "Start Listening")
            }.padding(.horizontal, 24).padding(.vertical, 22)
            Divider()
            HStack {
                Text(model.query.isEmpty ? "FAVOURITES & RECENT" : model.isFileSearch ? "FILES" : "RESULTS")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.5)
                Spacer()
                if model.isFileSearch { Text("Name · Kind · Folder · Date") }
                else if catalogue.scanning { ProgressView().controlSize(.mini); Text("Finding apps") }
                else { Text("\(catalogue.entries.count) apps") }
            }.foregroundStyle(.secondary).font(.system(size: 11)).padding(.horizontal, 24).padding(.top, 15).padding(.bottom, 8)
            ResultList(model: model, actions: actions)
                .padding(.horizontal, 10)
                .overlay {
                    if model.results.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "doc.text.magnifyingglass").font(.title)
                            Text(model.emptyMessage).font(.system(size: 13))
                                .multilineTextAlignment(.center)
                        }.foregroundStyle(.secondary).padding(32).allowsHitTesting(false)
                    }
                }
            if !model.fileStatus.isEmpty && !model.results.isEmpty {
                Text(model.fileStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 7)
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
                Text("↵ Open").foregroundStyle(.secondary)
                Button("⌘K Actions", action: actions).buttonStyle(.plain).disabled(model.selected == nil)
                Button(action: settings) { Image(systemName: "gearshape") }.buttonStyle(.plain).help("Settings")
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 22).padding(.vertical, 13)
        }
        .background(.regularMaterial)
    }
}

extension Notification.Name { static let launcherDidOpen = Notification.Name("launcherDidOpen") }
