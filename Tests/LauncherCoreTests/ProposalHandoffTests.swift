import XCTest
@testable import LauncherCore

final class ProposalHandoffTests: XCTestCase {
    /// What the runner saves must pass the app's strict validator decode.
    func testAgentProposalRoundTripsThroughValidator() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = #"{"summary":"Tidy","items":[{"id":"1","op":"mkdir","path":"ROOT/A","from":"","to":"","name":"","tags":[],"reason":"r"}]}"#
            .replacingOccurrences(of: "ROOT", with: root.path)
        guard case .proposal(let proposal) = try AgentOutput.parse(Data(agent.utf8), mode: .proposal) else { return XCTFail("not a proposal") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let result = ProposalValidator.check(rawJSON: try encoder.encode(proposal), roots: [root.path], now: Date(), protected: [])
        switch result {
        case .failure(let error): XCTFail("validator refused the handoff: \(error)")
        case .success(let manifest): XCTAssertEqual(manifest.checked.count, 1, "refused: \(manifest.refused)")
        }
    }
}

final class ProposalNewFolderTests: XCTestCase {
    /// "Make PDFs, then move a.pdf into it" is the common tidy plan; it must check, apply, and undo.
    func testMoveIntoFolderMadeByTheSameProposal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("newfolder-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("x".utf8).write(to: root.appendingPathComponent("a.pdf"))
        let proposal = Proposal(summary: "Tidy", items: [
            ProposalItem(id: "1", op: .mkdir, path: root.path + "/PDFs", reason: "folder"),
            ProposalItem(id: "2", op: .move, from: root.path + "/a.pdf", to: root.path + "/PDFs/a.pdf", reason: "pdf")])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let manifest = try ProposalValidator.check(rawJSON: encoder.encode(proposal), roots: [root.path], now: Date(), protected: []).get()
        XCTAssertEqual(manifest.refused, [:])
        let applier = ProposalApplier(manifest: manifest, approved: ["1", "2"], journalURL: root.appendingPathComponent("journal.json"))
        let journal = applier.apply()
        XCTAssertEqual(journal.entries.map(\.status), [.done, .done], "\(journal.entries.map { $0.message ?? "" })")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path + "/PDFs/a.pdf"))
        let undone = applier.undo(journal: journal)
        XCTAssertEqual(undone.entries.map(\.status), [.undone, .undone], "\(undone.entries.map { $0.message ?? "" })")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path + "/a.pdf"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path + "/PDFs"))
    }

    /// Only the move is approved: the folder was never made, so the move is skipped, not forced.
    func testMoveSkipsWhenItsNewFolderWasNotApproved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("newfolder-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("x".utf8).write(to: root.appendingPathComponent("a.pdf"))
        let proposal = Proposal(summary: "Tidy", items: [
            ProposalItem(id: "1", op: .mkdir, path: root.path + "/PDFs", reason: "folder"),
            ProposalItem(id: "2", op: .move, from: root.path + "/a.pdf", to: root.path + "/PDFs/a.pdf", reason: "pdf")])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let manifest = try ProposalValidator.check(rawJSON: encoder.encode(proposal), roots: [root.path], now: Date(), protected: []).get()
        let journal = ProposalApplier(manifest: manifest, approved: ["2"], journalURL: root.appendingPathComponent("journal.json")).apply()
        XCTAssertEqual(journal.entries.map(\.status), [.skipped])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path + "/a.pdf"))
    }
}
