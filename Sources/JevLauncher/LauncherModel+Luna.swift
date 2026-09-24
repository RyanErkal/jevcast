import AppKit
import LauncherCore

/// Luna's answer in the panel. Return copies it, or replaces the selection it came from.
struct LunaAnswer: Equatable {
    let id = UUID()
    let title: String
    var text = ""
    var isLoading = true
    var error: String?
    /// The answer is a rewrite of selected text, so Return pastes it over the selection.
    let replacesSelection: Bool
}

/// Luna rows and requests. Jev decides what runs; Luna only writes text for the rows below.
/// Code checks each request against the context switches in Settings before it is sent.
extension LauncherModel {
    static let askID = "luna:ask"
    static let customSelectionID = "this:luna:custom"

    var lunaReady: Bool { preferences.lunaEnabled }

    /// "ask …", "? …", or "luna …" in the search field.
    func askRows(_ q: String) -> [LauncherResult] {
        guard lunaReady, let question = LunaPresets.question(in: q) else { return [] }
        // Below a whole-name match (100), so "luna display" still opens the Luna Display app.
        return [askRow(question, score: 95)]
    }

    func askRow(_ question: String, score: Double) -> LauncherResult {
        let verb = Verb(title: "Ask Luna", after: .stay) { [weak self] in
            self?.startLuna(.ask(question), title: question, replacesSelection: false); return nil
        }
        return LauncherResult(id: Self.askID, title: "Ask Luna: " + question, detail: "GPT-6 Luna · " + preferences.lunaEffort.title,
                              symbol: "sparkles", action: .thing(Thing(verbs: [verb], twoLine: false,
                                                                       jevDetail: "Answer a question, explain something, or write new text with the Luna writing model")), score: score)
    }

    /// Luna rows for selected text. Without the "Selected text" switch, one row explains how to turn it on.
    func lunaRows(_ context: FrontContext) -> [LauncherResult] {
        guard lunaReady, case .text(let text, _) = context else { return [] }
        guard preferences.lunaSendsSelection else {
            let verb = Verb(title: "Open Luna Settings") { [weak self] in self?.openLunaSettings?(); return nil }
            return [LauncherResult(id: "this:luna:off", title: "Use Luna on Selected Text", detail: "Turn on “Selected text” in Settings › AI › Luna",
                                   symbol: "sparkles", action: .thing(Thing(verbs: [verb], twoLine: false)), score: 0)]
        }
        // Luna sees at most `maxText` characters, so a longer selection is copied, never replaced.
        let fits = text.count <= LunaRequest.maxText
        return LunaPresets.selection.map { preset in
            let verb = Verb(title: preset.title, after: .stay) { [weak self] in
                self?.startLuna(.transform(preset.instruction, text: text, label: preset.title), title: preset.title,
                                replacesSelection: fits && preset.id != "summary" && preset.id != "explain")
                return nil
            }
            return LauncherResult(id: "this:luna:" + preset.id, title: preset.title, detail: "Luna · " + (FrontContext.text(text, app: "").summary),
                                  symbol: "sparkles", action: .thing(Thing(verbs: [verb], twoLine: false,
                                                                           jevDetail: "\(preset.instruction) Applies to the text selected in the front app, with the Luna writing model")), score: 0)
        }
    }

    /// A typed instruction for the selected text, such as "translate to turkish".
    func customSelectionRow(_ q: String) -> LauncherResult? {
        guard lunaReady, preferences.lunaSendsSelection, case .text(let text, _) = frontContext else { return nil }
        let instruction = q.trimmingCharacters(in: .whitespaces)
        guard instruction.split(separator: " ").count >= 2, LunaPresets.question(in: instruction) == nil else { return nil }
        // A question about the text is answered and copied; only a change replaces the selection.
        let replaces = text.count <= LunaRequest.maxText && !LunaPresets.isQuestion(instruction)
        let verb = Verb(title: "Apply with Luna", after: .stay) { [weak self] in
            self?.startLuna(.transform(instruction, text: text), title: instruction, replacesSelection: replaces); return nil
        }
        return LauncherResult(id: Self.customSelectionID, title: "Luna: " + instruction, detail: "On " + FrontContext.text(text, app: "").summary,
                              symbol: "sparkles", action: .thing(Thing(verbs: [verb], twoLine: false,
                                                                       jevDetail: "Apply the typed instruction to the text selected in the front app, with the Luna writing model")), score: 60)
    }

    /// The Luna key: its own OpenRouter key, or the Jev key when that is an OpenRouter key.
    func lunaKey() async -> String? {
        if case .present(let key) = await lunaKeys.load() { return key }
        if case .present(let key) = await keys.load(), key.hasPrefix("sk-or-") { return key }
        return nil
    }

