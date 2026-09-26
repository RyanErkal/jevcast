import Foundation

/// What an agent in `proposal` mode returns: file changes for the user to approve.
/// The agent only describes changes. Jevcast code checks and applies them.
public struct Proposal: Codable, Equatable, Sendable {
    public static let formatVersion = 1
    public static let maxItems = 500
    public static let maxBytes = 512 * 1024
    public var version: Int
    public var summary: String
    public var items: [ProposalItem]
    public init(version: Int = Proposal.formatVersion, summary: String, items: [ProposalItem]) {
        self.version = version; self.summary = summary; self.items = items
    }
}

public struct ProposalItem: Codable, Equatable, Identifiable, Sendable {
    public enum Operation: String, Codable, CaseIterable, Sendable {
        case move, rename, mkdir, trash, tag
        public var title: String {
            switch self { case .move: return "Move"; case .rename: return "Rename"; case .mkdir: return "New folder"; case .trash: return "Move to Trash"; case .tag: return "Tag" }
        }
    }
    public var id: String
    public var op: Operation
    /// move: from, to (full destination path). rename: path, name. mkdir: path. trash: path. tag: path, tags.
    public var path: String?
    public var from: String?
    public var to: String?
    public var name: String?
    public var tags: [String]?
    public var reason: String
    public init(id: String, op: Operation, path: String? = nil, from: String? = nil, to: String? = nil,
                name: String? = nil, tags: [String]? = nil, reason: String) {
        self.id = id; self.op = op; self.path = path; self.from = from; self.to = to; self.name = name; self.tags = tags; self.reason = reason
    }
}

/// What code saw on disk when the proposal arrived. Approval binds to this, never to model-supplied facts.
public struct FileIdentity: Codable, Equatable, Sendable {
    public var device: UInt64
    public var inode: UInt64
    public var isDirectory: Bool
    public var size: UInt64
    public var modified: Date
    public var linkCount: UInt64
    public init(device: UInt64, inode: UInt64, isDirectory: Bool, size: UInt64, modified: Date, linkCount: UInt64) {
        self.device = device; self.inode = inode; self.isDirectory = isDirectory; self.size = size; self.modified = modified; self.linkCount = linkCount
    }
}

/// One checked item, ready to show and apply.
public struct CheckedItem: Codable, Equatable, Identifiable, Sendable {
    public var id: String { item.id }
    public var item: ProposalItem
    /// Standardized absolute source (move, rename, trash, tag) or new folder path (mkdir).
    public var source: String
    /// Standardized absolute destination for move, rename, mkdir.
    public var destination: String?
    /// Identity of the source, or of the destination's parent for mkdir.
    public var identity: FileIdentity
    /// Identity of the destination's parent folder.
    public var parentIdentity: FileIdentity?
    public init(item: ProposalItem, source: String, destination: String?, identity: FileIdentity, parentIdentity: FileIdentity?) {
        self.item = item; self.source = source; self.destination = destination; self.identity = identity; self.parentIdentity = parentIdentity
    }
}

/// `proposal.json` in the run folder: the raw proposal, the checked manifest, and any rejected items.
public struct ProposalManifest: Codable, Equatable, Sendable {
    public var proposal: Proposal
    public var checked: [CheckedItem]
    /// Item ID → reason it was refused. Refused items are shown but cannot be approved.
    public var refused: [String: String]
    public var roots: [String]
    /// SHA-256 hex of the encoded proposal. Approval must quote it.
    public var digest: String
    public var created: Date
    public init(proposal: Proposal, checked: [CheckedItem], refused: [String: String], roots: [String], digest: String, created: Date = Date()) {
        self.proposal = proposal; self.checked = checked; self.refused = refused; self.roots = roots; self.digest = digest; self.created = created
    }
}

/// `journal.json`: intent before and outcome after each applied operation, for recovery and undo.
public struct ApplyJournal: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public enum Status: String, Codable, Sendable { case intended, done, failed, skipped, undone, undoBlocked }
        public var itemID: String
        public var op: ProposalItem.Operation
        public var source: String
        public var destination: String?
        /// Where the Trash put the item.
        public var trashURL: String?
        /// Tags before a tag operation.
        public var previousTags: [String]?
        /// Inode of the folder a mkdir created, so undo removes only that folder.
        public var createdInode: UInt64?
        public var status: Status
        public var message: String?
        public init(itemID: String, op: ProposalItem.Operation, source: String, destination: String?, status: Status) {
            self.itemID = itemID; self.op = op; self.source = source; self.destination = destination; self.status = status
        }
    }
    public var digest: String
    public var approvedItems: [String]
    public var entries: [Entry]
    public var started: Date
    public var finished: Date?
    public init(digest: String, approvedItems: [String], entries: [Entry] = [], started: Date = Date()) {
        self.digest = digest; self.approvedItems = approvedItems; self.entries = entries; self.started = started
    }
}
