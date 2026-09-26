import XCTest
@testable import LauncherCore

final class ProposalTests: XCTestCase {
    private var base: URL!
    private var root: String!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("proposal-\(UUID().uuidString)")
        try fm.createDirectory(at: base.appendingPathComponent("root/Sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: base.appendingPathComponent("root2"), withIntermediateDirectories: true)
        root = base.appendingPathComponent("root").path
        try Data("a".utf8).write(to: URL(fileURLWithPath: root + "/a.txt"))
        try Data("b".utf8).write(to: URL(fileURLWithPath: root + "/b.txt"))
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: base) }

    private func json(_ items: [[String: Any]], version: Int = 1) -> Data {
        try! JSONSerialization.data(withJSONObject: ["version": version, "summary": "s", "items": items])
    }

    private func check(_ items: [[String: Any]], protected: [String] = []) -> ProposalManifest {
        let r = ProposalValidator.check(rawJSON: json(items), roots: [root], now: Date(), protected: protected)
        guard case .success(let m) = r else { XCTFail("\(r)"); fatalError() }
        return m
    }

    private func refusal(_ item: [String: Any], protected: [String] = []) -> String? {
        var item = item; item["id"] = "x"; item["reason"] = "r"
        return check([item], protected: protected).refused["x"]
    }

    // MARK: Decoding

    func testWholeProposalErrors() {
        func err(_ data: Data) -> ProposalError? {
            if case .failure(let e) = ProposalValidator.check(rawJSON: data, roots: [root], now: Date()) { return e }
            return nil
        }
        XCTAssertEqual(err(json([], version: 2)), .unsupportedVersion(2))
        XCTAssertEqual(err(json([["id": "a", "op": "chmod", "reason": ""]])), .unknownOperation("chmod"))
        XCTAssertEqual(err(json([["id": "a", "op": "trash", "reason": ""], ["id": "a", "op": "trash", "reason": ""]])), .duplicateItemID("a"))
        XCTAssertEqual(err(json([["id": "a", "op": "trash", "reason": "", "cmd": "rm"]])), .unexpectedField("cmd"))
        XCTAssertEqual(err(json(Array(repeating: ["op": "trash"], count: Proposal.maxItems + 1))), .tooManyItems(Proposal.maxItems + 1))
        XCTAssertEqual(err(Data(count: Proposal.maxBytes + 1)), .tooLarge(Proposal.maxBytes + 1))
        if case .failure(.noRoots) = ProposalValidator.check(rawJSON: json([]), roots: ["relative"], now: Date()) {} else { XCTFail() }
    }

    // MARK: Path rules

    func testPathRules() throws {
        let rootReal = try XCTUnwrap(realpath(root, nil).map { p in defer { free(p) }; return String(cString: p) })
        XCTAssertNil(refusal(["op": "trash", "path": root + "/a.txt"]))
        XCTAssertNil(refusal(["op": "trash", "path": rootReal + "/a.txt"]))
        XCTAssertNotNil(refusal(["op": "trash", "path": "a.txt"]))
        XCTAssertNotNil(refusal(["op": "trash", "path": root + "/Sub/../a.txt"]))
        XCTAssertNotNil(refusal(["op": "trash", "path": root + "//a.txt"]))
        XCTAssertNotNil(refusal(["op": "trash", "path": root]))
        XCTAssertNotNil(refusal(["op": "trash", "path": base.path + "/root2"]))
        XCTAssertNotNil(refusal(["op": "trash", "path": root + "2/x"]), "string prefix is not containment")
        XCTAssertNotNil(refusal(["op": "trash", "path": root + "/missing"]))
        XCTAssertNotNil(refusal(["op": "trash", "path": root + "/a.txt"], protected: [rootReal + "/a.txt"]))
        XCTAssertEqual(refusal(["op": "trash", "path": root + "/a.txt"], protected: ProtectedPaths.standard), "Path is in a protected folder")

        try fm.createSymbolicLink(atPath: root + "/link", withDestinationPath: root + "/Sub")
        XCTAssertNotNil(refusal(["op": "trash", "path": root + "/link"]))
        try Data().write(to: URL(fileURLWithPath: root + "/Sub/c.txt"))
        XCTAssertNotNil(refusal(["op": "trash", "path": root + "/link/c.txt"]))

        XCTAssertEqual(link(root + "/a.txt", root + "/hard.txt"), 0)
        XCTAssertEqual(refusal(["op": "trash", "path": root + "/a.txt"]), "Hard-linked files are not supported")
        XCTAssertEqual(mkfifo(root + "/fifo", 0o600), 0)
        XCTAssertEqual(refusal(["op": "trash", "path": root + "/fifo"]), "Special files are not supported")
    }

