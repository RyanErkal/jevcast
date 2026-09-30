import AppKit
import ImageIO
import LauncherCore

/// "tailnet" and the Tailnet view: each Tailscale device with its link, its load, and the pages it shares.
/// Phones and tablets are left out. The device list and this Mac's figures are local. Devices, this Mac's
/// own shares included, are asked only when Settings › General › Check tailnet devices is on, and only at
/// their Tailscale address. A load shows what is known at once and asks the devices again in the background;
/// only the first load, with nothing known yet, waits for the answers.
@MainActor
final class TailnetSource: UpdatingSource {
    let section = "Tailnet"
    /// Pages are checked again after this many seconds.
    static let pageLife: TimeInterval = 30
    /// Load figures and pings are asked again after this many seconds.
    private let surveyInterval: TimeInterval
    private let preferences: Preferences
    private let reader: TailnetReading
    private let checksOn: () -> Bool
    var onUpdate: (() -> Void)?
    private var pageCache: [String: (at: Date, pages: [TailnetPage])] = [:]
    private var reports: [String: TailnetReport] = [:]
    private var pings: [String: TailnetPing] = [:]
    /// Devices whose agent did not answer. They are asked again with their pages, not on every survey.
    private var withoutAgent: Set<String> = []
    /// Site icons by row ID. A page whose icon could not be read keeps nil, so it is not asked again.
    private var icons: [String: NSImage?] = [:]
    private var survey: Task<Void, Never>?
    private var surveyedAt = Date.distantPast

    /// `checks` overrides the setting, for demo snapshots.
    init(preferences: Preferences, reader: TailnetReading = TailscaleReader(), checks: (() -> Bool)? = nil, surveyInterval: TimeInterval = 4) {
        self.preferences = preferences; self.reader = reader; self.surveyInterval = surveyInterval
        checksOn = checks ?? { [weak preferences] in preferences?.tailnetChecks ?? false }
    }

    /// What one device answered in a survey.
    struct Found: Sendable {
        var report: TailnetReport?
        var asked = false
        var ping: TailnetPing?
        /// Nil when the pages were not read this time.
        var pages: [TailnetPage]?
    }

    func icon(for rowID: String) -> NSImage? { icons[rowID] ?? nil }

    /// Waits for a survey in progress, for tests.
    func settle() async { await survey?.value }

    func load(_ filter: String) async throws -> [LauncherResult] {
        let status = try await reader.status()
        guard status.isRunning else { throw SourceProblem(text: "Tailscale is not connected. Open Tailscale and connect, then try again.") }
        let checks = checksOn()
        let devices = status.devices.filter { !$0.isMobile }
        if !checks {
            reports = [:]; pings = [:]
            pageCache = pageCache.filter { id, _ in devices.contains { $0.id == id && $0.isSelf } }
        }
        let asked = devices.filter { $0.isSelf || (checks && $0.online) }
        let firstTime = asked.contains { pageCache[$0.id] == nil }
        if survey == nil, firstTime || Date().timeIntervalSince(surveyedAt) >= surveyInterval {
            survey = Task { [weak self] in await self?.runSurvey(devices, checks: checks, announce: !firstTime) }
        }
        async let localStats = reader.localStats()
        if firstTime { await survey?.value }
        return rows(devices, localStats: await localStats, checks: checks)
    }

    /// Asks every device once, keeps the answers, and reads new pages' icons. `announce` asks the view to show them.
    private func runSurvey(_ devices: [TailnetDevice], checks: Bool, announce: Bool) async {
        let now = Date()
        let stale = Set(devices.filter { now.timeIntervalSince(pageCache[$0.id]?.at ?? .distantPast) > Self.pageLife }.map(\.id))
        let reader = self.reader
        let withoutAgent = self.withoutAgent
        let found = await withTaskGroup(of: (String, Found).self) { group -> [String: Found] in
            for device in devices {
                let pages = stale.contains(device.id)
                let askAgent = pages || !withoutAgent.contains(device.id)
                group.addTask { (device.id, await TailnetSource.read(device, reader: reader, checks: checks, pages: pages, askAgent: askAgent)) }
            }
            var all: [String: Found] = [:]
            for await (id, item) in group { all[id] = item }
            return all
        }
        let current = Set(devices.filter { $0.isSelf || (checks && $0.online) }.map(\.id))
        pageCache = pageCache.filter { current.contains($0.key) }
        for (id, item) in found {
            if let pages = item.pages { pageCache[id] = (now, pages) }
            if item.asked { reports[id] = item.report }
            pings[id] = item.ping
        }
        self.withoutAgent = Set(devices.filter { !$0.isSelf && reports[$0.id] == nil }.map(\.id))
        if checks { await loadIcons(devices) }
        surveyedAt = Date()
        survey = nil
        if announce { onUpdate?() }
    }

