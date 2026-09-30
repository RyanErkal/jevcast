import AppKit
import XCTest
import LauncherCore
@testable import JevLauncher

/// Records every question, so a test can prove which devices were asked.
private final class FakeTailnet: TailnetReading, @unchecked Sendable {
    /// False for a computer without the agent.
    var hasAgent = true
    private let lock = NSLock()
    private var asked: [String] = []
    var networkCalls: [String] { lock.withLock { asked } }
    private func record(_ call: String) { lock.withLock { asked.append(call) } }

    func status() async throws -> TailnetStatus {
        TailnetStatus(backendState: "Running", devices: [
            TailnetDevice(id: "mac", name: "studio-mac", dnsName: "studio-mac.tail0000.ts.net", addresses: ["100.64.0.1"], os: "macOS", online: true, isSelf: true),
            TailnetDevice(id: "pc", name: "studio-pc", dnsName: "studio-pc.tail0000.ts.net", addresses: ["100.64.0.2"], os: "windows", online: true,
                          link: TailnetLink(direct: false, relay: "lhr", received: 2_097_152, sent: 1024), acceptsFiles: true),
            TailnetDevice(id: "phone", name: "pocket-phone", addresses: ["100.64.0.3"], os: "iOS", online: true),
            TailnetDevice(id: "old", name: "old-server", addresses: ["100.64.0.4"], os: "linux", online: false)
        ])
    }
    func localShares() async -> [TailnetShare] { [TailnetShare(kind: .tcp, port: 8318, path: "", target: "127.0.0.1:8317")] }
    func localStats() async -> DeviceStats { DeviceStats(cpuPercent: 10) }
    func report(from ip: String) async -> TailnetReport? {
        record("report \(ip)")
        guard hasAgent else { return nil }
        return TailnetReport(stats: DeviceStats(cpuPercent: 40), listeners: [.init(port: 3000, process: "node"), .init(port: 5357, process: "System"),
                                                                              .init(port: 8000, process: "python")])
    }
    func check(_ ip: String, port: Int, name: String?) async -> PortCheck? {
        record("check \(ip):\(port)")
        return PortCheck(port: port, secure: false, title: port == 3000 ? "Dashboard" : nil, icons: port == 3000 ? ["/favicon.png"] : [])
    }
    func icon(_ ip: String, port: Int, secure: Bool, name: String?, path: String) async -> Data? {
        record("icon \(ip):\(port)\(path)")
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        return image?.representation(using: .png, properties: [:])
    }
    func ping(_ ip: String) async -> TailnetPing? {
        record("ping \(ip)")
        return TailnetPing(milliseconds: 12, direct: true)
    }
}

final class TailnetSourceTests: XCTestCase {
    @MainActor private func make(checks: Bool, hidden: [String] = []) -> (TailnetSource, FakeTailnet, Preferences, () -> Void) {
        let suite = "JevLauncherTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let preferences = Preferences(defaults: defaults)
        preferences.tailnetChecks = checks
        preferences.tailnetHiddenPages = hidden
        let reader = FakeTailnet()
        // Every load asks again, so a test sees each survey.
        return (TailnetSource(preferences: preferences, reader: reader, surveyInterval: 0), reader, preferences, { defaults.removePersistentDomain(forName: suite) })
    }

    @MainActor func testWithChecksOffNoDeviceIsAsked() async throws {
        let (source, reader, _, done) = make(checks: false); defer { done() }
        let rows = try await source.load("")
        XCTAssertEqual(reader.networkCalls, [], "Only the local CLI and this Mac are read.")
        XCTAssertEqual(rows.map(\.id), ["tailnet:checks", "tailnet:device:pc", "tailnet:device:mac", "tailnet:page:mac:8318/", "tailnet:device:old"],
                       "Phones are left out; this Mac's own shares still show.")
        XCTAssertEqual(rows[1].detail, "Windows · Relayed through lhr · Received 2 MB, sent 1 KB", "The link comes from the local status.")
        XCTAssertEqual(rows[2].title, "studio-mac (this Mac)")
        XCTAssertEqual(rows[3].detail, "studio-mac:8318 · Serve to 127.0.0.1:8317")
        XCTAssertEqual(rows[4].detail, "Linux · Offline")
    }

