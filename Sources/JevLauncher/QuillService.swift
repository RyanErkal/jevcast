import Foundation
import LauncherCore

/// Quill's reply: the text and what it cost.
struct QuillReply: Sendable {
    let text: String
    let inputTokens: Int
    let outputTokens: Int
    let cost: Double?
}

protocol QuillWriting: Sendable {
    func complete(_ request: QuillRequest, options: QuillOptions, apiKey: String) async throws -> QuillReply
}

/// The Settings choices sent with one request.
struct QuillOptions: Equatable, Sendable {
    var model: String = QuillModel.defaultID
    var effort: ReasoningEffort
    var fast = false
}

/// Calls the chosen model through OpenRouter's chat completions API with the user's OpenRouter key.
struct QuillService: QuillWriting {
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private let session: URLSession
    private let endpoint: URL
    init(session: URLSession = .shared, endpoint: URL = QuillService.endpoint) { self.session = session; self.endpoint = endpoint }

    struct Failure: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    func complete(_ request: QuillRequest, options: QuillOptions, apiKey: String) async throws -> QuillReply {
        let effort = options.effort
        guard apiKey.hasPrefix("sk-or-") else { throw Failure(text: "Quill needs an OpenRouter key (sk-or-…). Add one in Settings › AI › Quill.") }
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = [.high, .xhigh, .max].contains(effort) ? 180 : 45
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(AppIdentity.name, forHTTPHeaderField: "X-Title")
        let body = Body(model: options.model,
                        messages: [.init(role: "system", content: request.system), .init(role: "user", content: request.user)],
                        reasoning: .init(effort: effort.apiValue, exclude: true),
                        // Room for reasoning on top of the answer. With reasoning off, none is needed.
                        max_tokens: request.maxOutputTokens + effort.reasoningHeadroom,
                        usage: .init(include: true),
                        // Priority tier for Fast. Documented at https://openrouter.ai/docs/api-reference/chat-completion
                        // (`service_tier`, "fast" is an alias for "priority") and
                        // https://openrouter.ai/docs/features/provider-routing (priority endpoints need `service_tier`).
                        service_tier: options.fast ? "priority" : nil)
        urlRequest.httpBody = try JSONEncoder().encode(body)
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: urlRequest) }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw Failure(text: "Quill is offline. Check the connection and try again.") }
        guard let http = response as? HTTPURLResponse else { throw Failure(text: "Quill sent a response Jevcast could not read.") }
        switch http.statusCode {
        case 200..<300: break
        case 400:
            let detail = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error.message.prefix(200)
            throw Failure(text: "Quill refused the request" + (detail.map { ": " + $0 } ?? "."))
        case 401, 403: throw Failure(text: "OpenRouter rejected the key. Check it in Settings › AI › Quill.")
        case 402: throw Failure(text: "The OpenRouter account needs credits.")
        case 429: throw Failure(text: "Quill is rate limited. Try again in a moment.")
        default: throw Failure(text: "Quill returned HTTP \(http.statusCode).")
        }
        guard let decoded = try? JSONDecoder().decode(Reply.self, from: data),
              let text = decoded.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw Failure(text: "Quill sent a response Jevcast could not read.")
        }
        guard !text.isEmpty else { throw Failure(text: "Quill returned no text. Try again, or choose High effort.") }
        // A reply cut off at the token limit is not used, so it can never replace a whole selection.
        if decoded.choices.first?.finish_reason == "length" {
            throw Failure(text: "Quill ran out of room before it finished. Try a shorter text, or Low effort.")
        }
        return QuillReply(text: text, inputTokens: decoded.usage?.prompt_tokens ?? 0, outputTokens: decoded.usage?.completion_tokens ?? 0,
                         cost: decoded.usage?.cost)
    }

    private struct Body: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        struct Reasoning: Encodable { let effort: String; let exclude: Bool }
        struct Usage: Encodable { let include: Bool }
        let model: String
        let messages: [Message]
        let reasoning: Reasoning
        let max_tokens: Int
        let usage: Usage
        let service_tier: String?
    }
    private struct ErrorBody: Decodable { struct Detail: Decodable { let message: String }; let error: Detail }
    private struct Reply: Decodable {
        struct Choice: Decodable { struct Message: Decodable { let content: String? }; let message: Message; let finish_reason: String? }
        struct Usage: Decodable { let prompt_tokens: Int?; let completion_tokens: Int?; let cost: Double? }
        let choices: [Choice]
        let usage: Usage?
    }
}

/// A record of each Quill request: when, which kind of action, which kinds of context went, and
/// the cost. Never the text, the question, or the instruction. Stored on this Mac.
@MainActor
final class QuillActivityLog: ObservableObject {
    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        let date: Date
        let action: String
        let sent: [QuillContext]
        let effort: ReasoningEffort
        /// Fast was on. Missing in entries from before Fast was a separate switch.
        var fast = false
        let inputTokens: Int
        let outputTokens: Int
        let cost: Double?
        let succeeded: Bool

        init(date: Date, action: String, sent: [QuillContext], effort: ReasoningEffort, fast: Bool = false,
             inputTokens: Int, outputTokens: Int, cost: Double?, succeeded: Bool) {
            self.date = date; self.action = action; self.sent = sent; self.effort = effort; self.fast = fast
            self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.cost = cost; self.succeeded = succeeded
        }

        private enum CodingKeys: String, CodingKey { case id, date, action, sent, effort, fast, inputTokens, outputTokens, cost, succeeded }

        /// Reads entries from earlier versions too, which stored the effort "fast" for Low.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            date = try c.decode(Date.self, forKey: .date)
            action = try c.decode(String.self, forKey: .action)
            sent = try c.decode([QuillContext].self, forKey: .sent)
            let stored = try c.decode(String.self, forKey: .effort)
            effort = ReasoningEffort(storedQuillValue: stored) ?? .low
            fast = try c.decodeIfPresent(Bool.self, forKey: .fast) ?? false
            inputTokens = try c.decode(Int.self, forKey: .inputTokens)
            outputTokens = try c.decode(Int.self, forKey: .outputTokens)
            cost = try c.decodeIfPresent(Double.self, forKey: .cost)
            succeeded = try c.decode(Bool.self, forKey: .succeeded)
        }
    }
    static let shared = QuillActivityLog()
    @Published private(set) var entries: [Entry]
    private let defaults: UserDefaults
    private static let key = QuillStorageKeys.activity
    static let limit = 300

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    func record(_ entry: Entry) {
        entries = Array(([entry] + entries).prefix(Self.limit))
        defaults.set(try? JSONEncoder().encode(entries), forKey: Self.key)
    }

    var totalCost: Double { entries.compactMap(\.cost).reduce(0, +) }

    func clear() { entries = []; defaults.removeObject(forKey: Self.key) }
}
