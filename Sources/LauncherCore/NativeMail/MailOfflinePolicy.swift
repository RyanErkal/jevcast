import Foundation

/// The amount of history Jevcast keeps without the user opening a folder.
public enum MailOfflineDownloadMode: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case recent
    case selectedFolders
    case allHistory

    public var title: String {
        switch self {
        case .recent: return "Recent mail"
        case .selectedFolders: return "Selected folders"
        case .allHistory: return "All history"
        }
    }
}

/// Per-account offline storage. The default is intentionally the existing bounded sync behavior.
/// `selectedFolderNames` uses server mailbox names, not SQLite row IDs, so it survives a store
/// rebuild and a UIDVALIDITY change.
public struct MailOfflinePolicy: Codable, Equatable, Sendable {
    public var mode: MailOfflineDownloadMode
    public var recentMessageLimit: Int
    public var selectedFolderNames: Set<String>
    public var downloadAttachments: Bool
    public var indexBodies: Bool
    public var paused: Bool

    public init(mode: MailOfflineDownloadMode = .recent,
                recentMessageLimit: Int = 500,
                selectedFolderNames: Set<String> = [],
                downloadAttachments: Bool = true,
                indexBodies: Bool = true,
                paused: Bool = false) {
        self.mode = mode
        self.recentMessageLimit = max(0, min(recentMessageLimit, 100_000))
        self.selectedFolderNames = Set(Set(selectedFolderNames.filter { !$0.isEmpty }).prefix(500))
        self.downloadAttachments = downloadAttachments
        self.indexBodies = indexBodies
        self.paused = paused
    }

    public static let `default` = MailOfflinePolicy()
}

public typealias MailOfflineStoragePolicy = MailOfflinePolicy
public typealias MailOfflineHistoryMode = MailOfflineDownloadMode

/// What is known locally for one mailbox. A nil percentage means the server has not supplied a
/// count, so the UI must not present a guessed percentage as complete coverage.
public struct MailOfflineMailboxCoverage: Equatable, Sendable, Identifiable {
    public let id: Int64
    public let accountID: String
    public let name: String
    public let downloadedHeaders: Int
    public let serverTotal: Int?
    public let indexedBodies: Int
    public let bodyCandidates: Int
    public let completeHistory: Bool
    public let storageBytes: Int64
    public let lastError: String?

    public var coverage: Double? {
        guard let serverTotal, serverTotal > 0 else {
            return serverTotal == 0 ? 1 : nil
        }
        return min(1, max(0, Double(downloadedHeaders) / Double(serverTotal)))
    }

    public init(id: Int64, accountID: String, name: String, downloadedHeaders: Int,
                serverTotal: Int?, indexedBodies: Int, bodyCandidates: Int,
                completeHistory: Bool, storageBytes: Int64, lastError: String? = nil) {
        self.id = id; self.accountID = accountID; self.name = name
        self.downloadedHeaders = downloadedHeaders; self.serverTotal = serverTotal
        self.indexedBodies = indexedBodies; self.bodyCandidates = bodyCandidates
        self.completeHistory = completeHistory; self.storageBytes = storageBytes
        self.lastError = lastError
    }
}

public struct MailOfflineStorageReport: Equatable, Sendable {
    public let accountID: String?
    public let bytes: Int64
    public let cachedMessageBodies: Int
    public let cachedAttachments: Int

    public init(accountID: String?, bytes: Int64, cachedMessageBodies: Int, cachedAttachments: Int) {
        self.accountID = accountID; self.bytes = bytes
        self.cachedMessageBodies = cachedMessageBodies; self.cachedAttachments = cachedAttachments
    }
}
