import Foundation

/// Finds a video-call link in an event's URL, location, or notes.
public enum MeetingLink {
    private static let hosts = ["zoom.us/j/", "zoom.us/my/", "meet.google.com/", "teams.microsoft.com/", "teams.live.com/",
                                "webex.com/", "facetime.apple.com/", "whereby.com/", "around.co/"]

    public static func find(in texts: [String?]) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for text in texts.compactMap({ $0 }) where !text.isEmpty {
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
                let lower = url.absoluteString.lowercased()
                if hosts.contains(where: lower.contains) { return url }
            }
        }
        return nil
    }
}
