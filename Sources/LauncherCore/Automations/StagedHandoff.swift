import Foundation

/// What a staged workflow's preflight script decides. Code checks every field and its size; nothing in
/// it is ever run. Fetch commands come only from the saved `FetchStage`, with `periodKey` filled in.
public struct StagedHandoff: Equatable, Sendable {
    public static let schema = "jevcast.staged.v1"
    public static let maxBytes = 1024 * 1024

    public enum Outcome: String, Sendable { case noDue = "no_due", work, blocked }

    public enum Action: String, Sendable {
        /// Fetch when `fetch` is true, then the analyst writes the report and finish saves it.
        case generate
        /// A saved report without a receipt. No agent runs: the finish script checks it fully and adopts it,
        /// or stops it for review.
        case adopt = "adopt_saved"
        /// A validated report that still has to be shown. No agent runs.
        case present = "present_saved"
        /// The report changed after its receipt, or cannot be repaired safely. Nothing runs; the user reviews it.
        case review
    }

    public struct Item: Equatable, Sendable {
        /// `[a-z0-9:._-]`, for example "sample-client:weekly:2026-09-27".
        public var id: String
        /// The planner's job, for example "sample-client:weekly".
        public var job: String
        /// "2026-09-27" or "2026-09".
        public var periodKey: String
        public var action: Action
        public var fetch: Bool
        /// One line for rows and alerts.
        public var title: String
        /// Data for the analyst from the trusted planner: exact periods, paths, and source coverage.
        public var brief: String
        /// Markdown to show for `present` and `review`.
        public var display: String
        /// For `present`: the receipt's artifact hashes, by path.
        public var artifactHashes: [String: String]
    }

    public var outcome: Outcome
    public var summary: String
    /// Shown in the run's output: source checks, row counts, or why nothing is due.
    public var markdown: String
    public var items: [Item]

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case tooLarge, notJSON, invalid(String)
        public var description: String {
            switch self {
            case .tooLarge: return "The preflight output is too large."
            case .notJSON: return "The preflight did not print one JSON object."
            case .invalid(let why): return "The preflight output is not valid: \(why)"
            }
        }
    }

    /// The last JSON object line or the whole text, so scripts may log before it.
    public static func parse(_ data: Data) throws -> StagedHandoff {
        guard data.count <= maxBytes else { throw ParseError.tooLarge }
        guard let object = StagedJSON.object(in: data) else { throw ParseError.notJSON }
        guard object["schema"] as? String == schema else { throw ParseError.invalid("schema must be \(schema)") }
        guard let raw = object["outcome"] as? String, let outcome = Outcome(rawValue: raw) else { throw ParseError.invalid("unknown outcome") }
        let summary = try StagedJSON.text(object, "summary", max: 300, required: true)
        let markdown = try StagedJSON.text(object, "markdown", max: 256 * 1024)
        let rawItems = try StagedJSON.array(object, "items")
        guard rawItems.count <= 3 else { throw ParseError.invalid("more than 3 items") }
        var seen = Set<String>()
        let items: [Item] = try rawItems.map { value in
            guard let d = value as? [String: Any] else { throw ParseError.invalid("an item is not an object") }
            let id = try StagedJSON.text(d, "id", max: 120, required: true)
            guard id.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || ":._-".contains($0)) }), seen.insert(id).inserted else {
                throw ParseError.invalid("item IDs use a-z, 0-9, and :._- and are unique")
            }
            let job = try StagedJSON.text(d, "job", max: 80, required: true)
            let period = try StagedJSON.text(d, "period_key", max: 10, required: true)
            guard isPeriodKey(period) else { throw ParseError.invalid("period_key \(period) is not YYYY-MM-DD or YYYY-MM") }
            guard let a = d["action"] as? String, let action = Action(rawValue: a) else { throw ParseError.invalid("unknown action in \(id)") }
            let fetch = try StagedJSON.bool(d, "fetch")
            guard !fetch || action == .generate else { throw ParseError.invalid("only generate items fetch") }
            let hashes = try StagedJSON.hashes(d, "artifact_hashes")
            guard action != .present || !hashes.isEmpty else { throw ParseError.invalid("a saved report needs its artifact hashes") }
            return Item(id: id, job: job, periodKey: period, action: action, fetch: fetch,
                        title: try StagedJSON.text(d, "title", max: 200, required: true),
                        brief: try StagedJSON.text(d, "brief", max: 64 * 1024),
                        display: try StagedJSON.text(d, "display", max: 256 * 1024), artifactHashes: hashes)
        }
        guard outcome == .work || items.isEmpty else { throw ParseError.invalid("only work has items") }
        guard outcome != .work || !items.isEmpty else { throw ParseError.invalid("work needs at least one item") }
        return StagedHandoff(outcome: outcome, summary: summary, markdown: markdown, items: items)
    }

    /// "2026-09-27" (a real date) or "2026-09".
    public static func isPeriodKey(_ key: String) -> Bool {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard [2, 3].contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              parts[0].count == 4, parts[1].count == 2, let month = Int(parts[1]), (1...12).contains(month) else { return false }
        guard parts.count == 3 else { return true }
        guard parts[2].count == 2, let year = Int(parts[0]), let day = Int(parts[2]) else { return false }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return false }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        return back.year == year && back.month == month && back.day == day
    }
}

