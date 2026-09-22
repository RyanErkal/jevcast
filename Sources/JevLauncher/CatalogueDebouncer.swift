import Foundation

/// Collapses a burst of calls into one call after a quiet period.
///
/// File-system events arrive in bursts while an app installs or updates. The
/// catalogue rescans once the folder has been quiet for ``delay``.
@MainActor
final class CatalogueDebouncer {
    let delay: Duration
    private var pending: Task<Void, Never>?

    init(delay: Duration) {
        self.delay = delay
    }

    var isPending: Bool { pending != nil }

    /// Replaces any pending call with ``action``, run after ``delay``.
    func schedule(_ action: @escaping @MainActor () -> Void) {
        pending?.cancel()
        let delay = delay
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.pending = nil
            action()
        }
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }
}