    @MainActor func testWithChecksOnListsPagesIconsAndPings() async throws {
        let (source, reader, preferences, done) = make(checks: true, hidden: ["studio-pc:8000"]); defer { done() }
        let rows = try await source.load("")
        XCTAssertEqual(Set(reader.networkCalls), ["report 100.64.0.2", "ping 100.64.0.2", "check 100.64.0.2:3000", "check 100.64.0.2:8000",
                                                  "check 100.64.0.1:8318", "icon 100.64.0.2:3000/favicon.png"],
                       "Online computers and this Mac's own share only; never the phone or the offline server.")
        XCTAssertFalse(rows.contains { $0.id == "tailnet:checks" })
        XCTAssertEqual(rows.map(\.id), ["tailnet:device:pc", "tailnet:page:pc:3000/", "tailnet:device:mac", "tailnet:page:mac:8318/", "tailnet:device:old"])
        XCTAssertEqual(rows[0].detail, "Windows · Direct, 12 ms · CPU 40% · Received 2 MB, sent 1 KB")
        XCTAssertEqual(rows[1].title, "Dashboard")
        XCTAssertEqual(rows[1].detail, "studio-pc:3000 · node")
        XCTAssertNotNil(source.icon(for: "tailnet:page:pc:3000/"))
        XCTAssertEqual(rows[3].detail, "http://100.64.0.1:8318/ · Serve to 127.0.0.1:8317", "This Mac's share answered, so it opens as a page.")
        for row in rows { XCTAssertNotNil(NSImage(systemSymbolName: row.symbol, accessibilityDescription: nil), "Missing symbol \(row.symbol)") }
        XCTAssertEqual(preferences.tailnetPages.map(\.id), ["pc:3000/", "mac:8318/"], "Kept for search; hidden pages are not.")
        XCTAssertEqual(preferences.tailnetPages.first?.url.absoluteString, "http://100.64.0.2:3000/")

        // A later load shows what is known at once, asks again in the background, and then asks the view to show it.
        // Pages and icons are kept for a while; load figures and pings are asked again.
        var updates = 0
        source.onUpdate = { updates += 1 }
        let again = try await source.load("")
        XCTAssertEqual(again.map(\.id), rows.map(\.id))
        await source.settle()
        XCTAssertEqual(updates, 1)
        XCTAssertEqual(reader.networkCalls.filter { $0.hasPrefix("check") || $0.hasPrefix("icon") }.count, 4)
        XCTAssertEqual(reader.networkCalls.filter { $0.hasPrefix("report") || $0.hasPrefix("ping") }.count, 4)
    }

    @MainActor func testAComputerWithoutTheAgentIsAskedAgainOnlyWithItsPages() async throws {
        let (source, reader, _, done) = make(checks: true); defer { done() }
        reader.hasAgent = false
        let rows = try await source.load("")
        XCTAssertEqual(rows.first?.detail, "Windows · Direct, 12 ms · Received 2 MB, sent 1 KB · Run the Jevcast agent on it to see its load")
        XCTAssertEqual(reader.networkCalls.filter { $0.hasPrefix("check 100.64.0.2") }.count, TailnetAgent.commonPorts.count, "Common ports without the agent.")
        _ = try await source.load("")
        await source.settle()
        XCTAssertEqual(reader.networkCalls.filter { $0.hasPrefix("report") }, ["report 100.64.0.2"], "Not asked again on every reload.")
    }

    @MainActor func testDeviceActionsFitEachComputer() {
        let pc = TailnetDevice(id: "pc", name: "studio-pc", dnsName: "studio-pc.tail0000.ts.net", addresses: ["100.64.0.2"], os: "windows", online: true, acceptsFiles: true)
        XCTAssertEqual(TailnetActions.verbs(for: pc).map(\.title), ["Remote Desktop", "Send Files…", "Copy SSH Command", "Copy Name", "Copy IP Address"])
        let mac = TailnetDevice(id: "m", name: "air", addresses: ["100.64.0.5"], os: "macOS", online: true)
        XCTAssertEqual(TailnetActions.verbs(for: mac).map(\.title), ["Screen Sharing", "Copy SSH Command", "Copy IP Address"])
        let away = TailnetDevice(id: "pc", name: "studio-pc", addresses: ["100.64.0.2"], os: "windows", online: false, acceptsFiles: true)
        XCTAssertFalse(TailnetActions.verbs(for: away).map(\.title).contains("Send Files…"), "Taildrop needs the device online.")
        let me = TailnetDevice(id: "me", name: "studio-mac", dnsName: "studio-mac.tail0000.ts.net", addresses: ["100.64.0.1"], os: "macOS", online: true, isSelf: true)
        XCTAssertEqual(TailnetActions.verbs(for: me).map(\.title), ["Copy Name", "Copy IP Address"])
    }

