import Foundation

/// Where a report workflow run is, from its own `stages.json`: the last stage that finished, in fixed words.
/// The runner writes a line after each stage finishes, so this never guesses at the stage running now.
/// It never names or numbers items: items the planner hands over as already saved log no stage, so a position
/// counted from the log could be wrong. No item names, paths, commands, or details, so it may show while names are hidden.
public struct StageProgress: Equatable, Sendable {
    /// The last finished stage in plain words, such as "Data fetched".
    public var phrase: String

    public init(phrase: String) { self.phrase = phrase }

    /// Reads `stages.json`. Nil when it is empty, unreadable, or ends with a stage this version does not know.
    public static func parse(_ data: Data) -> StageProgress? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let last = (try? decoder.decode([RunEngine.StageEntry].self, from: data))?.last,
              let phrase = phrase(stage: last.stage, succeeded: last.state == "succeeded") else { return nil }
        return StageProgress(phrase: phrase)
    }

    private static func phrase(stage: String, succeeded: Bool) -> String? {
        switch stage {
        case "publish": return succeeded ? "Earlier receipts recorded" : "A receipt was not recorded"
        case "preflight": return succeeded ? "Plan ready" : "Planning stopped"
        case "fetch": return succeeded ? "Data fetched" : "Fetch stopped"
        case "analyst": return succeeded ? "Analysis written" : "Analysis stopped"
        case "finish": return succeeded ? "Report checked" : "Report check stopped"
        default: return nil
        }
    }
}

extension RunRecord {
    /// A run that stopped on something only the user can settle, such as a report to review.
    /// It failed, so it is never shown as done, also when some of its items finished.
    public var needsReview: Bool { state == .failed && summary.hasPrefix(RunEngine.needsReviewPrefix) }

    /// A report workflow run that has a report ready to show.
    public var hasReadyReport: Bool { state == .succeeded && summary.hasPrefix(RunEngine.reportReadyPrefix) }

    /// The most recent run that finished successfully, from runs listed newest first.
    public static func lastSuccess(in runs: [RunRecord]) -> Date? {
        runs.first { $0.state == .succeeded && $0.finished != nil }?.finished
    }
}
