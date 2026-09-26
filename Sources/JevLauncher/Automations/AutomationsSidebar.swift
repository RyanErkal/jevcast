import SwiftUI
import LauncherCore

struct AutomationsSidebar: View {
    @ObservedObject var model: AutomationsViewModel

    var body: some View {
        List(selection: sectionBinding) {
            Section {
                row(.needsYou)
            }
            Section("Automations") {
                row(.all); row(.running); row(.failed); row(.history)
            }
            Section("More") {
                row(.quill); row(.codex); row(.clients)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { RunnerStatusPill(model: model).padding(10) }
    }

    private var sectionBinding: Binding<AutomationsViewModel.Section?> {
        Binding(get: { model.section }, set: { if let s = $0 { model.section = s } })
    }

    private func row(_ section: AutomationsViewModel.Section) -> some View {
        Label(section.title, systemImage: section.symbol)
            .badge(model.count(section) ?? 0)
            .tag(section)
    }
}

/// A dot and the runner's state. Clicking explains it and offers the fix.
struct RunnerStatusPill: View {
    @ObservedObject var model: AutomationsViewModel
    @State private var showing = false

    var body: some View {
        let status = model.runnerStatus
        Button { showing.toggle() } label: {
            HStack(spacing: 7) {
                Circle().fill(color(status)).frame(width: 8, height: 8)
                Text("Runner: " + status.title).font(.caption).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Background runner: " + status.title)
        .popover(isPresented: $showing, arrowEdge: .top) { RunnerStatusPopover(model: model, status: status) }
    }

    private func color(_ status: AutomationCenter.RunnerStatus) -> Color {
        switch status {
        case .running: return .green
        case .starting: return .yellow
        case .needsApproval, .notResponding: return .orange
        case .failed, .unsignedBuild: return .red
        case .off: return .gray
        }
    }
}

struct RunnerStatusPopover: View {
    @ObservedObject var model: AutomationsViewModel
    let status: AutomationCenter.RunnerStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Background runner").font(.headline)
            Text(explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                switch status {
                case .off, .failed, .notResponding: Button("Turn On") { model.turnOnRunner() }.keyboardShortcut(.defaultAction)
                case .needsApproval: Button("Open Login Items") { model.openLoginItems() }.keyboardShortcut(.defaultAction)
                default: EmptyView()
                }
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private var explanation: String {
        switch status {
        case .running(let since):
            return "Automations run on schedule, even when this window is closed. Running since " + since.formatted(date: .omitted, time: .shortened) + "."
        case .starting: return "The runner is starting. This takes a few seconds."
        case .off: return "Scheduled automations do not run while the runner is off. Run Now still queues work for when it starts."
        case .needsApproval: return "macOS needs your permission. In System Settings › General › Login Items, turn on Jevcast."
        case .notResponding: return "The runner has not checked in for over 90 seconds. Turn it on again to restart it."
        case .unsignedBuild: return "This build is not signed, so macOS will not start the runner. Use a signed release build."
        case .failed(let message): return "The runner could not start: " + message
        }
    }
}