    @MainActor func testSearchFindsKnownPagesWithoutAskingTheTailnet() {
        let suite = "JevLauncherTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.voiceEnabled = false; preferences.jevEnabled = false; preferences.fileFolders = []
        preferences.tailnetPages = [TailnetKnownPage(id: "pc:8080/", title: "qBittorrent WebUI", label: "studio-pc:8080", url: URL(string: "http://100.64.0.2:8080/")!)]
        let model = LauncherModel(preferences: preferences, catalogue: AppCatalogue(loadCache: false),
                                  keys: JevKeyCache(key: nil), clipboard: ClipboardHistory(pasteboard: FakePasteboard()))
        model.begin(); defer { model.end() }
        model.updateQuery("qbit", typed: true)
        let row = model.results.first { $0.id == "tailnet:search:pc:8080/" }
        XCTAssertEqual(row?.detail, "studio-pc:8080 · Tailnet page")
        XCTAssertFalse(model.jevCandidates().candidates.contains { $0.title == "qBittorrent WebUI" }, "Jev never sees tailnet pages.")
    }

    func testRequestsGoOnlyToTailscaleAddresses() async {
        let refuse: TailnetTCP.Send = { request in XCTFail("No connection to \(request.ip)"); return .nothing }
        let lan = await TailnetHTTP.get("192.168.1.20", port: 80, limit: 10, deadline: 1, send: refuse)
        XCTAssertEqual(lan, .nothing)
        let named = await TailnetHTTP.get("studio-pc.tail0000.ts.net", port: 80, limit: 10, deadline: 1, send: refuse)
        XCTAssertEqual(named, .nothing, "A name is never looked up.")
        let sent = await TailnetTCP.send(TCPRequest(ip: "example.com", port: 80, security: .plain, bytes: Data(), limit: 10, deadline: 1))
        XCTAssertEqual(sent, .nothing, "The sender refuses other hosts too.")
    }

    func testCheckReadsTitlesAndUsesTheNameForHTTPS() async {
        let tlsNotice = TCPOutcome.answered(Data("HTTP/1.0 400 Bad Request\r\n\r\nClient sent an HTTP request to an HTTPS server.".utf8))
        let plain: [Int: TCPOutcome] = [
            3000: .answered(Data("HTTP/1.1 200 OK\r\nContent-Length: 51\r\n\r\n<title>Dashboard</title><link rel=icon href=/i.png>".utf8)),
            443: tlsNotice, 8443: tlsNotice, 22: .answered(Data("SSH-2.0-OpenSSH_9.8\r\n".utf8)), 9: .nothing
        ]
        let secure: [Int: TCPOutcome] = [443: .answered(Data("HTTP/1.1 200 OK\r\nContent-Length: 22\r\n\r\n<title>T3 Code</title>".utf8)),
                                         8443: .untrusted, 22: .nothing]
        let send: TailnetTCP.Send = { request in
            let text = String(decoding: request.bytes, as: UTF8.self)
            switch request.security {
            case .plain:
                XCTAssertTrue(text.hasPrefix("GET / HTTP/1.1\r\nHost: 100.64.0.2:\(request.port)\r\n"), "Plain pages open at the address.")
                return plain[request.port] ?? .nothing
            case .tls(let name):
                XCTAssertEqual(name, "studio-pc.tail0000.ts.net")
                XCTAssertTrue(text.contains("Host: studio-pc.tail0000.ts.net"), text)
                return secure[request.port] ?? .nothing
            }
        }
        let name = "studio-pc.tail0000.ts.net"
        let page = await TailnetHTTP.check("100.64.0.2", port: 3000, name: name, send: send)
        XCTAssertEqual(page, PortCheck(port: 3000, secure: false, title: "Dashboard", icons: ["/i.png", "/favicon.ico"]))
        let serve = await TailnetHTTP.check("100.64.0.2", port: 443, name: name, send: send)
        XCTAssertEqual(serve, PortCheck(port: 443, secure: true, title: "T3 Code", icons: ["/favicon.ico"]), "The name gives a valid certificate and the title.")
        let selfSigned = await TailnetHTTP.check("100.64.0.2", port: 8443, name: name, send: send)
        XCTAssertEqual(selfSigned, PortCheck(port: 8443, secure: true))
        let ssh = await TailnetHTTP.check("100.64.0.2", port: 22, name: name, send: send)
        XCTAssertNil(ssh, "Not HTTP, and no HTTPS either.")
        let closed = await TailnetHTTP.check("100.64.0.2", port: 9, name: name, send: send)
        XCTAssertNil(closed)
    }
}
