import Foundation

/// Strict decoding: size, version, item count, field names, ops, and unique IDs.
enum ProposalDecoder {
    static let topKeys: Set<String> = ["version", "summary", "items"]
    static let itemKeys: Set<String> = ["id", "op", "path", "from", "to", "name", "tags", "reason"]

    static func decode(_ data: Data) -> Result<Proposal, ProposalError> {
        guard data.count <= Proposal.maxBytes else { return .failure(.tooLarge(data.count)) }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(.invalidJSON("Not a JSON object"))
        }
        if let extra = Set(root.keys).subtracting(topKeys).sorted().first { return .failure(.unexpectedField(extra)) }
        guard let number = root["version"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let version = Int(exactly: number.doubleValue) else { return .failure(.invalidJSON("Missing version")) }
        guard version == Proposal.formatVersion else { return .failure(.unsupportedVersion(version)) }
        guard let items = root["items"] as? [Any] else { return .failure(.invalidJSON("Missing items")) }
        guard items.count <= Proposal.maxItems else { return .failure(.tooManyItems(items.count)) }
        var seen = Set<String>()
        for raw in items {
            guard let item = raw as? [String: Any] else { return .failure(.invalidJSON("Item is not an object")) }
            if let extra = Set(item.keys).subtracting(itemKeys).sorted().first { return .failure(.unexpectedField(extra)) }
            guard let id = item["id"] as? String else { return .failure(.invalidJSON("Item without id")) }
            guard isValidID(id) else { return .failure(.invalidItemID(String(id.prefix(64)))) }
            guard seen.insert(id).inserted else { return .failure(.duplicateItemID(id)) }
            guard let op = item["op"] as? String else { return .failure(.invalidJSON("Item \(id) has no op")) }
            guard ProposalItem.Operation(rawValue: op) != nil else { return .failure(.unknownOperation(String(op.prefix(32)))) }
        }
        do {
            return .success(try JSONDecoder().decode(Proposal.self, from: data))
        } catch {
            return .failure(.invalidJSON("Wrong field types"))
        }
    }

    /// 1...64 of ASCII letters, digits, "-", "_", ".".
    static func isValidID(_ id: String) -> Bool {
        (1...64).contains(id.count) && id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)) }
    }
}
