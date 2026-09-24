import Foundation

/// One launchd job read from a property list in a LaunchAgents or LaunchDaemons folder.
public struct LaunchJob: Equatable, Sendable, Identifiable {
    public enum Domain: String, Sendable {
        /// `~/Library/LaunchAgents`: yours, runs as you.
        case userAgent
        /// `/Library/LaunchAgents`: installed for every user, runs as you.
        case globalAgent
        /// `/Library/LaunchDaemons`: runs as root, without a login.
        case daemon
        public var isAgent: Bool { self != .daemon }
        public var title: String {
            switch self {
            case .userAgent: return "Your agent"
            case .globalAgent: return "Agent for all users"
            case .daemon: return "System daemon"
            }
        }
    }
    public let label: String
    public let program: [String]
    public let schedule: LaunchSchedule
    public let domain: Domain
    public let plistPath: String
    public let disabledInPlist: Bool
    public let standardOutPath: String?
    public let standardErrorPath: String?
    public var id: String { "launchd:" + plistPath }
    /// The program file: `Program`, or the first of `ProgramArguments`.
    public var executable: String? { program.first }

    public init(label: String, program: [String], schedule: LaunchSchedule, domain: Domain, plistPath: String,
                disabledInPlist: Bool = false, standardOutPath: String? = nil, standardErrorPath: String? = nil) {
        self.label = label; self.program = program; self.schedule = schedule; self.domain = domain; self.plistPath = plistPath
        self.disabledInPlist = disabledInPlist; self.standardOutPath = standardOutPath; self.standardErrorPath = standardErrorPath
    }

    /// Reads a launchd property list. Returns nil when it has no label or is not a dictionary.
    public static func parse(_ data: Data, path: String, domain: Domain) -> LaunchJob? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = plist["Label"] as? String, !label.isEmpty else { return nil }
        var program = (plist["ProgramArguments"] as? [Any])?.compactMap { $0 as? String } ?? []
        if let path = plist["Program"] as? String {
            if program.isEmpty { program = [path] } else { program[0] = path }
        }
        return LaunchJob(label: label, program: program, schedule: LaunchSchedule(plist: plist), domain: domain, plistPath: path,
                         disabledInPlist: plist["Disabled"] as? Bool ?? false,
                         standardOutPath: plist["StandardOutPath"] as? String, standardErrorPath: plist["StandardErrorPath"] as? String)
    }

    /// Reasons a job looks out of place: a program in a temporary or download folder, or one that is missing.
    public func warnings(programExists: Bool) -> [String] {
        guard let executable else { return ["No program"] }
        var found: [String] = []
        if !programExists { found.append("Program missing") }
        let risky = ["/tmp/", "/private/tmp/", "/var/tmp/", "/Users/Shared/", "/Downloads/"]
        if risky.contains(where: { executable.contains($0) }) { found.append("Runs from an unusual folder") }
        return found
    }
}

/// When launchd starts a job.
public struct LaunchSchedule: Equatable, Sendable {
    /// `StartCalendarInterval`: each entry fires when every field it sets matches. Nil fields match any value.
    public struct CalendarEntry: Equatable, Sendable {
        public var minute: Int?, hour: Int?, day: Int?, weekday: Int?, month: Int?
        public init(minute: Int? = nil, hour: Int? = nil, day: Int? = nil, weekday: Int? = nil, month: Int? = nil) {
            self.minute = minute; self.hour = hour; self.day = day; self.weekday = weekday; self.month = month
        }
    }
    public var calendar: [CalendarEntry] = []
    /// `StartInterval`, in seconds.
    public var interval: Int?
    public var runAtLoad = false
    public var keepAlive = false
    public var watchesPaths = false
    public var onMount = false

    public init(calendar: [CalendarEntry] = [], interval: Int? = nil, runAtLoad: Bool = false, keepAlive: Bool = false,
                watchesPaths: Bool = false, onMount: Bool = false) {
        self.calendar = calendar; self.interval = interval; self.runAtLoad = runAtLoad; self.keepAlive = keepAlive
        self.watchesPaths = watchesPaths; self.onMount = onMount
    }

