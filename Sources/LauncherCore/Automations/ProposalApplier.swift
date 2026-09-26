import Foundation

/// Applies approved items from a checked manifest, one at a time, with a durable journal.
/// Never overwrites and never deletes permanently.
public struct ProposalApplier {
    public let manifest: ProposalManifest
    public let approved: Set<String>
    public let journalURL: URL

    public init(manifest: ProposalManifest, approved: Set<String>, journalURL: URL) {
        self.manifest = manifest; self.approved = approved; self.journalURL = journalURL
    }

    typealias Entry = ApplyJournal.Entry

    /// Result of one step. `.failed` stops the run.
    enum Outcome { case done, skipped(String), failed(String) }

    public func apply() -> ApplyJournal {
        var journal = ApplyJournal(digest: manifest.digest, approvedItems: approved.sorted())
        let byID = Dictionary(manifest.checked.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Manifest order, so the user sees the same order they approved.
        let order = manifest.proposal.items.map(\.id).filter { approved.contains($0) }
        // Folders made earlier in this apply, by folded path, so later moves can go into them.
        var created: [String: (device: UInt64, inode: UInt64)] = [:]
        for id in order {
            guard let item = byID[id] else {
                var e = Entry(itemID: id, op: manifest.proposal.items.first { $0.id == id }?.op ?? .move, source: "", destination: nil, status: .skipped)
                e.message = manifest.refused[id] ?? "Not in the checked list"
                journal.entries.append(e)
                continue
            }
            var entry = Entry(itemID: id, op: item.item.op, source: item.source, destination: item.destination, status: .intended)
            journal.entries.append(entry)
            let index = journal.entries.count - 1
            guard save(journal) else {
                journal.entries[index].status = .failed
                journal.entries[index].message = "Could not write the journal. Nothing was changed."
                break
            }
            let outcome = run(item, entry: &entry, created: &created)
            journal.entries[index] = entry
            var stop = false
            switch outcome {
            case .done: journal.entries[index].status = .done
            case .skipped(let m): journal.entries[index].status = .skipped; journal.entries[index].message = m
            case .failed(let m): journal.entries[index].status = .failed; journal.entries[index].message = m; stop = true
            }
            _ = save(journal)
            if stop { break }
        }
        journal.finished = Date()
        _ = save(journal)
        return journal
    }

    public func undo(journal: ApplyJournal) -> ApplyJournal {
        var journal = journal
        let byID = Dictionary(manifest.checked.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for index in journal.entries.indices.reversed() where journal.entries[index].status == .done {
            let entry = journal.entries[index]
            let result: Outcome
            if let item = byID[entry.itemID] { result = undoStep(entry, item: item) } else { result = .failed("Item is not in the manifest") }
            switch result {
            case .done: journal.entries[index].status = .undone; journal.entries[index].message = nil
            case .skipped(let m), .failed(let m): journal.entries[index].status = .undoBlocked; journal.entries[index].message = m
            }
            _ = save(journal)
        }
        return journal
    }

    private func save(_ journal: ApplyJournal) -> Bool {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(journal) else { return false }
        return (try? SafeFS.writeDurably(data, to: journalURL)) != nil
    }

    // MARK: Apply steps

    private func run(_ c: CheckedItem, entry: inout Entry, created: inout [String: (device: UInt64, inode: UInt64)]) -> Outcome {
        switch c.item.op {
        case .move, .rename:
            guard let dst = c.destination, var parentID = c.parentIdentity else { return .failed("Checked item is incomplete") }
            // A destination folder made by this proposal: expect the folder this apply created.
            if parentID.inode == 0 {
                guard let made = created[SafeFS.folded(SafeFS.parent(dst))] else { return .skipped("Its new folder was not created") }
                parentID.device = made.device; parentID.inode = made.inode
            }
            return withSource(c) { srcFD, srcLeaf in
                withDir(SafeFS.parent(dst), expect: parentID) { dstFD in
                    guard SafeFS.statAt(dstFD, SafeFS.leaf(dst)) == nil else { return .skipped("Destination now exists") }
                    guard renameatx_np(srcFD, srcLeaf, dstFD, SafeFS.leaf(dst), UInt32(RENAME_EXCL)) == 0 else { return .failed(errorText()) }
                    return .done
                }
            }
        case .mkdir:
            guard let parentID = c.parentIdentity else { return .failed("Checked item is incomplete") }
            return withDir(SafeFS.parent(c.source), expect: parentID) { fd in
                guard mkdirat(fd, SafeFS.leaf(c.source), 0o755) == 0 else {
                    return errno == EEXIST ? .skipped("Folder now exists") : .failed(errorText())
                }
                if let st = SafeFS.statAt(fd, SafeFS.leaf(c.source)) {
                    entry.createdInode = UInt64(st.st_ino)
                    created[SafeFS.folded(c.source)] = (UInt64(st.st_dev), UInt64(st.st_ino))
                }
                return .done
            }
        case .trash:
            return withSource(c) { _, _ in
                do {
                    var result: NSURL?
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: c.source), resultingItemURL: &result)
                    entry.trashURL = result?.path
                    return .done
                } catch {
                    return .failed("Could not move to Trash: \(error.localizedDescription)")
                }
            }
        case .tag:
            return withSource(c) { _, _ in
                let url = URL(fileURLWithPath: c.source)
                entry.previousTags = (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
                do { try setTags(c.item.tags ?? [], on: url); return .done } catch { return .failed("Could not set tags: \(error.localizedDescription)") }
            }
        }
    }

    /// Opens the source's parent without following links, and checks the source is the object seen at approval.
    private func withSource(_ c: CheckedItem, _ body: (Int32, String) -> Outcome) -> Outcome {
        guard let fd = SafeFS.openDirectory(SafeFS.parent(c.source)) else { return .skipped("Source folder changed or is missing") }
        defer { close(fd) }
        let leaf = SafeFS.leaf(c.source)
        guard let st = SafeFS.statAt(fd, leaf) else { return .skipped("Source is missing") }
        guard SafeFS.sameObject(SafeFS.identity(st), c.identity) else { return .skipped("Source changed since approval") }
        return body(fd, leaf)
    }

    private func withDir(_ path: String, expect: FileIdentity, _ body: (Int32) -> Outcome) -> Outcome {
        guard let fd = SafeFS.openDirectory(path) else { return .skipped("Destination folder changed or is missing") }
        defer { close(fd) }
        guard let st = SafeFS.fstatFD(fd), SafeFS.identity(st).device == expect.device, UInt64(st.st_ino) == expect.inode else {
            return .skipped("Destination folder changed since approval")
        }
        return body(fd)
    }

    // MARK: Undo steps

    private func undoStep(_ e: Entry, item c: CheckedItem) -> Outcome {
        switch e.op {
        case .move, .rename:
            guard let dst = e.destination else { return .failed("Journal entry has no destination") }
            return moveBack(from: dst, to: e.source, inode: c.identity.inode)
        case .trash:
            guard let trash = e.trashURL else { return .failed("Trash location unknown. Restore it from the Trash by hand.") }
            return moveBackFromTrash(trash, to: e.source, inode: c.identity.inode)
        case .mkdir:
            guard let fd = SafeFS.openDirectory(SafeFS.parent(e.source)) else { return .failed("Parent folder changed or is missing") }
            defer { close(fd) }
            let leaf = SafeFS.leaf(e.source)
            guard let st = SafeFS.statAt(fd, leaf), st.st_mode & S_IFMT == S_IFDIR else { return .failed("Folder is gone or replaced") }
            if let inode = e.createdInode, UInt64(st.st_ino) != inode { return .failed("Folder was replaced") }
            removeFinderMetadata(in: fd, leaf, inode: UInt64(st.st_ino))
            // rmdir only removes an empty folder.
            guard unlinkat(fd, leaf, AT_REMOVEDIR) == 0 else {
                return .failed(errno == ENOTEMPTY ? "Folder is not empty" : errorText())
            }
            return .done
        case .tag:
            guard let fd = SafeFS.openDirectory(SafeFS.parent(e.source)) else { return .failed("Folder changed or is missing") }
            defer { close(fd) }
            guard let st = SafeFS.statAt(fd, SafeFS.leaf(e.source)), UInt64(st.st_ino) == c.identity.inode else { return .failed("Item changed or is missing") }
            do { try setTags(e.previousTags ?? [], on: URL(fileURLWithPath: e.source)); return .done } catch { return .failed("Could not restore tags: \(error.localizedDescription)") }
        }
    }

    /// Moves an applied object back, only if it is still the same inode and the original place is empty.
    private func moveBack(from current: String, to original: String, inode: UInt64) -> Outcome {
        guard let curFD = SafeFS.openDirectory(SafeFS.parent(current)) else { return .failed("Current folder changed or is missing") }
        defer { close(curFD) }
        guard let st = SafeFS.statAt(curFD, SafeFS.leaf(current)), UInt64(st.st_ino) == inode else { return .failed("Item was moved or replaced") }
        guard let origFD = SafeFS.openDirectory(SafeFS.parent(original)) else { return .failed("Original folder changed or is missing") }
        defer { close(origFD) }
        guard SafeFS.statAt(origFD, SafeFS.leaf(original)) == nil else { return .failed("Something now exists at the original place") }
        guard renameatx_np(curFD, SafeFS.leaf(current), origFD, SafeFS.leaf(original), UInt32(RENAME_EXCL)) == 0 else {
            return .failed(errno == EXDEV ? "Item is on another volume. Move it back by hand." : errorText())
        }
        return .done
    }

    /// macOS privacy protection refuses to open `~/.Trash` itself, but a known item in it can still be
    /// checked and renamed by path. The inode check and the no-overwrite rename keep this safe.
    private func moveBackFromTrash(_ current: String, to original: String, inode: UInt64) -> Outcome {
        var st = stat()
        guard lstat(current, &st) == 0 else { return .failed("It is no longer in the Trash") }
        guard UInt64(st.st_ino) == inode, st.st_mode & S_IFMT == S_IFREG else { return .failed("The item in the Trash was replaced") }
        guard let origFD = SafeFS.openDirectory(SafeFS.parent(original)) else { return .failed("Original folder changed or is missing") }
        defer { close(origFD) }
        guard SafeFS.statAt(origFD, SafeFS.leaf(original)) == nil else { return .failed("Something now exists at the original place") }
        guard renameatx_np(AT_FDCWD, current, origFD, SafeFS.leaf(original), UInt32(RENAME_EXCL)) == 0 else {
            return .failed(errno == EXDEV ? "Item is on another volume. Put it back from the Trash." : errorText())
        }
        return .done
    }

    /// Finder may write `.DS_Store` into a folder it showed. When that is the only thing inside, remove it so the folder can go.
    private func removeFinderMetadata(in parentFD: Int32, _ leaf: String, inode: UInt64) {
        let dirFD = openat(parentFD, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dirFD >= 0 else { return }
        defer { close(dirFD) }
        guard let st = SafeFS.fstatFD(dirFD), UInt64(st.st_ino) == inode, let names = SafeFS.names(inDirectory: dirFD),
              names == [".DS_Store"], let file = SafeFS.statAt(dirFD, ".DS_Store"), file.st_mode & S_IFMT == S_IFREG else { return }
        unlinkat(dirFD, ".DS_Store", 0)
    }

    private func setTags(_ tags: [String], on url: URL) throws {
        try (url as NSURL).setResourceValue(tags as NSArray, forKey: .tagNamesKey)
    }

    private func errorText() -> String { String(cString: strerror(errno)) }
}
