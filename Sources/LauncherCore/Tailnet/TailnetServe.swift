import Foundation

/// One thing a device shares with `tailscale serve` or `tailscale funnel`.
public struct TailnetShare: Equatable, Sendable {
    public enum Kind: String, Sendable { case https, http, tcp }
    public let kind: Kind
    public let port: Int
    /// The web path it answers on, such as "/" or "/api". Empty for a TCP forward.
    public let path: String
    /// What it serves: a local address, a folder, or "text".
    public let target: String
    /// True when Funnel also shares it on the public internet.
    public let funnel: Bool

    public init(kind: Kind, port: Int, path: String, target: String, funnel: Bool = false) {
        self.kind = kind; self.port = port; self.path = path; self.target = target; self.funnel = funnel
    }
}

/// Reads `tailscale serve status --json`, the same on every platform.
public enum TailnetServe {
    /// Every share, by port and path. Empty when nothing is shared or the text does not read.
    public static func parse(_ data: Data) -> [TailnetShare] {
        (try? JSONDecoder().decode(ServeConfig.self, from: data)).map(shares) ?? []
    }

    static func shares(_ config: ServeConfig) -> [TailnetShare] {
        // `tailscale serve` without --bg keeps its share under Foreground while it runs.
        let parts = [config] + (config.foreground ?? [:]).sorted { $0.key < $1.key }.map(\.value)
        var found: [TailnetShare] = []
        for part in parts {
            for (portText, handler) in part.tcp ?? [:] {
                guard let port = Int(portText) else { continue }
                let suffix = ":" + portText
                let funnel = (part.allowFunnel ?? [:]).contains { $0.key.hasSuffix(suffix) && $0.value }
                if handler.https == true || handler.http == true {
                    let kind: TailnetShare.Kind = handler.https == true ? .https : .http
                    let handlers = (part.web ?? [:]).filter { $0.key.hasSuffix(suffix) }.values.flatMap { ($0.handlers ?? [:]).map { $0 } }
                    if handlers.isEmpty { found.append(TailnetShare(kind: kind, port: port, path: "/", target: "", funnel: funnel)) }
                    for (mount, web) in handlers {
                        let target = web.proxy ?? web.path ?? web.redirect ?? (web.text == nil ? "" : "text")
                        found.append(TailnetShare(kind: kind, port: port, path: mount, target: target, funnel: funnel))
                    }
                } else if let forward = handler.tcpForward, !forward.isEmpty {
                    found.append(TailnetShare(kind: .tcp, port: port, path: "", target: forward, funnel: funnel))
                }
            }
        }
        var seen = Set<String>()
        return found.sorted { ($0.port, $0.path) < ($1.port, $1.path) }.filter { seen.insert("\($0.port)\($0.path)").inserted }
    }
}

/// The parts of Tailscale's ServeConfig that say what is shared.
struct ServeConfig: Decodable {
    struct TCPHandler: Decodable {
        let https: Bool?
        let http: Bool?
        let tcpForward: String?
        enum CodingKeys: String, CodingKey { case https = "HTTPS", http = "HTTP", tcpForward = "TCPForward" }
    }
    struct WebHandler: Decodable {
        let path: String?
        let proxy: String?
        let text: String?
        let redirect: String?
        enum CodingKeys: String, CodingKey { case path = "Path", proxy = "Proxy", text = "Text", redirect = "Redirect" }
    }
    struct Web: Decodable {
        let handlers: [String: WebHandler]?
        enum CodingKeys: String, CodingKey { case handlers = "Handlers" }
    }
    let tcp: [String: TCPHandler]?
    let web: [String: Web]?
    let allowFunnel: [String: Bool]?
    let foreground: [String: ServeConfig]?
    enum CodingKeys: String, CodingKey { case tcp = "TCP", web = "Web", allowFunnel = "AllowFunnel", foreground = "Foreground" }
}
