import Foundation

/// Clipboard history choices from Settings › General › Clipboard.
public struct ClipboardSettings: Codable, Equatable, Sendable {
    public static let keepDayChoices = [1, 7, 30, 90, 0]
    public static let maxItemChoices = [100, 500, 1000, 2000]
    public static let maxByteChoices: [Int64] = [250_000_000, 1_000_000_000, 5_000_000_000]
    public static let maxImageBytes = 50_000_000
    public static let maxTextBytes = 1_000_000
    /// Password managers and Apple's password apps. Their copies are never recorded.
    public static let defaultIgnoredApps = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.apple.keychainaccess",
        "com.apple.Passwords", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal", "com.dashlane.Dashlane"
    ]

    public var enabled = true
    /// Keep history after restart. Off keeps it in memory only.
    public var persist = true
    /// 0 keeps entries until they are deleted.
    public var keepDays = 30
    public var maxItems = 500
    public var maxBytes: Int64 = 1_000_000_000
    public var recordText = true
    public var recordRichText = true
    public var recordImages = true
    public var recordFiles = true
    public var ocr = true
    public var ignoredApps = ClipboardSettings.defaultIgnoredApps

    public init() {}

    public var retention: ClipRetention { ClipRetention(keepDays: keepDays, maxItems: maxItems, maxBytes: maxBytes) }

    public func ignores(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return ignoredApps.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    /// Reads stored settings, keeping defaults for keys an older version did not write.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        persist = try c.decodeIfPresent(Bool.self, forKey: .persist) ?? true
        keepDays = try c.decodeIfPresent(Int.self, forKey: .keepDays) ?? 30
        maxItems = try c.decodeIfPresent(Int.self, forKey: .maxItems) ?? 500
        maxBytes = try c.decodeIfPresent(Int64.self, forKey: .maxBytes) ?? 1_000_000_000
        recordText = try c.decodeIfPresent(Bool.self, forKey: .recordText) ?? true
        recordRichText = try c.decodeIfPresent(Bool.self, forKey: .recordRichText) ?? true
        recordImages = try c.decodeIfPresent(Bool.self, forKey: .recordImages) ?? true
        recordFiles = try c.decodeIfPresent(Bool.self, forKey: .recordFiles) ?? true
        ocr = try c.decodeIfPresent(Bool.self, forKey: .ocr) ?? true
        ignoredApps = try c.decodeIfPresent([String].self, forKey: .ignoredApps) ?? Self.defaultIgnoredApps
    }
}

/// How long entries stay. Pinned entries never expire.
public struct ClipRetention: Equatable, Sendable {
    public var keepDays: Int
    public var maxItems: Int
    public var maxBytes: Int64
    public init(keepDays: Int, maxItems: Int, maxBytes: Int64) {
        self.keepDays = keepDays; self.maxItems = maxItems; self.maxBytes = maxBytes
    }

    /// IDs to remove: unpinned entries past the age, then the oldest unpinned beyond the count,
    /// then the oldest unpinned until the total size fits.
    public func expired(_ entries: [ClipEntry], now: Date) -> Set<UUID> {
        var removed = Set<UUID>()
        let newestFirst = entries.sorted { $0.copiedAt > $1.copiedAt }
        if keepDays > 0 {
            let cutoff = now.addingTimeInterval(-Double(keepDays) * 86_400)
            for entry in newestFirst where !entry.pinned && entry.copiedAt < cutoff { removed.insert(entry.id) }
        }
        var unpinned = 0
        for entry in newestFirst where !entry.pinned && !removed.contains(entry.id) {
            unpinned += 1
            if unpinned > maxItems { removed.insert(entry.id) }
        }
        var total = newestFirst.filter { !removed.contains($0.id) }.reduce(Int64(0)) { $0 + $1.byteSize }
        for entry in newestFirst.reversed() where total > maxBytes && !entry.pinned && !removed.contains(entry.id) {
            removed.insert(entry.id)
            total -= entry.byteSize
        }
        return removed
    }
}
