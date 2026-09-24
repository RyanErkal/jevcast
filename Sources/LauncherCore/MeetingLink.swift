import Foundation

/// Finds a video-call link in an event's URL, location, or notes.
public enum MeetingLink {
    /// Call services by host, with the path a meeting link starts with. The host must match, so a
    /// link that only mentions a service in its path or query is not treated as a call.
    private static let services: [(host: String, path: String)] = [
        ("zoom.us", "/j/"), ("zoom.us", "/my/"), ("zoom.us", "/w/"), ("meet.google.com", "/"), ("teams.microsoft.com", "/l/meetup-join"),
        ("teams.live.com", "/meet"), ("webex.com", "/"), ("facetime.apple.com", "/join"), ("whereby.com", "/")
    ]

    public static func find(in texts: [String?]) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for text in texts.compactMap({ $0 }) where !text.isEmpty {
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
                guard let host = url.host?.lowercased() else { continue }
                let path = url.path.lowercased()
                if services.contains(where: { (host == $0.host || host.hasSuffix("." + $0.host)) && path.hasPrefix($0.path) && path.count > 1 }) { return url }
            }
        }
        return nil
    }
}
