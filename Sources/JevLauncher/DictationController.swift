import AppKit
import AVFoundation
import Combine
import LauncherCore

/// Hold Right Command to dictate into the front app. Audio stays in memory on this Mac;
/// only the text is kept, and only as long as the retention setting allows.
@MainActor
final class DictationController: ObservableObject {
    nonisolated static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(AppIdentity.name + "/Dictation", isDirectory: true)

    let store: TranscriptStore
    @Published private(set) var preparing: String?
    private let preferences: Preferences
    private let model: LauncherModel
    private let engine: DictationEngine?
    private let capture = AudioCapture()
    private let overlay = DictationOverlay()
    private lazy var hotkey = DictationHotkey { [weak self] in self?.handle($0) }
    private var session: Task<String, Error>?
    private var target: String?
    /// A transcript is being made or pasted.
    private var finishing = false
    /// Why a hold did not record. Shown on release, so a chord such as ⌘C shows nothing.
    private var refusal: String?
    private var observers: Set<AnyCancellable> = []
    /// Dictation waits while the launcher is open, because the launcher may be listening.
    var canStart: () -> Bool = { true }

    init(preferences: Preferences, model: LauncherModel, folder: URL = DictationController.folder, engine: DictationEngine? = DictationEngines.make()) {
        self.preferences = preferences; self.model = model; self.engine = engine
        store = TranscriptStore(folder: folder)
    }

    /// Follows the Settings switch and the retention choice.
    func start() {
        store.prune(preferences.dictationRetention)
        preferences.$dictationEnabled.removeDuplicates().sink { [weak self] enabled in
            Task { @MainActor in self?.setActive(enabled) }
        }.store(in: &observers)
        preferences.$dictationRetention.dropFirst().sink { [weak self] retention in self?.store.prune(retention) }.store(in: &observers)
    }

    private func setActive(_ enabled: Bool) {
        guard enabled, engine != nil else { hotkey.stop(); return }
        hotkey.start()
        prepareModel()
    }

    /// Downloads the language model ahead of the first dictation.
    func prepareModel() {
        guard let engine else { return }
        Task { @MainActor [weak self] in
            do {
                try await engine.prepare { self?.preparing = $0 }
                self?.preparing = nil
            } catch {
                self?.preparing = error.localizedDescription
            }
        }
    }

    func deleteHistory() {
        store.deleteAll()
        objectWillChange.send()
    }

    private func handle(_ output: DictationHold.Output) {
        switch output {
        case .start: begin()
        case .cancel: cancel()
        case .finish(let duration): finish(duration: duration)
        }
    }

    private func begin() {
        // One dictation at a time, so a new hold cannot restore the clipboard or pill of the last one.
        guard let engine, canStart(), !finishing else { return }
        // Without Accessibility, keys in other apps are not seen, so a chord such as ⌘C would look like a hold.
        guard NSApp.isActive || AXIsProcessTrusted() else { refusal = "Allow Accessibility in Settings › Dictation."; return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return
        default:
            refusal = "Allow the microphone in Settings › Dictation."
            return
        }
        do {
            let (audio, format) = try capture.start()
            target = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            session = Task { try await engine.transcribe(audio, format: format) }
            overlay.show(.recording)
        } catch {
            refusal = error.localizedDescription
        }
    }

    private func cancel() {
        refusal = nil
        // Nothing records, so the pill of a dictation still transcribing stays.
        guard session != nil else { return }
        capture.stop()
        session?.cancel()
        session = nil
        overlay.hide()
    }

    private func finish(duration: TimeInterval) {
        if let refusal {
            self.refusal = nil
            overlay.show(.error(refusal))
            return
        }
        guard let session, let engine else { return }
        self.session = nil
        capture.stop()
        // The launcher opened during the hold, such as with ⌘Space: a shortcut, not dictation.
        guard canStart() else { session.cancel(); overlay.hide(); return }
        finishing = true
        overlay.show(.transcribing)
        let target = self.target
        Task { @MainActor [weak self] in
            defer { self?.finishing = false }
            guard let self else { return }
            do {
                let raw = try await session.value
                // Another app came forward, as after ⌘Tab, whose Tab key the monitors do not see.
                // Checked before Luna and again before the paste, so text never goes to the wrong app.
                guard self.isFront(target) else { self.notPasted(raw); return }
                let cleaned = await self.model.cleanDictation(raw)
                guard !cleaned.text.isEmpty else { self.overlay.show(.message("No speech heard.")); return }
                guard self.isFront(target) else { self.notPasted(cleaned.text); return }
                switch TextInserter.insert(cleaned.text) {
                case .pasted: self.overlay.hide()
                case .onClipboard: self.overlay.show(.message("Copied. Allow Accessibility to paste."))
                }
                let entry = Transcript(text: cleaned.text, date: Date(), duration: duration, target: target,
                                       engine: engine.name + (cleaned.usedLuna ? "+luna" : ""))
                try? self.store.append(entry, retention: self.preferences.dictationRetention)
                self.store.prune(self.preferences.dictationRetention)
            } catch is CancellationError {
                self.overlay.hide()
            } catch {
                self.overlay.show(.error(error.localizedDescription))
            }
        }
    }

    private func isFront(_ target: String?) -> Bool {
        canStart() && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == target
    }

    /// The text is dropped: not pasted and not kept. Silence after a shortcut shows nothing.
    private func notPasted(_ text: String) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { overlay.hide() }
        else { overlay.show(.message("Not pasted: the app in front changed.")) }
    }
}