/// What the finish script reports for one item.
public struct StagedFinish: Equatable, Sendable {
    public static let schema = "jevcast.finish.v1"
    public enum Status: String, Sendable { case validated, blocked }
    public var status: Status
    public var summary: String
    /// The complete report and drafts, for the run's durable output.
    public var markdown: String
    /// Set when a validated report waits to be shown.
    public var publication: PublicationItem?

    public static func parse(_ data: Data) throws -> StagedFinish {
        guard data.count <= StagedHandoff.maxBytes else { throw StagedHandoff.ParseError.tooLarge }
        guard let o = StagedJSON.object(in: data), o["schema"] as? String == schema,
              let raw = o["status"] as? String, let status = Status(rawValue: raw) else { throw StagedHandoff.ParseError.notJSON }
        var publication: PublicationItem?
        switch o["publication"] {
        case nil, is NSNull: break
        case let p as [String: Any]: publication = try PublicationItem.parse(p)
        default: throw StagedHandoff.ParseError.invalid("publication is not an object")
        }
        guard status == .blocked || publication != nil else { throw StagedHandoff.ParseError.invalid("a validated report needs its publication") }
        return StagedFinish(status: status, summary: try StagedJSON.text(o, "summary", max: 300, required: true),
                            markdown: try StagedJSON.text(o, "markdown", max: 512 * 1024), publication: publication)
    }
}

/// One validated report a run shows, with the hashes its receipt holds.
public struct PublicationItem: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        /// Waiting for the notch to show the run.
        case pending
        /// The publish script recorded the presentation.
        case recorded
        /// The publish script refused the proof, for example because the report changed. Needs review.
        case refused
    }
    public var job: String
    public var periodKey: String
    public var title: String
    public var artifactHashes: [String: String]
    public var state: State
    public var detail: String?

    enum CodingKeys: String, CodingKey {
        case job, periodKey = "period_key", title, artifactHashes = "artifact_hashes", state, detail
    }

    public init(job: String, periodKey: String, title: String, artifactHashes: [String: String], state: State = .pending, detail: String? = nil) {
        self.job = job; self.periodKey = periodKey; self.title = title; self.artifactHashes = artifactHashes
        self.state = state; self.detail = detail
    }

    static func parse(_ p: [String: Any]) throws -> PublicationItem {
        let job = try StagedJSON.text(p, "job", max: 80, required: true)
        let period = try StagedJSON.text(p, "period_key", max: 10, required: true)
        guard StagedHandoff.isPeriodKey(period) else { throw StagedHandoff.ParseError.invalid("publication period_key") }
        let hashes = try StagedJSON.hashes(p, "artifact_hashes")
        guard !hashes.isEmpty else { throw StagedHandoff.ParseError.invalid("publication without hashes") }
        return PublicationItem(job: job, periodKey: period, title: try StagedJSON.text(p, "title", max: 200), artifactHashes: hashes)
    }

    /// The same report: job, period, and every hash.
    public func sameReport(_ other: PublicationItem) -> Bool {
        job == other.job && periodKey == other.periodKey && artifactHashes == other.artifactHashes
    }
}

/// `publication.json` in a run folder. Written by the runner only.
public struct PublicationRecord: Codable, Equatable, Sendable {
    public static let fileName = "publication.json"
    public var schema = "jevcast.publication.v1"
    public var automationID: String
    public var runID: String
    public var items: [PublicationItem]
    enum CodingKeys: String, CodingKey { case schema, automationID = "automation_id", runID = "run_id", items }
    public init(automationID: String, runID: String, items: [PublicationItem]) {
        self.automationID = automationID; self.runID = runID; self.items = items
    }
}

/// `presentation.json` in a run folder. Written by the app only, after the notch drew the run's alert on
/// screen. It is the evidence a posting receipt needs; a queued alert never writes it.
public struct PresentationProof: Codable, Equatable, Sendable {
    public static let fileName = "presentation.json"
    public var schema = "jevcast.presentation.v1"
    public var automationID: String
    public var runID: String
    public var alertID: String
    public var presentedAt: Date
    public var items: [PublicationItem]
    enum CodingKeys: String, CodingKey {
        case schema, automationID = "automation_id", runID = "run_id", alertID = "alert_id", presentedAt = "presented_at", items
    }
    public init(automationID: String, runID: String, alertID: String, presentedAt: Date, items: [PublicationItem]) {
        self.automationID = automationID; self.runID = runID; self.alertID = alertID; self.presentedAt = presentedAt; self.items = items
    }

    /// ISO 8601 dates, so the publish script can read them.
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .custom { date, encoder in
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var c = encoder.singleValueContainer(); try c.encode(f.string(from: date))
        }
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = f.date(from: text) else { throw StagedHandoff.ParseError.invalid("presented_at") }
            return date
        }
        return d
    }
}