    init(plist: [String: Any]) {
        func entry(_ value: Any) -> CalendarEntry? {
            guard let dict = value as? [String: Any] else { return nil }
            func int(_ key: String) -> Int? { (dict[key] as? NSNumber)?.intValue }
            return CalendarEntry(minute: int("Minute"), hour: int("Hour"), day: int("Day"), weekday: int("Weekday"), month: int("Month"))
        }
        if let list = plist["StartCalendarInterval"] as? [Any] { calendar = list.compactMap(entry) }
        else if let single = plist["StartCalendarInterval"].flatMap(entry) { calendar = [single] }
        interval = (plist["StartInterval"] as? NSNumber)?.intValue
        runAtLoad = plist["RunAtLoad"] as? Bool ?? false
        // KeepAlive is a bool or a dictionary of conditions. Either way launchd restarts the job.
        if let bool = plist["KeepAlive"] as? Bool { keepAlive = bool } else { keepAlive = plist["KeepAlive"] is [String: Any] }
        watchesPaths = plist["WatchPaths"] != nil || plist["QueueDirectories"] != nil
        onMount = plist["StartOnMount"] as? Bool ?? false
    }

    /// "Every day at 09:00", "Every 15 min", "Always running", "At login".
    public var summary: String {
        var parts: [String] = []
        parts += calendar.prefix(2).map(Self.describe)
        if calendar.count > 2 { parts.append("and \(calendar.count - 2) more times") }
        if let interval, interval > 0 { parts.append("Every " + Self.duration(interval)) }
        if keepAlive { parts.append("Always running") }
        if watchesPaths { parts.append("When files change") }
        if onMount { parts.append("When a disk mounts") }
        if runAtLoad && !keepAlive { parts.append(parts.isEmpty ? "At login" : "and at login") }
        return parts.isEmpty ? "When asked" : parts.joined(separator: ", ")
    }

    public var hasTimer: Bool { !calendar.isEmpty || (interval ?? 0) > 0 }

    /// The next start for a calendar schedule after `date`. Interval and event jobs have no fixed time.
    public func nextRun(after date: Date, calendar cal: Calendar = .current) -> Date? {
        calendar.compactMap { Self.next($0, after: date, calendar: cal) }.min()
    }

    static func next(_ entry: CalendarEntry, after date: Date, calendar cal: Calendar) -> Date? {
        let start = cal.date(byAdding: .minute, value: 1, to: date).flatMap { cal.dateInterval(of: .minute, for: $0)?.start } ?? date
        guard var day = cal.dateInterval(of: .day, for: start)?.start else { return nil }
        for _ in 0..<(366 * 4) {
            let parts = cal.dateComponents([.month, .day, .weekday], from: day)
            let weekday = (parts.weekday ?? 1) - 1 // launchd: 0 and 7 are Sunday.
            let dayMatches = (entry.month.map { $0 == parts.month } ?? true)
                && (entry.day.map { $0 == parts.day } ?? true)
                && (entry.weekday.map { $0 % 7 == weekday } ?? true)
            if dayMatches {
                let hours = entry.hour.map { [$0] } ?? Array(0..<24)
                let minutes = entry.minute.map { [$0] } ?? Array(0..<60)
                for hour in hours {
                    for minute in minutes {
                        if let time = cal.date(bySettingHour: hour, minute: minute, second: 0, of: day), time >= start { return time }
                    }
                }
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
        }
        return nil
    }

    static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]

    static func describe(_ entry: CalendarEntry) -> String {
        let time: String
        switch (entry.hour, entry.minute) {
        case let (hour?, minute?): time = String(format: "at %02d:%02d", hour, minute)
        case let (hour?, nil): time = String(format: "every minute from %02d:00 to %02d:59", hour, hour)
        case let (nil, minute?): time = minute == 0 ? "every hour" : "every hour at :\(String(format: "%02d", minute))"
        case (nil, nil): time = "every minute"
        }
        var when: String
        if let weekday = entry.weekday { when = "Every " + weekdays[weekday % 7] }
        else if let day = entry.day { when = "On day \(day) of " + (entry.month.map { months[($0 - 1) % 12] } ?? "each month") }
        else if let month = entry.month { when = "Every day in " + months[(month - 1) % 12] }
        else { when = entry.hour == nil ? "" : "Every day" }
        if when.isEmpty { return time.prefix(1).uppercased() + time.dropFirst() }
        return when + " " + time
    }

