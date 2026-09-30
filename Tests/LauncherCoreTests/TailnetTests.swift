import XCTest
@testable import LauncherCore

final class TailnetTests: XCTestCase {
    private let status = """
    {"BackendState":"Running","MagicDNSSuffix":"tail0000.ts.net",
     "Self":{"ID":"n1","HostName":"Studio Mac","DNSName":"studio-mac.tail0000.ts.net.","OS":"macOS","TailscaleIPs":["fd7a:115c:a1e0::1","100.64.0.1"],"Online":true},
     "Peer":{
      "k2":{"ID":"n2","HostName":"STUDIO-PC","DNSName":"studio-pc.tail0000.ts.net.","OS":"windows","TailscaleIPs":["100.64.0.2","fd7a:115c:a1e0::2"],"Online":true,"LastSeen":"0001-01-01T00:00:00Z",
            "CurAddr":"[2a01::1]:41641","Relay":"lhr","RxBytes":668991488,"TxBytes":48234496,"KeyExpiry":"2027-03-03T22:23:30Z","TaildropTarget":1},
      "k3":{"ID":"n3","HostName":"pocket","DNSName":"pocket-phone.tail0000.ts.net.","OS":"iOS","TailscaleIPs":["100.64.0.3"],"Online":true},
      "k4":{"ID":"n4","HostName":"box","DNSName":"","OS":"linux","TailscaleIPs":["100.64.0.4"],"Online":false,"LastSeen":"2026-09-28T10:15:30.123456789Z"}
     }}
    """

