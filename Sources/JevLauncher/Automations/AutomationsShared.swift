import AppKit
import SwiftUI
import LauncherCore

/// A symbol in a tinted rounded square, like Settings and Shortcuts rows.
struct SymbolTile: View {
    let symbol: String
    var tint: Color = .accentColor
    var size: CGFloat = 28
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay { Image(systemName: symbol).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white) }
            .accessibilityHidden(true)
    }
}

enum AutomationTint {
    static let palette: [Color] = [.blue, .indigo, .purple, .pink, .orange, .teal, .green, .cyan, .mint, .brown]
    /// A stable colour per automation ID.
    static func color(_ id: String) -> Color {
        palette[Int(id.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value } % UInt32(palette.count))]
    }
}

extension RunState {
    var tint: Color {
        switch self {
        case .succeeded: return .green
        case .failed, .interrupted, .expired: return .red
        case .needsInput, .needsApproval: return .orange
        case .running, .applying, .queued, .retryWaiting: return .blue
        case .cancelled, .rejected: return .secondary
        }
    }
    var symbol: String {
        switch self {
        case .succeeded: return "checkmark.circle.fill"
        case .failed, .interrupted, .expired: return "xmark.octagon.fill"
        case .needsInput: return "questionmark.bubble.fill"
        case .needsApproval: return "hand.raised.fill"
        case .running, .applying: return "play.circle.fill"
        case .queued, .retryWaiting: return "clock.fill"
        case .cancelled, .rejected: return "minus.circle.fill"
        }
    }
}

/// A small coloured capsule with a state name.
struct StatusChip: View {
    let title: String
    let tint: Color
    var symbol: String?
    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .foregroundStyle(tint)
        .background(tint.opacity(0.14), in: Capsule())
        .fixedSize()
    }
}

extension StatusChip {
    init(_ state: RunState) { self.init(title: state.title, tint: state.tint, symbol: state.symbol) }
}

/// A centred message with one clear action.
struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.semibold))
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            if let actionTitle, let action {
                Button(actionTitle, action: action).controlSize(.large).padding(.top, 4)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A titled group with a light background, used in detail panes.
struct DetailCard<Content: View>: View {
    let title: String
    var symbol: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label { Text(title) } icon: { if let symbol { Image(systemName: symbol) } }
                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

/// A label and value pair in a detail card.
struct FactRow: View {
    let label: String
    let value: String
    var mono = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            Text(value).font(mono ? .system(.callout, design: .monospaced) : .callout)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }
}

enum AutomationFormat {
    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds >= 0 else { return "—" }
        if seconds < 60 { return "\(Int(seconds.rounded())) s" }
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds < 3600 ? [.minute, .second] : [.hour, .minute]
        f.unitsStyle = .abbreviated
        return f.string(from: seconds) ?? "—"
    }
    static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: now)
    }
    static func tokens(_ usage: TokenUsage?) -> String {
        guard let usage else { return "Unknown" }
        return usage.total.formatted() + " tokens"
    }
    static func trigger(_ trigger: RunTrigger) -> String {
        switch trigger { case .schedule: return "Scheduled"; case .manual: return "Manual"; case .test: return "Test run"; case .resume: return "Resumed" }
    }
    static func path(_ path: String?) -> String { path.map(Paths.display) ?? "—" }
}

extension Automation {
    var agent: AgentTask? {
        switch kind { case .agent(let a): return a; case .scriptWithDiagnosis(_, let a): return a; case .script: return nil }
    }
    var script: ScriptTask? {
        switch kind { case .script(let s): return s; case .scriptWithDiagnosis(let s, _): return s; case .agent: return nil }
    }
    var scheduleSummary: String { ScheduleText.summary(schedule) }
}

/// Finder icons, loaded off the main thread once per path.
@MainActor
final class FileIconCache {
    static let shared = FileIconCache()
    private var icons: [String: NSImage] = [:]
    func cached(_ path: String) -> NSImage? { icons[path] }
    func load(_ path: String) async -> NSImage {
        if let icon = icons[path] { return icon }
        let icon = await Task.detached(priority: .utility) { () -> NSImage in
            FileManager.default.fileExists(atPath: path)
                ? NSWorkspace.shared.icon(forFile: path)
                : NSWorkspace.shared.icon(for: .init(filenameExtension: URL(fileURLWithPath: path).pathExtension) ?? .item)
        }.value
        icons[path] = icon
        return icon
    }
}

struct FileIconView: View {
    let path: String
    var size: CGFloat = 22
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable() } else { Image(systemName: "doc").foregroundStyle(.tertiary) }
        }
        .frame(width: size, height: size)
        .task(id: path) { image = FileIconCache.shared.cached(path); if image == nil { image = await FileIconCache.shared.load(path) } }
        .accessibilityHidden(true)
    }
}

/// Markdown parsed once per run. Inline styles with line breaks kept, since SwiftUI `Text` flattens
/// block elements; plain text when parsing fails. Never HTML.
enum MarkdownText {
    static func render(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
