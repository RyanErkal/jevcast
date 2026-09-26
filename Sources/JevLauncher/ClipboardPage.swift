import AppKit
import Combine
import LauncherCore
import SwiftUI

/// The Clipboard view: chips and the list on the left, the selected entry large on the right.
/// ↑↓ move, ⇧↑↓ select more, Return copies, ⇧Return pastes, ⌥Return pastes plain text,
/// ⌘P pins, ⌫ deletes (⌘Z brings it back), Space is Quick Look, ⌘K shows actions, and ⌘1…⌘9
/// paste that row. ← and → change the chip while the filter is empty.
@MainActor
final class ClipboardPage: ObservableObject, LauncherPage {
    struct Toast: Equatable {
        var text: String
        var undo = false
        var id = UUID()
    }

    let id = ViewID.clipboard
    let history: ClipboardHistory
    private weak var model: LauncherModel?
    @Published var chip: ClipFilter = .all { didSet { if chip != oldValue { refresh() } } }
    @Published private(set) var rows: [ClipEntry] = []
    /// The row the keys act on.
    @Published private(set) var cursor: UUID?
    /// Selected rows. More than one after ⇧↑ or ⇧↓.
    @Published var selection: Set<UUID> = [] {
        didSet {
            guard selection != oldValue else { return }
            if let cursor, selection.contains(cursor) { return }
            cursor = rows.first { selection.contains($0.id) }?.id
        }
    }
    @Published var toast: Toast?
    private var text = ""
    private var anchor: UUID?
    private var watch: AnyCancellable?
    private let quickLook = FilePreview()
    private var quickLookFile: URL?
    /// A view inside the panel, for the actions menu and Quick Look.
    weak var anchorView: NSView?
    let actions = ClipboardActions()

    init(history: ClipboardHistory, model: LauncherModel) {
        self.history = history; self.model = model
    }

    var selected: ClipEntry? { rows.first { $0.id == cursor } }
    /// Selected rows in list order.
    var selectedEntries: [ClipEntry] {
        let picked = rows.filter { selection.contains($0.id) }
        return picked.isEmpty ? (selected.map { [$0] } ?? []) : picked
    }
    var isOn: Bool { history.isEnabled }
    var openTitle: String { "Copy" }
    /// Fixed, because the launcher footer does not redraw on each selection.
    var footerHints: [(title: String, key: String)] {
        guard isOn else { return [] }
        return [("Actions", "⌘K"), ("Pin", "⌘P"), ("Plain Text", "⌥↩"), ("Paste", "⇧↩")]
    }

