import AppKit
import LauncherCore

/// Everything that runs on a schedule or in the background: launchd agents and daemons,
/// the user's crontab, and Jevcast timers. Apple's own jobs are hidden unless the filter says "apple".
@MainActor
final class ScheduledSource: ThingSource {
    let section = "Scheduled Tasks"
    private let timers: TimerCenter
    private let catalogue: AppCatalogue
    init(timers: TimerCenter, catalogue: AppCatalogue) { self.timers = timers; self.catalogue = catalogue }

    nonisolated static let folders: [(path: String, domain: LaunchJob.Domain)] = [
        (NSHomeDirectory() + "/Library/LaunchAgents", .userAgent),
        ("/Library/LaunchAgents", .globalAgent),
        ("/Library/LaunchDaemons", .daemon)
    ]

    func load(_ filter: String) async throws -> [LauncherResult] {
        let scan = await Self.scan()
        let words = filter.lowercased().split(separator: " ").map(String.init)
        let showApple = words.contains("apple")
        let failingOnly = words.contains { ["failing", "failed", "errors", "broken"].contains($0) }
        let text = words.filter { !["apple", "failing", "failed", "errors", "broken", "all"].contains($0) }.joined(separator: " ")
        let now = Date()
        var rows: [LauncherResult] = []
        for timer in timers.active where text.isEmpty && !failingOnly {
            rows.append(LauncherResult(id: "cancel:" + timer.id, title: timer.title,
                                       detail: "Jevcast timer · ends " + timer.fires.formatted(date: .omitted, time: .shortened),
                                       symbol: "timer", action: .cancelTimer(timer.id), score: 3000))
        }
        for job in scan.jobs {
            guard showApple || !job.label.hasPrefix("com.apple.") else { continue }
            let status = scan.status[job.label]
            if failingOnly, (status?.lastExit ?? 0) == 0 { continue }
            let name = displayName(job)
            if !text.isEmpty, SearchRanking.score(query: text, title: name, aliases: [job.label, job.executable ?? ""]) == nil { continue }
            let off = job.disabledInPlist || scan.disabled.contains(job.label)
            let warnings = job.warnings(programExists: job.executable.map { FileManager.default.fileExists(atPath: $0) } ?? false)
            rows.append(row(job, name: name, status: status, off: off, warnings: warnings, now: now))
        }
        for job in scan.cron {
            if failingOnly { continue }
            if !text.isEmpty, SearchRanking.score(query: text, title: job.command) == nil { continue }
            rows.append(cronRow(job, now: now))
        }
        return rows
    }

    // MARK: Reading

    struct Scan {
        var jobs: [LaunchJob] = []
        var status: [String: LaunchStatus] = [:]
        var disabled = Set<String>()
        var cron: [CronJob] = []
    }

    /// Reads the plists and asks launchctl and crontab, off the main thread.
    static func scan() async -> Scan {
        async let list = try? CommandRunner.capture(["/bin/launchctl", "list"], allowFailure: true)
        async let disabled = try? CommandRunner.capture(["/bin/launchctl", "print-disabled", "gui/\(getuid())"], allowFailure: true)
        async let crontab = try? CommandRunner.capture(["/usr/bin/crontab", "-l"], allowFailure: true)
        let jobs = await Task.detached(priority: .userInitiated) { readJobs() }.value
        return Scan(jobs: jobs, status: LaunchStatus.parse(await list ?? ""),
                    disabled: LaunchStatus.parseDisabled(await disabled ?? ""), cron: CronJob.parse(await crontab ?? ""))
    }

    nonisolated static func readJobs() -> [LaunchJob] {
        var jobs: [LaunchJob] = []
        for folder in folders {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names.sorted() where name.hasSuffix(".plist") {
                let path = folder.path + "/" + name
                guard let data = FileManager.default.contents(atPath: path),
                      let job = LaunchJob.parse(data, path: path, domain: folder.domain) else { continue }
                jobs.append(job)
            }
        }
        return jobs
    }

    // MARK: Rows

