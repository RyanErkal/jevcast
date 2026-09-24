import Foundation
import LauncherCore

/// Luna's reply: the text and what it cost.
struct LunaReply: Sendable {
    let text: String
    let inputTokens: Int
    let outputTokens: Int
    let cost: Double?
}

protocol LunaWriting: Sendable {
    func complete(_ request: LunaRequest, effort: LunaEffort, apiKey: String) async throws -> LunaReply
}

/// Calls GPT-6 Luna through OpenRouter's chat completions API with the user's OpenRouter key.
struct LunaService: LunaWriting {
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private let session: URLSession
    private let endpoint: URL
    init(session: URLSession = .shared, endpoint: URL = LunaService.endpoint) { self.session = session; self.endpoint = endpoint }

    struct Failure: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    func complete(_ request: LunaRequest, effort: LunaEffort, apiKey: String) async throws -> LunaReply {
        guard apiKey.hasPrefix("sk-or-") else { throw Failure(text: "Luna needs an OpenRouter key (sk-or-…). Add one in Settings › Luna.") }
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = effort == .fast ? 45 : 180
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(AppIdentity.name, forHTTPHeaderField: "X-Title")
        let body = Body(model: LunaRequest.model,
                        messages: [.init(role: "system", content: request.system), .init(role: "user", content: request.user)],
                        reasoning: .init(effort: effort.apiValue, exclude: true),
                        max_tokens: request.maxOutputTokens + (effort == .fast ? 2000 : 16_000),
                        usage: .init(include: true))
        urlRequest.httpBody = try JSONEncoder().encode(body)
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: urlRequest) }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw Failure(text: "Luna is offline. Check the connection and try again.") }
        guard let http = response as? HTTPURLResponse else { throw Failure(text: "Luna sent a response Jevcast could not read.") }
        switch http.statusCode {
        case 200..<300: break
        case 400:
            let detail = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error.message.prefix(200)
            throw Failure(text: "Luna refused the request" + (detail.map { ": " + $0 } ?? "."))
        case 401, 403: throw Failure(text: "OpenRouter rejected the key. Check it in Settings › Luna.")
        case 402: throw Failure(text: "The OpenRouter account needs credits.")
        case 429: throw Failure(text: "Luna is rate limited. Try again in a moment.")
        default: throw Failure(text: "Luna returned HTTP \(http.statusCode).")
        }
        guard let decoded = try? JSONDecoder().decode(Reply.self, from: data),
              let text = decoded.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw Failure(text: "Luna sent a response Jevcast could not read.")
        }
        guard !text.isEmpty else { throw Failure(text: "Luna returned no text. Try again, or choose High effort.") }
        // A reply cut off at the token limit is not used, so it can never replace a whole selection.
        if decoded.choices.first?.finish_reason == "length" {
            throw Failure(text: "Luna ran out of room before it finished. Try a shorter text, or Fast effort.")
        }
        return LunaReply(text: text, inputTokens: decoded.usage?.prompt_tokens ?? 0, outputTokens: decoded.usage?.completion_tokens ?? 0,
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
    }
    private struct ErrorBody: Decodable { struct Detail: Decodable { let message: String }; let error: Detail }
    private struct Reply: Decodable {
        struct Choice: Decodable { struct Message: Decodable { let content: String? }; let message: Message; let finish_reason: String? }
        struct Usage: Decodable { let prompt_tokens: Int?; let completion_tokens: Int?; let cost: Double? }
        let choices: [Choice]
        let usage: Usage?
    }
}

/// A record of each Luna request: when, which kind of action, which kinds of context went, and
/// the cost. Never the text, the question, or the instruction. Stored on this Mac.
@MainActor
final class LunaActivityLog: ObservableObject {
    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        let date: Date
        let action: String
        let sent: [LunaContext]
        let effort: LunaEffort
        let inputTokens: Int
        let outputTokens: Int
        let cost: Double?
        let succeeded: Bool
    }
    static let shared = LunaActivityLog()
    @Published private(set) var entries: [Entry]
    private let defaults: UserDefaults
    private static let key = "lunaActivity"
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
