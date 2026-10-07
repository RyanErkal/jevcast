import AppKit
import LauncherCore

/// The AI answer in the panel. Return copies it, or replaces the selection it came from.
struct AIWritingAnswer: Equatable {
    let id = UUID()
    let title: String
    var text = ""
    var isLoading = true
    var error: String?
    /// The answer is a rewrite of selected text, so Return pastes it over the selection.
    let replacesSelection: Bool
}

/// AI writing rows and requests. Jev decides what runs; AI writing only writes text for the rows below.
/// Code checks each request against the context switches in Settings before it is sent.
extension LauncherModel {
    static let askID = AIWritingStorageKeys.askRowID
    static let customSelectionID = AIWritingStorageKeys.selectionRowPrefix + "custom"

    var aiWritingReady: Bool { preferences.aiWritingEnabled }

    /// "ask …" or "? …" in the search field.
    func askRows(_ q: String) -> [LauncherResult] {
        guard aiWritingReady, let question = AIWritingPresets.question(in: q) else { return [] }
        // Below a whole-name match (100), so an app named "Ask …" still comes first.
        return [askRow(question, score: 95)]
    }

    func askRow(_ question: String, score: Double) -> LauncherResult {
        let verb = Verb(title: "Ask AI", after: .stay) { [weak self] in
            self?.startAIWriting(.ask(question), title: question, replacesSelection: false); return nil
        }
        return LauncherResult(id: Self.askID, title: "Ask AI: " + question, detail: AIWritingModel.title(for: preferences.aiWritingModel) + " · " + preferences.aiWritingEffort.title + (preferences.aiWritingFast ? " · Fast" : ""),
                              symbol: "sparkles", action: .thing(Thing(verbs: [verb], twoLine: false,
                                                                       jevDetail: "Answer a question, explain something, or write new text with the writing model")), score: score)
    }

    /// AI writing rows for selected text. Without the "Selected text" switch, one row explains how to turn it on.
    func aiWritingRows(_ context: FrontContext) -> [LauncherResult] {
        guard aiWritingReady, case .text(let text, _) = context else { return [] }
        guard preferences.aiWritingSendsSelection else {
            let verb = Verb(title: "Open Writing Settings") { [weak self] in self?.openAIWritingSettings?(); return nil }
            return [LauncherResult(id: AIWritingStorageKeys.selectionRowPrefix + "off", title: "Use AI on Selected Text", detail: "Turn on “Selected text” in Settings › AI › Writing",
                                   symbol: "sparkles", action: .thing(Thing(verbs: [verb], twoLine: false)), score: 0)]
        }
        // The writing model sees at most `maxText` characters, so a longer selection is copied, never replaced.
        let fits = text.count <= AIWritingRequest.maxText
        return AIWritingPresets.selection.map { preset in
            let verb = Verb(title: preset.title, after: .stay) { [weak self] in
                self?.startAIWriting(.transform(preset.instruction, text: text, label: preset.title), title: preset.title,
                                replacesSelection: fits && preset.id != "summary" && preset.id != "explain")
                return nil
            }
            return LauncherResult(id: AIWritingStorageKeys.selectionRowPrefix + preset.id, title: preset.title, detail: "AI · " + (FrontContext.text(text, app: "").summary),
                                  symbol: "sparkles", action: .thing(Thing(verbs: [verb], twoLine: false,
                                                                           jevDetail: "\(preset.instruction) Applies to the text selected in the front app, with the writing model")), score: 0)
        }
    }

    /// A typed instruction for the selected text, such as "translate to turkish".
    func customSelectionRow(_ q: String) -> LauncherResult? {
        guard aiWritingReady, preferences.aiWritingSendsSelection, case .text(let text, _) = frontContext else { return nil }
        let instruction = q.trimmingCharacters(in: .whitespaces)
        guard instruction.split(separator: " ").count >= 2, AIWritingPresets.question(in: instruction) == nil else { return nil }
        // A question about the text is answered and copied; only a change replaces the selection.
        let replaces = text.count <= AIWritingRequest.maxText && !AIWritingPresets.isQuestion(instruction)
        let verb = Verb(title: "Apply to Selection", after: .stay) { [weak self] in
            self?.startAIWriting(.transform(instruction, text: text), title: instruction, replacesSelection: replaces); return nil
        }
        return LauncherResult(id: Self.customSelectionID, title: "AI: " + instruction, detail: "On " + FrontContext.text(text, app: "").summary,
                              symbol: "sparkles", action: .thing(Thing(verbs: [verb], twoLine: false,
                                                                       jevDetail: "Apply the typed instruction to the text selected in the front app, with the writing model")), score: 60)
    }

    /// The AI writing key: its own OpenRouter key, or the Jev key when that is an OpenRouter key.
    func aiWritingKey() async -> String? {
        if case .present(let key) = await aiWritingKeys.load() { return key }
        if case .present(let key) = await keys.load(), key.hasPrefix("sk-or-") { return key }
        return nil
    }

    /// Kinds of context the user allows. What they typed is allowed once AI writing is on.
    var allowedAIWritingContext: Set<AIWritingContext> {
        guard preferences.aiWritingEnabled else { return [] }
        var allowed: Set<AIWritingContext> = [.typedText]
        if preferences.aiWritingSendsSelection { allowed.insert(.selectedText) }
        if preferences.aiWritingSendsMail { allowed.insert(.mailMessage) }
        if preferences.aiWritingSendsCalendar { allowed.insert(.calendar) }
        if preferences.aiWritingSendsUnreadMail { allowed.insert(.unreadMail) }
        if preferences.aiWritingSendsDictation { allowed.insert(.dictation) }
        return allowed
    }

