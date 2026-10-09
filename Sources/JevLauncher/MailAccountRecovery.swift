import Foundation
import LauncherCore

/// Owns sign-in while the launcher is hidden for the provider's browser window.
@MainActor
final class MailAccountRecovery: ObservableObject {
    @Published private(set) var working: Set<String> = []
    @Published private(set) var errors: [String: String] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var attempts: [String: UUID] = [:]
    private let reconnect: (NativeMailAccount, String?) async throws -> Void

    init(reconnect: @escaping (NativeMailAccount, String?) async throws -> Void) {
        self.reconnect = reconnect
    }

    func start(_ account: NativeMailAccount, password: String? = nil) {
        guard !working.contains(account.id) else { return }
        let attempt = UUID()
        attempts[account.id] = attempt
        errors[account.id] = nil
        working.insert(account.id)
        tasks[account.id] = Task { [weak self] in
            guard let self else { return }
            do { try await reconnect(account, password) }
            catch is CancellationError {}
            catch MailOAuthError.cancelled {}
            catch {
                if attempts[account.id] == attempt { errors[account.id] = error.localizedDescription }
            }
            guard attempts[account.id] == attempt else { return }
            attempts[account.id] = nil
            tasks[account.id] = nil
            working.remove(account.id)
        }
    }

    func cancel(_ id: String) {
        attempts[id] = nil
        tasks.removeValue(forKey: id)?.cancel()
        working.remove(id)
        errors[id] = nil
    }
}
