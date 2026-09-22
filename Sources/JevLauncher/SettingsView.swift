import SwiftUI
import LauncherCore

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var model: LauncherModel
    @ObservedObject var speech: SpeechService
    @ObservedObject var catalogue: AppCatalogue
    @State private var key = ""
    @State private var status = ""
    @State private var alias = ""
    @State private var aliasApp = ""
    @State private var login = false
    let changed: () -> Void
    var body: some View {
        TabView {
            Form {
                Section("Launcher") {
                    Picker("Open Launcher", selection: $preferences.hotkey) {
                        Text("Control–Shift–Space").tag(0)
                        Text("Option–Space").tag(1)
                        Text("Command–Space").tag(2)
                    }
                    Text("Release a shortcut in Spotlight or Raycast before assigning it here.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Launch at login", isOn: $login).onChange(of: login) { _, value in
                        do { try preferences.setLogin(value) } catch { status = error.localizedDescription; login = preferences.loginEnabled }
                    }
                    Picker("Web Search", selection: $preferences.webEngine) {
                        Text("Google").tag("Google"); Text("DuckDuckGo").tag("DuckDuckGo")
                    }
                }
                Section("Voice") {
                    Toggle("Start listening when the launcher opens", isOn: $preferences.voiceEnabled)
                    Text("Uses the system microphone and on-device Apple speech recognition. Audio is not saved. Typing stops listening.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Allow Microphone and Speech") { Task { await speech.requestPermissions(); status = speech.status } }
                    Text(speech.status).font(.caption).foregroundStyle(.secondary)
                }
                Section("Window Control") {
                    Button(WindowManager.hasPermission ? "Accessibility Access Granted" : "Allow Accessibility Access") { model.windows.requestPermission() }
                    Toggle("Snap windows when dragged to screen edges", isOn: $preferences.edgeSnapping)
                    Toggle("Enable direct window shortcuts", isOn: $preferences.windowShortcuts)
                    Text("Control–Option–Command: ← → ↑ ↓ for halves; U I J K for quarters; 1 2 3 for thirds; Return to maximise; Z to restore; N/P for displays. Repeat left/right within 1.5 seconds to cycle half, two-thirds, and one-third.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack { Text("Window Gap"); Slider(value: $preferences.gap, in: 0...24, step: 1); Text("\(Int(preferences.gap)) pt").monospacedDigit() }
                }
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
            }.formStyle(.grouped).tabItem { Label("General", systemImage: "slider.horizontal.3") }
            Form {
                Section("Applications") {
                    Text("\(catalogue.entries.count) apps found. Standard application folders are included.").font(.caption)
                    ForEach(preferences.appFolders, id: \.self) { path in
                        HStack { Text(path).lineLimit(1).truncationMode(.middle); Spacer(); Button("Remove") { preferences.appFolders.removeAll { $0 == path }; catalogue.refresh(extra: preferences.appFolders) } }
                    }
                    HStack {
                        Button("Add App Folder") { preferences.addFolder(apps: true); catalogue.refresh(extra: preferences.appFolders) }
                        Button("Refresh Apps") { catalogue.refresh(extra: preferences.appFolders) }
                    }
                }
                Section("File Search Folders") {
                    ForEach(preferences.fileFolders, id: \.self) { path in
                        HStack { Text(path).lineLimit(1).truncationMode(.middle); Spacer(); Button("Remove") { preferences.fileFolders.removeAll { $0 == path } } }
                    }
                    Button("Add Search Folder") { preferences.addFolder(apps: false) }
                    Text("Search names, file types, folders, and modification dates. Try kind:pdf in:downloads or files modified today. Results depend on Spotlight indexing and macOS file access.").font(.caption).foregroundStyle(.secondary)
                }
                Section("App Aliases") {
                    TextField("Alias, for example coding app", text: $alias)
                    Picker("Application", selection: $aliasApp) {
                        Text("Choose an app").tag("")
                        ForEach(catalogue.entries) { app in Text(app.name).tag(app.id) }
                    }
                    Button("Add Alias") {
                        preferences.aliases[alias.trimmingCharacters(in: .whitespacesAndNewlines)] = aliasApp; alias = ""
                    }.disabled(alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || aliasApp.isEmpty)
                    ForEach(preferences.aliases.keys.sorted(), id: \.self) { value in
                        HStack {
                            Text(value); Spacer()
                            Text(catalogue.entries.first { $0.id == preferences.aliases[value] }?.name ?? "App unavailable").foregroundStyle(.secondary)
                            Button("Remove") { preferences.aliases.removeValue(forKey: value) }
                        }
                    }
                }
            }.formStyle(.grouped).tabItem { Label("Search", systemImage: "magnifyingglass") }
            Form {
                Section("TypeSafe AI") {
                    Toggle("Use Jev for natural-language matching", isOn: $preferences.jevEnabled)
                    Text("Local results appear first. Jev receives the request text and candidate names or paths. No audio is sent. Jev can select built-in actions only.")
                        .font(.caption).foregroundStyle(.secondary)
                    SecureField("TypeSafe API Key", text: $key)
                    HStack {
                        Button("Save Key") {
                            do { try KeychainStore.save(key.trimmingCharacters(in: .whitespacesAndNewlines)); key = ""; status = "Key saved in macOS Keychain." }
                            catch { status = error.localizedDescription }
                        }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Remove Key") {
                            do { try KeychainStore.delete(); preferences.jevEnabled = false; status = "Key removed." }
                            catch { status = error.localizedDescription }
                        }
                    }
                    Text(status).font(.caption)
                    Text("Model: jev-1.13.0 · Exact local commands do not wait for Jev.").font(.caption).foregroundStyle(.secondary)
                }
                Section("About This Build") {
                    Text("Jev Launcher · Local Preview")
                    Text("Apps, files, voice input, and window controls.").font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "Last local search: %.2f ms", model.localSearchMS)).font(.caption.monospaced())
                }
            }.formStyle(.grouped).tabItem { Label("Jev", systemImage: "sparkles") }
        }
        .frame(width: 630, height: 650)
        .onAppear { login = preferences.loginEnabled }
        .onChange(of: preferences.hotkey) { _, _ in changed() }
        .onChange(of: preferences.windowShortcuts) { _, _ in changed() }
        .onChange(of: preferences.edgeSnapping) { _, _ in changed() }
        .onChange(of: preferences.gap) { _, _ in changed() }
    }
}
