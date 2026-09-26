import AppKit
import LauncherCore

/// Quill's answer in the panel. Return copies it, or replaces the selection it came from.
struct QuillAnswer: Equatable {
    let id = UUID()
    let title: String
    var text = ""
    var isLoading = true
    var error: String?
    /// The answer is a rewrite of selected text, so Return pastes it over the selection.
    let replacesSelection: Bool
}

/// Quill rows and requests. Jev decides what runs; Quill only writes text for the rows below.
/// Code checks each request against the context switches in Settings before it is sent.
extension LauncherModel {
    static let askID = QuillStorageKeys.askRowID
    static let customSelectionID = QuillStorageKeys.selectionRowPrefix + "custom"

    var quillReady: Bool { preferences.quillEnabled }

    /// "ask …" or "? …" in the search field.
    func askRows(_ q: String) -> [LauncherResult] {
        guard quillReady, let question = QuillPresets.question(in: q) else { return [] }
        // Below a whole-name match (100), so an app named "Ask …" still comes first.
        return [askRow(question, score: 95)]
    }

    func askRow(_ question: String, score: Double) -> LauncherResult {
        let verb = Verb(title: "Ask Quill", after: .stay) { [weak self] in
            self?.startQuill(.ask(question), title: question, replacesSelection: false); return nil
        }
        return LauncherResult(id: Self.askID, title: "Ask Quill: " + question, detail: QuillModel.title(for: preferences.quillModel) + " · " + preferences.quillEffort.title + (preferences.quillFast ? " · Fast" : ""),
                              symbol: "sparkles", action: .thing(Thing(verbs: [verb], twoLine: false,
                                                                       jevDetail: "Answer a question, explain something, or write new text with the Quill writing model")), score: score)
    }

    /// Quill rows for selected text. Without the "Selected text" switch, one row explains how to turn it on.
    func quillRows(_ context: FrontContext) -> [LauncherResult] {
        guard quillReady, case .text(let text, _) = context else { return [] }
        guard preferences.quillSendsSelection else {
            let verb = Verb(title: "Open Quill Settings") { [weak self] in self?.openQuillSettings?(); return nil }
            return [LauncherResult(id: QuillStorageKeys.selectionRowPrefix + "off", title: "Use Quill on Selected Text", detail: "Turn on “Selected text” in Settings › AI › Quill",
                                   symbol: "sparkles", action: .thing(Thing(verbs: [verb], twoLine: false)), score: 0)]
        }
        // Quill sees at most `maxText` characters, so a longer selection is copied, never replaced.
        let fits = text.count <= QuillRequest.maxText
        return QuillPresets.selection.map { preset in
            let verb = Verb(title: preset.title, after: .stay) { [weak self] in
                self?.startQuill(.transform(preset.instruction, text: text, label: preset.title), title: preset.title,
                                replacesSelection: fits && preset.id != "summary" && preset.id != "explain")
                return nil
            }
            return LauncherResult(id: QuillStorageKeys.selectionRowPrefix + preset.id, title: preset.title, detail: "Quill · " + (FrontContext.text(text, app: "").summary),
                                  symbol: "sparkles", action: .thing(Thing(verbs: [verb], twoLine: false,
                                                                           jevDetail: "\(preset.instruction) Applies to the text selected in the front app, with the Quill writing model")), score: 0)
        }
    }

    /// A typed instruction for the selected text, such as "translate to turkish".
    func customSelectionRow(_ q: String) -> LauncherResult? {
        guard quillReady, preferences.quillSendsSelection, case .text(let text, _) = frontContext else { return nil }
        let instruction = q.trimmingCharacters(in: .whitespaces)
        guard instruction.split(separator: " ").count >= 2, QuillPresets.question(in: instruction) == nil else { return nil }
        // A question about the text is answered and copied; only a change replaces the selection.
        let replaces = text.count <= QuillRequest.maxText && !QuillPresets.isQuestion(instruction)
        let verb = Verb(title: "Apply with Quill", after: .stay) { [weak self] in
            self?.startQuill(.transform(instruction, text: text), title: instruction, replacesSelection: replaces); return nil
        }
        return LauncherResult(id: Self.customSelectionID, title: "Quill: " + instruction, detail: "On " + FrontContext.text(text, app: "").summary,
                              symbol: "sparkles", action: .thing(Thing(verbs: [verb], twoLine: false,
                                                                       jevDetail: "Apply the typed instruction to the text selected in the front app, with the Quill writing model")), score: 60)
    }

    /// The Quill key: its own OpenRouter key, or the Jev key when that is an OpenRouter key.
    func quillKey() async -> String? {
        if case .present(let key) = await quillKeys.load() { return key }
        if case .present(let key) = await keys.load(), key.hasPrefix("sk-or-") { return key }
        return nil
    }

