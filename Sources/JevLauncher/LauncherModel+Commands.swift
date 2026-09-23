import AppKit
import LauncherCore

/// Built-in commands, the user's own commands, and the port lookup.
extension LauncherModel {
    /// Built-in and custom command rows that match the query by name or alias.
    func commandRows(_ q: String) -> [LauncherResult] {
        var rows: [LauncherResult] = []
        for command in SystemCommands.all {
            guard let score = SearchRanking.score(query: q, title: command.title, aliases: command.aliases) else { continue }
            rows.append(Self.systemRow(command, score: score * 100))
        }
        for command in preferences.customCommands {
            // "Open repo swift" passes "swift" to a command that takes {input}.
            if command.takesInput, q.lowercased().hasPrefix(command.name.lowercased() + " ") {
                let input = String(q.dropFirst(command.name.count + 1)).trimmingCharacters(in: .whitespaces)
                if !input.isEmpty {
                    rows.append(LauncherResult(id: "custom:\(command.id):input", title: "\(command.name): \(input)", detail: "Your command",
                                               symbol: "terminal", action: .custom(command, input: input), score: 1750))
                    continue
                }
            }
            guard let score = SearchRanking.score(query: q, title: command.name) else { continue }
            rows.append(Self.customRow(command, score: score * 100))
        }
        return rows
    }

    /// A row for a remembered or Jev-chosen command ID, or nil for another kind of ID.
    func commandRow(id: String, score: Double) -> LauncherResult? {
        if id.hasPrefix("command:") {
            return SystemCommands.command(id: String(id.dropFirst("command:".count))).map { Self.systemRow($0, score: score) }
        }
        if id.hasPrefix("custom:") {
            return preferences.customCommands.first { "custom:" + $0.id == id }.map { Self.customRow($0, score: score) }
        }
        return nil
    }

    /// One row for each process that listens on the queried port, or on any port. Your own
    /// servers come first, then macOS services, then other users' processes.
    func portRows() -> [LauncherResult] {
        guard portQuery != nil else { return [] }
        let order: [ProcessSnapshot.Owner: Int] = [.yours: 0, .system: 1, .otherUser: 2]
        let sorted = listeners.sorted { lhs, rhs in
            let l = order[portOwner(lhs)] ?? 0, r = order[portOwner(rhs)] ?? 0
            return l != r ? l < r : lhs.port < rhs.port
        }
        return sorted.enumerated().map { index, listener in
            LauncherResult(id: listener.id, title: portName(listener) + "  :" + String(listener.port), detail: portDetail(listener),
                           symbol: portSymbol(listener), action: .stopProcess(listener), score: 1900 - Double(index))
        }
    }

    /// "Google Chrome", or the program name for a command-line server.
    func portName(_ listener: ListeningPort) -> String {
        if let app = NSRunningApplication(processIdentifier: listener.pid), let name = app.localizedName { return name }
        if let executable = portDetails[listener.pid]?.executable, !executable.isEmpty { return (executable as NSString).lastPathComponent }
        return listener.command
    }

    func portOwner(_ listener: ListeningPort) -> ProcessSnapshot.Owner {
        portDetails[listener.pid]?.owner(currentUID: getuid()) ?? .yours
    }

    /// "vite · 4.2% CPU · 84 MB · up 2 h · ~/Dev/site · open to your network".
    func portDetail(_ listener: ListeningPort) -> String {
        guard let details = portDetails[listener.pid] else { return "PID \(listener.pid) · reading details…" }
        var parts: [String] = []
        switch portOwner(listener) {
        case .system: parts.append("macOS service")
        case .otherUser: parts.append("another user's process")
        case .yours: break
        }
        // An app's name already says what it is; a command-line server gets its script or module.
        let role = NSRunningApplication(processIdentifier: listener.pid) == nil ? details.role : ""
        if !role.isEmpty, role.lowercased() != portName(listener).lowercased() { parts.append(role) }
        parts += [details.cpuText, details.memoryText, details.uptimeText]
        // "~/Dev/site", or "…/worktrees/site" for a deep folder.
        if let folder = details.folder { parts.append(Self.folderDetail(folder + "/_")) }
        parts.append(listener.exposed ? "open to your network" : "this Mac only")
        return parts.joined(separator: " · ")
    }

    private func portSymbol(_ listener: ListeningPort) -> String {
        switch portOwner(listener) {
        case .yours: return listener.exposed ? "network" : "server.rack"
        case .system: return "gearshape.2"
        case .otherUser: return "lock"
        }
    }

