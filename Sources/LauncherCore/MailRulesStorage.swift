import Darwin
import Foundation

/// Extra policy on top of SecureFile for the mail feature's state files. SecureFile provides
/// descriptor-relative no-follow access; this check rejects an existing state file that is not
/// owner-only instead of silently broadening its permissions or overwriting it.
enum MailRulesSecureState {
    static func validateFile(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw MailRulesStorageError.unreadable(url.path) }
        let kind = info.st_mode & S_IFMT
        guard kind != S_IFLNK else { throw MailRulesStorageError.symlink(url.path) }
        guard kind == S_IFREG else { throw MailRulesStorageError.unreadable(url.path) }
        guard info.st_uid == getuid() else { throw MailRulesStorageError.notOwned(url.path) }
        guard info.st_nlink == 1 else { throw MailRulesStorageError.unreadable("Hard-linked state files are not supported.") }
        guard (info.st_mode & 0o777) == 0o600 else { throw MailRulesStorageError.notOwnerOnly(url.path) }
    }
}

enum MailRulesStorageError: Error, LocalizedError, Equatable {
    case unreadable(String)
    case symlink(String)
    case notOwned(String)
    case notOwnerOnly(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let path): return "Mail state could not be read: \(path)"
        case .symlink(let path): return "Mail state uses an unsupported symbolic link: \(path)"
        case .notOwned(let path): return "Mail state is not owned by this user: \(path)"
        case .notOwnerOnly(let path): return "Mail state is not owner-only: \(path)"
        }
    }
}
