import Foundation
import LauncherCore

/// Invented devices for `--snapshot-ui --demo`, so captures never show a real tailnet.
struct DemoTailnet: TailnetReading {
    private static let gib = 1_073_741_824.0
    private static let pc = "100.64.0.2", server = "100.64.0.3"

    func status() async throws -> TailnetStatus {
        TailnetStatus(backendState: "Running", devices: [
            TailnetDevice(id: "demo-mac", name: "studio-mac", dnsName: "studio-mac.tail0000.ts.net", addresses: ["100.64.0.1"], os: "macOS", online: true, isSelf: true),
            TailnetDevice(id: "demo-server", name: "home-server", dnsName: "home-server.tail0000.ts.net", addresses: [Self.server], os: "linux", online: true,
                          link: TailnetLink(direct: false, relay: "ams", received: 84_000_000, sent: 12_500_000), keyExpiry: Date().addingTimeInterval(9 * 86_400)),
            TailnetDevice(id: "demo-phone", name: "pocket-phone", dnsName: "pocket-phone.tail0000.ts.net", addresses: ["100.64.0.4"], os: "iOS", online: true),
            TailnetDevice(id: "demo-pc", name: "studio-pc", dnsName: "studio-pc.tail0000.ts.net", addresses: [Self.pc], os: "windows", online: true,
                          link: TailnetLink(direct: true, received: 1_530_000_000, sent: 96_000_000), keyExpiry: Date().addingTimeInterval(160 * 86_400),
                          acceptsFiles: true),
            TailnetDevice(id: "demo-laptop", name: "travel-laptop", dnsName: "travel-laptop.tail0000.ts.net", addresses: ["100.64.0.5"], os: "macOS",
                          online: false, lastSeen: Date().addingTimeInterval(-2 * 86_400))
        ])
    }

    func localShares() async -> [TailnetShare] { [TailnetShare(kind: .https, port: 443, path: "/", target: "http://127.0.0.1:5173")] }

    func localStats() async -> DeviceStats {
        DeviceStats(cpuPercent: 14, memoryUsed: 11.2 * Self.gib, memoryTotal: 24 * Self.gib,
                    disks: [.init(name: "", total: 926 * Self.gib, free: 412 * Self.gib)], uptime: 3 * 86_400 + 5 * 3600)
    }

    func report(from ip: String) async -> TailnetReport? {
        guard ip == Self.pc else { return nil }
        return TailnetReport(os: "Windows 11 Pro",
                             stats: DeviceStats(cpuPercent: 37, memoryUsed: 18.4 * Self.gib, memoryTotal: 64 * Self.gib,
                                                disks: [.init(name: "C:", total: 1862 * Self.gib, free: 704 * Self.gib),
                                                        .init(name: "D:", total: 3726 * Self.gib, free: 2150 * Self.gib)],
                                                uptime: 26 * 3600 + 40 * 60),
                             listeners: [.init(port: 3000, process: "node"), .init(port: 8000, process: "python")],
                             shares: [TailnetShare(kind: .https, port: 8443, path: "/", target: "http://127.0.0.1:7860")])
    }

    func check(_ ip: String, port: Int, name: String?) async -> PortCheck? {
        switch (ip, port) {
        case (Self.pc, 3000): return PortCheck(port: port, secure: false, title: "Team dashboard")
        case (Self.pc, 8000): return PortCheck(port: port, secure: false, title: "Photo archive")
        case (Self.server, 8080): return PortCheck(port: port, secure: false, title: "Build status")
        case (Self.pc, 8443): return PortCheck(port: port, secure: true, title: "Image studio")
        default: return nil
        }
    }

    func icon(_ ip: String, port: Int, secure: Bool, name: String?, path: String) async -> Data? { nil }

    func ping(_ ip: String) async -> TailnetPing? {
        ip == Self.pc ? TailnetPing(milliseconds: 4, direct: true) : ip == Self.server ? TailnetPing(milliseconds: 38, direct: false, relay: "ams") : nil
    }
}