    /// Kinds of context the user allows. What they typed is allowed once Luna is on.
    var allowedLunaContext: Set<LunaContext> {
        guard preferences.lunaEnabled else { return [] }
        var allowed: Set<LunaContext> = [.typedText]
        if preferences.lunaSendsSelection { allowed.insert(.selectedText) }
        if preferences.lunaSendsMail { allowed.insert(.mailMessage) }
        if preferences.lunaSendsCalendar { allowed.insert(.calendar) }
        if preferences.lunaSendsUnreadMail { allowed.insert(.unreadMail) }
        if preferences.lunaSendsDictation { allowed.insert(.dictation) }
        return allowed
    }

    /// Sends one request and shows the answer in the panel. A request that carries context the
    /// user has not allowed is refused here, before anything is sent.
    func startLuna(_ request: LunaRequest, title: String, replacesSelection: Bool) {
        lunaWork?.cancel()
        pauseListening()
        let answer = LunaAnswer(title: title, replacesSelection: replacesSelection)
        lunaAnswer = answer
        lunaWork = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.sendLuna(request)
                // A reply for an answer that was dismissed or replaced is dropped.
                guard !Task.isCancelled, self.lunaAnswer?.id == answer.id else { return }
                self.lunaAnswer?.text = reply.text
                self.lunaAnswer?.isLoading = false
            } catch is CancellationError {
            } catch {
                guard self.lunaAnswer?.id == answer.id else { return }
                self.lunaAnswer?.isLoading = false
                self.lunaAnswer?.error = error.localizedDescription
            }
        }
    }

    /// The checked request, used by the launcher and the mail window.
    func sendLuna(_ request: LunaRequest) async throws -> LunaReply {
        let refused = Set(request.sent).subtracting(allowedLunaContext)
        guard preferences.lunaEnabled else { throw LauncherError("Luna is off. Turn it on in Settings › AI › Luna.") }
        guard refused.isEmpty else {
            throw LauncherError("Luna may not read " + refused.map(\.title).sorted().joined(separator: " or ").lowercased() + ". Turn it on in Settings › AI › Luna.")
        }
        guard let key = await lunaKey() else { throw LauncherError("Luna needs an OpenRouter key. Add one in Settings › AI › Luna.") }
        let effort = request.effort ?? preferences.lunaEffort
        do {
            let reply = try await luna.complete(request, effort: effort, apiKey: key)
            lunaLog.record(.init(date: Date(), action: request.action, sent: request.sent, effort: effort,
                                 inputTokens: reply.inputTokens, outputTokens: reply.outputTokens, cost: reply.cost, succeeded: true))
            return reply
        } catch is CancellationError {
            // The request may already have reached OpenRouter, so it is logged too.
            lunaLog.record(.init(date: Date(), action: request.action + " (cancelled)", sent: request.sent, effort: effort,
                                 inputTokens: 0, outputTokens: 0, cost: nil, succeeded: false))
            throw CancellationError()
        } catch {
            lunaLog.record(.init(date: Date(), action: request.action, sent: request.sent, effort: effort,
                                 inputTokens: 0, outputTokens: 0, cost: nil, succeeded: false))
            throw error
        }
    }

    /// Return on an answer: copy it, or paste it over the selection. ⇧Return always pastes.
    func finishLunaAnswer(paste: Bool) {
        guard let answer = lunaAnswer else { return }
        guard !answer.isLoading, answer.error == nil, !answer.text.isEmpty else { return }
        copy(answer.text)
        onClose?(true)
        if paste || answer.replacesSelection { Paster.pasteSoon() }
    }

    var lunaPrimaryTitle: String? {
        guard let answer = lunaAnswer, !answer.isLoading, answer.error == nil else { return nil }
        return answer.replacesSelection ? "Replace Selection" : "Copy Answer"
    }

    func dismissLuna() {
        lunaWork?.cancel(); lunaWork = nil; lunaAnswer = nil
    }
}

extension LauncherModel {
    /// "every weekday at 8am brief me on my meetings": a row that schedules a Luna task.
    func taskRows(_ q: String) -> [LauncherResult] {
        // Only with Luna on, and below whole-name matches, so "daily standup notes" stays a search.
        guard lunaReady, let task = LunaTaskQuery.parse(q) else { return [] }
        var parts = [task.schedule.summary]
        if !task.contexts.isEmpty { parts.append("reads " + task.contexts.map(\.title).joined(separator: ", ").lowercased()) }
        let refused = lunaTasks.refused(task)
        if !refused.isEmpty { parts.append("turn on " + refused.map(\.title).joined(separator: " and ").lowercased() + " in Settings › AI › Luna") }
        let verb = Verb(title: "Schedule Task") { [weak self] in
            guard let self else { return nil }
            self.lunaTasks.add(task)
            let next = task.nextRun(after: Date()).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "soon"
            _ = await Notifier.post(title: "Scheduled: " + task.name, body: task.schedule.summary + ". First run " + next + ". “scheduled tasks” lists it.")
            return nil
        }
        return [LauncherResult(id: "lunatask:new", title: "Schedule with Luna: " + task.prompt, detail: parts.joined(separator: " · "),
                               symbol: "calendar.badge.clock", action: .thing(Thing(verbs: [verb], twoLine: false)), score: 95)]
    }
}
