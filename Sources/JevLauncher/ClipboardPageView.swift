import AppKit
import LauncherCore
import SwiftUI

struct ClipboardPageView: View {
    @ObservedObject var page: ClipboardPage
    @ObservedObject var history: ClipboardHistory

    var body: some View {
        VStack(spacing: 0) {
            ClipChipBar(page: page, count: page.rows.count)
            Divider()
            if !history.isEnabled {
                ClipOffState(turnOn: page.turnOn)
            } else {
                HStack(spacing: 0) {
                    list.frame(width: 310)
                    Divider()
                    Group {
                        if let entry = page.selected {
                            ClipPreview(entry: entry, page: page, count: page.selectedEntries.count).id(entry.id)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(ClipAnchor { page.anchorView = $0 })
        .overlay(alignment: .bottom) {
            if let toast = page.toast {
                HStack(spacing: 10) {
                    Text(toast.text).font(.callout).lineLimit(3)
                    if toast.undo { Button("Undo") { page.undoDelete() }.buttonStyle(.link) }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator.opacity(0.5)))
                .padding(.bottom, 14)
                .onTapGesture { page.toast = nil }
                .task(id: toast.id) {
                    try? await Task.sleep(nanoseconds: toast.undo ? 8_000_000_000 : 4_000_000_000)
                    if page.toast?.id == toast.id { page.toast = nil }
                }
            }
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    let shortcuts = Dictionary(page.rows.prefix(9).enumerated().map { ($1.id, $0 + 1) }, uniquingKeysWith: { a, _ in a })
                    ForEach(page.rows) { entry in
                        ClipRow(entry: entry, thumbnails: history.thumbnails, shortcut: shortcuts[entry.id],
                                selected: page.selection.contains(entry.id), current: entry.id == page.cursor)
                            .id(entry.id)
                            .onTapGesture(count: 2) { page.select(entry.id); page.copy(page.selectedEntries) }
                            .onTapGesture { page.click(entry.id, modifiers: NSEvent.modifierFlags) }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityValue(page.selection.contains(entry.id) ? "Selected" : "")
                            .accessibilityAction { page.select(entry.id) }
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 8)
            }
            .overlay {
                if page.rows.isEmpty {
                    ClipEmptyState(chip: page.chip, loaded: history.loaded, hasHistory: !history.entries.isEmpty)
                }
            }
            .onChange(of: page.cursor) { _, id in if let id { proxy.scrollTo(id) } }
        }
    }
}

/// Filter chips and the entry count.
private struct ClipChipBar: View {
    @ObservedObject var page: ClipboardPage
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ClipFilter.allCases, id: \.self) { chip in
                Button { page.chip = chip } label: {
                    Text(chip.title)
                        .font(.system(size: 12, weight: page.chip == chip ? .semibold : .regular))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .foregroundStyle(page.chip == chip ? Color.white : Color.primary)
                        .background(Capsule().fill(page.chip == chip ? Color.accentColor : Color.primary.opacity(0.07)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 8)
            Text(count == 1 ? "1 entry" : "\(count.formatted()) entries").font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

struct ClipRow: View {
    let entry: ClipEntry
    let thumbnails: ClipThumbnails
    let shortcut: Int?
    var selected = false
    var current = false

    var body: some View {
        HStack(spacing: 10) {
            ClipLeading(entry: entry, thumbnails: thumbnails, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title.isEmpty ? " " : entry.title)
                    .font(entry.kind == .code ? .system(size: 12.5, design: .monospaced) : .system(size: 13))
                    .lineLimit(1).truncationMode(.tail)
                HStack(spacing: 4) {
                    if let icon = ClipAppIcons.icon(entry.sourceBundleID) {
                        Image(nsImage: icon).resizable().frame(width: 12, height: 12)
                    }
                    Text(detail).lineLimit(1)
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 3) {
                if entry.pinned {
                    Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(.orange).rotationEffect(.degrees(45))
                }
                if let shortcut { Text("⌘\(shortcut)").font(.system(size: 10)).foregroundStyle(.tertiary) }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(current ? 0.22 : 0.14) : .clear))
        .contentShape(Rectangle())
    }

    private var detail: String {
        var parts: [String] = []
        if let name = entry.sourceName { parts.append(name) }
        parts.append(ClipStyle.relative(entry.copiedAt))
        if let measure = ClipStyle.measure(entry) { parts.append(measure) }
        return parts.joined(separator: " · ")
    }
}

/// A row's thumbnail, colour swatch, or kind symbol.
struct ClipLeading: View {
    let entry: ClipEntry
    let thumbnails: ClipThumbnails
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let color = ClipStyle.color(entry) {
                RoundedRectangle(cornerRadius: 7).fill(color)
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.15)))
            } else if let image = image ?? thumbnails.cached(entry.id) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.1)))
                if entry.isMedia, entry.files.first?.category == .video {
                    Image(systemName: "play.fill").font(.system(size: 10)).foregroundStyle(.white).shadow(radius: 2)
                }
            } else {
                RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06))
                Image(systemName: ClipStyle.symbol(entry)).font(.system(size: size * 0.42)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .task(id: entry.id) {
            guard image == nil, entry.hasThumbnail || entry.kind == .image else { return }
            image = await thumbnails.thumbnail(for: entry)
        }
    }
}

private struct ClipEmptyState: View {
    let chip: ClipFilter
    let loaded: Bool
    let hasHistory: Bool
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard").font(.system(size: 28)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24)
    }
    private var title: String {
        if !loaded { return "Loading…" }
        if !hasHistory { return "Nothing copied yet" }
        return chip == .all ? "No matches" : "No \(chip.title.lowercased()) entries"
    }
    private var detail: String {
        if !loaded { return "" }
        if !hasHistory { return "Copy text, images, links, or files, and they show here." }
        return "Try another filter or clear the search."
    }
}

private struct ClipOffState: View {
    let turnOn: () -> Void
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "clipboard").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("Clipboard history is off").font(.title3.weight(.semibold))
            Text("Turn it on to keep what you copy: text, images, links, and files. It stays on this Mac.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            Button("Turn On Clipboard History", action: turnOn).controlSize(.large).keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Hands the page an AppKit view inside the panel, for menus and Quick Look.
private struct ClipAnchor: NSViewRepresentable {
    let found: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { found(view) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
