import LauncherCore
import SwiftUI

/// Settings › AI › Usage: Jev requests, tokens, and cost over 7 days, 30 days, and all time.
/// Counts come from TypeSafe's own usage figures in each reply and stay on this Mac.
struct UsageSettings: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var usage: JevUsageLog
    @State private var confirmReset = false

    private var periods: [(title: String, summary: JevUsageSummary)] {
        [("7 days", usage.summary(days: 7)), ("30 days", usage.summary(days: 30)), ("All time", usage.summary(days: nil))]
    }

    var body: some View {
        Group {
            Section {
                Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 10) {
                    GridRow {
                        Text("").gridColumnAlignment(.leading)
                        ForEach(periods, id: \.title) { Text($0.title).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary) }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    row("Cost") { JevPricing.format($0.cost) }
                    row("Requests") { $0.requests.formatted() }
                    row("Input tokens") { $0.inputTokens.formatted() }
                    row("Output tokens") { $0.outputTokens.formatted() }
                    row("Tokens per request") { $0.averageInputTokens.formatted() }
                    row("Jev picks") { $0.matches.formatted() }
                    row("Answered from memory") { $0.saved.formatted() }
                }
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
                InfoCaption("Estimated. Your TypeSafe console has the billed amount.",
                            detail: "Priced at $\(JevPricing.dollarsPerMillionInputTokens.formatted(.number.precision(.fractionLength(3)))) per million input tokens for jev-1.13.0. Output tokens are free.")
            } header: { Text("Jev usage") }

            Section {
                LabeledContent("Remembered requests") { Text(preferences.learned.entries.count.formatted()).monospacedDigit() }
                InfoCaption("Remembered picks need no Jev call.",
                            detail: "When you choose a result for a request, \(AppIdentity.name) remembers it on this Mac. The same request then needs no Jev call. Press ⌘Z on a remembered pick to forget it.")
                HStack {
                    Button("Forget all") { preferences.clearLearned() }.disabled(preferences.learned.entries.isEmpty)
                    Spacer()
                    Button("Reset usage…") { confirmReset = true }.disabled(usage.ledger.isEmpty)
                }
                .controlSize(.small)
            } header: { Text("Memory") }
        }
        .confirmationDialog("Reset Jev usage?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { usage.reset() }
        } message: {
            Text("This clears the counts on this Mac. It does not change your TypeSafe bill.")
        }
    }

    @ViewBuilder private func row(_ title: String, _ value: @escaping (JevUsageSummary) -> String) -> some View {
        GridRow {
            Text(title).gridColumnAlignment(.leading)
            ForEach(periods, id: \.title) { Text(value($0.summary)) }
        }
    }
}
