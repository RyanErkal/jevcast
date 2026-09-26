import Foundation
import LauncherCore

/// The schedule part of the editor: friendly presets that map to and from an RRULE. Pure; no I/O.
struct ScheduleDraft: Equatable {
    enum Preset: String, CaseIterable, Identifiable {
        case manual, everyHours, daily, weekdays, weekly, once, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .manual: return "Manual"
            case .everyHours: return "Every N hours"
            case .daily: return "Daily"
            case .weekdays: return "Weekdays"
            case .weekly: return "Weekly"
            case .once: return "Once"
            case .custom: return "Custom"
            }
        }
    }

    static let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]
    static let dayCodes = [1: "SU", 2: "MO", 3: "TU", 4: "WE", 5: "TH", 6: "FR", 7: "SA"]
    static let shortNames = [1: "Sun", 2: "Mon", 3: "Tue", 4: "Wed", 5: "Thu", 6: "Fri", 7: "Sat"]

    var preset: Preset = .manual
    var intervalHours = 4
    var hour = 9
    var minute = 0
    /// Calendar weekdays, 1 = Sunday.
    var weekdays: Set<Int> = [2]
    var onceDate = Date().addingTimeInterval(3600)
    var customText = ""
    var timeZone = TimeZone.current.identifier
    /// Kept from the saved schedule so an edit does not shift an hourly phase.
    var anchor = Date()

    init() {}

    /// Reads a saved schedule back into a preset. Rules no preset can express open as Custom.
    init(_ schedule: Schedule) {
        timeZone = schedule.timeZone
        anchor = schedule.anchor
        switch schedule.rule {
        case .manual: preset = .manual
        case .once(let date): preset = .once; onceDate = date
        case .rrule(let text):
            customText = text
            guard let rule = try? RRule(text) else { preset = .custom; return }
            let singleTime = rule.hours.count == 1 && rule.minutes.count == 1
            if singleTime { hour = rule.hours[0]; minute = rule.minutes[0] }
            switch rule.frequency {
            case .hourly:
                preset = .everyHours; intervalHours = rule.interval
            case .daily where rule.interval == 1 && rule.weekdays.isEmpty && singleTime:
                preset = .daily
            case .weekly where rule.interval == 1 && singleTime && Set(rule.weekdays) == Set(2...6):
                preset = .weekdays; weekdays = Set(2...6)
            case .weekly where rule.interval == 1 && singleTime && !rule.weekdays.isEmpty:
                preset = .weekly; weekdays = Set(rule.weekdays)
            default:
                preset = .custom
            }
        }
    }

    /// The RRULE text a preset builds, or nil for Manual and Once.
    var presetRuleText: String? {
        let at = "BYHOUR=\(hour);BYMINUTE=\(minute)"
        switch preset {
        case .manual, .once: return nil
        case .everyHours: return intervalHours == 1 ? "FREQ=HOURLY" : "FREQ=HOURLY;INTERVAL=\(intervalHours)"
        case .daily: return "FREQ=DAILY;" + at
        case .weekdays: return "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;" + at
        case .weekly:
            let days = Self.weekdayOrder.filter(weekdays.contains).compactMap { Self.dayCodes[$0] }
            return "FREQ=WEEKLY;BYDAY=" + days.joined(separator: ",") + ";" + at
        case .custom: return customText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// The rule to save, or a message saying what is wrong.
    func rule(now: Date = Date()) -> Result<Schedule.Rule, ScheduleProblem> {
        guard TimeZone(identifier: timeZone) != nil else { return .failure(.init("Choose a valid time zone.")) }
        switch preset {
        case .manual: return .success(.manual)
        case .once:
            return onceDate > now ? .success(.once(onceDate)) : .failure(.init("Pick a time in the future."))
        case .weekly where weekdays.isEmpty:
            return .failure(.init("Pick at least one day."))
        case .everyHours where !(1...168).contains(intervalHours):
            return .failure(.init("Hours must be between 1 and 168."))
        default:
            let text = presetRuleText ?? ""
            do {
                let parsed = try RRule(text)
                return .success(.rrule(parsed.text))
            } catch let error as RRule.ParseError {
                return .failure(.init(error.description))
            } catch {
                return .failure(.init("The rule could not be read."))
            }
        }
    }

    /// The schedule to save. Hourly rules keep the saved anchor; new ones start counting now.
    func schedule(now: Date = Date()) -> Schedule? {
        guard case .success(let rule) = self.rule(now: now) else { return nil }
        return Schedule(rule: rule, timeZone: timeZone, anchor: anchor)
    }

    var summary: String {
        guard let schedule = schedule() else { return preset == .custom ? "Not a valid rule" : "Not set" }
        return ScheduleText.summary(schedule)
    }

    /// Upcoming times, ignoring whether the automation is on.
    func upcoming(_ limit: Int, now: Date = Date()) -> [Date] {
        guard let schedule = schedule(now: now) else { return [] }
        return ScheduleText.upcoming(schedule, limit: limit, now: now)
    }
}

struct ScheduleProblem: Error, Equatable {
    var message: String
    init(_ message: String) { self.message = message }
}

/// Human text for a saved schedule.
enum ScheduleText {
    static func summary(_ schedule: Schedule) -> String {
        let zone = TimeZone(identifier: schedule.timeZone) ?? .current
        switch schedule.rule {
        case .manual: return "Manual"
        case .once(let date): return "Once, " + date.formatted(date: .abbreviated, time: .shortened)
        case .rrule(let text):
            guard let rule = try? RRule(text) else { return "Invalid rule" }
            let base = rule.summary(anchor: schedule.anchor, timeZone: zone)
            return zone.identifier == TimeZone.current.identifier ? base : base + " (" + zone.identifier + ")"
        }
    }

    static func upcoming(_ schedule: Schedule, limit: Int, now: Date = Date()) -> [Date] {
        switch schedule.rule {
        case .manual: return []
        case .once(let date): return date > now ? [date] : []
        case .rrule(let text):
            guard let rule = try? RRule(text), let zone = TimeZone(identifier: schedule.timeZone) else { return [] }
            return rule.occurrences(after: now, anchor: schedule.anchor, timeZone: zone, limit: limit)
        }
    }
}