    /// Reads one device off the main thread. Without the setting, only this Mac's own shares are read.
    nonisolated private static func read(_ device: TailnetDevice, reader: TailnetReading, checks: Bool, pages: Bool, askAgent: Bool) async -> Found {
        let name = device.dnsName.isEmpty ? nil : device.dnsName
        if device.isSelf {
            guard pages else { return Found() }
            let shares = await reader.localShares()
            // This Mac's own shares answer at its own Tailscale address, which gives their titles.
            var answered: [PortCheck] = []
            if checks, let ip = device.ipv4 { answered = await checkPorts(TailnetAgent.sharePorts(shares), ip: ip, name: name, reader: reader) }
            return Found(pages: TailnetPages.merge(shares: shares, checks: answered, listeners: []))
        }
        guard checks, device.online, let ip = device.ipv4 else { return Found() }
        async let ping = reader.ping(ip)
        let report = askAgent ? await reader.report(from: ip) : nil
        var item = Found(report: report, asked: askAgent)
        if pages {
            let answered = await checkPorts(TailnetAgent.portsToCheck(report), ip: ip, name: name, reader: reader)
            item.pages = TailnetPages.merge(shares: report?.shares ?? [], checks: answered, listeners: report?.listeners ?? [])
        }
        item.ping = await ping
        return item
    }

    nonisolated private static func checkPorts(_ ports: [Int], ip: String, name: String?, reader: TailnetReading) async -> [PortCheck] {
        await withTaskGroup(of: PortCheck?.self) { group -> [PortCheck] in
            for port in ports { group.addTask { await reader.check(ip, port: port, name: name) } }
            var all: [PortCheck] = []
            for await check in group { if let check { all.append(check) } }
            return all
        }
    }

    /// Reads each new page's icon once: an inline icon, or up to three files from the page's own server.
    private func loadIcons(_ devices: [TailnetDevice]) async {
        var wanted: [(rowID: String, device: TailnetDevice, page: TailnetPage)] = []
        for device in devices where device.online {
            for page in pageCache[device.id]?.pages ?? [] where page.scheme != .tcp && !page.icons.isEmpty {
                let rowID = Self.pageRowID(device, page)
                if !icons.keys.contains(rowID) { wanted.append((rowID, device, page)) }
            }
        }
        guard !wanted.isEmpty else { return }
        let reader = self.reader
        let loaded = await withTaskGroup(of: (String, Data?).self) { group -> [String: Data?] in
            for item in wanted {
                group.addTask { (item.rowID, await TailnetSource.iconData(item.page, on: item.device, reader: reader)) }
            }
            var all: [String: Data?] = [:]
            for await (rowID, data) in group { all[rowID] = data }
            return all
        }
        for (rowID, data) in loaded { icons[rowID] = data.flatMap(NSImage.init(data:)) }
    }

    nonisolated private static func iconData(_ page: TailnetPage, on device: TailnetDevice, reader: TailnetReading) async -> Data? {
        guard let ip = device.ipv4 else { return nil }
        let secure = page.scheme == .https
        let name = device.dnsName.isEmpty ? nil : device.dnsName
        let hosts = Set([ip, device.dnsName.lowercased()].filter { !$0.isEmpty })
        for href in page.icons.prefix(3) {
            let data: Data?
            if let inline = HTMLIcon.inline(href) { data = inline }
            else if let path = HTMLIcon.path(href, hosts: hosts, port: page.port, secure: secure) {
                data = await reader.icon(ip, port: page.port, secure: secure, name: name, path: path)
            } else { continue }
            // Only images the system can draw; an SVG icon moves on to the next one.
            if let data, let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 { return data }
        }
        return nil
    }

    static func pageRowID(_ device: TailnetDevice, _ page: TailnetPage) -> String { "tailnet:page:\(device.id):\(page.id)" }

