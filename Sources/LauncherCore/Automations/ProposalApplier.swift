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
            guard save(journal) else {
                journal.entries[index].status = .failed
                journal.entries[index].message = "The change ran, but its result could not be saved. Check the files before continuing."
                return journal
            }
            if stop { break }
        }
        journal.finished = Date()
        _ = save(journal)
        return journal
    }

    public func undo(journal: ApplyJournal) -> ApplyJournal {
        var journal = journal
        guard journal.digest == manifest.digest else { return journal }
        let byID = Dictionary(manifest.checked.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for index in journal.entries.indices.reversed() where journal.entries[index].status == .done {
            let entry = journal.entries[index]
            let result: Outcome
            if let item = byID[entry.itemID] { result = undoStep(entry, item: item) } else { result = .failed("Item is not in the manifest") }
            switch result {
            case .done: journal.entries[index].status = .undone; journal.entries[index].message = nil
            case .skipped(let m), .failed(let m): journal.entries[index].status = .undoBlocked; journal.entries[index].message = m
            }
            guard save(journal) else {
                journal.entries[index].message = "Undo stopped because its result could not be saved. Check the files before continuing."
                break
            }
        }
        return journal
    }

    private func save(_ journal: ApplyJournal) -> Bool {
        let encoder = AutomationJSON.encoder()
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
            return withSourceFile(c) { parentFD, leaf, _, verified in
                var result: NSURL?
                do {
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: c.source), resultingItemURL: &result)
                } catch {
                    return .failed("Could not move to Trash: \(error.localizedDescription)")
                }
                guard let trashed = result?.path else { return .failed("The Trash did not report where it put the item. Check the Trash.") }
                entry.trashURL = trashed
                // The path could have named another object between the check and the move. Confirm the Trash got the checked one.
                if let st = SafeFS.lstatPath(trashed), UInt64(bitPattern: Int64(st.st_dev)) == verified.device, UInt64(st.st_ino) == verified.inode {
                    return .done
                }
                return .failed("A different item than the approved one went to the Trash. " + putBackFromTrash(trashed, parentFD: parentFD, leaf: leaf))
            }
        case .tag:
            return withSourceFile(c) { _, _, fd, _ in
                // Read and write through the checked descriptor, so the change reaches the approved object.
                let previous: [String]
                switch UserTags.read(fd) {
                case .success(let tags): previous = tags
                case .failure(let why): return .failed("Could not read tags: \(why)")
                }
                entry.previousTags = previous
                if let why = UserTags.write(c.item.tags ?? [], to: fd) { return .failed("Could not set tags: \(why)") }
                return .done
            }
        }
    }

    /// Opens the source's parent without following links, and checks the source is the object seen at approval.
    private func withSource(_ c: CheckedItem, _ body: (Int32, String) -> Outcome) -> Outcome {
        guard let fd = SafeFS.openDirectory(SafeFS.parent(c.source)) else { return .skipped("Source folder changed or is missing") }
        defer { close(fd) }
        let leaf = SafeFS.leaf(c.source)
        guard let st = SafeFS.statAt(fd, leaf) else { return .skipped("Source is missing") }
        guard (st.st_mode & S_IFMT == S_IFDIR || st.st_nlink == 1),
              SafeFS.sameObject(SafeFS.identity(st), c.identity) else { return .skipped("Source changed since approval") }
        return body(fd, leaf)
    }

    /// As `withSource`, and also opens the source itself without following links, relative to the checked
    /// parent, and checks the open object's identity. `body` gets the parent, the leaf, the object, and its identity.
    private func withSourceFile(_ c: CheckedItem, _ body: (Int32, String, Int32, FileIdentity) -> Outcome) -> Outcome {
        withSource(c) { parentFD, leaf in
            // O_NONBLOCK: a special file swapped in must not hang the open.
            let fd = openat(parentFD, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return .skipped(errno == ELOOP ? "Source is now a symbolic link" : "Source changed since approval") }
            defer { close(fd) }
            guard let st = SafeFS.fstatFD(fd), (st.st_mode & S_IFMT == S_IFDIR || st.st_mode & S_IFMT == S_IFREG),
                  (st.st_mode & S_IFMT == S_IFDIR || st.st_nlink == 1),
                  SafeFS.sameObject(SafeFS.identity(st), c.identity) else { return .skipped("Source changed since approval") }
            return body(parentFD, leaf, fd, SafeFS.identity(st))
        }
    }

    /// Moves an item the Trash took by mistake back to where it was. Never deletes and never overwrites.
    private func putBackFromTrash(_ trashed: String, parentFD: Int32, leaf: String) -> String {
        if SafeFS.statAt(parentFD, leaf) == nil,
           renameatx_np(AT_FDCWD, trashed, parentFD, leaf, UInt32(RENAME_EXCL)) == 0 {
            return "It was moved back. Nothing else changed."
        }
        return "It could not be moved back (\(errorText())). Restore \((trashed as NSString).lastPathComponent) from the Trash by hand."
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
        guard e.op == c.item.op, e.source == c.source, e.destination == c.destination else {
            return .failed("Journal does not match the approved item")
        }
        switch e.op {
        case .move, .rename:
            guard let dst = e.destination else { return .failed("Journal entry has no destination") }
            return moveBack(from: dst, to: e.source, identity: c.identity)
        case .trash:
            guard let trash = e.trashURL else { return .failed("Trash location unknown. Restore it from the Trash by hand.") }
            return moveBackFromTrash(trash, to: e.source, identity: c.identity)
        case .mkdir:
            guard let fd = SafeFS.openDirectory(SafeFS.parent(e.source)) else { return .failed("Parent folder changed or is missing") }
            defer { close(fd) }
            let leaf = SafeFS.leaf(e.source)
            guard let st = SafeFS.statAt(fd, leaf), st.st_mode & S_IFMT == S_IFDIR else { return .failed("Folder is gone or replaced") }
            guard let inode = e.createdInode, UInt64(st.st_ino) == inode,
                  SafeFS.identity(st).device == c.identity.device else { return .failed("Folder was replaced or its identity is missing") }
            removeFinderMetadata(in: fd, leaf, inode: UInt64(st.st_ino))
            // rmdir only removes an empty folder.
            guard unlinkat(fd, leaf, AT_REMOVEDIR) == 0 else {
                return .failed(errno == ENOTEMPTY ? "Folder is not empty" : errorText())
            }
            return .done
        case .tag:
            guard let dirFD = SafeFS.openDirectory(SafeFS.parent(e.source)) else { return .failed("Folder changed or is missing") }
            defer { close(dirFD) }
            let fd = openat(dirFD, SafeFS.leaf(e.source), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return .failed("Item or tags changed since apply") }
            defer { close(fd) }
            guard let st = SafeFS.fstatFD(fd), SafeFS.sameObject(SafeFS.identity(st), c.identity),
                  (st.st_mode & S_IFMT == S_IFDIR || st.st_nlink == 1),
                  case .success(let tags) = UserTags.read(fd),
                  Set(tags.map(UserTags.name)) == Set(c.item.tags ?? []) else { return .failed("Item or tags changed since apply") }
            if let why = UserTags.write(e.previousTags ?? [], to: fd) { return .failed("Could not restore tags: \(why)") }
            return .done
        }
    }

    /// Moves an applied object back, only if it is still the same unchanged object and the original place is empty.
    private func moveBack(from current: String, to original: String, identity: FileIdentity) -> Outcome {
        guard let curFD = SafeFS.openDirectory(SafeFS.parent(current)) else { return .failed("Current folder changed or is missing") }
        defer { close(curFD) }
        guard let st = SafeFS.statAt(curFD, SafeFS.leaf(current)), st.st_nlink == 1, SafeFS.sameObject(SafeFS.identity(st), identity) else { return .failed("Item was changed, moved or replaced") }
        guard let origFD = SafeFS.openDirectory(SafeFS.parent(original)) else { return .failed("Original folder changed or is missing") }
        defer { close(origFD) }
        guard SafeFS.statAt(origFD, SafeFS.leaf(original)) == nil else { return .failed("Something now exists at the original place") }
        guard renameatx_np(curFD, SafeFS.leaf(current), origFD, SafeFS.leaf(original), UInt32(RENAME_EXCL)) == 0 else {
            return .failed(errno == EXDEV ? "Item is on another volume. Move it back by hand." : errorText())
        }
        return .done
    }

    /// macOS privacy protection refuses to open `~/.Trash` itself, but a known item in it can still be
    /// checked and renamed by path. Recheck its identity and refuse to overwrite the original path.
    private func moveBackFromTrash(_ current: String, to original: String, identity: FileIdentity) -> Outcome {
        var st = stat()
        guard lstat(current, &st) == 0 else { return .failed("It is no longer in the Trash") }
        guard st.st_nlink == 1, SafeFS.sameObject(SafeFS.identity(st), identity), st.st_mode & S_IFMT == S_IFREG else { return .failed("The item in the Trash was replaced") }
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

    private func errorText() -> String { String(cString: strerror(errno)) }
}