    func testOperationRules() {
        XCTAssertNil(refusal(["op": "move", "from": root + "/b.txt", "to": root + "/Sub/b.txt"]))
        XCTAssertNotNil(refusal(["op": "move", "from": root + "/b.txt", "to": root + "/Sub"]), "exists")
        XCTAssertNotNil(refusal(["op": "move", "from": root + "/b.txt", "to": root + "/Nope/b.txt"]))
        XCTAssertNotNil(refusal(["op": "move", "from": root + "/Sub", "to": root + "/Sub/Inner"]))
        XCTAssertNotNil(refusal(["op": "move", "from": root + "/b.txt", "to": base.path + "/root2/b.txt"]))
        XCTAssertNotNil(refusal(["op": "move", "from": root + "/b.txt", "to": root + "/c.txt", "path": root]))
        XCTAssertNil(refusal(["op": "rename", "path": root + "/b.txt", "name": "c.txt"]))
        for bad in ["", ".", "..", "a/b", String(repeating: "x", count: 256), "a.txt"] {
            XCTAssertNotNil(refusal(["op": "rename", "path": root + "/b.txt", "name": bad]), bad)
        }
        XCTAssertNil(refusal(["op": "mkdir", "path": root + "/New"]))
        XCTAssertNotNil(refusal(["op": "mkdir", "path": root + "/Sub"]))
        XCTAssertNotNil(refusal(["op": "mkdir", "path": root + "/A/B"]))
        XCTAssertNil(refusal(["op": "tag", "path": root + "/b.txt", "tags": ["Red"]]))
        XCTAssertNotNil(refusal(["op": "tag", "path": root + "/b.txt", "tags": []]))
        XCTAssertNotNil(refusal(["op": "tag", "path": root + "/b.txt", "tags": [""]]))
        XCTAssertNotNil(refusal(["op": "tag", "path": root + "/b.txt", "tags": Array(repeating: "t", count: 17)]))
        XCTAssertNotNil(refusal(["op": "tag", "path": root + "/b.txt", "tags": [String(repeating: "t", count: 64)]]))
    }

    func testDependentItemsAndDigest() {
        let m = check([
            ["id": "1", "op": "move", "from": root + "/a.txt", "to": root + "/Sub/a.txt", "reason": ""],
            ["id": "2", "op": "tag", "path": root + "/A.TXT", "tags": ["y"], "reason": ""],
            ["id": "3", "op": "tag", "path": root + "/b.txt", "tags": ["x"], "reason": ""],
        ])
        XCTAssertEqual(Set(m.refused.keys), ["1", "2"])
        XCTAssertEqual(m.checked.map(\.id), ["3"])
        XCTAssertEqual(m.digest.count, 64)
        let single: [[String: Any]] = [["id": "3", "op": "tag", "path": root + "/b.txt", "tags": ["x"], "reason": ""]]
        XCTAssertEqual(check(single).digest, check(single).digest)
        XCTAssertNotEqual(check(single).digest, m.digest)
    }

    // MARK: Apply and undo

    func testApplyAndUndo() throws {
        let m = check([
            ["id": "mv", "op": "move", "from": root + "/a.txt", "to": root + "/Sub/moved.txt", "reason": ""],
            ["id": "rn", "op": "rename", "path": root + "/b.txt", "name": "renamed.txt", "reason": ""],
            ["id": "mk", "op": "mkdir", "path": root + "/Made", "reason": ""],
        ])
        XCTAssertEqual(m.refused, [:])
        let journalURL = base.appendingPathComponent("journal.json")
        let applier = ProposalApplier(manifest: m, approved: ["mv", "rn", "mk"], journalURL: journalURL)
        let j = applier.apply()
        XCTAssertEqual(j.entries.map(\.status), [.done, .done, .done])
        XCTAssertTrue(fm.fileExists(atPath: root + "/Sub/moved.txt"))
        XCTAssertTrue(fm.fileExists(atPath: root + "/renamed.txt"))
        XCTAssertTrue(fm.fileExists(atPath: root + "/Made"))
        XCTAssertNotNil(try? Data(contentsOf: journalURL))

        let u = applier.undo(journal: j)
        XCTAssertEqual(u.entries.map(\.status), [.undone, .undone, .undone])
        XCTAssertTrue(fm.fileExists(atPath: root + "/a.txt"))
        XCTAssertTrue(fm.fileExists(atPath: root + "/b.txt"))
        XCTAssertFalse(fm.fileExists(atPath: root + "/Made"))
    }

