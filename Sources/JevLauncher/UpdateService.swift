import Foundation

/// A published release that is newer than the running app. The app never
/// downloads or installs it; the user opens its page.
struct AppRelease: Equatable, Sendable {
    let version: String
    let page: URL
}

enum UpdateServiceError: Error, LocalizedError, Equatable {
    case requestFailed(statusCode: Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case let .requestFailed(statusCode): return "GitHub returned HTTP status \(statusCode)."
        case .invalidResponse: return "GitHub returned an unreadable release."
        }
    }
}

/// Asks GitHub for the newest release. One GET with the app version in the
/// User-Agent; no identifier, query text, or usage data is sent.
struct UpdateService: Sendable {
    private let session: URLSession
    private let endpoint: URL

    init(session: URLSession = .shared, endpoint: URL = AppIdentity.latestReleaseAPI) {
        self.session = session
        self.endpoint = endpoint
    }

    /// The newest release when it is newer than `current`, or nil.
    func newerRelease(than current: String) async throws -> AppRelease? {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("JevLauncher/\(current)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateServiceError.invalidResponse }
        // No release is published yet.
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else { throw UpdateServiceError.requestFailed(statusCode: http.statusCode) }
        let release = try Self.parse(data)
        return Self.isNewer(release.version, than: current) ? release : nil
    }

    static func parse(_ data: Data) throws -> AppRelease {
        struct Payload: Decodable {
            let tag_name: String
            let html_url: URL
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { throw UpdateServiceError.invalidResponse }
        let version = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
        guard !numbers(in: version).isEmpty else { throw UpdateServiceError.invalidResponse }
        return AppRelease(version: version, page: payload.html_url)
    }

    /// Dot-separated numeric comparison: 1.10.0 is newer than 1.9.2, and 1.0 equals 1.0.0.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let new = numbers(in: candidate), old = numbers(in: current)
        for index in 0..<max(new.count, old.count) {
            let a = index < new.count ? new[index] : 0, b = index < old.count ? old[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// The leading "1.2.3" of a version; a suffix such as "-beta" is ignored.
    private static func numbers(in version: String) -> [Int] {
        version.prefix { $0.isNumber || $0 == "." }.split(separator: ".").compactMap { Int($0) }
    }
}
