import AVKit
import AppKit
import LauncherCore
import SwiftUI

/// The large preview on the right of the Clipboard view.
struct ClipPreview: View {
    let entry: ClipEntry
    @ObservedObject var page: ClipboardPage
    /// Selected rows; more than one shows a summary.
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)
            Divider()
            Group {
                if count > 1 { multiple } else { content }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: ClipStyle.symbol(entry)).font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(count > 1 ? "\(count) entries selected" : ClipStyle.kindLabel(entry)).font(.system(size: 13, weight: .semibold))
                HStack(spacing: 4) {
                    if let icon = ClipAppIcons.icon(entry.sourceBundleID) { Image(nsImage: icon).resizable().frame(width: 12, height: 12) }
                    Text(meta).lineLimit(1)
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if entry.pinned {
                Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(.orange).rotationEffect(.degrees(45)).help("Pinned")
            }
        }
    }

    private var meta: String {
        var parts: [String] = []
        if let name = entry.sourceName { parts.append("From \(name)") }
        parts.append(ClipStyle.relative(entry.copiedAt))
        return parts.joined(separator: " · ")
    }

    private var multiple: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Return copies them joined by new lines. ⇧Return pastes them one after another, in this order.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(page.selectedEntries) { item in
                        HStack(spacing: 8) {
                            ClipLeading(entry: item, thumbnails: page.history.thumbnails, size: 22)
                            Text(item.title).lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
    }

    @ViewBuilder private var content: some View {
        switch entry.kind {
        case .image: ClipImagePreview(entry: entry, page: page)
        case .color: ClipColorPreview(entry: entry, page: page)
        case .link: ClipLinkPreview(entry: entry, page: page)
        case .files: ClipFilesPreview(entry: entry, page: page)
        default: ClipTextPreview(entry: entry, page: page)
        }
    }
}

// MARK: Text

private struct ClipTextPreview: View {
    let entry: ClipEntry
    @ObservedObject var page: ClipboardPage
    @State private var full: String?
    @State private var rich: NSAttributedString?
    @State private var summary = ""

    /// Very long text shows its start; copying still uses all of it.
    private static let shownLimit = 60_000

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let rich {
                ClipRichText(text: rich).padding(.horizontal, 12).padding(.vertical, 8)
            } else {
                // Code keeps its lines and scrolls sideways; prose wraps.
                GeometryReader { geometry in
                    ScrollView(entry.kind == .code ? [.vertical, .horizontal] : .vertical) {
                        Text(verbatim: String(text.prefix(Self.shownLimit)))
                            .font(entry.kind == .code ? .system(size: 12, design: .monospaced) : .system(size: 14))
                            .lineSpacing(entry.kind == .code ? 2 : 3)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: entry.kind == .code, vertical: false)
                            .padding(18)
                            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                    }
                }
                .background(entry.kind == .code ? Color.primary.opacity(0.035) : Color.clear)
            }
            Divider()
            HStack {
                Text(summary).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if entry.hasRTF || entry.hasHTML { Text("Formatting kept").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 18).padding(.vertical, 6)
        }
        .task(id: entry.id) {
            if entry.textInBlob { full = await page.history.worker.fullText(entry) }
            let counted = text
            summary = await Task.detached(priority: .userInitiated) { ClipTransform.countSummary(counted) }.value
            if entry.hasRTF { rich = await ClipRichText.load(entry, worker: page.history.worker) }
        }
    }

    private var text: String { full ?? entry.text ?? "" }
}

/// Formatted text, drawn by AppKit so fonts and colours come through.
struct ClipRichText: NSViewRepresentable {
    let text: NSAttributedString

    static func load(_ entry: ClipEntry, worker: ClipboardWorker) async -> NSAttributedString? {
        // Only RTF is drawn formatted. HTML parsing blocks the main thread, so HTML-only entries show
        // plain text here; pasting still keeps their HTML.
        guard entry.hasRTF, let data = await worker.read(ClipEntry.Blob.rtf, for: entry.id) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            NSAttributedString(rtf: data, documentAttributes: nil)
        }.value
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.drawsBackground = false
            view.textContainerInset = NSSize(width: 6, height: 10)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.textStorage?.string != text.string else { return }
        view.textStorage?.setAttributedString(text)
    }
}

