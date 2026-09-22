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

    /// One row for each process that listens on the queried port, or on any port.
    func portRows() -> [LauncherResult] {
        guard portQuery != nil else { return [] }
        return listeners.enumerated().map { index, listener in
            LauncherResult(id: listener.id, title: "Stop \(listener.command)", detail: ":\(listener.port) · PID \(listener.pid)",
                           symbol: "xmark.octagon", action: .stopProcess(listener), score: 1900 - Double(index))
        }
    }

    /// The strip text for a port lookup that is running or found nothing.
    var portNotice: String? {
        guard let portQuery, listeners.isEmpty else { return nil }
        if isLoadingPorts { return "Looking for listening ports…" }
        return portQuery.port.map { "Nothing is listening on port \($0)." } ?? "No TCP ports are listening."
    }

    /// Runs lsof off the main thread. `promoteFirst` puts the first listener at the top, for a Jev match.
    func loadPorts(_ query: PortQuery, revision current: UUID, promoteFirst: Bool) {
        portQuery = query; isLoadingPorts = true; listeners = []
        rebuild()
        Task { [weak self] in
            let found = await CommandRunner.listeningPorts()
            guard let self, self.visible, self.revision == current else { return }
            self.listeners = query.port.map { port in found.filter { $0.port == port } } ?? found
            self.isLoadingPorts = false
            if promoteFirst, let first = self.listeners.first { self.promotedID = first.id }
            self.rebuild()
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

    /// Ends a process that ignored Stop, from the actions menu.
    func forceStop(_ listener: ListeningPort) {
        do { try CommandRunner.stop(listener, force: true); onClose?(true) }
        catch { message = error.localizedDescription }
    }

    /// "stop node on port 3000", for the confirmation strip.
    static func confirmPhrase(_ result: LauncherResult) -> String {
        switch result.action {
        case .stopProcess(let listener): return "stop \(listener.command) on port \(listener.port)"
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
