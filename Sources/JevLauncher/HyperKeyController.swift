import AppKit
import Combine
import IOKit.hid
import LauncherCore

/// Turns the Hyper key on and off: the Caps Lock remap, the event tap, and the Caps Lock light.
/// Settings reads the status lines. Actions go to `perform` on the main queue.
@MainActor
final class HyperKeyController: ObservableObject {
    @Published private(set) var tapRunning = false
    @Published private(set) var remapError: String?
    @Published private(set) var lightAvailable = true

    var perform: (HyperAction, CGEventFlags) -> Void = { _, _ in }

    private let preferences: Preferences
    private let light = CapsLockLight()
    private lazy var tap = HyperKeyTap { [weak self] decision, flags in self?.handle(decision, flags: flags) }
    private var active = false
    private var watches: [AnyCancellable] = []
    private var wakeObserver: NSObjectProtocol?
    private var retry: Timer?
    private var reapply: DispatchWorkItem?

    init(preferences: Preferences) { self.preferences = preferences }

    /// Called once at launch. Undoes a remap left by a crash when the feature is off.
    func launch() {
        if !preferences.hyperKeyEnabled, HyperKeyRemap.isMarked() { try? HyperKeyRemap.remove() }
        watches = [
            preferences.$hyperKeyEnabled.removeDuplicates().sink { [weak self] _ in DispatchQueue.main.async { self?.update() } },
            preferences.$hyperBindings.sink { [weak self] bindings in self?.tap.setTable(HyperLayer.table(bindings)) }
        ]
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReapply() }
        }
        light.onKeyboardConnected = { [weak self] in self?.scheduleReapply() }
    }

    /// Starts or stops everything to match the preference.
    func update() {
        preferences.hyperKeyEnabled ? turnOn() : turnOff()
    }

    /// At quit: Caps Lock goes back to normal and the light goes off.
    func shutdown() {
        guard active || HyperKeyRemap.isMarked() else { return }
        turnOff()
    }

    /// Asks again for the event tap, after the user allows access.
    func retryTap() {
        guard active, !tapRunning else { return }
        tapRunning = tap.start()
        if tapRunning { retry?.invalidate(); retry = nil }
    }

    private func turnOn() {
        tap.setTable(HyperLayer.table(preferences.hyperBindings))
        applyRemap()
        guard !active else { return }
        active = true
        light.start()
        lightAvailable = light.isAvailable
        light.set(false)
        tapRunning = tap.start()
        if !tapRunning {
            retry = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.retryTap() } }
        }
    }

    private func turnOff() {
        retry?.invalidate(); retry = nil
        reapply?.cancel(); reapply = nil
        tap.stop()
        tapRunning = false
        light.set(false)
        light.stop()
        active = false
        guard HyperKeyRemap.isMarked() else { remapError = nil; return }
        do { try HyperKeyRemap.remove(); remapError = nil } catch { remapError = describe(error) }
    }

    private func applyRemap() {
        do { try HyperKeyRemap.apply(); remapError = nil } catch { remapError = describe(error) }
    }

    /// Mappings can reset after sleep or when a keyboard connects. Several keyboards connect at once, so wait a moment.
    private func scheduleReapply() {
        guard active else { return }
        reapply?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active else { return }
            self.applyRemap()
            self.light.set(false)
        }
        reapply = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func handle(_ decision: HyperKeyState.Decision, flags: CGEventFlags) {
        if let on = decision.light { light.set(on) }
        if let action = decision.perform { perform(action, flags) }
    }

    private func describe(_ error: Error) -> String {
        switch error {
        case HyperKeyRemap.Failure.unreadable: return "The current key mapping could not be read, so Caps Lock was not changed."
        case HyperKeyRemap.Failure.command(let text): return "hidutil failed: \(text.isEmpty ? "no output" : text)"
        default: return error.localizedDescription
        }
    }

    /// `--hyper-led-test`: the light on for two seconds, then off. Prints the result and quits.
    static func runLightTest() {
        let light = CapsLockLight()
        light.start()
        print("[Jev hyper] keyboards opened: \(light.isAvailable ? "yes" : String(format: "no (IOReturn 0x%08x)", UInt32(bitPattern: light.openResult)))")
        print("[Jev hyper] Input Monitoring: \(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted ? "allowed" : "not allowed")")
        let on = light.set(true)
        print("[Jev hyper] light on: \(on ? "succeeded" : "failed")")
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let off = light.set(false)
            print("[Jev hyper] light off: \(off ? "succeeded" : "failed")")
            fflush(stdout)
            light.stop()
            exit(on && off ? 0 : 1)
        }
        RunLoop.main.run()
    }
}