    static func duration(_ seconds: Int) -> String {
        if seconds % 86_400 == 0 { return seconds == 86_400 ? "day" : "\(seconds / 86_400) days" }
        if seconds % 3600 == 0 { return seconds == 3600 ? "hour" : "\(seconds / 3600) hours" }
        if seconds % 60 == 0 { return seconds == 60 ? "minute" : "\(seconds / 60) min" }
        return "\(seconds) s"
    }
}

/// What `launchctl list` says about a loaded job.
public struct LaunchStatus: Equatable, Sendable {
    public let pid: Int32?
    /// The last exit status. Negative values are signals.
    public let lastExit: Int
    public init(pid: Int32?, lastExit: Int) { self.pid = pid; self.lastExit = lastExit }

    /// Parses `launchctl list`: "PID\tStatus\tLabel", with "-" for no PID.
    public static func parse(_ output: String) -> [String: LaunchStatus] {
        var found: [String: LaunchStatus] = [:]
        for line in output.split(whereSeparator: \.isNewline).dropFirst() {
            let fields = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard fields.count == 3, let status = Int(fields[1]) else { continue }
            found[fields[2]] = LaunchStatus(pid: Int32(fields[0]), lastExit: status)
        }
        return found
    }

    /// Parses `launchctl print-disabled`: lines such as `"com.example.job" => disabled`.
    public static func parseDisabled(_ output: String) -> Set<String> {
        var labels = Set<String>()
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard value == "disabled" || value == "true" else { continue }
            let label = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !label.isEmpty { labels.insert(label) }
        }
        return labels
    }
}

/// One line of the user's crontab.
public struct CronJob: Equatable, Sendable, Identifiable {
    public let line: String
    public let command: String
    public let summary: String
    /// Minute, hour, day of month, month, day of week. Nil for `@reboot`.
    let fields: [Set<Int>]?
    let dayOfMonthAny: Bool
    let dayOfWeekAny: Bool
    public var id: String { "cron:" + line }
    public var atReboot: Bool { fields == nil }

    /// Reads `crontab -l`. Skips comments, blank lines, and variable lines such as `PATH=…`.
    public static func parse(_ crontab: String) -> [CronJob] {
        crontab.split(whereSeparator: \.isNewline).compactMap { parseLine(String($0)) }
    }

    static let macros: [String: String] = [
        "@yearly": "0 0 1 1 *", "@annually": "0 0 1 1 *", "@monthly": "0 0 1 * *", "@weekly": "0 0 * * 0",
        "@daily": "0 0 * * *", "@midnight": "0 0 * * *", "@hourly": "0 * * * *"
    ]

