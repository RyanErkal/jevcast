import Foundation
import LauncherCore

/// App-owned delivery state. Never rewrite the runner's record to mark an alert as shown.
struct AutomationAlertReceipt: Codable, Equatable, Sendable {
    static let fileName = "alert-delivery.json"
    let state: RunState
    let attempt: Int
    let started: Date?
    let finished: Date?
    let round: Int?

    init(_ run: RunRecord) {
        state = run.state; attempt = run.attempt; started = run.started
        finished = run.finished; round = run.questions.last?.round
    }

    static func wasDelivered(_ run: RunRecord, store: AutomationStore) -> Bool {
        guard let data = try? store.readRunFile(automationID: run.automationID, runID: run.id, name: fileName),
              let receipt = try? AutomationJSON.decoder().decode(Self.self, from: data) else { return false }
        return receipt == Self(run)
    }

    static func save(_ run: RunRecord, store: AutomationStore) throws {
        try store.writeRunFile(automationID: run.automationID, runID: run.id, name: fileName,
                               data: AutomationJSON.encoder().encode(Self(run)))
    }
}
