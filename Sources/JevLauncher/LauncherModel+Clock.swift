import Foundation
import LauncherCore

/// Time zone answers. Code reads the clock time and does the math. Jev only helps with loose
/// wording, and then only by choosing places from a fixed list.
extension LauncherModel {
    static let clockCandidateID = "time:convert"
    static let clockLocalChoice = "zone:local"

    static func clockRow(_ answer: TimeZoneQuery.Answer, score: Double = 2000) -> LauncherResult {
        LauncherResult(id: "clock", title: answer.title, detail: answer.detail, symbol: "clock", action: .copy(answer.title), score: score)
    }

    /// Jev's candidate for a time conversion. It is offered only for a clock time such as "6pm",
    /// or for "now" or "time" beside a place name, so "now playing" and "screen time" do not get it.
    func clockCandidate() -> (id: String, title: String, detail: String)? {
        guard TimeZoneQuery.clock(in: query, explicitOnly: true) != nil
            || (TimeZoneQuery.clock(in: query) != nil && !TimeZonePlaces.mentioned(in: query).isEmpty) else { return nil }
        return (Self.clockCandidateID, "Convert a time between places", "Say what a clock time in one city, country, or time zone is in another")
    }

    /// Asks Jev for the source and target places at once, then converts locally.
    /// Nil when Jev finds no target or both sides are the same place.
    func clockRow(for text: String, key: String) async throws -> LauncherResult? {
        guard let clock = TimeZoneQuery.clock(in: text) else { return nil }
        let here = (id: Self.clockLocalChoice, title: "Here", detail: "The user's own time zone: me, here, local, my time, or no place named")
        let (candidates, ids) = Self.opaque([here] + TimeZonePlaces.choices(for: text))
        async let fromReply = jev.choose(query: "The place the time is in, in this request: " + text, candidates: candidates, apiKey: key)
        async let toReply = jev.choose(query: "The place to give the time in, in this request: " + text, candidates: candidates, apiKey: key)
        var fromID = try await fromReply.flatMap { ids[$0] }
        let toID = try await toReply.flatMap { ids[$0] }
        // "6pm for my mate in cork" names one place, and both questions may pick it. The source is then the user's own zone.
        if fromID == toID { fromID = nil }
        // Only IDs from the list resolve. A missing source is the user's own zone; a missing target is no answer.
        func place(_ id: String?) -> TimeZonePlace? { id.flatMap(TimeZonePlaces.place(forChoice:)) }
        guard let toID else { return nil }
        guard let answer = TimeZoneQuery.convert(clock, from: place(fromID), to: place(toID)) else { return nil }
        return Self.clockRow(answer, score: 0)
    }
}
