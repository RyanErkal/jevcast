import XCTest
@testable import LauncherCore

final class ScheduledJobTests: XCTestCase {
    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/London")!; return cal
    }()
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func plist(_ dict: [String: Any]) -> Data { try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) }

    func testSourceQueryKeywordsAndFilters() {
        XCTAssertEqual(SourceQuery.parse("show me our scheduled tasks"), SourceQuery(kind: .scheduled, filter: ""))
        XCTAssertEqual(SourceQuery.parse("scheduled tasks failing"), SourceQuery(kind: .scheduled, filter: "failing"))
        XCTAssertEqual(SourceQuery.parse("what runs at login"), SourceQuery(kind: .scheduled, filter: ""))
        XCTAssertEqual(SourceQuery.parse("cron"), SourceQuery(kind: .scheduled, filter: ""))
        XCTAssertEqual(SourceQuery.parse("tabs slack"), SourceQuery(kind: .tabs, filter: "slack"))
        XCTAssertEqual(SourceQuery.parse("list my reminders"), SourceQuery(kind: .reminders, filter: ""))
        XCTAssertEqual(SourceQuery.parse("tasks"), SourceQuery(kind: .reminders, filter: ""))
        XCTAssertEqual(SourceQuery.parse("contact sam"), SourceQuery(kind: .contacts, filter: "sam"))
        XCTAssertEqual(SourceQuery.parse("history swift"), SourceQuery(kind: .history, filter: "swift"))
        XCTAssertEqual(SourceQuery.parse("show mail"), SourceQuery(kind: .mail, filter: ""))
        XCTAssertNil(SourceQuery.parse("history"), "Bare history stays the calculator history.")
        XCTAssertNil(SourceQuery.parse("safari"))
        XCTAssertNil(SourceQuery.parse("show"))
        XCTAssertNil(SourceQuery.parse("tablet"))
    }

    func testLaunchJobParsesProgramAndSchedule() throws {
        let data = plist(["Label": "com.example.sync", "ProgramArguments": ["/usr/local/bin/sync", "--all"],
                          "StartCalendarInterval": ["Hour": 9, "Minute": 30], "RunAtLoad": true, "StandardErrorPath": "/tmp/sync.err"])
        let job = try XCTUnwrap(LaunchJob.parse(data, path: "/Users/me/Library/LaunchAgents/com.example.sync.plist", domain: .userAgent))
        XCTAssertEqual(job.label, "com.example.sync")
        XCTAssertEqual(job.program, ["/usr/local/bin/sync", "--all"])
        XCTAssertEqual(job.schedule.summary, "Every day at 09:30, and at login")
        XCTAssertEqual(job.standardErrorPath, "/tmp/sync.err")
        XCTAssertNil(LaunchJob.parse(plist(["Program": "/bin/true"]), path: "x", domain: .daemon), "A job needs a label.")
        let program = try XCTUnwrap(LaunchJob.parse(plist(["Label": "a", "Program": "/bin/echo", "ProgramArguments": ["echo", "hi"]]), path: "x", domain: .daemon))
        XCTAssertEqual(program.program, ["/bin/echo", "hi"], "Program replaces the first argument.")
    }

    func testScheduleSummaries() {
        XCTAssertEqual(LaunchSchedule(interval: 900).summary, "Every 15 min")
        XCTAssertEqual(LaunchSchedule(interval: 3600).summary, "Every hour")
        XCTAssertEqual(LaunchSchedule(keepAlive: true).summary, "Always running")
        XCTAssertEqual(LaunchSchedule(runAtLoad: true).summary, "At login")
        XCTAssertEqual(LaunchSchedule().summary, "When asked")
        XCTAssertEqual(LaunchSchedule(calendar: [.init(minute: 0, hour: 8, weekday: 1)]).summary, "Every Monday at 08:00")
        XCTAssertEqual(LaunchSchedule(calendar: [.init(minute: 15)]).summary, "Every hour at :15")
        XCTAssertEqual(LaunchSchedule(calendar: [.init(minute: 0, hour: 3, day: 1)]).summary, "On day 1 of each month at 03:00")
        XCTAssertEqual(LaunchSchedule(watchesPaths: true).summary, "When files change")
    }

    func testLaunchNextRun() {
        let schedule = LaunchSchedule(calendar: [.init(minute: 30, hour: 9)])
        XCTAssertEqual(schedule.nextRun(after: date("2026-09-23T07:00:00Z"), calendar: calendar), date("2026-09-23T08:30:00Z"))
        XCTAssertEqual(schedule.nextRun(after: date("2026-09-23T09:00:00Z"), calendar: calendar), date("2026-09-24T08:30:00Z"))
        let sunday = LaunchSchedule(calendar: [.init(minute: 0, hour: 12, weekday: 7)])
        XCTAssertEqual(sunday.nextRun(after: date("2026-09-23T12:00:00Z"), calendar: calendar), date("2026-09-27T11:00:00Z"), "Weekday 7 is Sunday.")
        XCTAssertNil(LaunchSchedule(interval: 60).nextRun(after: Date(), calendar: calendar))
        // Day and Weekday together fire on either, as launchd does: Friday 25th comes before the 13th.
        let either = LaunchSchedule(calendar: [.init(minute: 0, hour: 0, day: 13, weekday: 5)])
        XCTAssertEqual(either.nextRun(after: date("2026-09-23T12:00:00Z"), calendar: calendar), date("2026-09-24T23:00:00Z"))
        XCTAssertEqual(either.summary, "Every Friday and on day 13 at 00:00")
    }

    func testLaunchStatusAndDisabled() {
        let status = LaunchStatus.parse("PID\tStatus\tLabel\n123\t0\tcom.example.a\n-\t78\tcom.example.b\n-\t-9\tcom.example.c\n")
        XCTAssertEqual(status["com.example.a"], LaunchStatus(pid: 123, lastExit: 0))
        XCTAssertEqual(status["com.example.b"], LaunchStatus(pid: nil, lastExit: 78))
        XCTAssertEqual(status["com.example.c"]?.lastExit, -9)
        let overrides = LaunchStatus.parseOverrides("disabled services = {\n\t\"com.example.a\" => disabled\n\t\"com.example.b\" => enabled\n\t\"com.example.c\" => true\n}")
        XCTAssertEqual(overrides, ["com.example.a": true, "com.example.b": false, "com.example.c": true])
    }

    func testCronParsingAndSummaries() {
        let jobs = CronJob.parse("""
        # backups
        PATH=/usr/bin:/bin
        MAILTO=""
        30 2 * * * /usr/local/bin/backup --full
        */15 * * * * ~/bin/poll
        0 9 * * 1-5 say hello
        @reboot ~/bin/start
        @daily ~/bin/rotate
        bad line
        """)
        XCTAssertEqual(jobs.map(\.command), ["/usr/local/bin/backup --full", "~/bin/poll", "say hello", "~/bin/start", "~/bin/rotate"])
        XCTAssertEqual(jobs.map(\.summary), ["Every day at 02:30", "Every 15 min", "Weekdays at 09:00", "When the Mac starts", "Every day at 00:00"])
        XCTAssertTrue(jobs[3].atReboot)
    }

    func testCronNextRun() {
        let weekdays = CronJob.parse("0 9 * * 1-5 say hello")[0]
        // 2026-09-26 is a Saturday, so the next run is Monday 28th at 09:00 London (08:00 UTC).
        XCTAssertEqual(weekdays.nextRun(after: date("2026-09-26T10:00:00Z"), calendar: calendar), date("2026-09-28T08:00:00Z"))
        let quarter = CronJob.parse("*/15 * * * * poll")[0]
        XCTAssertEqual(quarter.nextRun(after: date("2026-09-23T10:07:00Z"), calendar: calendar), date("2026-09-23T10:15:00Z"))
        // Day of month OR day of week when both are set.
        // A day field that starts with "*" makes both fields required: a Monday on an odd day.
        let stepped = CronJob.parse("0 9 */2 * 1 weekly")[0]
        XCTAssertEqual(stepped.nextRun(after: date("2026-09-23T12:00:00Z"), calendar: calendar), date("2026-10-05T08:00:00Z"))
        let either = CronJob.parse("0 0 13 * 5 spooky")[0]
        XCTAssertEqual(either.nextRun(after: date("2026-09-23T12:00:00Z"), calendar: calendar), date("2026-09-24T23:00:00Z"), "Friday 25th matches the weekday.")
    }

    func testOutOfRangeCalendarEntryIsDropped() throws {
        let data = plist(["Label": "bad", "Program": "/bin/true", "StartCalendarInterval": [["Month": 0], ["Weekday": -1], ["Hour": 5, "Minute": 0]]])
        let job = try XCTUnwrap(LaunchJob.parse(data, path: "x", domain: .userAgent))
        XCTAssertEqual(job.schedule.calendar, [.init(minute: 0, hour: 5)])
        XCTAssertEqual(job.schedule.summary, "Every day at 05:00")
    }

    func testConditionalKeepAliveAndRelativeProgram() throws {
        let data = plist(["Label": "k", "ProgramArguments": ["bash", "-c", "true"], "KeepAlive": ["SuccessfulExit": false], "RunAtLoad": true])
        let job = try XCTUnwrap(LaunchJob.parse(data, path: "x", domain: .userAgent))
        XCTAssertEqual(job.schedule.summary, "Restarts when needed, and at login")
        XCTAssertEqual(job.warnings(programExists: false), [], "launchd finds a bare program name on PATH.")
    }

    func testWarningsAndQuoting() {
        let job = LaunchJob(label: "x", program: ["/tmp/run.sh"], schedule: LaunchSchedule(), domain: .userAgent, plistPath: "p")
        XCTAssertEqual(job.warnings(programExists: false), ["Program missing", "Runs from an unusual folder"])
        XCTAssertEqual(ShellQuote.join(["/bin/echo", "it's here", "plain"]), "/bin/echo 'it'\\''s here' plain")
    }
}

final class DiscoveryQueryTests: XCTestCase {
    func testDiscoveryWords() {
        XCTAssertEqual(SourceQuery.parse("show automations")?.kind, .scheduled)
        XCTAssertEqual(SourceQuery.parse("schedule")?.kind, .scheduled)
        XCTAssertEqual(SourceQuery.parse("help")?.kind, .help)
        XCTAssertEqual(SourceQuery.parse("what can you do")?.kind, .help)
        XCTAssertEqual(SourceQuery.parse("show mail")?.explicit, true)
        XCTAssertEqual(SourceQuery.parse("mail")?.explicit, false)
        XCTAssertEqual(SourceQuery.parse("check my inbox")?.explicit, true)
    }
}

final class SpokenQueryTests: XCTestCase {
    func testDictatedPunctuation() {
        XCTAssertEqual(SourceQuery.parse("Show mail.")?.kind, .mail)
        XCTAssertEqual(SourceQuery.parse("Show mail.")?.explicit, true)
    }
}