    private func rows(_ devices: [TailnetDevice], localStats: DeviceStats, checks: Bool) -> [LauncherResult] {
        var rows: [LauncherResult] = []
        var known: [TailnetKnownPage] = []
        func add(_ id: String, _ title: String, _ detail: String, _ symbol: String, _ verbs: [Verb]) {
            var row = LauncherResult(id: id, title: title, detail: detail, symbol: symbol, action: .thing(Thing(verbs: verbs)), score: 5000 - Double(rows.count))
            row.help = detail
            rows.append(row)
        }
        let peers = devices.filter { !$0.isSelf }
        if !checks, !peers.isEmpty {
            let turnOn = Verb(title: "Turn On", after: .stay) { [weak self] in
                self?.preferences.tailnetChecks = true
                return "Tailnet checks are on. Turn them off in Settings › General."
            }
            add("tailnet:checks", "Check your devices", "Turn on to see their load, their ping, and the pages they share. Jevcast asks only Tailscale addresses.",
                "network", [turnOn])
        }
        let hidden = Set(preferences.tailnetHiddenPages)
        // Online devices first, where the shared pages are; this Mac next; then devices that are off.
        let ordered = peers.filter(\.online) + devices.filter(\.isSelf) + peers.filter { !$0.online }
        for device in ordered {
            add("tailnet:device:" + device.id, device.name + (device.isSelf ? " (this Mac)" : ""), detail(device, localStats: localStats, checks: checks),
                Self.symbol(device), TailnetActions.verbs(for: device))
            guard device.online, device.isSelf || checks else { continue }
            for page in pageCache[device.id]?.pages ?? [] where !hidden.contains(page.label(on: device.name)) {
                let row = pageRow(page, on: device)
                add(Self.pageRowID(device, page), row.title, row.detail, page.scheme == .tcp ? "arrow.left.arrow.right" : "globe", row.verbs)
                if let url = row.url { known.append(TailnetKnownPage(id: "\(device.id):\(page.id)", title: row.title, label: page.label(on: device.name), url: url)) }
            }
        }
        // Kept for search, so typing a page's name finds it without asking the tailnet.
        if preferences.tailnetPages != known { preferences.tailnetPages = known }
        return rows
    }

    private func detail(_ device: TailnetDevice, localStats: DeviceStats, checks: Bool) -> String {
        let report = reports[device.id]
        var parts = [(report?.os).map { $0.replacingOccurrences(of: "Microsoft ", with: "") } ?? device.osName]
        if device.online {
            if let link = device.link { parts.append(link.route(ping: pings[device.id])) } else if !device.isSelf { parts.append("Online") }
            if let summary = (device.isSelf ? localStats : report?.stats)?.summary, !summary.isEmpty { parts.append(summary) }
            if let traffic = device.link?.traffic { parts.append(traffic) }
        } else {
            parts.append("Offline")
            if let seen = device.lastSeen { parts.append("last seen " + seen.formatted(.relative(presentation: .named))) }
        }
        if let expiry = device.keyExpiry {
            parts.append(expiry <= Date() ? "Key expired: sign in again" : "Key expires " + expiry.formatted(.relative(presentation: .named)))
        }
        if checks, device.online, device.isWindows, report == nil { parts.append("Run the Jevcast agent on it to see its load") }
        return parts.joined(separator: " · ")
    }

    private func pageRow(_ page: TailnetPage, on device: TailnetDevice) -> (title: String, detail: String, verbs: [Verb], url: URL?) {
        let label = page.label(on: device.name)
        let url = page.url(dnsName: device.dnsName, ip: device.ipv4)
        var parts = [page.title == nil ? (url?.absoluteString ?? label) : label]
        if page.serve { parts.append(page.via.map { "Serve to " + $0 } ?? "Serve") } else if let via = page.via { parts.append(via) }
        if page.funnel { parts.append("Funnel: public on the internet") }
        let hide = Verb(title: "Hide", after: .stay) { [weak self] in
            self?.preferences.tailnetHiddenPages.append(label)
            return "\(label) is hidden. Settings › General lists hidden pages."
        }
        var verbs: [Verb]
        if let url {
            let open = Verb(title: "Open", after: .closeKeepFocus) { Frontmost.open(url); return nil }
            verbs = [open, TailnetActions.copy("Copy URL", url.absoluteString)]
        } else {
            verbs = [TailnetActions.copy("Copy Address", "\(device.dnsName.isEmpty ? (device.ipv4 ?? device.name) : device.dnsName):\(page.port)")]
        }
        verbs.append(hide)
        return (page.title ?? label, parts.joined(separator: " · "), verbs, url)
    }

    private static func symbol(_ device: TailnetDevice) -> String {
        switch device.os.lowercased() {
        case "windows": return "pc"
        case "macos": return "laptopcomputer"
        case "linux", "freebsd": return "server.rack"
        default: return "desktopcomputer"
        }
    }
}
