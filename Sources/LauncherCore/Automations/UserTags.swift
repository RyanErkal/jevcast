import Darwin
import Foundation

/// Finder tags through an open descriptor: the `com.apple.metadata:_kMDItemUserTags` extended attribute,
/// a binary property list array of strings such as "Red\n6" (name, newline, color index).
enum UserTags {
    static let attribute = "com.apple.metadata:_kMDItemUserTags"
    static let maxBytes = 64 * 1024

    enum Read { case success([String]), failure(String) }

    /// The stored entries as written, with any color suffix. Empty when the attribute is missing.
    static func read(_ fd: Int32) -> Read {
        let size = fgetxattr(fd, attribute, nil, 0, 0, 0)
        if size < 0 { return errno == ENOATTR ? .success([]) : .failure(String(cString: strerror(errno))) }
        guard size <= maxBytes else { return .failure("The tag data is too large") }
        var data = Data(count: size)
        let n = data.withUnsafeMutableBytes { fgetxattr(fd, attribute, $0.baseAddress, size, 0, 0) }
        if n < 0 { return errno == ENOATTR ? .success([]) : .failure(String(cString: strerror(errno))) }
        data.count = n
        guard let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else {
            return .failure("The existing tags could not be read")
        }
        return .success(list)
    }

    /// Replaces the tags. An empty list removes the attribute. Returns an error text, or nil on success.
    static func write(_ tags: [String], to fd: Int32) -> String? {
        if tags.isEmpty {
            return fremovexattr(fd, attribute, 0) == 0 || errno == ENOATTR ? nil : String(cString: strerror(errno))
        }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: tags, format: .binary, options: 0) else {
            return "The tags could not be encoded"
        }
        let result = data.withUnsafeBytes { fsetxattr(fd, attribute, $0.baseAddress, data.count, 0, 0) }
        return result == 0 ? nil : String(cString: strerror(errno))
    }

    /// The tag name without its color suffix.
    static func name(_ entry: String) -> String {
        entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? entry
    }
}