// MARK: Image

private struct ClipImagePreview: View {
    let entry: ClipEntry
    @ObservedObject var page: ClipboardPage
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                ClipCheckerboard().clipShape(RoundedRectangle(cornerRadius: 8))
                if let image = image ?? page.history.thumbnails.cached(entry.id) {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            HStack(spacing: 14) {
                if let info = entry.image {
                    ClipFact("Dimensions", "\(info.width) × \(info.height)")
                    ClipFact("Type", ClipStyle.typeName(info.uti) ?? "Image")
                    ClipFact("Size", ClipStyle.bytes(Int64(info.byteSize)))
                }
                Spacer()
            }
            if let ocr = entry.ocrText {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Text in image").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Text(ocr).font(.system(size: 12)).lineLimit(4).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
        .task(id: entry.id) { image = await page.history.thumbnails.preview(for: entry) }
    }
}

private struct ClipCheckerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 10
            for row in 0..<Int(size.height / cell) + 1 {
                for column in 0..<Int(size.width / cell) + 1 where (row + column) % 2 == 0 {
                    context.fill(Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
                                 with: .color(.primary.opacity(0.04)))
                }
            }
        }
    }
}

struct ClipFact: View {
    let label: String, value: String
    init(_ label: String, _ value: String) { self.label = label; self.value = value }
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12.5, weight: .medium)).monospacedDigit()
        }
    }
}

// MARK: Colour

private struct ClipColorPreview: View {
    let entry: ClipEntry
    @ObservedObject var page: ClipboardPage

    var body: some View {
        let parsed = entry.text.flatMap(ClipColor.parse)
        VStack(alignment: .leading, spacing: 16) {
            RoundedRectangle(cornerRadius: 14)
                .fill(ClipStyle.color(entry) ?? .clear)
                .background(ClipCheckerboard().clipShape(RoundedRectangle(cornerRadius: 14)))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.12)))
                .frame(maxWidth: .infinity).frame(height: 220)
            if let parsed {
                VStack(spacing: 0) {
                    row("HEX", parsed.hexString)
                    Divider()
                    row("RGB", parsed.rgbString)
                    Divider()
                    row("HSL", parsed.hslString)
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            }
            Spacer()
        }
        .padding(18)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
            Text(value).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
            Spacer()
            Button { page.copyNew(value, message: "\(value) copied.") } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help("Copy \(label)").accessibilityLabel("Copy \(label)")
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }
}

// MARK: Link

private struct ClipLinkPreview: View {
    let entry: ClipEntry
    @ObservedObject var page: ClipboardPage

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.12))
                    Image(systemName: "globe").font(.system(size: 26)).foregroundStyle(Color.accentColor)
                }
                .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.linkHost ?? "Link").font(.title2.weight(.semibold)).lineLimit(1)
                    Text(scheme).font(.callout).foregroundStyle(.secondary)
                }
            }
            Text(verbatim: entry.text ?? "")
                .font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            HStack {
                Button("Open Link") { page.open(entry) }
                Button("Copy as Markdown") {
                    let url = entry.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    page.copyNew("[\(entry.linkHost ?? url)](\(url))", message: "Markdown link copied.")
                }
            }
            Spacer()
        }
        .padding(18)
    }

    private var scheme: String {
        let text = entry.text ?? ""
        if text.hasPrefix("https://") { return "Secure web link" }
        return "Web link"
    }
}

// MARK: Files and media

private struct ClipFilesPreview: View {
    let entry: ClipEntry
    @ObservedObject var page: ClipboardPage

