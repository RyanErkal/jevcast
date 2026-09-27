import SwiftUI
import LauncherCore

/// Dashboard cards, each read from a JSON file the user chose.
struct DashboardsSectionView: View {
    @ObservedObject var model: AutomationsViewModel
    @State private var editing: DashboardConfig?

    var body: some View {
        Group {
            if model.dashboards.isEmpty {
                EmptyStateView(symbol: "chart.bar.xaxis", title: "No dashboards yet",
                               message: "A dashboard shows numbers from a JSON file on this Mac, such as a report an automation writes. Pick the file, then choose the values to show.",
                               actionTitle: "Add Dashboard") { editing = DashboardConfig.new() }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                        ForEach(model.dashboards) { entry in
                            DashboardCard(model: model, entry: entry) { editing = entry.config }
                        }
                    }
                    .padding(20)
                }
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        Text("Numbers come from files on this Mac. Showing them never goes online.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Add Dashboard…") { editing = DashboardConfig.new() }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(.bar)
                }
                // The center watches the files' folders only while the cards are on screen.
                .onAppear { model.live?.setDashboardsVisible(true) }
                .onDisappear { model.live?.setDashboardsVisible(false) }
            }
        }
        .sheet(item: $editing) { config in
            DashboardEditor(config: config, automations: model.automations) { saved in
                model.live?.saveDashboard(saved)
                editing = nil
            } cancel: { editing = nil }
        }
    }
}

struct DashboardCard: View {
    @ObservedObject var model: AutomationsViewModel
    let entry: AutomationCenter.DashboardEntry
    var edit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.config.name).font(.title3.weight(.semibold)).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                freshnessChip
            }
            if let readings = entry.snapshot?.readings, !readings.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8, alignment: .top), GridItem(.flexible(), spacing: 8, alignment: .top)], spacing: 8) {
                    ForEach(readings, id: \.metric.id) { MetricTile(reading: $0) }
                }
            }
            if let problem = DashboardDisplay.problem(entry) {
                Label(problem, systemImage: entry.config.metrics.isEmpty ? "info.circle" : "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(entry.config.metrics.isEmpty ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Edit…", action: edit)
                if entry.config.openPath != nil { Button("Open File") { model.openDashboardFile(entry.id) } }
                if entry.config.automationID != nil || model.isDemo { Button("Refresh Now") { model.refreshDashboard(entry.id) } }
                Spacer()
                if let read = entry.readAt { Text("Read " + AutomationFormat.relative(read)).font(.caption).foregroundStyle(.tertiary) }
            }
            .controlSize(.small)
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }

    private var subtitle: String {
        (entry.config.filePath as NSString).abbreviatingWithTildeInPath
    }

    @ViewBuilder private var freshnessChip: some View {
        if let text = DashboardDisplay.freshnessText(entry) {
            let tint: Color = switch DashboardDisplay.freshness(entry) {
            case .fresh: .green
            case .aging: .orange
            case .stale: .red
            case .unknown: .gray
            }
            StatusChip(title: text, tint: tint, symbol: "circle.fill")
        }
    }
}

struct MetricTile: View {
    let reading: DashboardSnapshot.Reading
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(reading.metric.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(DashboardText.value(reading.value, metric: reading.metric))
                .font(reading.metric.format == .text ? .body.weight(.semibold) : .title3.weight(.semibold).monospacedDigit())
                .lineLimit(2)
                .foregroundStyle(reading.value == nil ? .secondary : .primary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

extension DashboardConfig {
    static func new() -> DashboardConfig {
        DashboardConfig(id: "dashboard-" + String(UUID().uuidString.prefix(6)).lowercased(), name: "", filePath: "")
    }
}
