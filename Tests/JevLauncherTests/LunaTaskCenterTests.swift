import XCTest
import LauncherCore
@testable import JevLauncher

final class LunaTaskCenterTests: XCTestCase {
    @MainActor func testRunRecordsResultAndRefusesWithoutSwitch() async throws {
        let suite = "JevLauncherTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let sent = LockedBox<[LunaRequest]>([])
        var allowed: Set<LunaContext> = [.typedText]
        let center = LunaTaskCenter(defaults: defaults, send: { request in
            sent.mutate { $0.append(request) }
            return LunaReply(text: "Nothing urgent today.\nTwo meetings.", inputTokens: 1, outputTokens: 1, cost: nil)
        }, allowed: { allowed })
        let plain = LunaTask(name: "Quote", prompt: "give me a quote", schedule: .everyHours(24), contexts: [])
        center.add(plain)
        center.run(plain)
        try await until { center.runs.count == 1 }
        XCTAssertTrue(center.runs[0].succeeded)
        XCTAssertEqual(center.runs[0].preview, "Nothing urgent today. · Two meetings.")
        let file = try XCTUnwrap(center.runs[0].file)
        XCTAssertTrue(try String(contentsOfFile: file, encoding: .utf8).contains("Two meetings."))
        try? FileManager.default.removeItem(atPath: file)

        let mail = LunaTask(name: "Mail", prompt: "check my unread mail", schedule: .everyHours(1), contexts: [.unreadMail])
        center.run(mail)
        try await until { center.runs.count == 2 }
        XCTAssertFalse(center.runs[0].succeeded)
        XCTAssertEqual(sent.value.count, 1, "A task that reads mail sends nothing until mail is allowed.")
        allowed.insert(.mailMessage)
        XCTAssertEqual(center.refused(mail), [])

        // Persisted across a new center on the same store.
        let again = LunaTaskCenter(defaults: defaults, send: { _ in throw CancellationError() }, allowed: { [] })
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
