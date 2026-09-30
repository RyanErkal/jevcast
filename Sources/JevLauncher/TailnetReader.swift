import Foundation
import LauncherCore

/// Where the Tailnet view gets its data. Tests and demo snapshots use their own.
protocol TailnetReading: Sendable {
    /// `tailscale status --json` from the Tailscale app on this Mac.
    func status() async throws -> TailnetStatus
    /// What this Mac shares with `tailscale serve`.
    func localShares() async -> [TailnetShare]
    /// This Mac's load, read locally.
    func localStats() async -> DeviceStats
    /// The Jevcast agent's report from another device, or nil when it has none. Uses the network.
    func report(from ip: String) async -> TailnetReport?
    /// What a port answers, or nil when no web server answers. `name` is the device's MagicDNS name,
    /// for HTTPS certificates and Serve. Uses the network.
    func check(_ ip: String, port: Int, name: String?) async -> PortCheck?
    /// The bytes of a page's icon at `path` on the page's own server. Uses the network.
    func icon(_ ip: String, port: Int, secure: Bool, name: String?, path: String) async -> Data?
    /// One `tailscale ping`, or nil when no pong came back. Sends Tailscale's own ping packets.
    func ping(_ ip: String) async -> TailnetPing?
}

/// The real tailnet: the Tailscale CLI with fixed arguments, and requests to Tailscale addresses only.
struct TailscaleReader: TailnetReading {
    /// The app's own binary works as the CLI. Homebrew installs a separate one.
    static let cliPaths = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
    static var cli: String? { cliPaths.first { FileManager.default.isExecutableFile(atPath: $0) } }

    func status() async throws -> TailnetStatus {
        guard let cli = Self.cli else { throw SourceProblem(text: "Tailscale is not installed on this Mac.") }
        let output = (try? await CommandRunner.capture([cli, "status", "--json"], allowFailure: true, timeout: 5)) ?? ""
        guard let status = try? TailnetStatus.parse(Data(output.utf8)) else {
            throw SourceProblem(text: "Tailscale did not answer. Open the Tailscale app, then try again.")
        }
        return status
    }

    func localShares() async -> [TailnetShare] {
        guard let cli = Self.cli,
              let output = try? await CommandRunner.capture([cli, "serve", "status", "--json"], allowFailure: true, timeout: 5) else { return [] }
        return TailnetServe.parse(Data(output.utf8))
    }

    func localStats() async -> DeviceStats { await MacStats.read() }

    func report(from ip: String) async -> TailnetReport? {
        // The agent reads Windows counters before it answers, so it gets longer than a page check.
        guard case .response(let response) = await TailnetHTTP.get(ip, port: TailnetAgent.port, path: TailnetAgent.path, limit: 262_144, deadline: 5),
              response.status == 200 else { return nil }
        return TailnetAgent.parse(response.body)
    }

    func check(_ ip: String, port: Int, name: String?) async -> PortCheck? { await TailnetHTTP.check(ip, port: port, name: name) }

    func icon(_ ip: String, port: Int, secure: Bool, name: String?, path: String) async -> Data? {
        await TailnetHTTP.icon(ip, port: port, secure: secure, name: name, path: path)
    }

    func ping(_ ip: String) async -> TailnetPing? {
        guard let cli = Self.cli, TailnetAddress.isTailnet(ip),
              let output = try? await CommandRunner.capture([cli, "ping", "-c", "1", "--timeout", "2s", ip], allowFailure: true, timeout: 4) else { return nil }
        return TailnetPing.parse(output)
    }
}

/// GET requests to devices on the tailnet, through `TailnetTCP`. Only Tailscale addresses are reached,
/// a redirect is only an answer, no proxy is used, and nothing is cached or stored.
enum TailnetHTTP {
    enum Result: Equatable {
        /// Nothing listens, or a firewall dropped the request.
        case nothing
        /// Something answered, or closed the connection, without HTTP.
        case notHTTP
        /// A TLS server answered with a certificate this Mac does not accept.
        case untrusted
        case response(PlainHTTP.Response)
    }

    /// One GET. `name` is the certificate name for TLS and the Host header; the IP address is used without one.
    static func get(_ ip: String, port: Int, path: String = "/", secure: Bool = false, name: String? = nil, limit: Int, deadline: TimeInterval,
                    send: TailnetTCP.Send = TailnetTCP.send) async -> Result {
        guard TailnetAddress.isTailnet(ip) else { return .nothing }
        let bytes = PlainHTTP.request(host: name ?? ip, port: port, path: path, agent: AppIdentity.name, secure: secure)
        let request = TCPRequest(ip: ip, port: port, security: secure ? .tls(name: name) : .plain, bytes: bytes, limit: limit, deadline: deadline)
        switch await send(request) {
        case .nothing: return .nothing
        case .closedEmpty: return .notHTTP
        case .untrusted: return .untrusted
        case .answered(let data): return PlainHTTP.parse(data).map { .response($0) } ?? .notHTTP
        }
    }

    /// Asks a port for its front page over HTTP, then over HTTPS when the port speaks TLS.
    /// Nil when no web server answers, or a firewall stops the request.
    static func check(_ ip: String, port: Int, name: String?, send: TailnetTCP.Send = TailnetTCP.send) async -> PortCheck? {
        // Plain pages open at the IP address, so the Host header is the address, as the browser sends it.
        let plain = await get(ip, port: port, limit: 65_536, deadline: 1.5, send: send)
        var saysTLS = false
        switch plain {
        case .nothing:
            return nil
        case .response(let response):
            // "Client sent an HTTP request to an HTTPS server."
            saysTLS = response.status == 400 && String(decoding: response.body.prefix(512), as: UTF8.self).localizedCaseInsensitiveContains("https")
            if !saysTLS { return page(port: port, secure: false, response.body) }
        case .notHTTP, .untrusted:
            break
        }
        switch await get(ip, port: port, secure: true, name: name, limit: 65_536, deadline: 1.5, send: send) {
        case .response(let response): return page(port: port, secure: true, response.body)
        // A web server answered; the certificate does not carry this device's name, or signs itself.
        case .untrusted: return PortCheck(port: port, secure: true)
        case .nothing, .notHTTP: return saysTLS ? PortCheck(port: port, secure: true) : nil
        }
    }

    private static func page(port: Int, secure: Bool, _ body: Data) -> PortCheck {
        PortCheck(port: port, secure: secure, title: HTMLTitle.find(in: body), icons: HTMLIcon.candidates(in: body))
    }

    /// An icon file from the page's own server, when it answers 200.
    static func icon(_ ip: String, port: Int, secure: Bool, name: String?, path: String, send: TailnetTCP.Send = TailnetTCP.send) async -> Data? {
        guard case .response(let response) = await get(ip, port: port, path: path, secure: secure, name: secure ? name : nil, limit: 262_144,
                                                       deadline: 2, send: send),
              response.status == 200, !response.body.isEmpty else { return nil }
        return response.body
    }
}
