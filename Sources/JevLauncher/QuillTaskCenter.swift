import AppKit
import EventKit
import LauncherCore

/// One finished run of a scheduled task. The full text is in a Markdown file on this Mac.
struct QuillTaskRun: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    let taskID: String
    let taskName: String
    let date: Date
    let succeeded: Bool
    /// The first lines, for rows and notifications.
    let preview: String
    let file: String?
}

/// Runs scheduled Quill tasks while Jevcast is open: at the time, it reads the data the task may
/// read, asks Quill, and saves the result as Markdown. Successes stay silent in the history; a failure
/// calls `onFailure`, which the app shows in the notch panel. A run missed while the Mac slept for hours
/// is skipped, not run late.
@MainActor
final class QuillTaskCenter: ObservableObject {
    @Published private(set) var tasks: [QuillTask]
    @Published private(set) var runs: [QuillTaskRun]
    @Published private(set) var running: Set<String> = []
    private let defaults: UserDefaults
    private let send: (QuillRequest) async throws -> QuillReply
    private let allowed: () -> Set<QuillContext>
    private var loop: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(AppIdentity.name + "/" + QuillStorageKeys.tasksFolder, isDirectory: true)
    /// Where results go. Tests use a temporary folder.
    let resultsFolder: URL
    static let runLimit = 200
    /// Called on the main actor when a run fails. The app shows a notch alert. No system notifications.
    var onFailure: ((QuillTaskRun) -> Void)?

    init(defaults: UserDefaults = .standard, folder: URL = QuillTaskCenter.folder,
         send: @escaping (QuillRequest) async throws -> QuillReply, allowed: @escaping () -> Set<QuillContext>) {
        self.defaults = defaults; self.send = send; self.allowed = allowed; self.resultsFolder = folder
        tasks = defaults.data(forKey: QuillStorageKeys.tasks).flatMap { try? JSONDecoder().decode([QuillTask].self, from: $0) } ?? []
        runs = defaults.data(forKey: QuillStorageKeys.taskRuns).flatMap { try? JSONDecoder().decode([QuillTaskRun].self, from: $0) } ?? []
    }

    // MARK: Tasks