    func testApplySkipsChangedSourceAndNeverOverwrites() throws {
        let m = check([
            ["id": "mv", "op": "move", "from": root + "/a.txt", "to": root + "/Sub/a.txt", "reason": ""],
            ["id": "rn", "op": "rename", "path": root + "/b.txt", "name": "c.txt", "reason": ""],
        ])
        try Data("changed".utf8).write(to: URL(fileURLWithPath: root + "/a.txt"))
        try Data("keep".utf8).write(to: URL(fileURLWithPath: root + "/c.txt"))
        let j = ProposalApplier(manifest: m, approved: ["mv", "rn"], journalURL: base.appendingPathComponent("j.json")).apply()
        XCTAssertEqual(j.entries.map(\.status), [.skipped, .skipped])
        XCTAssertEqual(try String(contentsOfFile: root + "/c.txt"), "keep")
        XCTAssertTrue(fm.fileExists(atPath: root + "/b.txt"))
    }

    func testUndoBlockedWhenOriginalOccupiedAndNonEmptyFolder() throws {
        let m = check([
            ["id": "rn", "op": "rename", "path": root + "/b.txt", "name": "c.txt", "reason": ""],
            ["id": "mk", "op": "mkdir", "path": root + "/Made", "reason": ""],
        ])
        let applier = ProposalApplier(manifest: m, approved: ["rn", "mk"], journalURL: base.appendingPathComponent("j.json"))
        let j = applier.apply()
        try Data("new".utf8).write(to: URL(fileURLWithPath: root + "/b.txt"))
        try Data().write(to: URL(fileURLWithPath: root + "/Made/f"))
        let u = applier.undo(journal: j)
        XCTAssertEqual(u.entries.map(\.status), [.undoBlocked, .undoBlocked])
        XCTAssertEqual(try String(contentsOfFile: root + "/b.txt"), "new")
        XCTAssertTrue(fm.fileExists(atPath: root + "/c.txt"))
        XCTAssertTrue(fm.fileExists(atPath: root + "/Made/f"))
    }

    func testTagAndUndo() throws {
        let m = check([["id": "t", "op": "tag", "path": root + "/b.txt", "tags": ["Blue"], "reason": ""]])
        let applier = ProposalApplier(manifest: m, approved: ["t"], journalURL: base.appendingPathComponent("j.json"))
        let j = applier.apply()
        XCTAssertEqual(j.entries.first?.status, .done)
        XCTAssertEqual(j.entries.first?.previousTags, [])
        let url = URL(fileURLWithPath: root + "/b.txt")
        XCTAssertEqual(try url.resourceValues(forKeys: [.tagNamesKey]).tagNames, ["Blue"])
        XCTAssertEqual(applier.undo(journal: j).entries.first?.status, .undone)
        XCTAssertEqual(try URL(fileURLWithPath: root + "/b.txt").resourceValues(forKeys: [.tagNamesKey]).tagNames ?? [], [])
    }

    func testUnapprovedAndRefusedAreNotApplied() {
        let m = check([
            ["id": "ok", "op": "mkdir", "path": root + "/One", "reason": ""],
            ["id": "bad", "op": "mkdir", "path": root + "/Sub", "reason": ""],
        ])
        let j = ProposalApplier(manifest: m, approved: ["bad"], journalURL: base.appendingPathComponent("j.json")).apply()
        XCTAssertEqual(j.entries.map(\.status), [.skipped])
        XCTAssertFalse(fm.fileExists(atPath: root + "/One"))
    }

    // MARK: v1 limits

    func testFoldersCannotBeMovedRenamedOrTrashed() {
        let reason = "Folders cannot be moved or trashed yet"
        XCTAssertEqual(refusal(["op": "move", "from": root + "/Sub", "to": root + "/Other"]), reason)
        XCTAssertEqual(refusal(["op": "trash", "path": root + "/Sub"]), reason)
        XCTAssertEqual(refusal(["op": "rename", "path": root + "/Sub", "name": "Other"]), reason)
        XCTAssertNil(refusal(["op": "tag", "path": root + "/Sub", "tags": ["Red"]]))
        XCTAssertNil(refusal(["op": "trash", "path": root + "/a.txt"]))
    }