    /// Kinds of context the user allows. What they typed is allowed once Quill is on.
    var allowedQuillContext: Set<QuillContext> {
        guard preferences.quillEnabled else { return [] }
        var allowed: Set<QuillContext> = [.typedText]
        if preferences.quillSendsSelection { allowed.insert(.selectedText) }
        if preferences.quillSendsMail { allowed.insert(.mailMessage) }
        if preferences.quillSendsCalendar { allowed.insert(.calendar) }
        if preferences.quillSendsUnreadMail { allowed.insert(.unreadMail) }
        if preferences.quillSendsDictation { allowed.insert(.dictation) }
        return allowed
    }

    /// Sends one request and shows the answer in the panel. A request that carries context the
    /// user has not allowed is refused here, before anything is sent.
    func startQuill(_ request: QuillRequest, title: String, replacesSelection: Bool) {
        quillWork?.cancel()
        pauseListening()
        let answer = QuillAnswer(title: title, replacesSelection: replacesSelection)
        quillAnswer = answer
        quillWork = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.sendQuill(request)
                // A reply for an answer that was dismissed or replaced is dropped.
                guard !Task.isCancelled, self.quillAnswer?.id == answer.id else { return }
                self.quillAnswer?.text = reply.text
                self.quillAnswer?.isLoading = false
            } catch is CancellationError {
            } catch {
                guard self.quillAnswer?.id == answer.id else { return }
                self.quillAnswer?.isLoading = false
                self.quillAnswer?.error = error.localizedDescription
            }
        }
    }

    /// The checked request, used by the launcher and the mail window.
    func sendQuill(_ request: QuillRequest) async throws -> QuillReply {
        let refused = Set(request.sent).subtracting(allowedQuillContext)
        guard preferences.quillEnabled else { throw LauncherError("Quill is off. Turn it on in Settings › AI › Quill.") }
        guard refused.isEmpty else {
            throw LauncherError("Quill may not read " + refused.map(\.title).sorted().joined(separator: " or ").lowercased() + ". Turn it on in Settings › AI › Quill.")
        }
        guard let key = await quillKey() else { throw LauncherError("Quill needs an OpenRouter key. Add one in Settings › AI › Quill.") }
        let effort = request.effort ?? preferences.quillEffort
        let fast = preferences.quillFast
        let options = QuillOptions(model: preferences.quillModel, effort: effort, fast: fast)
        do {
            let reply = try await quill.complete(request, options: options, apiKey: key)
            quillLog.record(.init(date: Date(), action: request.action, sent: request.sent, effort: effort, fast: fast,
                                 inputTokens: reply.inputTokens, outputTokens: reply.outputTokens, cost: reply.cost, succeeded: true))
            return reply
        } catch is CancellationError {
            // The request may already have reached OpenRouter, so it is logged too.
            quillLog.record(.init(date: Date(), action: request.action + " (cancelled)", sent: request.sent, effort: effort, fast: fast,
                                 inputTokens: 0, outputTokens: 0, cost: nil, succeeded: false))
            throw CancellationError()
        } catch {
            quillLog.record(.init(date: Date(), action: request.action, sent: request.sent, effort: effort, fast: fast,
                                 inputTokens: 0, outputTokens: 0, cost: nil, succeeded: false))
            throw error
        }
    }

    /// Return on an answer: copy it, or paste it over the selection. ⇧Return always pastes.
    func finishQuillAnswer(paste: Bool) {
        guard let answer = quillAnswer else { return }
        guard !answer.isLoading, answer.error == nil, !answer.text.isEmpty else { return }
        copy(answer.text)
        onClose?(true)
        if paste || answer.replacesSelection { Paster.pasteSoon() }
    }

    var quillPrimaryTitle: String? {
        guard let answer = quillAnswer, !answer.isLoading, answer.error == nil else { return nil }
        return answer.replacesSelection ? "Replace Selection" : "Copy Answer"
    }

    func dismissQuill() {
        quillWork?.cancel(); quillWork = nil; quillAnswer = nil
    }
}

extension LauncherModel {
    /// "every weekday at 8am brief me on my meetings": a row that schedules a Quill task.
    func taskRows(_ q: String) -> [LauncherResult] {
        // Only with Quill on, and below whole-name matches, so "daily standup notes" stays a search.
        guard quillReady, let task = QuillTaskQuery.parse(q) else { return [] }
        var parts = [task.schedule.summary]
        if !task.contexts.isEmpty { parts.append("reads " + task.contexts.map(\.title).joined(separator: ", ").lowercased()) }
        let refused = quillTasks.refused(task)
        if !refused.isEmpty { parts.append("turn on " + refused.map(\.title).joined(separator: " and ").lowercased() + " in Settings › AI › Quill") }
        let verb = Verb(title: "Schedule Task") { [weak self] in
            guard let self else { return nil }
            self.quillTasks.add(task)
            let next = task.nextRun(after: Date()).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "soon"
            _ = await Notifier.post(title: "Scheduled: " + task.name, body: task.schedule.summary + ". First run " + next + ". “scheduled tasks” lists it.")
            return nil
        }
        return [LauncherResult(id: QuillStorageKeys.taskRowPrefix + "new", title: "Schedule with Quill: " + task.prompt, detail: parts.joined(separator: " · "),
                               symbol: "calendar.badge.clock", action: .thing(Thing(verbs: [verb], twoLine: false)), score: 95)]
    }
}