    func add(_ task: QuillTask) { tasks.append(task); save() }
    func remove(_ id: String) { tasks.removeAll { $0.id == id }; save() }
    func setEnabled(_ id: String, _ enabled: Bool) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].enabled = enabled
        // Turning a task back on starts from now, so it does not run for the time it was off.
        if enabled { tasks[index].lastRun = Date() }
        save()
    }
    func lastRun(of id: String) -> QuillTaskRun? { runs.first { $0.taskID == id } }

    private func save() {
        defaults.set(try? JSONEncoder().encode(tasks), forKey: QuillStorageKeys.tasks)
        defaults.set(try? JSONEncoder().encode(runs), forKey: QuillStorageKeys.taskRuns)
    }

    /// Kinds of data a task reads that the user has not allowed.
    func refused(_ task: QuillTask) -> [QuillTaskContext] {
        task.contexts.filter { !allowed().contains($0.quillContext) }
    }

    // MARK: Scheduling

    /// Checks every 30 seconds and after the Mac wakes.
    func start() {
        loop?.cancel()
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.runDue()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        // After waking, the network needs a moment, so the check waits 20 seconds.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    self?.runDue()
                }
            }
        }
    }

    func runDue(now: Date = Date()) {
        for task in tasks where !running.contains(task.id) {
            guard let due = task.due(at: now) else { continue }
            if due.late {
                mark(task.id, ranAt: now)
                record(QuillTaskRun(taskID: task.id, taskName: task.name, date: now, succeeded: false,
                                   preview: "Skipped the \(due.time.formatted(date: .omitted, time: .shortened)) run: the Mac was asleep or Jevcast was closed.", file: nil))
                continue
            }
            mark(task.id, ranAt: now)
            run(task)
        }
    }

    private func mark(_ id: String, ranAt date: Date) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].lastRun = date
        // A one-off task is done after its run.
        if case .once = tasks[index].schedule { tasks[index].enabled = false }
        save()
    }

    // MARK: Running

    /// Runs a task now. The result is saved and announced; errors are saved and announced too.
    func run(_ task: QuillTask) {
        guard !running.contains(task.id) else { return }
        running.insert(task.id)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.running.remove(task.id) }
            let date = Date()
            do {
                let refused = self.refused(task)
                guard refused.isEmpty else {
                    throw LauncherError("This task reads " + refused.map(\.title).joined(separator: " and ").lowercased() + ". Turn that on in Settings › AI › Quill.")
                }
                let sections = await Self.gather(task.contexts)
                let sent = Array(Set(task.contexts.map(\.quillContext))).sorted { $0.rawValue < $1.rawValue }
                let reply = try await self.send(.task(task, sections: sections, sent: sent, now: date))
                let file = Self.write(task, text: reply.text, date: date, in: self.resultsFolder)
                let run = QuillTaskRun(taskID: task.id, taskName: task.name, date: date, succeeded: true, preview: Self.preview(reply.text), file: file)
                self.record(run)
            } catch {
                let run = QuillTaskRun(taskID: task.id, taskName: task.name, date: date, succeeded: false, preview: error.localizedDescription, file: nil)
                self.record(run)
                self.onFailure?(run)
            }
        }
    }

    private func record(_ run: QuillTaskRun) {
        runs = Array(([run] + runs).prefix(Self.runLimit))
        save()
    }

    static func preview(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " #*-")) }.filter { !$0.isEmpty }
        return String(lines.prefix(3).joined(separator: " · ").prefix(240))
    }

    static let stampFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return formatter
    }()

    /// Saves the result as `<task name>/<local date and time>.md`, and returns its path. A name that
    /// is already taken gets a number, so no result replaces another.
    static func write(_ task: QuillTask, text: String, date: Date, in root: URL = folder) -> String? {
        let safe = task.name.map { "/:\\".contains($0) ? "-" : $0 }.prefix(60)
        let folder = root.appendingPathComponent(String(safe), isDirectory: true)
        let stamp = stampFormat.string(from: date)
        var file = folder.appendingPathComponent(stamp + ".md"), number = 2
        while FileManager.default.fileExists(atPath: file.path) { file = folder.appendingPathComponent("\(stamp) \(number).md"); number += 1 }
        let body = "# \(task.name)\n\n_\(date.formatted(date: .complete, time: .shortened)) · \(task.schedule.summary)_\n\n> \(task.prompt)\n\n\(text)\n"
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(body.utf8).write(to: file, options: .atomic)
            return file.path
        } catch { return nil }
    }

    // MARK: Data a task may read

    /// Today's events, open reminders due by tomorrow, and unread inbox mail: titles, times, senders,
    /// and previews only. Each kind is read only when the task names it and the user allowed it.
    static func gather(_ contexts: [QuillTaskContext]) async -> [(title: String, text: String)] {
        var sections: [(String, String)] = []
        let store = Permissions.events
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        if contexts.contains(.calendar) {
            if EKEventStore.authorizationStatus(for: .event) == .fullAccess, let end = cal.date(byAdding: .day, value: 2, to: today) {
                let events = store.events(matching: store.predicateForEvents(withStart: today, end: end, calendars: nil))
                    .filter { $0.status != .canceled }.sorted { $0.startDate < $1.startDate }.prefix(40)
                let lines = events.map { "- \(CalendarSource.when($0)): \($0.title ?? "Untitled")" + ($0.location.map { " (\($0))" } ?? "") }
                sections.append(("Calendar", lines.isEmpty ? "No events today or tomorrow." : lines.joined(separator: "\n")))
            } else { sections.append(("Calendar", "Calendar access is off, so events could not be read.")) }
        }
        if contexts.contains(.reminders) {
            if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess, let end = cal.date(byAdding: .day, value: 2, to: today) {
                let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: end, calendars: nil)
                let reminders: [String] = await withCheckedContinuation { continuation in
                    store.fetchReminders(matching: predicate) { found in
                        continuation.resume(returning: (found ?? []).prefix(40).map { "- " + ($0.title ?? "Untitled") })
                    }
                }
                sections.append(("Reminders", reminders.isEmpty ? "No reminders due." : reminders.joined(separator: "\n")))
            } else { sections.append(("Reminders", "Reminders access is off, so reminders could not be read.")) }
        }
        if contexts.contains(.unreadMail) {
            if case .ready(let root) = MailStore.status() {
                let messages = await Task.detached { () -> [MailSummary] in
                    let inboxes = ((try? MailStore.mailboxes(root: root)) ?? []).filter { $0.role == .inbox }.map(\.rowID)
                    return (try? MailStore.messages(root: root, .init(mailboxes: inboxes, unreadOnly: true, limit: 30))) ?? []
                }.value
                let lines = messages.map { "- From \($0.sender): \($0.subject). \($0.snippet.prefix(160))" }
                sections.append(("Unread mail", lines.isEmpty ? "No unread mail in the inbox." : lines.joined(separator: "\n")))
            } else { sections.append(("Unread mail", "Mail could not be read. Jevcast needs Full Disk Access.")) }
        }
        return sections
    }
}