    /// Sends one request and shows the answer in the panel. A request that carries context the
    /// user has not allowed is refused here, before anything is sent.
    func startAIWriting(_ request: AIWritingRequest, title: String, replacesSelection: Bool) {
        aiWritingWork?.cancel()
        pauseListening()
        let answer = AIWritingAnswer(title: title, replacesSelection: replacesSelection)
        aiWritingAnswer = answer
        aiWritingWork = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.sendAIWriting(request)
                // A reply for an answer that was dismissed or replaced is dropped.
                guard !Task.isCancelled, self.aiWritingAnswer?.id == answer.id else { return }
                self.aiWritingAnswer?.text = reply.text
                self.aiWritingAnswer?.isLoading = false
            } catch is CancellationError {
            } catch {
                guard self.aiWritingAnswer?.id == answer.id else { return }
                self.aiWritingAnswer?.isLoading = false
                self.aiWritingAnswer?.error = error.localizedDescription
            }
        }
    }

    /// The checked request, used by the launcher and its Mail view.
    func sendAIWriting(_ request: AIWritingRequest) async throws -> AIWritingReply {
        let refused = Set(request.sent).subtracting(allowedAIWritingContext)
        guard preferences.aiWritingEnabled else { throw LauncherError("AI writing is off. Turn it on in Settings › AI › Writing.") }
        guard refused.isEmpty else {
            throw LauncherError("AI writing may not read " + refused.map(\.title).sorted().joined(separator: " or ").lowercased() + ". Turn it on in Settings › AI › Writing.")
        }
        guard let key = await aiWritingKey() else { throw LauncherError("AI writing needs an OpenRouter key. Add one in Settings › AI › Writing.") }
        let effort = request.effort ?? preferences.aiWritingEffort
        let fast = preferences.aiWritingFast
        let options = AIWritingOptions(model: preferences.aiWritingModel, effort: effort, fast: fast)
        do {
            let reply = try await aiWriting.complete(request, options: options, apiKey: key)
            aiWritingLog.record(.init(date: Date(), action: request.action, sent: request.sent, effort: effort, fast: fast,
                                 inputTokens: reply.inputTokens, outputTokens: reply.outputTokens, cost: reply.cost, succeeded: true))
            return reply
        } catch is CancellationError {
            // The request may already have reached OpenRouter, so it is logged too.
            aiWritingLog.record(.init(date: Date(), action: request.action + " (cancelled)", sent: request.sent, effort: effort, fast: fast,
                                 inputTokens: 0, outputTokens: 0, cost: nil, succeeded: false))
            throw CancellationError()
        } catch {
            aiWritingLog.record(.init(date: Date(), action: request.action, sent: request.sent, effort: effort, fast: fast,
                                 inputTokens: 0, outputTokens: 0, cost: nil, succeeded: false))
            throw error
        }
    }

    /// Return on an answer: copy it, or paste it over the selection. ⇧Return always pastes.
    func finishAIWritingAnswer(paste: Bool) {
        guard let answer = aiWritingAnswer else { return }
        guard !answer.isLoading, answer.error == nil, !answer.text.isEmpty else { return }
        copy(answer.text)
        onClose?(true)
        if paste || answer.replacesSelection { clipboard.pasteSoon() }
    }

    var aiWritingPrimaryTitle: String? {
        guard let answer = aiWritingAnswer, !answer.isLoading, answer.error == nil else { return nil }
        return answer.replacesSelection ? "Replace Selection" : "Copy Answer"
    }

    func dismissAIWriting() {
        aiWritingWork?.cancel(); aiWritingWork = nil; aiWritingAnswer = nil
    }
}

extension LauncherModel {
    /// "every weekday at 8am brief me on my meetings": a row that schedules a brief.
    func taskRows(_ q: String) -> [LauncherResult] {
        // Only with AI writing on, and below whole-name matches, so "daily standup notes" stays a search.
        guard aiWritingReady, let task = ScheduledBriefQuery.parse(q) else { return [] }
        var parts = [task.schedule.summary]
        if !task.contexts.isEmpty { parts.append("reads " + task.contexts.map(\.title).joined(separator: ", ").lowercased()) }
        let refused = scheduledBriefs.refused(task)
        if !refused.isEmpty { parts.append("turn on " + refused.map(\.title).joined(separator: " and ").lowercased() + " in Settings › AI › Writing") }
        // The launcher stays open on the scheduled tasks list, with the new task in it. No system notification.
        let verb = Verb(title: "Schedule Task", after: .keepOpen) { [weak self] in
            guard let self else { return nil }
            self.scheduledBriefs.add(task)
            let next = task.nextRun(after: Date()).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "soon"
            self.updateQuery("scheduled tasks", typed: false)
            self.sourceNote = "Scheduled “\(task.name)”. First run " + next + "."
            return nil
        }
        return [LauncherResult(id: AIWritingStorageKeys.taskRowPrefix + "new", title: "Schedule a brief: " + task.prompt, detail: parts.joined(separator: " · "),
                               symbol: "calendar.badge.clock", action: .thing(Thing(verbs: [verb], twoLine: false)), score: 95)]
    }
}
