import Foundation

/// Why one item was refused. Shown next to the item.
struct Refusal: Error { var text: String; init(_ text: String) { self.text = text } }

/// Checks one proposal item against the disk. Paths are resolved to their real form inside a root.
struct ItemChecker {
    let roots: [ResolvedRoot]
    let protected: [[String]]

    static let maxTags = 16
    static let maxTagLength = 64

    func check(_ item: ProposalItem) -> Result<CheckedItem, Refusal> {
        do { return .success(try checkOrThrow(item)) } catch let r as Refusal { return .failure(r) } catch { return .failure(Refusal("\(error)")) }
    }

    private func checkOrThrow(_ item: ProposalItem) throws -> CheckedItem {
        switch item.op {
        case .move:
            try only(item, ["from", "to"])
            let src = try existing(try required(item.from, "from"))
            try notFolder(src.identity)
            let (dstParent, dstParentID, leaf) = try newPath(try required(item.to, "to"))
            let dst = dstParent + [leaf]
            guard src.identity.device == dstParentID.device else { throw Refusal("Moves between volumes are not supported") }
            return CheckedItem(item: item, source: SafeFS.join(src.parts), destination: SafeFS.join(dst),
                               identity: src.identity, parentIdentity: dstParentID)
        case .rename:
            try only(item, ["path", "name"])
            let src = try existing(try required(item.path, "path"))
            try notFolder(src.identity)
            let name = try required(item.name, "name")
            try validName(name)
            let parentParts = Array(src.parts.dropLast())
            guard let pst = SafeFS.lstatPath(SafeFS.join(parentParts)) else { throw Refusal("Parent folder is missing") }
            let dst = parentParts + [name]
            guard SafeFS.lstatPath(SafeFS.join(dst)) == nil else { throw Refusal("Something named \(name) already exists") }
            return CheckedItem(item: item, source: SafeFS.join(src.parts), destination: SafeFS.join(dst),
                               identity: src.identity, parentIdentity: SafeFS.identity(pst))
        case .mkdir:
            try only(item, ["path"])
            let (parent, parentID, leaf) = try newPath(try required(item.path, "path"))
            let path = SafeFS.join(parent + [leaf])
            return CheckedItem(item: item, source: path, destination: path, identity: parentID, parentIdentity: parentID)
        case .trash:
            try only(item, ["path"])
            let src = try existing(try required(item.path, "path"))
            try notFolder(src.identity)
            return CheckedItem(item: item, source: SafeFS.join(src.parts), destination: nil, identity: src.identity, parentIdentity: nil)
        case .tag:
            try only(item, ["path", "tags"])
            let src = try existing(try required(item.path, "path"))
            let tags = try required(item.tags, "tags")
            guard (1...Self.maxTags).contains(tags.count) else { throw Refusal("Use 1 to \(Self.maxTags) tags") }
            for tag in tags where tag.trimmingCharacters(in: .whitespaces).isEmpty || tag.count >= Self.maxTagLength
                || tag.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
                throw Refusal("Tags must be non-empty and under \(Self.maxTagLength) characters")
            }
            return CheckedItem(item: item, source: SafeFS.join(src.parts), destination: nil, identity: src.identity, parentIdentity: nil)
        }
    }

    /// v1 moves, renames, and trashes files only. A folder's contents are not in the manifest, so its effect cannot be shown.
    private func notFolder(_ identity: FileIdentity) throws {
        if identity.isDirectory { throw Refusal("Folders cannot be moved or trashed yet") }
    }

    // MARK: Arguments

    private func required<T>(_ value: T?, _ name: String) throws -> T {
        guard let value else { throw Refusal("Missing \(name)") }
        return value
    }

    /// Fields that belong to other ops make the item ambiguous.
    private func only(_ item: ProposalItem, _ allowed: Set<String>) throws {
        let present: [(String, Bool)] = [("path", item.path != nil), ("from", item.from != nil), ("to", item.to != nil),
                                         ("name", item.name != nil), ("tags", item.tags != nil)]
        if let extra = present.first(where: { $0.1 && !allowed.contains($0.0) }) { throw Refusal("Unexpected field \(extra.0) for \(item.op.rawValue)") }
    }

    private func validName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"),
              name.utf8.count <= 255 else { throw Refusal("Name must be one valid file name") }
    }

    // MARK: Paths

    /// Resolves a model-given path to real components inside a root. Every component under the root must be a real folder or the leaf.
    private func resolve(_ raw: String) throws -> [String] {
        guard !raw.contains("\0") else { throw Refusal("Path contains NUL") }
        guard raw.hasPrefix("/") else { throw Refusal("Path must be absolute") }
        guard let parts = SafeFS.components(raw) else { throw Refusal("Path must be standardized, without . or ..") }
        guard let root = roots.first(where: { SafeFS.isInside(parts, $0.real) || SafeFS.isInside(parts, $0.given) }) else {
            throw Refusal("Path is outside the allowed folders")
        }
        let base = SafeFS.isInside(parts, root.real) ? root.real : root.given
        let real = root.real + parts.dropFirst(base.count)
        guard real.count > root.real.count else { throw Refusal("Cannot change an allowed folder itself") }
        // "library" reaches ~/Library on a case-insensitive volume, so protected paths compare folded.
        let foldedProtected = protected.map { $0.map(SafeFS.folded) }
        for p in [parts, real] where foldedProtected.contains(where: { SafeFS.isInside(p.map(SafeFS.folded), $0) }) {
            throw Refusal("Path is in a protected folder")
        }
        // No symlink anywhere below the root, including the leaf.
        for n in (root.real.count + 1)...real.count {
            guard let st = SafeFS.lstatPath(SafeFS.join(Array(real.prefix(n)))) else {
                if n == real.count { break }
                throw Refusal("A folder in the path is missing")
            }
            if st.st_mode & S_IFMT == S_IFLNK { throw Refusal("Path goes through a symbolic link") }
        }
        return real
    }

    private func existing(_ raw: String) throws -> (parts: [String], identity: FileIdentity) {
        let parts = try resolve(raw)
        guard let st = SafeFS.lstatPath(SafeFS.join(parts)) else { throw Refusal("Item does not exist") }
        let type = st.st_mode & S_IFMT
        guard type == S_IFREG || type == S_IFDIR else { throw Refusal("Special files are not supported") }
        if type == S_IFREG, st.st_nlink > 1 { throw Refusal("Hard-linked files are not supported") }
        return (parts, SafeFS.identity(st))
    }

    /// A path that must not exist yet, with an existing parent folder inside a root (the root itself is fine).
    private func newPath(_ raw: String) throws -> (parent: [String], parentIdentity: FileIdentity, leaf: String) {
        let parts = try resolve(raw)
        let leaf = parts.last!
        try validName(leaf)
        let parent = Array(parts.dropLast())
        guard let pst = SafeFS.lstatPath(SafeFS.join(parent)), pst.st_mode & S_IFMT == S_IFDIR else {
            throw Refusal("Destination folder does not exist")
        }
        guard SafeFS.lstatPath(SafeFS.join(parts)) == nil else { throw Refusal("Destination already exists") }
        return (parent, SafeFS.identity(pst), leaf)
    }
}