    func testDependenciesIgnoreCase() {
        let m = check([
            ["id": "1", "op": "move", "from": root + "/a.txt", "to": root + "/Sub/x.txt", "reason": ""],
            ["id": "2", "op": "move", "from": root + "/b.txt", "to": root + "/sub/X.TXT", "reason": ""],
        ])
        XCTAssertEqual(Set(m.refused.keys), ["1", "2"])
    }

    func testProtectedPathsIgnoreCase() {
        XCTAssertNotNil(refusal(["op": "trash", "path": root + "/a.txt"], protected: [root.uppercased() + "/A.TXT"]))
    }

    func testExpiry() {
        let m = check([["id": "t", "op": "tag", "path": root + "/b.txt", "tags": ["x"], "reason": ""]])
        XCTAssertFalse(ProposalValidator.isExpired(m, now: m.created.addingTimeInterval(6 * 86400)))
        XCTAssertTrue(ProposalValidator.isExpired(m, now: m.created.addingTimeInterval(7 * 86400 + 1)))
    }

    func testMkdirUndoRemovesFinderMetadataAndChecksInode() throws {
        let m = check([["id": "mk", "op": "mkdir", "path": root + "/Made", "reason": ""]])
        let applier = ProposalApplier(manifest: m, approved: ["mk"], journalURL: base.appendingPathComponent("j.json"))
        let j = applier.apply()
        XCTAssertNotNil(j.entries.first?.createdInode)
        try Data().write(to: URL(fileURLWithPath: root + "/Made/.DS_Store"))
        XCTAssertEqual(applier.undo(journal: j).entries.first?.status, .undone)
        XCTAssertFalse(fm.fileExists(atPath: root + "/Made"))

        // A folder made again by someone else is not the one we made.
        let j2 = applier.apply()
        try fm.removeItem(atPath: root + "/Made")
        try fm.createDirectory(atPath: root + "/Spacer", withIntermediateDirectories: false)
        try fm.createDirectory(atPath: root + "/Made", withIntermediateDirectories: false)
        var entry = j2.entries[0]; entry.createdInode = (entry.createdInode ?? 0) &+ 999_999
        var forged = j2; forged.entries[0] = entry
        XCTAssertEqual(applier.undo(journal: forged).entries.first?.status, .undoBlocked)
        XCTAssertTrue(fm.fileExists(atPath: root + "/Made"))
    }

    func testJournalDecodes() throws {
        let m = check([["id": "mk", "op": "mkdir", "path": root + "/Made", "reason": ""]])
        let url = base.appendingPathComponent("j.json")
        let j = ProposalApplier(manifest: m, approved: ["mk"], journalURL: url).apply()
        XCTAssertEqual(ApplyJournal.decode(try Data(contentsOf: url))?.entries.map(\.status), j.entries.map(\.status))
    }
    func testUndoBlocksChangedFileAndTags() throws {
        let moved = check([["id": "rn", "op": "rename", "path": root + "/a.txt", "name": "c.txt", "reason": ""]])
        let applier = ProposalApplier(manifest: moved, approved: ["rn"], journalURL: base.appendingPathComponent("j.json"))
        let journal = applier.apply()
        try Data("changed in place".utf8).write(to: URL(fileURLWithPath: root + "/c.txt"))
        XCTAssertEqual(applier.undo(journal: journal).entries.first?.status, .undoBlocked)
        XCTAssertFalse(fm.fileExists(atPath: root + "/a.txt"))

        let tagged = check([["id": "t", "op": "tag", "path": root + "/b.txt", "tags": ["Blue"], "reason": ""]])
        let tagger = ProposalApplier(manifest: tagged, approved: ["t"], journalURL: base.appendingPathComponent("tags.json"))
        let tags = tagger.apply()
        let url = URL(fileURLWithPath: root + "/b.txt")
        try (url as NSURL).setResourceValue(["Red"], forKey: .tagNamesKey)
        XCTAssertEqual(tagger.undo(journal: tags).entries.first?.status, .undoBlocked)
        XCTAssertEqual(try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.tagNamesKey]).tagNames, ["Red"])
    }

    func testJournalIsOwnerOnly() throws {
        let manifest = check([["id": "mk", "op": "mkdir", "path": root + "/Made", "reason": ""]])
        let url = base.appendingPathComponent("j.json")
        _ = ProposalApplier(manifest: manifest, approved: ["mk"], journalURL: url).apply()
        let attributes = try fm.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

}
