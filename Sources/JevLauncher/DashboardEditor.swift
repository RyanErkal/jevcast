import AppKit
import LauncherCore
import SwiftUI
import UniformTypeIdentifiers

/// Adds or edits one dashboard: the data file, the values to show, and optional links.
struct DashboardEditor: View {
    @State var config: DashboardConfig
    let automations: [Automation]
    let save: (DashboardConfig) -> Void
    let cancel: () -> Void

    /// Values found in the chosen file, for the pickers.
    @State private var leaves: [DashboardReader.LeafPath] = []
    @State private var fileProblem: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $config.name, prompt: Text("Sales report"))
                    FileChooserRow(title: "Data file", path: config.filePath, types: ["json"]) { config.filePath = $0 }
                    if let fileProblem { Label(fileProblem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                    if let note = config.note { Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
                } footer: {
                    Text("Choose a JSON file on this Mac. Jevcast only reads it.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Values to show") {
                    if config.metrics.isEmpty { Text("No values yet.").foregroundStyle(.secondary) }
                    ForEach($config.metrics) { $metric in
                        MetricEditorRow(metric: $metric, leaves: leaves) { config.metrics.removeAll { $0.id == metric.id } }
                    }
                    HStack {
                        AddButton(title: "Add value") {
                            let first = leaves.first { lf in !config.metrics.contains { $0.keyPath == lf.path } }
                            config.metrics.append(DashboardMetric(label: first.map { Self.label(for: $0.path) } ?? "",
                                                                  keyPath: first?.path ?? "",
                                                                  format: first.map { Self.format(for: $0) } ?? .number))
                        }
                        Spacer()
                    }
                }
                Section {
                    KeyPathField(title: "Updated at", path: Binding(get: { config.updatedAtKeyPath ?? "" },
                                                                    set: { config.updatedAtKeyPath = $0.isEmpty ? nil : $0 }),
                                 leaves: leaves.filter { DashboardReader.date(Self.raw($0.value)) != nil }, optional: true)
                    Picker("Refresh with", selection: $config.automationID) {
                        Text("None").tag(String?.none)
                        ForEach(automations) { Text($0.name).tag(Optional($0.id)) }
                    }
                    FileChooserRow(title: "File to open", path: config.openPath ?? "", types: [], clear: { config.openPath = nil }) { config.openPath = $0 }
                } header: { Text("Optional") } footer: {
                    Text("Updated at is a date in the file; the card shows how old the data is. Refresh Now runs the chosen automation, then reads the file again.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Save") {
                    var saved = config
                    saved.name = saved.name.trimmingCharacters(in: .whitespaces)
                    saved.metrics = saved.metrics.filter { !$0.keyPath.trimmingCharacters(in: .whitespaces).isEmpty }
                    if !saved.metrics.isEmpty { saved.note = nil }
                    save(saved)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(config.name.trimmingCharacters(in: .whitespaces).isEmpty || config.filePath.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 560, height: 620)
        .task(id: config.filePath) { await loadLeaves() }
    }

    private func loadLeaves() async {
        let path = config.filePath
        guard !path.isEmpty else { leaves = []; fileProblem = nil; return }
        let result = await Task.detached(priority: .userInitiated) { () -> Result<[DashboardReader.LeafPath], Error> in
            Result { DashboardReader.leafPaths(in: try DashboardReader.load(url: URL(fileURLWithPath: path))) }
        }.value
        guard path == config.filePath else { return }
        switch result {
        case .success(let found):
            leaves = found
            fileProblem = found.isEmpty ? "No numbers or text found in this file." : nil
        case .failure(let error):
            leaves = []
            fileProblem = switch error as? DashboardReadError {
            case .tooLarge: "The file is larger than 10 MB."
            case .notJSON: "The file is not valid JSON."
            default: "The file could not be read."
            }
        }
    }

    /// "totals.cost_per_lead" → "Cost per lead".
    static func label(for path: String) -> String {
        let last = DashboardReader.segments(path).last(where: { Int($0) == nil }) ?? path
        var words = ""
        for ch in last {
            if ch == "_" || ch == "-" { words.append(" ") }
            else if ch.isUppercase, let prev = words.last, prev != " " { words.append(" "); words.append(Character(ch.lowercased())) }
            else { words.append(ch) }
        }
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    static func format(for leaf: DashboardReader.LeafPath) -> DashboardFormat {
        if case .number = leaf.value { return .number }
        return .text
    }

    static func raw(_ value: DashboardValue) -> Any {
        switch value {
        case .number(let n): return NSNumber(value: n)
        case .text(let s): return s
        case .bool(let b): return NSNumber(value: b)
        }
    }
}

/// One value: label, key path, and format.
private struct MetricEditorRow: View {
    @Binding var metric: DashboardMetric
    let leaves: [DashboardReader.LeafPath]
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Label", text: $metric.label, prompt: Text("Label"))
                RemoveButton(label: "Remove " + (metric.label.isEmpty ? "value" : metric.label), action: remove)
            }
            KeyPathField(title: "Key path", path: $metric.keyPath, leaves: leaves, optional: false) { chosen in
                if metric.label.isEmpty { metric.label = DashboardEditor.label(for: chosen.path) }
                if case .text = chosen.value { metric.format = .text }
            }
            HStack {
                Picker("Format", selection: $metric.format) {
                    ForEach(DashboardFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if metric.format == .currency {
                    TextField("Symbol", text: Binding(get: { metric.currencySymbol ?? "$" }, set: { metric.currencySymbol = $0 }))
                        .frame(width: 60).labelsHidden().accessibilityLabel("Currency symbol")
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// A key path typed or picked from the values found in the file.
private struct KeyPathField: View {
    let title: String
    @Binding var path: String
    let leaves: [DashboardReader.LeafPath]
    let optional: Bool
    var picked: (DashboardReader.LeafPath) -> Void = { _ in }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, text: $path, prompt: Text(optional ? "None" : "totals.count"))
                    .labelsHidden().font(.system(.body, design: .monospaced))
                Menu {
                    if optional { Button("None") { path = "" }; Divider() }
                    if leaves.isEmpty { Text("Choose a data file first") }
                    ForEach(leaves, id: \.path) { leaf in
                        Button(leaf.path + "  =  " + DashboardText.preview(leaf.value)) { path = leaf.path; picked(leaf) }
                    }
                } label: { Image(systemName: "list.bullet") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Pick a value from the file").accessibilityLabel("Pick a " + title.lowercased())
            }
        }
    }
}

struct FileChooserRow: View {
    let title: String
    let path: String
    let types: [String]
    var clear: (() -> Void)?
    let chosen: (String) -> Void

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(path.isEmpty ? "None" : (path as NSString).abbreviatingWithTildeInPath)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let clear, !path.isEmpty {
                    Button(action: clear) { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                        .foregroundStyle(.secondary).accessibilityLabel("Clear " + title.lowercased())
                }
                Button("Choose…", action: choose).controlSize(.small)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        if !types.isEmpty { panel.allowedContentTypes = types.compactMap { .init(filenameExtension: $0) } }
        if !path.isEmpty { panel.directoryURL = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        chosen(url.path)
    }
}
