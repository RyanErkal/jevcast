import CryptoKit
import Foundation

enum Sha256 {
    /// Lowercase hex SHA-256 of the bytes.
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