    func opened() {
        watch = history.$entries.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }
        refresh()
    }
    func closed(handingOff: Bool) {
        watch = nil
        closeQuickLook()
        actions.dismiss()
    }

    func filter(_ text: String) {
        self.text = text
        refresh()
        if let first = rows.first { move(to: first.id) }
    }

    func refresh() {
        rows = history.matches(text, chip: chip)
        let ids = Set(rows.map(\.id))
        let kept = selection.intersection(ids)
        if let cursor, ids.contains(cursor) {
            if kept != selection { selection = kept.isEmpty ? [cursor] : kept }
        } else if let first = rows.first {
            move(to: first.id)
        } else {
            cursor = nil; selection = []
        }
    }

    func select(_ id: UUID) { move(to: id) }

    /// A click selects one row; ⇧ selects a range and ⌘ adds or removes a row.
    func click(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if selection.contains(id), selection.count > 1 { selection.remove(id) } else { selection.insert(id); cursor = id }
        } else if modifiers.contains(.shift), let anchorIndex = rows.firstIndex(where: { $0.id == (anchor ?? cursor) }),
                  let index = rows.firstIndex(where: { $0.id == id }) {
            cursor = id
            selection = Set(rows[min(anchorIndex, index)...max(anchorIndex, index)].map(\.id))
        } else {
            move(to: id)
        }
    }

    private func move(to id: UUID) {
        cursor = id; anchor = id; selection = [id]
        if quickLook.isVisible { Task { await updateQuickLook() } }
    }

    private func step(_ delta: Int, extend: Bool) {
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == cursor } ?? -1
        let next = rows[min(max(index + delta, 0), rows.count - 1)]
        guard extend else { move(to: next.id); return }
        let anchorIndex = rows.firstIndex { $0.id == (anchor ?? cursor) } ?? 0
        let nextIndex = rows.firstIndex { $0.id == next.id } ?? 0
        cursor = next.id
        selection = Set(rows[min(anchorIndex, nextIndex)...max(anchorIndex, nextIndex)].map(\.id))
    }

    func cycleChip(_ delta: Int) {
        let all = ClipFilter.allCases
        let index = all.firstIndex(of: chip) ?? 0
        chip = all[(index + delta + all.count) % all.count]
    }

    // MARK: Keys

    func handle(_ key: PageKey) -> Bool {
        guard isOn else { return key != .delete }
        switch key {
        case .down: step(1, extend: false)
        case .up: step(-1, extend: false)
        case .left: cycleChip(-1)
        case .right: cycleChip(1)
        case .open(let shift): shift ? paste(selectedEntries, plain: false) : copy(selectedEntries)
        case .delete: delete()
        }
        return true
    }

    /// Keys with modifiers, and Space. Runs before the plain keys.
    func handleEvent(_ event: NSEvent) -> Bool {
        guard isOn else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let queryEmpty = model?.query.isEmpty ?? true
        switch (event.keyCode, flags) {
        case (125, [.shift]): step(1, extend: true); return true
        case (126, [.shift]): step(-1, extend: true); return true
        case (36, [.option]), (76, [.option]): paste(selectedEntries, plain: true); return true
        case (35, [.command]): togglePin(); return true
        case (40, [.command]): showActions(); return true
        case (6, [.command]):
            // ⌘Z brings back deleted rows while the filter is empty; otherwise the filter keeps its own undo.
            guard history.canUndoDelete, queryEmpty else { return false }
            undoDelete(); return true
        case (49, []) where queryEmpty: toggleQuickLook(); return true
        case (let code, [.command]):
            guard let number = Self.digitKeys.firstIndex(of: code) else { return false }
            guard number < rows.count else { return true }
            paste([rows[number]], plain: false)
            return true
        default: return false
        }
    }
    static let digitKeys: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    func back() -> Bool {
        if actions.isShowing { actions.dismiss(); return true }
        if quickLook.isVisible { closeQuickLook(); return true }
        if selection.count > 1, let cursor { move(to: cursor); return true }
        return false
    }

    // MARK: Actions

    func copy(_ entries: [ClipEntry]) {
        guard !entries.isEmpty else { return }
        Task {
            guard await history.restore(entries) else { show("This entry could not be copied. Its file may have moved."); return }
            model?.onClose?(true)
        }
    }

    /// Pastes into the app that was in front. Several entries paste one after another, in list order.
    func paste(_ entries: [ClipEntry], plain: Bool) {
        guard !entries.isEmpty else { return }
        let history = history
        Task {
            guard entries.count > 1, AXIsProcessTrusted() else {
                guard await history.restore(entries, plain: plain) else { show(plain ? "This entry has no text." : "This entry could not be copied."); return }
                model?.onClose?(true)
                Paster.pasteSoon()
                return
            }
            model?.onClose?(true)
            try? await Task.sleep(nanoseconds: 200_000_000)
            for entry in entries {
                guard await history.restore([entry], plain: plain) else { continue }
                TextInserter.postPaste()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    func togglePin() {
        let entries = selectedEntries
        guard !entries.isEmpty else { return }
        let pin = entries.contains { !$0.pinned }
        for entry in entries where entry.pinned != pin { history.togglePin(entry.id) }
    }

    func delete() {
        let entries = selectedEntries
        guard !entries.isEmpty else { return }
        let index = rows.firstIndex { $0.id == entries.first?.id } ?? 0
        let ids = Set(entries.map(\.id))
        let after = rows.filter { !ids.contains($0.id) }
        history.delete(ids)
        if !after.isEmpty { move(to: after[min(index, after.count - 1)].id) }
        toast = Toast(text: entries.count == 1 ? "Deleted. Press ⌘Z to undo." : "Deleted \(entries.count) entries. Press ⌘Z to undo.", undo: true)
    }

    func undoDelete() {
        let restored = history.undoDelete()
        refresh()
        if let first = restored.first { move(to: first.id) }
        toast = nil
    }

    func show(_ message: String) { toast = Toast(text: message) }

    /// Runs a text transform and copies the result as a new entry. Count only shows its result.
    func transform(_ transform: ClipTransform) {
        guard let entry = selected, entry.kind.isText else { return }
        Task {
            guard let text = await history.worker.fullText(entry) else { return }
            do {
                let result = try transform.apply(text)
                guard transform.makesEntry else { show(result); return }
                let added = await history.addText(result)
                if chip != .all, let added, !chip.includes(added) { chip = .all }
                refresh()
                if let added { move(to: added.id) }
                show("\(transform.title): copied as a new entry.")
            } catch let error as ClipTransformError {
                show(error.message)
            } catch {
                show("The text could not be changed.")
            }
        }
    }

    /// Copies text made from an entry, such as text found in an image, as a new entry.
    func copyNew(_ text: String, message: String) {
        Task {
            let added = await history.addText(text)
            refresh()
            if let added { move(to: added.id) }
            show(message)
        }
    }

    func saveImageToDownloads() {
        guard let entry = selected, entry.isImage else { return }
        let worker = history.worker
        Task {
            let payload = await worker.payload(for: entry, plain: false)
            var data = payload?.data.first { $0.type == "public.png" }?.data
            if data == nil, let file = payload?.fileURLs.first {
                data = await Task.detached { (try? Data(contentsOf: file)).flatMap(ClipboardCapture.png) }.value
            }
            guard let data else { show("The image could not be saved."); return }
            let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: ".")
            let folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
            let url = folder.appendingPathComponent("Clipboard Image \(stamp).png")
            let saved = await Task.detached { (try? data.write(to: url, options: .withoutOverwriting)) != nil }.value
            show(saved ? "Saved to Downloads as \(url.lastPathComponent)." : "The image could not be saved.")
        }
    }

    func open(_ entry: ClipEntry) {
        switch entry.kind {
        case .files:
            let urls = entry.files.compactMap(ClipboardWorker.resolve)
            guard !urls.isEmpty else { show("The file was moved or deleted."); return }
            for url in urls { _ = Frontmost.open(url) }
            model?.onClose?(false)
        case .link:
            guard let text = entry.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let url = URL(string: text.hasPrefix("www.") ? "https://" + text : text) else { return }
            _ = Frontmost.open(url)
            model?.onClose?(false)
        default: break
        }
    }

    func reveal(_ entry: ClipEntry) {
        let urls = entry.files.compactMap(ClipboardWorker.resolve)
        guard !urls.isEmpty else { show("The file was moved or deleted."); return }
        Frontmost.reveal(urls)
        model?.onClose?(false)
    }

    func showActions() {
        guard let entry = selected, let view = anchorView else { return }
        actions.show(for: entry, count: selectedEntries.count, page: self, in: view)
    }

    // MARK: Quick Look

    func toggleQuickLook() {
        if quickLook.isVisible { closeQuickLook(); return }
        Task { await openQuickLook() }
    }

    private func quickLookURL(for entry: ClipEntry) async -> URL? {
        switch entry.kind {
        case .files: return entry.files.first.flatMap(ClipboardWorker.resolve)
        case .image:
            if let url = await history.worker.fileURL(ClipEntry.Blob.image, for: entry.id) {
                // The blob has no extension; Quick Look needs one, so a linked copy is made in a private temp folder.
                return temporaryCopy(of: url, entry: entry)
            }
            guard let data = await history.worker.read(ClipEntry.Blob.image, for: entry.id) else { return nil }
            return temporaryFile(data, entry: entry)
        default:
            // Text shows in the preview pane; it is not written to a file.
            return nil
        }
    }

    private static var temporaryFolder: URL { ClipboardStore.previewFolder }

    private func temporaryFile(_ data: Data, entry: ClipEntry, ext: String? = nil) -> URL? {
        let folder = Self.temporaryFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let suffix = ext ?? (entry.image.flatMap { UTType($0.uti)?.preferredFilenameExtension } ?? "png")
        let url = folder.appendingPathComponent("\(entry.id.uuidString).\(suffix)")
        if let quickLookFile, quickLookFile != url { try? FileManager.default.removeItem(at: quickLookFile) }
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return nil }
        quickLookFile = url
        return url
    }

    private func temporaryCopy(of blob: URL, entry: ClipEntry) -> URL? {
        guard let data = try? Data(contentsOf: blob) else { return nil }
        return temporaryFile(data, entry: entry)
    }

    private func openQuickLook() async {
        guard let entry = selected, let window = anchorView?.window, let url = await quickLookURL(for: entry) else { return }
        quickLook.toggle(path: url.path, beside: window)
    }

    private func updateQuickLook() async {
        guard let entry = selected, let url = await quickLookURL(for: entry) else { closeQuickLook(); return }
        quickLook.update(path: url.path)
    }

    private func closeQuickLook() {
        quickLook.close()
        if let quickLookFile { try? FileManager.default.removeItem(at: quickLookFile) }
        quickLookFile = nil
    }

    func turnOn() { model?.preferences.clipboardHistory = true; refresh() }

    func content() -> AnyView { AnyView(ClipboardPageView(page: self, history: history)) }
}

import UniformTypeIdentifiers
