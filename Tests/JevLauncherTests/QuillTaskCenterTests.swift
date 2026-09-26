import XCTest
import LauncherCore
@testable import JevLauncher

final class QuillTaskCenterTests: XCTestCase {
    @MainActor func testRunRecordsResultAndRefusesWithoutSwitch() async throws {
        let suite = "JevLauncherTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let sent = LockedBox<[QuillRequest]>([])
        var allowed: Set<QuillContext> = [.typedText]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("quilltasks-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let center = QuillTaskCenter(defaults: defaults, folder: folder, send: { request in
            sent.mutate { $0.append(request) }
            return QuillReply(text: "Nothing urgent today.\nTwo meetings.", inputTokens: 1, outputTokens: 1, cost: nil)
        }, allowed: { allowed })
        let plain = QuillTask(name: "Quote", prompt: "give me a quote", schedule: .everyHours(24), contexts: [])
        center.add(plain)
        center.run(plain)
        try await until { center.runs.count == 1 }
        XCTAssertTrue(center.runs[0].succeeded)
        XCTAssertEqual(center.runs[0].preview, "Nothing urgent today. · Two meetings.")
        let file = try XCTUnwrap(center.runs[0].file)
        XCTAssertTrue(try String(contentsOfFile: file, encoding: .utf8).contains("Two meetings."))
        XCTAssertTrue(file.hasPrefix(folder.path), "Results go to the injected folder.")

        let mail = QuillTask(name: "Mail", prompt: "check my unread mail", schedule: .everyHours(1), contexts: [.unreadMail])
        center.run(mail)
        try await until { center.runs.count == 2 }
        XCTAssertFalse(center.runs[0].succeeded)
        XCTAssertEqual(sent.value.count, 1, "A task that reads mail sends nothing until mail is allowed.")
        allowed.insert(.mailMessage)
        XCTAssertEqual(center.refused(mail), [.unreadMail], "The single-message switch does not allow the unread list.")
        allowed.insert(.unreadMail)
        XCTAssertEqual(center.refused(mail), [])

        // Persisted across a new center on the same store.
        let again = QuillTaskCenter(defaults: defaults, send: { _ in throw CancellationError() }, allowed: { [] })
        XCTAssertEqual(again.tasks.map(\.name), ["Quote"])
        XCTAssertEqual(again.runs.count, 2)
    }
}

final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func mutate(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}
