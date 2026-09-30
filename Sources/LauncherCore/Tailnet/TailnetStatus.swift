import Foundation

/// One device on the tailnet, from `tailscale status --json`.
public struct TailnetDevice: Equatable, Sendable, Identifiable {
    public let id: String
    /// The MagicDNS label, such as "studio-pc", or the host name when there is none.
    public let name: String
    /// The full MagicDNS name without the final dot, such as "studio-pc.tail1234.ts.net". Empty without one.
    public let dnsName: String
    /// Tailscale addresses, IPv4 first.
    public let addresses: [String]
    /// As Tailscale names it: "macOS", "windows", "linux", "iOS", "android".
    public let os: String
    public let online: Bool
    public let lastSeen: Date?
    /// True for this Mac.
    public let isSelf: Bool
    /// How this Mac reaches it. Nil for this Mac.
    public let link: TailnetLink?
    /// When its node key expires and it must sign in again. Nil when the key does not expire.
    public let keyExpiry: Date?
    /// True when Taildrop can send it files.
    public let acceptsFiles: Bool

    public init(id: String, name: String, dnsName: String = "", addresses: [String] = [], os: String, online: Bool, lastSeen: Date? = nil,
                isSelf: Bool = false, link: TailnetLink? = nil, keyExpiry: Date? = nil, acceptsFiles: Bool = false) {
        self.id = id; self.name = name; self.dnsName = dnsName; self.addresses = addresses
        self.os = os; self.online = online; self.lastSeen = lastSeen; self.isSelf = isSelf
        self.link = link; self.keyExpiry = keyExpiry; self.acceptsFiles = acceptsFiles
    }

    /// Phones and tablets are left out: they share no pages and report no load.
    public var isMobile: Bool { ["ios", "ipados", "android"].contains(os.lowercased()) }
    public var ipv4: String? { addresses.first { !$0.contains(":") } }
    public var isWindows: Bool { os.lowercased() == "windows" }
    public var osName: String {
        switch os.lowercased() {
        case "windows": return "Windows"
        case "macos": return "macOS"
        case "linux": return "Linux"
        case "freebsd": return "FreeBSD"
        default: return os
        }
    }
}

/// What `tailscale status --json` says about the tailnet.
public struct TailnetStatus: Equatable, Sendable {
    /// "Running" when signed in and connected; "Stopped", "NeedsLogin", and others otherwise.
    public let backendState: String
    /// This Mac first, then the other devices by name.
    public let devices: [TailnetDevice]
    public var isRunning: Bool { backendState == "Running" }

    public init(backendState: String, devices: [TailnetDevice]) { self.backendState = backendState; self.devices = devices }

    public static func parse(_ data: Data) throws -> TailnetStatus {
        let raw = try JSONDecoder().decode(RawStatus.self, from: data)
        let peers = (raw.peers ?? [:]).values.map { device($0, isSelf: false) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return TailnetStatus(backendState: raw.backendState ?? "", devices: (raw.selfNode.map { [device($0, isSelf: true)] } ?? []) + peers)
    }

    private static func device(_ node: RawNode, isSelf: Bool) -> TailnetDevice {
        var dnsName = node.dnsName ?? ""
        if dnsName.hasSuffix(".") { dnsName.removeLast() }
        let label = dnsName.split(separator: ".").first.map(String.init) ?? ""
        let ips = node.addresses ?? []
        let link = isSelf ? nil : TailnetLink(direct: !(node.curAddr ?? "").isEmpty, relay: node.relay ?? "",
                                              received: node.rxBytes ?? 0, sent: node.txBytes ?? 0)
        return TailnetDevice(id: node.id ?? dnsName, name: label.isEmpty ? (node.hostName ?? "Device") : label, dnsName: dnsName,
                             addresses: ips.filter { !$0.contains(":") } + ips.filter { $0.contains(":") },
                             os: node.os ?? "", online: node.online ?? isSelf, lastSeen: date(node.lastSeen), isSelf: isSelf,
                             // Taildrop's "available" state is 1.
                             link: link, keyExpiry: date(node.keyExpiry), acceptsFiles: node.taildrop == 1)
    }

    /// Go writes up to nine digits after the second, and "0001-01-01T00:00:00Z" for never.
    static func date(_ text: String?) -> Date? {
        guard var text, !text.isEmpty else { return nil }
        if let dot = text.firstIndex(of: ".") {
            let end = text[text.index(after: dot)...].firstIndex { !$0.isNumber } ?? text.endIndex
            text.removeSubrange(dot..<end)
        }
        guard let date = ISO8601DateFormatter().date(from: text), date.timeIntervalSince1970 > 0 else { return nil }
        return date
    }
}

private struct RawStatus: Decodable {
    let backendState: String?
    let selfNode: RawNode?
    let peers: [String: RawNode]?
    enum CodingKeys: String, CodingKey { case backendState = "BackendState", selfNode = "Self", peers = "Peer" }
}

private struct RawNode: Decodable {
    let id: String?
    let hostName: String?
    let dnsName: String?
    let os: String?
    let addresses: [String]?
    let online: Bool?
    let lastSeen: String?
    let curAddr: String?
    let relay: String?
    let rxBytes: Int64?
    let txBytes: Int64?
    let keyExpiry: String?
    let taildrop: Int?
    enum CodingKeys: String, CodingKey {
        case id = "ID", hostName = "HostName", dnsName = "DNSName", os = "OS", addresses = "TailscaleIPs", online = "Online", lastSeen = "LastSeen"
        case curAddr = "CurAddr", relay = "Relay", rxBytes = "RxBytes", txBytes = "TxBytes", keyExpiry = "KeyExpiry", taildrop = "TaildropTarget"
    }
}

/// Tailscale gives each device an address in 100.64.0.0/10 and one in fd7a:115c:a1e0::/48.
/// Jevcast sends tailnet requests only to these.
public enum TailnetAddress {
    public static func isTailnet(_ host: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            let bytes = withUnsafeBytes(of: v4.s_addr) { Array($0) }
            return bytes[0] == 100 && bytes[1] & 0xC0 == 64
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            return withUnsafeBytes(of: v6) { Array($0.prefix(6)) } == [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0]
        }
        return false
    }
}
