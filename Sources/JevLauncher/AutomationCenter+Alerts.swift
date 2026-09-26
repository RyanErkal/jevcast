import AppKit
import LauncherCore

/// Notch alerts for runs that need the user, and Codex reading. The decision is `AlertDecision` in LauncherCore.
extension AutomationCenter {
    nonisolated static func alertID(_ run: RunRecord) -> String { "run:\(run.automationID)/\(run.id)" }

    /// Shows alerts for runs that reached an alerting state. Quiet hours delay them until the period ends.
    func processAlerts(now: Date = Date()) {
        guard !isolated else { return }
        let settings = alertSettings()
        var wake: Date?
        let candidates = runs.values.flatMap { $0 }.filter { !$0.alerted }.sorted { $0.queued < $1.queued }
        for run in candidates where !shownAlerts.contains(Self.alertID(run)) {
            let a = automation(run.automationID)
            switch AlertDecision.decide(run, policy: a?.policy, settings: settings, now: now) {
            case .show: show(run, automation: a, hideNames: settings.hideNames)
            case .wait(let until): wake = min(wake ?? until, until)
            case .skip: break
            }
        }
        quietTask?.cancel()
        if let wake {
            quietTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(1, wake.timeIntervalSinceNow) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.processAlerts()
            }
        }
    }

    private func show(_ run: RunRecord, automation a: Automation?, hideNames: Bool) {
        let text = AlertText.make(run, name: a?.name ?? run.automationName, hideNames: hideNames)
        let tone: NotchAlert.Tone
        let actions: [NotchAlert.Action]
        switch run.state {
        case .needsInput: tone = .attention; actions = [.init("Answer", id: "answer", primary: true), .init("Later", id: "later")]
        case .needsApproval: tone = .attention; actions = [.init("Review", id: "review", primary: true), .init("Later", id: "later")]
        case .failed: tone = .failure; actions = [.init("Retry", id: "retry", primary: true), .init("Open", id: "open")]
        default: tone = .success; actions = [.init("Open", id: "open", primary: true), .init("Later", id: "later")]
        }
        let id = Self.alertID(run)
        shownAlerts.insert(id)
        NotchAlertController.shared.visibleSeconds = min(max(alertSeconds(), 4), 12)
        NotchAlertController.shared.show(NotchAlert(id: id, symbol: hideNames ? "bolt.badge.clock" : (a?.symbol ?? "gearshape.2"),
                                                    title: text.title, message: text.message, tone: tone, actions: actions))
        markAlerted(run)
    }

    /// Save delivery without a read-modify-write of run.json.
    private func markAlerted(_ run: RunRecord) {
        let store = self.store
        Task.detached(priority: .utility) { try? AutomationAlertReceipt.save(run, store: store) }
    }

    /// Handles a notch button for an automation alert. Returns false for alerts that are not ours.
    @discardableResult func handleAlertAction(_ alertID: String, _ action: String) -> Bool {
        if alertID.hasPrefix("merged-") {
            if action == "open" || action == "review" || action == "answer" { openWindow?(nil, nil) }
            return true
        }
        guard alertID.hasPrefix("run:") else { return false }
        let parts = alertID.dropFirst(4).split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return true }
        switch action {
        case "review", "answer", "open": openWindow?(parts[0], parts[1])
        case "retry": runNow(parts[0])
        default: break // later, dismiss: it stays in Needs you.
        }
        return true
    }

    /// A sample alert for Settings, with invented content.
    func showTestAlert() {
        NotchAlertController.shared.visibleSeconds = min(max(alertSeconds(), 4), 12)
        NotchAlertController.shared.show(NotchAlert(id: "test-\(UUID().uuidString)", symbol: "bolt.badge.clock",
                                                    title: alertSettings().hideNames ? "An automation" : "Test alert",
                                                    message: "Automation alerts look like this.", tone: .info,
                                                    actions: [.init("OK", id: "later", primary: true)]))
    }

    // MARK: Codex

    /// Reads `~/.codex/automations` off the main thread. Never writes there.
    func loadCodex() {
        guard !isolated else { return }
        Task { @MainActor [weak self] in
            let list = await Task.detached(priority: .utility) { CodexImport.readAll(folder: Self.codexFolder) }.value
            guard let self, self.codex != list else { return }
            self.codex = list
        }
    }
}