    static func homeRelative(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// The strip text for a port lookup: what just stopped, how to stop, or why the list is empty.
    var portNotice: String? {
        guard let portQuery else { return nil }
        if let stoppedNotice { return stoppedNotice }
        if let selected, case .stopProcess(let listener) = selected.action {
            if portOwner(listener) == .otherUser { return "Owned by another user. ⌘K copies a sudo kill command." }
            return manualSelection ? "Press ⌫ to stop \(portName(listener)). Return opens it in your browser."
                                   : "Press ⌘⌫ to stop \(portName(listener)), or pick a row with ↑↓ and press ⌫."
        }
        guard listeners.isEmpty else { return nil }
        if isLoadingPorts { return "Looking for listening ports…" }
        return portQuery.port.map { "Nothing is listening on port \($0)." } ?? "No TCP ports are listening."
    }

    /// Runs lsof and ps off the main thread, then refreshes CPU and memory every two seconds
    /// while the list is open. `promoteFirst` puts the first listener at the top, for a Jev match.
    func loadPorts(_ query: PortQuery, revision current: UUID, promoteFirst: Bool) {
        portQuery = query; isLoadingPorts = true; listeners = []; portDetails = [:]
        rebuild()
        Task { [weak self] in
            var first = true
            while let self, self.visible, self.revision == current {
                let found = await CommandRunner.listeningPorts()
                let matching = query.port.map { port in found.filter { $0.port == port } } ?? found
                let details = await CommandRunner.processDetails(Array(Set(matching.map(\.pid))))
                guard self.visible, self.revision == current else { return }
                self.listeners = matching
                self.portDetails = details
                self.isLoadingPorts = false
                if first, promoteFirst, let top = self.portRows().first { self.promotedID = top.id }
                first = false
                self.rebuild()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// Runs a built-in command after the launcher closes. A failure reopens it with the reason.
    func run(_ command: SystemCommand) {
        Task { [weak self] in
            do {
                let output = try await CommandRunner.run(command)
                guard command.output == .copy else { return }
                if output.isEmpty { self?.showFailure("\(command.title) found nothing to copy.") }
                else { self?.copy(output) }
            } catch {
                self?.showFailure(error.localizedDescription)
            }
        }
    }

    func run(_ command: CustomCommand, input: String?) {
        Task { [weak self] in
            do {
                let output = try await CommandRunner.run(command, input: input)
                switch command.output {
                case .none: break
                case .copy:
                    if output.isEmpty { self?.showFailure("\(command.name) printed nothing to copy.") } else { self?.copy(output) }
                case .notify:
                    _ = await Notifier.post(title: command.name, body: output.isEmpty ? "Finished." : String(output.prefix(400)))
                }
            } catch {
                self?.showFailure("\(command.name): \(error.localizedDescription)")
            }
        }
    }

    /// ⌫ on a port row: the first press asks, the second stops the process. The launcher stays
    /// open and the list refreshes. Returns false when the selected row is not a port.
    @discardableResult
    func stopSelectedPort(force: Bool = false, confirmed: Bool = false) -> Bool {
        guard let result = selected, case .stopProcess(let listener) = result.action else { return false }
        let name = portName(listener)
        if portOwner(listener) == .otherUser {
            message = "\(name) belongs to another user. To stop it, run sudo kill \(listener.pid) in Terminal. ⌘K copies the command."
            return true
        }
        guard confirmed || force || pendingConfirmID == result.id else { pendingConfirmID = result.id; stoppedNotice = nil; return true }
        pendingConfirmID = nil
        do {
            try CommandRunner.stop(listener, force: force)
            listeners.removeAll { $0.pid == listener.pid && $0.port == listener.port }
            manualSelection = false
            message = nil
            stoppedNotice = (force ? "Force stopped " : "Stopped ") + "\(name) on :\(listener.port)."
            rebuild()
        } catch {
            message = error.localizedDescription
        }
        return true
    }

    /// Stops a process from the actions menu, where choosing Stop is already deliberate.
    /// `force` sends SIGKILL, for a process that ignored a normal stop. The launcher stays open.
    func stop(_ listener: ListeningPort, force: Bool) {
        select(listener.id)
        stopSelectedPort(force: force, confirmed: true)
    }

    /// "stop node on port 3000", for the confirmation strip.
    func confirmPhrase(_ result: LauncherResult) -> String {
        switch result.action {
        case .stopProcess(let listener):
            let phrase = "stop \(portName(listener)) on port \(listener.port)"
            return portOwner(listener) == .system ? phrase + ". It is a macOS service and may start again" : phrase
        case .command(let command): return command.title.lowercased()
        default: return result.title.lowercased()
        }
    }

    static func systemRow(_ command: SystemCommand, score: Double) -> LauncherResult {
        LauncherResult(id: "command:" + command.id, title: command.title, detail: "Command",
                       symbol: command.symbol, action: .command(command), score: score)
    }

    static func customRow(_ command: CustomCommand, score: Double) -> LauncherResult {
        LauncherResult(id: "custom:" + command.id, title: command.name, detail: command.takesInput ? "Your command · type text after the name" : "Your command",
                       symbol: "terminal", action: .custom(command, input: nil), score: score)
    }
}