    static func parseLine(_ raw: String) -> CronJob? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
        let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = parts.first else { return nil }
        if first.contains("="), !first.hasPrefix("@"), first.first?.isNumber != true, first.first != "*" { return nil }
        if first == "@reboot" {
            guard parts.count >= 2 else { return nil }
            return CronJob(line: line, command: parts.dropFirst().joined(separator: " "), summary: "When the Mac starts",
                           fields: nil, dayOfMonthAny: true, dayOfWeekAny: true)
        }
        let spec: [String], command: String
        if let macro = macros[first] {
            guard parts.count >= 2 else { return nil }
            spec = macro.split(separator: " ").map(String.init); command = parts.dropFirst().joined(separator: " ")
        } else {
            guard parts.count >= 6 else { return nil }
            spec = Array(parts.prefix(5)); command = parts.dropFirst(5).joined(separator: " ")
        }
        let ranges = [0...59, 0...23, 1...31, 1...12, 0...7]
        var fields: [Set<Int>] = []
        for (index, text) in spec.enumerated() {
            guard let values = field(text, range: ranges[index], names: index == 3 ? monthNames : index == 4 ? dayNames : [:]) else { return nil }
            fields.append(index == 4 ? Set(values.map { $0 % 7 }) : values)
        }
        return CronJob(line: line, command: command, summary: describe(spec), fields: fields,
                       dayOfMonthAny: spec[2] == "*", dayOfWeekAny: spec[4] == "*")
    }

    static let monthNames = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
    static let dayNames = ["sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6]

    /// Expands "*", "5", "1-5", "*/15", "1,15", "mon-fri".
    static func field(_ text: String, range: ClosedRange<Int>, names: [String: Int]) -> Set<Int>? {
        var values = Set<Int>()
        for part in text.lowercased().split(separator: ",") {
            let stepParts = part.split(separator: "/", maxSplits: 1)
            let step = stepParts.count == 2 ? Int(stepParts[1]) : 1
            guard let step, step > 0 else { return nil }
            let base = String(stepParts[0])
            func value(_ s: Substring) -> Int? { Int(s) ?? names[String(s)] }
            let lower: Int, upper: Int
            if base == "*" { lower = range.lowerBound; upper = range.upperBound }
            else if base.contains("-") {
                let bounds = base.split(separator: "-", maxSplits: 1)
                guard bounds.count == 2, let l = value(bounds[0]), let u = value(bounds[1]), l <= u else { return nil }
                lower = l; upper = u
            } else {
                guard let single = value(Substring(base)) else { return nil }
                lower = single; upper = stepParts.count == 2 ? range.upperBound : single
            }
            guard range.contains(lower), range.contains(upper) else { return nil }
            values.formUnion(stride(from: lower, through: upper, by: step))
        }
        return values.isEmpty ? nil : values
    }

    static func describe(_ spec: [String]) -> String {
        let (minute, hour, day, month, weekday) = (spec[0], spec[1], spec[2], spec[3], spec[4])
        let simpleTime = Int(minute) != nil && Int(hour) != nil
        var when: String
        if minute == "*" && hour == "*" { when = "Every minute" }
        else if minute.hasPrefix("*/"), hour == "*" { when = "Every \(minute.dropFirst(2)) min" }
        else if Int(minute) != nil, hour == "*" { when = minute == "0" ? "Every hour" : "Every hour at :\(String(format: "%02d", Int(minute)!))" }
        else if hour.hasPrefix("*/"), Int(minute) != nil { when = "Every \(hour.dropFirst(2)) hours" }
        else if simpleTime { when = String(format: "at %02d:%02d", Int(hour)!, Int(minute)!) }
        else { return spec.joined(separator: " ") }
        guard simpleTime else { return day == "*" && month == "*" && weekday == "*" ? when : when + " (" + spec[2...].joined(separator: " ") + ")" }
        if day == "*" && month == "*" {
            switch weekday.lowercased() {
            case "*": return "Every day " + when
            case "1-5", "mon-fri": return "Weekdays " + when
            case "0,6", "6,0", "sat,sun", "sun,sat": return "Weekends " + when
            default:
                if let index = Int(weekday) ?? dayNames[weekday.lowercased()] { return "Every " + LaunchSchedule.weekdays[index % 7] + " " + when }
            }
        }
        if let d = Int(day), month == "*", weekday == "*" { return "On day \(d) of each month " + when }
        return "Cron " + spec.joined(separator: " ")
    }

    /// The next run after `date`. Cron runs when day of month OR day of week matches, if both are set.
    public func nextRun(after date: Date, calendar cal: Calendar = .current) -> Date? {
        guard let fields else { return nil }
        let start = cal.date(byAdding: .minute, value: 1, to: date).flatMap { cal.dateInterval(of: .minute, for: $0)?.start } ?? date
        guard var day = cal.dateInterval(of: .day, for: start)?.start else { return nil }
        for _ in 0..<(366 * 5) {
            let parts = cal.dateComponents([.month, .day, .weekday], from: day)
            let monthOK = fields[3].contains(parts.month ?? 0)
            let domOK = fields[2].contains(parts.day ?? 0), dowOK = fields[4].contains((parts.weekday ?? 1) - 1)
            let dayOK: Bool
            if dayOfMonthAny && dayOfWeekAny { dayOK = true }
            else if dayOfMonthAny { dayOK = dowOK }
            else if dayOfWeekAny { dayOK = domOK }
            else { dayOK = domOK || dowOK }
            if monthOK && dayOK {
                for hour in fields[1].sorted() {
                    for minute in fields[0].sorted() {
                        if let time = cal.date(bySettingHour: hour, minute: minute, second: 0, of: day), time >= start { return time }
                    }
                }
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
        }
        return nil
    }
}
