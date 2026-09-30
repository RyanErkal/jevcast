import Foundation

/// How this Mac reaches a device, from `tailscale status`.
public struct TailnetLink: Equatable, Sendable {
    /// True when packets go straight to the device, not through a Tailscale relay.
    public let direct: Bool
    /// The relay's region, such as "lhr". Empty when unknown.
    public let relay: String
    /// Bytes this Mac received from the device and sent to it since Tailscale started.
    public let received: Int64
    public let sent: Int64

    public init(direct: Bool, relay: String = "", received: Int64 = 0, sent: Int64 = 0) {
        self.direct = direct; self.relay = relay; self.received = received; self.sent = sent
    }

    /// "Direct, 64 ms" or "Relayed through lhr, 120 ms". A ping says the current route, so it wins.
    public func route(ping: TailnetPing?) -> String {
        let direct = ping?.direct ?? self.direct
        let relay = ping?.relay ?? relay
        let route = direct ? "Direct" : (relay.isEmpty ? "Relayed" : "Relayed through \(relay)")
        return ping.map { route + ", \(Int($0.milliseconds.rounded())) ms" } ?? route
    }

    /// "Received 638 MB, sent 46 MB". Nil before any traffic.
    public var traffic: String? {
        guard received > 0 || sent > 0 else { return nil }
        return "Received \(Self.amount(Double(received))), sent \(Self.amount(Double(sent)))"
    }

    /// Binary units: "900 KB", "46 MB", "1.2 GB".
    public static func amount(_ bytes: Double) -> String {
        if bytes >= 1_073_741_824 { return DeviceStats.size(bytes) }
        if bytes >= 1_048_576 { return "\(Int((bytes / 1_048_576).rounded())) MB" }
        return "\(max(Int((bytes / 1024).rounded()), bytes > 0 ? 1 : 0)) KB"
    }
}

/// One answer from `tailscale ping -c 1`.
public struct TailnetPing: Equatable, Sendable {
    public let milliseconds: Double
    public let direct: Bool
    /// The relay's region, such as "lhr", when the pong came through a relay.
    public let relay: String?

    public init(milliseconds: Double, direct: Bool, relay: String? = nil) {
        self.milliseconds = milliseconds; self.direct = direct; self.relay = relay
    }

    /// Reads "pong from studio-pc (100.64.0.2) via [2a01::1]:41641 in 64ms" or "… via DERP(lhr) in 120ms".
    /// Nil when no pong came back.
    public static func parse(_ output: String) -> TailnetPing? {
        for line in output.split(whereSeparator: \.isNewline).reversed() where line.hasPrefix("pong from") {
            let words = line.split(separator: " ").map(String.init)
            guard let via = words.firstIndex(of: "via"), via + 3 < words.count, words[via + 2] == "in",
                  words[via + 3].hasSuffix("ms"), let ms = Double(words[via + 3].dropLast(2)) else { continue }
            let route = words[via + 1]
            if route.hasPrefix("DERP("), route.hasSuffix(")") {
                return TailnetPing(milliseconds: ms, direct: false, relay: String(route.dropFirst(5).dropLast()))
            }
            // A peer relay is another tailnet device that passes the packets on.
            if route.hasPrefix("peer-relay") { return TailnetPing(milliseconds: ms, direct: false, relay: "a peer relay") }
            return TailnetPing(milliseconds: ms, direct: true)
        }
        return nil
    }
}