    /// The app a job belongs to, from its label or program path, or the label's last useful part.
    func displayName(_ job: LaunchJob) -> String {
        if let program = job.executable, let range = program.range(of: ".app/") {
            let appPath = String(program[..<range.lowerBound]) + ".app"
            return (appPath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        }
        if let app = catalogue.entries.first(where: { app in app.bundleID.map { !$0.isEmpty && job.label.hasPrefix($0) } ?? false }) {
            return app.name
        }
        return job.label
    }

    private func row(_ job: LaunchJob, name: String, status: LaunchStatus?, off: Bool, warnings: [String], now: Date) -> LauncherResult {
        var parts = [job.schedule.summary]
        if let next = job.schedule.nextRun(after: now) { parts.append("next " + next.formatted(.relative(presentation: .named))) }
        if off { parts.append("turned off") }
        else if let status {
            if let pid = status.pid { parts.append("running (PID \(pid))") }
            else if status.lastExit != 0 { parts.append(status.lastExit < 0 ? "last run stopped by signal \(-status.lastExit)" : "last run failed (exit \(status.lastExit))") }
        } else if job.domain.isAgent { parts.append("not loaded") }
        parts.append(job.domain.title)
        parts += warnings
        if name != job.label { parts.append(job.label) }
        let symbol = !warnings.isEmpty ? "exclamationmark.triangle" : off ? "pause.circle" : (status?.lastExit ?? 0) != 0 ? "xmark.octagon" : "clock.arrow.circlepath"
        // Failing and unusual jobs first, then the rest by name.
        let score = 2000 + (warnings.isEmpty ? 0 : 200) + ((status?.lastExit ?? 0) != 0 ? 100 : 0)
        return LauncherResult(id: job.id, title: name, detail: parts.joined(separator: " · "), symbol: symbol,
                              action: .thing(Thing(verbs: verbs(job, off: off, loaded: status != nil), path: job.plistPath)), score: Double(score))
    }

    private func verbs(_ job: LaunchJob, off: Bool, loaded: Bool) -> [Verb] {
        let target = "gui/\(getuid())"
        let plist = job.plistPath
        var verbs: [Verb] = [
            Verb(title: "Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: plist)]); return nil
            }
        ]
        if job.domain.isAgent {
            if loaded && !off {
                verbs.append(Verb(title: "Run Now", after: .stay) {
                    _ = try await CommandRunner.capture(["/bin/launchctl", "kickstart", target + "/" + job.label])
                    return "Started \(job.label)."
                })
            }
            if off {
                verbs.append(Verb(title: "Turn On", after: .stay) {
                    _ = try await CommandRunner.capture(["/bin/launchctl", "enable", target + "/" + job.label])
                    _ = try? await CommandRunner.capture(["/bin/launchctl", "bootstrap", target, plist])
                    return "Turned on \(job.label)."
                })
            } else {
                verbs.append(Verb(title: "Turn Off", after: .stay) {
                    _ = try await CommandRunner.capture(["/bin/launchctl", "disable", target + "/" + job.label])
                    _ = try? await CommandRunner.capture(["/bin/launchctl", "bootout", target, plist])
                    return "Turned off \(job.label). It stays off after a restart."
                })
            }
        }
        verbs.append(Verb(title: "Open Property List") {
            NSWorkspace.shared.open(URL(fileURLWithPath: plist)); return nil
        })
        for log in Set([job.standardOutPath, job.standardErrorPath].compactMap { $0 }).sorted()
        where FileManager.default.fileExists(atPath: log) {
            verbs.append(Verb(title: "Open Log " + (log as NSString).lastPathComponent) {
                let console = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
                let config = NSWorkspace.OpenConfiguration(); config.activates = true
                _ = try await NSWorkspace.shared.open([URL(fileURLWithPath: log)], withApplicationAt: console, configuration: config)
                return nil
            })
        }
        verbs.append(Verb(title: "Copy Label", after: .stay) { copyText(job.label); return "Label copied." })
        if !job.program.isEmpty {
            verbs.append(Verb(title: "Copy Command", after: .stay) { copyText(ShellQuote.join(job.program)); return "Command copied." })
        }
        if job.domain == .daemon {
            verbs.append(Verb(title: "Copy sudo Command to Turn Off", after: .stay) {
                copyText("sudo launchctl bootout system " + ShellQuote.quote(plist)); return "Command copied. Paste it in Terminal."
            })
        }
        verbs.append(Verb(title: "Open Login Items Settings") {
            if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") { NSWorkspace.shared.open(url) }
            return nil
        })
        return verbs
    }

    private func cronRow(_ job: CronJob, now: Date) -> LauncherResult {
        var parts = [job.summary]
        if let next = job.nextRun(after: now) { parts.append("next " + next.formatted(.relative(presentation: .named))) }
        parts.append("crontab")
        let verbs = [
            Verb(title: "Copy Command", after: .stay) { copyText(job.command); return "Command copied." },
            Verb(title: "Copy Line", after: .stay) { copyText(job.line); return "Line copied." }
        ]
        return LauncherResult(id: job.id, title: job.command, detail: parts.joined(separator: " · "), symbol: "calendar.badge.clock",
                              action: .thing(Thing(verbs: verbs)), score: 1900)
    }
}
