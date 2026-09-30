import Foundation

/// What a port on another device answered.
public struct PortCheck: Equatable, Sendable {
    public let port: Int
    public let secure: Bool
    public let title: String?
    /// The page's icon references, from `HTMLIcon.candidates`.
    public let icons: [String]
    public init(port: Int, secure: Bool, title: String? = nil, icons: [String] = []) {
        self.port = port; self.secure = secure; self.title = title; self.icons = icons
    }
}

/// A page or port that a device shares on the tailnet.
public struct TailnetPage: Equatable, Sendable, Identifiable {
    public enum Scheme: String, Sendable { case http, https, tcp }
    public let scheme: Scheme
    public let port: Int
    public let path: String
    /// The page's own title.
    public let title: String?
    /// What serves it: the process that listens, or where `tailscale serve` sends it.
    public let via: String?
    public let serve: Bool
    public let funnel: Bool
    /// Icon references from the page, from `HTMLIcon.candidates`.
    public let icons: [String]

    public init(scheme: Scheme, port: Int, path: String = "/", title: String? = nil, via: String? = nil, serve: Bool = false, funnel: Bool = false,
                icons: [String] = []) {
        self.scheme = scheme; self.port = port; self.path = path; self.title = title; self.via = via; self.serve = serve; self.funnel = funnel
        self.icons = icons
    }

    public var id: String { "\(port)\(path)" }
    /// "studio-pc:3000", or "studio-pc:443/api" for a path.
    public func label(on device: String) -> String { "\(device):\(port)" + (path == "/" || path.isEmpty ? "" : path) }

    /// HTTPS uses the MagicDNS name, which its certificate needs. HTTP uses the address, which works without MagicDNS.
    public func url(dnsName: String, ip: String?) -> URL? {
        let host: String
        switch scheme {
        case .tcp: return nil
        case .https: host = dnsName.isEmpty ? (ip ?? "") : dnsName
        case .http: host = ip ?? dnsName
        }
        guard !host.isEmpty else { return nil }
        let standard = scheme == .https ? 443 : 80
        let shownHost = host.contains(":") ? "[\(host)]" : host
        return URL(string: "\(scheme.rawValue)://\(shownHost)" + (port == standard ? "" : ":\(port)") + (path.isEmpty ? "/" : path))
    }
}

public enum TailnetPages {
    /// Shares first, then checked ports that answered, by port. A TCP share that answered opens as a page,
    /// and a share at "/" takes the title of the page that answered on its port.
    public static func merge(shares: [TailnetShare], checks: [PortCheck], listeners: [TailnetReport.Listener]) -> [TailnetPage] {
        let answered = Dictionary(checks.map { ($0.port, $0) }, uniquingKeysWith: { first, _ in first })
        let processes = Dictionary(listeners.map { ($0.port, $0.process) }, uniquingKeysWith: { first, _ in first })
        var pages = shares.map { share -> TailnetPage in
            let via = share.target.isEmpty ? nil : share.target
            let check = answered[share.port]
            if share.kind == .tcp, let check {
                return TailnetPage(scheme: check.secure ? .https : .http, port: share.port, title: check.title, via: via, serve: true,
                                   funnel: share.funnel, icons: check.icons)
            }
            let scheme: TailnetPage.Scheme = switch share.kind { case .https: .https; case .http: .http; case .tcp: .tcp }
            let root = share.path == "/"
            return TailnetPage(scheme: scheme, port: share.port, path: share.path.isEmpty ? "/" : share.path, title: root ? check?.title : nil,
                               via: via, serve: true, funnel: share.funnel, icons: root ? check?.icons ?? [] : [])
        }
        let shared = Set(shares.map(\.port))
        pages += checks.filter { !shared.contains($0.port) }.map {
            TailnetPage(scheme: $0.secure ? .https : .http, port: $0.port, title: $0.title, via: processes[$0.port].flatMap { $0.isEmpty ? nil : $0 },
                        icons: $0.icons)
        }
        return pages.sorted { ($0.port, $0.path) < ($1.port, $1.path) }
    }
}

/// A page the Tailnet view found, kept so that a search can open it later.
public struct TailnetKnownPage: Codable, Equatable, Sendable {
    /// "<device ID>:<port><path>".
    public let id: String
    public let title: String
    /// "studio-pc:3000".
    public let label: String
    public let url: URL
    public init(id: String, title: String, label: String, url: URL) { self.id = id; self.title = title; self.label = label; self.url = url }
}
