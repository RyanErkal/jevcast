import Foundation

/// The hold-to-dictate state machine for Right Command. Pure, so tests drive it with times.
/// Recording starts on press so no speech is lost; a short tap or a chord such as ⌘C cancels it.
public struct DictationHold: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        /// Right Command went down (`true`) or up (`false`).
        case rightCommand(down: Bool, at: TimeInterval)
        /// Any other key or modifier changed while the machine runs.
        case otherKey
    }
    public enum Output: Equatable, Sendable {
        case start
        /// The hold was long enough: stop recording and transcribe.
        case finish(duration: TimeInterval)
        /// Discard what was recorded: a short tap or a chord.
        case cancel
    }
    enum State: Equatable, Sendable { case idle, holding(since: TimeInterval), cancelled }

    public static let rightCommandKeyCode: UInt16 = 54
    public static let minimumHold: TimeInterval = 0.2
    private(set) var state: State = .idle
    public init() {}

    public var isHolding: Bool { if case .holding = state { return true }; return false }

    public mutating func handle(_ event: Event) -> Output? {
        switch (state, event) {
        // A press while cancelled means the release after a chord was missed: start afresh.
        case (.idle, .rightCommand(down: true, let time)), (.cancelled, .rightCommand(down: true, let time)):
            state = .holding(since: time); return .start
        case (.holding(let since), .rightCommand(down: false, let time)):
            state = .idle
            return time - since < Self.minimumHold ? .cancel : .finish(duration: time - since)
        case (.holding, .otherKey):
            // Wait for the release, so the rest of the chord does not start a new recording.
            state = .cancelled; return .cancel
        case (.cancelled, .rightCommand(down: false, _)):
            state = .idle; return nil
        default:
            return nil
        }
    }
}