/// What the publish script reports.
public struct StagedPublish: Equatable, Sendable {
    public static let schema = "jevcast.publish.v1"
    public struct Entry: Equatable, Sendable { public var job: String; public var periodKey: String; public var reason: String }
    public var recorded: [Entry]
    public var refused: [Entry]

    public static func parse(_ data: Data) throws -> StagedPublish {
        guard data.count <= 256 * 1024, let o = StagedJSON.object(in: data), o["schema"] as? String == schema else {
            throw StagedHandoff.ParseError.notJSON
        }
        func entries(_ key: String) throws -> [Entry] {
            try StagedJSON.array(o, key).prefix(20).map { v in
                guard let d = v as? [String: Any] else { throw StagedHandoff.ParseError.invalid(key) }
                return Entry(job: try StagedJSON.text(d, "job", max: 80, required: true),
                             periodKey: try StagedJSON.text(d, "period_key", max: 10, required: true),
                             reason: try StagedJSON.text(d, "reason", max: 500))
            }
        }
        return StagedPublish(recorded: try entries("recorded"), refused: try entries("refused"))
    }
}

/// The analyst's answer in a staged run: a report, with optional print-ready HTML for a PDF.
public struct StagedAgentOutput: Equatable, Sendable {
    public var summary: String
    public var markdown: String
    public var html: String

    public static func schema() -> String {
        #"{"type":"object","additionalProperties":false,"required":["summary","report_markdown","pdf_html"],"properties":{"summary":{"type":"string"},"report_markdown":{"type":"string"},"pdf_html":{"type":"string"}}}"#
    }

    public static let contract = "Output: reply only with JSON {summary, report_markdown, pdf_html}. summary is one short line. report_markdown is the complete report. pdf_html is complete print-ready HTML when the item asks for a PDF, otherwise an empty string."

    public static func parse(_ data: Data) throws -> StagedAgentOutput {
        guard data.count <= 4 * 1024 * 1024, let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AgentOutput.ParseError.notJSON
        }
        let summary = String(((o["summary"] as? String) ?? "").prefix(500)).replacingOccurrences(of: "\n", with: " ")
        guard let markdown = o["report_markdown"] as? String, !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentOutput.ParseError.missing("report_markdown")
        }
        guard markdown.utf8.count <= 1_000_000 else { throw AgentOutput.ParseError.tooLarge }
        let html = (o["pdf_html"] as? String) ?? ""
        guard html.utf8.count <= 2_000_000 else { throw AgentOutput.ParseError.tooLarge }
        return StagedAgentOutput(summary: summary, markdown: markdown, html: html)
    }
}

enum StagedJSON {
    /// The whole text as one object, or else the last line that is one.
    static func object(in data: Data) -> [String: Any]? {
        if let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { return o }
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("{"), let o = (try? JSONSerialization.jsonObject(with: Data(t.utf8))) as? [String: Any] else { continue }
            return o
        }
        return nil
    }

    /// A missing key is an empty list; any other type is an error.
    static func array(_ o: [String: Any], _ key: String) throws -> [Any] {
        switch o[key] {
        case nil: return []
        case let a as [Any]: return a
        default: throw StagedHandoff.ParseError.invalid("\(key) is not a list")
        }
    }

    /// A missing key is false; only a JSON boolean is accepted.
    static func bool(_ o: [String: Any], _ key: String) throws -> Bool {
        switch o[key] {
        case nil: return false
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): return n.boolValue
        default: throw StagedHandoff.ParseError.invalid("\(key) is not true or false")
        }
    }

    /// Full paths to SHA-256 hex values. A missing key is empty.
    static func hashes(_ o: [String: Any], _ key: String) throws -> [String: String] {
        let raw: [String: Any]
        switch o[key] {
        case nil: return [:]
        case let d as [String: Any]: raw = d
        default: throw StagedHandoff.ParseError.invalid("\(key) is not an object")
        }
        guard raw.count <= 10 else { throw StagedHandoff.ParseError.invalid("\(key) has too many entries") }
        var out: [String: String] = [:]
        for (path, hash) in raw {
            guard path.hasPrefix("/"), path.utf8.count <= 1024, let h = hash as? String, h.count == 64, h.allSatisfy(\.isHexDigit) else {
                throw StagedHandoff.ParseError.invalid("\(key) needs full paths and SHA-256 values")
            }
            out[path] = h.lowercased()
        }
        return out
    }

    static func text(_ o: [String: Any], _ key: String, max: Int, required: Bool = false) throws -> String {
        guard let v = o[key] else {
            if required { throw StagedHandoff.ParseError.invalid("\(key) is missing") }
            return ""
        }
        guard let s = v as? String else { throw StagedHandoff.ParseError.invalid("\(key) is not text") }
        guard s.utf8.count <= max else { throw StagedHandoff.ParseError.invalid("\(key) is too long") }
        if required, s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw StagedHandoff.ParseError.invalid("\(key) is empty") }
        return s
    }
}