    func testReadsStatusWithThisMacFirst() throws {
        let parsed = try TailnetStatus.parse(Data(status.utf8))
        XCTAssertTrue(parsed.isRunning)
        XCTAssertEqual(parsed.devices.map(\.name), ["studio-mac", "box", "pocket-phone", "studio-pc"])
        let mac = parsed.devices[0]
        XCTAssertTrue(mac.isSelf)
        XCTAssertEqual(mac.dnsName, "studio-mac.tail0000.ts.net")
        XCTAssertEqual(mac.addresses, ["100.64.0.1", "fd7a:115c:a1e0::1"], "IPv4 first.")
        XCTAssertEqual(parsed.devices[1].name, "box", "Without MagicDNS the host name is used.")
        XCTAssertEqual(parsed.devices[1].lastSeen, Date(timeIntervalSince1970: 1_790_590_530))
        XCTAssertNil(parsed.devices[3].lastSeen, "Year one means never.")
        XCTAssertTrue(parsed.devices[2].isMobile)
        XCTAssertFalse(parsed.devices[3].isMobile)
        XCTAssertEqual(parsed.devices[3].osName, "Windows")
        XCTAssertEqual(parsed.devices[3].link, TailnetLink(direct: true, relay: "lhr", received: 668_991_488, sent: 48_234_496))
        XCTAssertEqual(parsed.devices[3].keyExpiry, Date(timeIntervalSince1970: 1_804_112_610))
        XCTAssertTrue(parsed.devices[3].acceptsFiles)
        XCTAssertEqual(parsed.devices[1].link, TailnetLink(direct: false), "No address in use means a relay.")
        XCTAssertFalse(parsed.devices[1].acceptsFiles)
        XCTAssertNil(mac.link, "This Mac has no link to itself.")
        XCTAssertFalse(try TailnetStatus.parse(Data(#"{"BackendState":"NeedsLogin"}"#.utf8)).isRunning)
        XCTAssertThrowsError(try TailnetStatus.parse(Data("failed to connect to local Tailscale service".utf8)))
    }

    func testOnlyTailscaleAddressesAreTailnet() {
        for host in ["100.64.0.1", "100.127.255.254", "fd7a:115c:a1e0::1", "fd7a:115c:a1e0:ab12::7"] {
            XCTAssertTrue(TailnetAddress.isTailnet(host), host)
        }
        for host in ["100.63.255.255", "100.128.0.1", "192.168.1.20", "10.0.0.1", "127.0.0.1", "fd7a:115c:a1e1::1", "::1",
                     "studio-pc.tail0000.ts.net", "example.com", "100.64.0.1.example.com", ""] {
            XCTAssertFalse(TailnetAddress.isTailnet(host), host)
        }
    }

    func testReadsServeWebTCPFunnelAndForegroundShares() {
        let json = """
        {"TCP":{"443":{"HTTPS":true},"8318":{"TCPForward":"127.0.0.1:8317"},"8080":{"HTTP":true}},
         "Web":{"studio-mac.tail0000.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"},"/files":{"Path":"/Users/me/Public"}}},
                "studio-mac.tail0000.ts.net:8080":{"Handlers":{"/":{"Text":"hello"}}}},
         "AllowFunnel":{"studio-mac.tail0000.ts.net:443":true},
         "Foreground":{"session1":{"TCP":{"5173":{"HTTP":true}},"Web":{"studio-mac.tail0000.ts.net:5173":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:5173"}}}}}}}
        """
        let shares = TailnetServe.parse(Data(json.utf8))
        XCTAssertEqual(shares, [
            TailnetShare(kind: .https, port: 443, path: "/", target: "http://127.0.0.1:3000", funnel: true),
            TailnetShare(kind: .https, port: 443, path: "/files", target: "/Users/me/Public", funnel: true),
            TailnetShare(kind: .http, port: 5173, path: "/", target: "http://127.0.0.1:5173"),
            TailnetShare(kind: .http, port: 8080, path: "/", target: "text"),
            TailnetShare(kind: .tcp, port: 8318, path: "", target: "127.0.0.1:8317")
        ])
        XCTAssertEqual(TailnetServe.parse(Data("{}".utf8)), [])
        XCTAssertEqual(TailnetServe.parse(Data("".utf8)), [])
    }

    func testReadsTheAgentReportAndPicksPortsToCheck() throws {
        let json = """
        {"agent":"jevcast","version":1,"os":"Microsoft Windows 11 Pro","uptimeSeconds":7200,"cpuPercent":12.4,
         "memoryTotalBytes":34359738368,"memoryUsedBytes":10522669875,
         "disks":[{"name":"C:","totalBytes":511101108224,"freeBytes":128849018880}],
         "listening":[{"port":135,"process":"svchost"},{"port":5357,"process":"System"},{"port":3000,"process":"node"},
                      {"port":41112,"process":"tailscaled.exe"},{"port":61209,"process":"powershell"},{"port":8000,"process":"python"},
                      {"port":8443,"process":"caddy"},{"port":0,"process":"bad"}],
         "serve":{"TCP":{"8443":{"HTTPS":true},"9000":{"TCPForward":"127.0.0.1:9001"},"61209":{"TCPForward":"127.0.0.1:61209"}},
                  "Web":{"studio-pc.tail0000.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:7860"}}}}}}
        """
        let report = try XCTUnwrap(TailnetAgent.parse(Data(json.utf8)))
        XCTAssertEqual(report.os, "Microsoft Windows 11 Pro")
        XCTAssertEqual(report.stats.cpuPercent, 12.4)
        XCTAssertEqual(report.stats.disks, [DeviceStats.Disk(name: "C:", total: 511_101_108_224, free: 128_849_018_880)])
        XCTAssertEqual(report.listeners.count, 7, "A port of 0 is dropped.")
        XCTAssertEqual(report.shares.map(\.port), [8443, 9000, 61209])
        XCTAssertEqual(TailnetAgent.portsToCheck(report), [3000, 8000, 8443, 9000],
                       "Services, Tailscale, and the agent itself are not checked; shares are, for their titles.")
        XCTAssertEqual(TailnetAgent.sharePorts(report.shares), [8443, 9000])
        XCTAssertEqual(TailnetAgent.portsToCheck(nil), TailnetAgent.commonPorts)
        XCTAssertNil(TailnetAgent.parse(Data(#"{"agent":"glances","cpuPercent":3}"#.utf8)), "Another program's JSON is not a report.")
        XCTAssertNil(TailnetAgent.parse(Data("<html>".utf8)))
    }

    func testMergesSharesAndAnsweredPorts() {
        let shares = [TailnetShare(kind: .https, port: 8443, path: "/", target: "http://127.0.0.1:7860", funnel: true),
                      TailnetShare(kind: .tcp, port: 9000, path: "", target: "127.0.0.1:9001"),
                      TailnetShare(kind: .tcp, port: 9100, path: "", target: "127.0.0.1:22")]
        let checks = [PortCheck(port: 3000, secure: false, title: "Dashboard"), PortCheck(port: 9000, secure: false, title: "Admin"),
                      PortCheck(port: 8443, secure: true)]
        let pages = TailnetPages.merge(shares: shares, checks: checks, listeners: [.init(port: 3000, process: "node")])
        XCTAssertEqual(TailnetPages.merge(shares: [shares[0]], checks: [PortCheck(port: 8443, secure: true, title: "Image studio", icons: ["/i.png"])], listeners: []),
                       [TailnetPage(scheme: .https, port: 8443, title: "Image studio", via: "http://127.0.0.1:7860", serve: true, funnel: true, icons: ["/i.png"])],
                       "A share at / takes the title of the page on its port.")
        XCTAssertEqual(pages, [
            TailnetPage(scheme: .http, port: 3000, title: "Dashboard", via: "node"),
            TailnetPage(scheme: .https, port: 8443, via: "http://127.0.0.1:7860", serve: true, funnel: true),
            TailnetPage(scheme: .http, port: 9000, title: "Admin", via: "127.0.0.1:9001", serve: true),
            TailnetPage(scheme: .tcp, port: 9100, via: "127.0.0.1:22", serve: true)
        ])
    }

    func testPageAddresses() {
        let dns = "studio-pc.tail0000.ts.net", ip = "100.64.0.2"
        XCTAssertEqual(TailnetPage(scheme: .https, port: 443).url(dnsName: dns, ip: ip)?.absoluteString, "https://studio-pc.tail0000.ts.net/")
        XCTAssertEqual(TailnetPage(scheme: .https, port: 8443, path: "/api").url(dnsName: dns, ip: ip)?.absoluteString,
                       "https://studio-pc.tail0000.ts.net:8443/api")
        XCTAssertEqual(TailnetPage(scheme: .http, port: 3000).url(dnsName: dns, ip: ip)?.absoluteString, "http://100.64.0.2:3000/")
        XCTAssertEqual(TailnetPage(scheme: .http, port: 80).url(dnsName: dns, ip: nil)?.absoluteString, "http://studio-pc.tail0000.ts.net/")
        XCTAssertNil(TailnetPage(scheme: .tcp, port: 22).url(dnsName: dns, ip: ip))
        XCTAssertEqual(TailnetPage(scheme: .https, port: 443, path: "/files").label(on: "studio-pc"), "studio-pc:443/files")
        XCTAssertEqual(TailnetPage(scheme: .http, port: 3000).label(on: "studio-pc"), "studio-pc:3000")
    }

    func testFindsThePageTitle() {
        XCTAssertEqual(HTMLTitle.find(in: Data("<html><head><TITLE lang=en>  Team &amp; Co\n  dashboard </TITLE>".utf8)), "Team & Co dashboard")
        XCTAssertEqual(HTMLTitle.find(in: Data("<titlebar>no</titlebar><title>Real</title>".utf8)), "Real")
        XCTAssertNil(HTMLTitle.find(in: Data("<title></title>".utf8)))
        XCTAssertNil(HTMLTitle.find(in: Data(#"{"ok":true}"#.utf8)))
    }

    func testSummarisesLoad() {
        let gib = 1_073_741_824.0
        let stats = DeviceStats(cpuPercent: 12.4, memoryUsed: 9.8 * gib, memoryTotal: 32 * gib,
                                disks: [.init(name: "C:", total: 476 * gib, free: 120 * gib), .init(name: "D:", total: 3726 * gib, free: 1843 * gib)],
                                uptime: 3 * 86_400 + 4 * 3600 + 59)
        XCTAssertEqual(stats.summary, "CPU 12% · Memory 9.8 of 32 GB · C: 120 GB free, D: 1.8 TB free · up 3 d 4 h")
        XCTAssertEqual(DeviceStats(disks: [.init(name: "", total: 994 * gib, free: 412.3 * gib)]).summary, "Disk 412 GB free")
        XCTAssertEqual(DeviceStats().summary, "")
        XCTAssertEqual(DeviceStats.duration(4 * 3600 + 12 * 60), "4 h 12 min")
        XCTAssertEqual(DeviceStats.duration(2 * 86_400), "2 d")
        XCTAssertEqual(DeviceStats.duration(20), "1 min")
    }

    func testReadsPlainHTTPAnswers() {
        XCTAssertEqual(String(decoding: PlainHTTP.request(host: "100.64.0.2", port: 3000, path: "/v1/status", agent: "Jevcast"), as: UTF8.self),
                       "GET /v1/status HTTP/1.1\r\nHost: 100.64.0.2:3000\r\nUser-Agent: Jevcast\r\nAccept: */*\r\nConnection: close\r\n\r\n")
        XCTAssertNil(PlainHTTP.parse(Data("HTTP/1.1 200 OK\r\nContent-Len".utf8)), "The head is not whole yet.")
        XCTAssertNil(PlainHTTP.parse(Data("SSH-2.0-OpenSSH\r\n\r\n".utf8)))
        let partial = PlainHTTP.parse(Data("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc".utf8))
        XCTAssertEqual(partial, PlainHTTP.Response(status: 200, body: Data("abc".utf8), complete: false))
        let whole = PlainHTTP.parse(Data("HTTP/1.1 302 Found\r\nLocation: https://example.com/\r\ncontent-length: 3\r\n\r\nabcEXTRA".utf8))
        XCTAssertEqual(whole, PlainHTTP.Response(status: 302, body: Data("abc".utf8), complete: true), "A redirect is only an answer.")
        let chunked = PlainHTTP.parse(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n7\r\n<title>\r\n5;x=1\r\nHello\r\n8\r\n</title>\r\n0\r\n\r\n".utf8))
        XCTAssertEqual(chunked, PlainHTTP.Response(status: 200, body: Data("<title>Hello</title>".utf8), complete: true))
        let cut = PlainHTTP.parse(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n7\r\n<tit".utf8))
        XCTAssertEqual(cut, PlainHTTP.Response(status: 200, body: Data("<tit".utf8), complete: false))
        XCTAssertEqual(PlainHTTP.parse(Data("HTTP/1.0 400 Bad Request\r\n\r\nClient sent".utf8))?.status, 400)
        XCTAssertTrue(String(decoding: PlainHTTP.request(host: "studio-pc.tail0000.ts.net", port: 443, path: "/", agent: "J", secure: true), as: UTF8.self)
            .contains("Host: studio-pc.tail0000.ts.net\r\n"), "The standard port is left out, as a browser does.")
    }

    func testReadsPingsAndDescribesTheLink() {
        XCTAssertEqual(TailnetPing.parse("pong from studio-pc (100.64.0.2) via [2a01:4b00::1]:41641 in 64ms\n"),
                       TailnetPing(milliseconds: 64, direct: true))
        XCTAssertEqual(TailnetPing.parse("pong from box (100.64.0.4) via DERP(lhr) in 118ms"), TailnetPing(milliseconds: 118, direct: false, relay: "lhr"))
        XCTAssertEqual(TailnetPing.parse("pong from box (100.64.0.4) via peer-relay(100.64.0.9:7777:vni:5) in 30ms")?.direct, false)
        XCTAssertNil(TailnetPing.parse("ping \"100.64.0.4\" timed out"))
        let relayed = TailnetLink(direct: false, relay: "lhr", received: 668_991_488, sent: 48_234_496)
        XCTAssertEqual(relayed.route(ping: nil), "Relayed through lhr")
        XCTAssertEqual(relayed.route(ping: TailnetPing(milliseconds: 63.6, direct: true)), "Direct, 64 ms", "A ping gives the current route.")
        XCTAssertEqual(relayed.traffic, "Received 638 MB, sent 46 MB")
        XCTAssertNil(TailnetLink(direct: true).traffic)
        XCTAssertEqual(TailnetLink.amount(1_610_612_736), "1.5 GB")
        XCTAssertEqual(TailnetLink.amount(300), "1 KB")
    }

    func testFindsSiteIcons() {
        let html = Data("""
        <head><link rel="stylesheet" href="/a.css"><link rel="icon" type="image/svg+xml" href="/logo.svg">
        <LINK REL='shortcut icon' HREF='images/fav.png?v=2'><link href="https://studio-pc.tail0000.ts.net/touch.png" rel="apple-touch-icon">
        <link rel="icon" href="https://cdn.example.com/x.png"><link rel="mask-icon" href="/mask.svg"></head>
        """.utf8)
        let found = HTMLIcon.candidates(in: html)
        XCTAssertEqual(found, ["images/fav.png?v=2", "https://studio-pc.tail0000.ts.net/touch.png", "https://cdn.example.com/x.png", "/logo.svg", "/favicon.ico"])
        let hosts: Set<String> = ["100.64.0.2", "studio-pc.tail0000.ts.net"]
        XCTAssertEqual(HTMLIcon.path(found[0], hosts: hosts, port: 443, secure: true), "/images/fav.png?v=2")
        XCTAssertEqual(HTMLIcon.path(found[1], hosts: hosts, port: 443, secure: true), "/touch.png")
        XCTAssertNil(HTMLIcon.path(found[2], hosts: hosts, port: 443, secure: true), "Another server is never asked.")
        XCTAssertNil(HTMLIcon.path("https://studio-pc.tail0000.ts.net:8443/x.png", hosts: hosts, port: 443, secure: true), "Another port neither.")
        XCTAssertEqual(HTMLIcon.path("//100.64.0.2:3000/i.ico", hosts: hosts, port: 3000, secure: false), "/i.ico")
        XCTAssertEqual(HTMLIcon.candidates(in: Data("<title>x</title>".utf8)), ["/favicon.ico"])
        XCTAssertEqual(HTMLIcon.inline("data:image/png;base64,aGk="), Data("hi".utf8))
        XCTAssertNil(HTMLIcon.inline("data:text/html;base64,aGk="))
        XCTAssertNil(HTMLIcon.path("data:image/png;base64,aGk=", hosts: hosts, port: 80, secure: false))
    }

    func testTailnetWordsOpenTheList() {
        XCTAssertEqual(SourceQuery.parse("tailnet")?.kind, .tailnet)
        XCTAssertEqual(SourceQuery.parse("show tailnet devices")?.kind, .tailnet)
        XCTAssertEqual(SourceQuery.parse("tailnet studio")?.filter, "studio")
        XCTAssertNil(SourceQuery.parse("tailscale"), "The word alone still finds the Tailscale app.")
        XCTAssertEqual(FunctionCatalog.search("tailscale", in: FunctionCatalog.builtIn).first?.id, "view:tailnet")
    }
}