    var body: some View {
        if entry.files.count == 1, let file = entry.files.first {
            single(file)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(entry.files, id: \.path) { file in
                        ClipFileRow(file: file)
                        Divider()
                    }
                }
                .padding(18)
            }
        }
    }

    @ViewBuilder private func single(_ file: ClipFile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            switch file.category {
            case .video: ClipVideoPreview(entry: entry, file: file, thumbnails: page.history.thumbnails, worker: page.history.worker)
            case .audio: ClipAudioPreview(file: file, worker: page.history.worker)
            case .image, .pdf: ClipFileImage(entry: entry, page: page)
            default:
                ClipFileRow(file: file, large: true)
                Spacer()
            }
            HStack(spacing: 14) {
                ClipFact("Name", file.name)
                if let size = file.size { ClipFact("Size", ClipStyle.bytes(size)) }
                if let duration = file.duration { ClipFact("Duration", ClipStyle.duration(duration)) }
                Spacer()
            }
            Text(verbatim: (file.path as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .padding(18)
    }
}

private struct ClipFileImage: View {
    let entry: ClipEntry
    @ObservedObject var page: ClipboardPage
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            if let image = image ?? page.history.thumbnails.cached(entry.id) {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            } else {
                Image(systemName: ClipStyle.symbol(entry)).font(.system(size: 60)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: entry.id) { image = await page.history.thumbnails.preview(for: entry) }
    }
}

private struct ClipFileRow: View {
    let file: ClipFile
    var large = false
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: ClipFileIcons.icon(file)).resizable().frame(width: large ? 64 : 28, height: large ? 64 : 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(large ? .title3.weight(.semibold) : .system(size: 13)).lineLimit(1)
                Text(file.size.map(ClipStyle.bytes) ?? file.category.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }
}

/// File icons by path, looked up once. Missing files get their type's icon.
@MainActor
enum ClipFileIcons {
    private static var cache: [String: NSImage] = [:]
    static func icon(_ file: ClipFile) -> NSImage {
        if let hit = cache[file.path] { return hit }
        let icon: NSImage
        if FileManager.default.fileExists(atPath: file.path) {
            icon = NSWorkspace.shared.icon(forFile: file.path)
        } else {
            icon = NSWorkspace.shared.icon(for: file.uti.flatMap { UTType($0) } ?? .data)
        }
        if cache.count >= 300 { cache.removeAll() }
        cache[file.path] = icon
        return icon
    }
}

/// A poster frame with a play button. Plays inline, muted until the video is clicked.
private struct ClipVideoPreview: View {
    let entry: ClipEntry
    let file: ClipFile
    let thumbnails: ClipThumbnails
    let worker: ClipboardWorker
    @State private var wantsPlay = false
    @State private var poster: NSImage?
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.85))
            if let player {
                VideoPlayer(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .simultaneousGesture(TapGesture().onEnded { player.isMuted = false })
                    .overlay(alignment: .topTrailing) {
                        if player.isMuted {
                            Label("Muted. Click to hear it.", systemImage: "speaker.slash.fill")
                                .font(.caption).padding(6).background(.regularMaterial, in: Capsule()).padding(8)
                        }
                    }
            } else {
                if let poster = poster ?? thumbnails.cached(entry.id) {
                    Image(nsImage: poster).resizable().aspectRatio(contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 10))
                }
                Button { wantsPlay = true } label: {
                    Image(systemName: "play.fill").font(.system(size: 26)).foregroundStyle(.white)
                        .frame(width: 64, height: 64).background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain).help("Play").accessibilityLabel("Play video")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: entry.id) { poster = await thumbnails.preview(for: entry) }
        .task(id: wantsPlay) {
            guard wantsPlay, let url = await worker.resolveFiles([file]).first, !Task.isCancelled else { return }
            let player = AVPlayer(url: url)
            player.isMuted = true
            self.player = player
            player.play()
        }
        .onDisappear { wantsPlay = false; player?.pause() }
    }
}

private struct ClipAudioPreview: View {
    let file: ClipFile
    let worker: ClipboardWorker
    @State private var player: AVPlayer?
    @State private var playing = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "waveform").font(.system(size: 64)).foregroundStyle(Color.accentColor.opacity(0.8))
            Button {
                playing.toggle()
            } label: {
                Label(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill").frame(minWidth: 90)
            }
            .controlSize(.large)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: playing) {
            guard playing else { player?.pause(); return }
            if player == nil {
                guard let url = await worker.resolveFiles([file]).first, !Task.isCancelled else { playing = false; return }
                player = AVPlayer(url: url)
            }
            player?.play()
        }
        .onDisappear { playing = false; player?.pause() }
    }
}

import UniformTypeIdentifiers
