import Foundation
import LauncherCore

enum MailScheduleState: String, Codable, Sendable {
    case scheduled
    /// Persisted before the submission closure is called. A relaunch converts this to needsReview.
    case dispatching
    case submitted
    case needsReview
    case cancelled
}

struct MailScheduleEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var account: MailAccountIdentity
    var draft: MailModel.Draft
    let createdAt: Date
    var scheduledAt: Date
    var state: MailScheduleState
    var note: String?
    var lastAttemptAt: Date?

    /// A dispatch that reached its transport handoff must be checked in Sent before it can be
    /// scheduled again. Missed items have no attempt timestamp and can be reviewed normally.
    var requiresSentCheck: Bool {
        draft.uncertainSend || (state == .needsReview && lastAttemptAt != nil)
    }
}

struct MailScheduleStoreSnapshot: Codable, Sendable {
    var entries: [MailScheduleEntry] = []
}

final class MailScheduleStore: @unchecked Sendable {
    let directory: URL
    private let file: MailOwnedJSONStore<MailScheduleStoreSnapshot>

    init(directory: URL) {
        self.directory = directory
        file = MailOwnedJSONStore(directory: directory, fileName: "schedules.json")
    }

    static var standard: MailScheduleStore {
        MailScheduleStore(directory: MailIOPolicy.isOffline ? offlineDirectory : URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Jevcast/MailSchedule", isDirectory: true))
    }

    /// Offline and snapshot runs must never inspect a real user's mail state.
    private static let offlineDirectory: URL = {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("jevcast-offline-mail-schedule-\(UUID().uuidString)", isDirectory: true)
    }()

    func load() throws -> MailScheduleStoreSnapshot { try file.load(or: MailScheduleStoreSnapshot()) }
    func save(_ snapshot: MailScheduleStoreSnapshot) throws { try file.save(snapshot) }
}
