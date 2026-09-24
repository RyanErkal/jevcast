import Foundation
import SQLite3

/// A read-only SQLite connection for other apps' databases: browser history and Mail's index.
/// Values are bound as parameters, never joined into SQL text.
final class SQLiteReader {
    enum Value: Sendable, Equatable {
        case int(Int64), double(Double), text(String), null
        var int: Int64? { if case .int(let v) = self { return v }; if case .double(let v) = self { return Int64(v) }; return nil }
        var double: Double? { if case .double(let v) = self { return v }; if case .int(let v) = self { return Double(v) }; return nil }
        var text: String? { if case .text(let v) = self { return v }; return nil }
    }
    struct Failure: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    private var db: OpaquePointer?

    /// Opens `path` read-only. `immutable` skips locking, for a private copy nothing else writes.
    init(path: String, immutable: Bool = false) throws {
        let uri = "file:" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path) + (immutable ? "?immutable=1" : "?mode=ro")
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db); db = nil
            throw Failure(text: "Could not open the database: \(message)")
        }
        sqlite3_busy_timeout(db, 1500)
    }
    deinit { sqlite3_close(db) }

    func rows(_ sql: String, _ arguments: [Value] = []) throws -> [[Value]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Failure(text: "Query failed: " + String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, argument) in arguments.enumerated() {
            let position = Int32(index + 1)
            switch argument {
            case .int(let v): sqlite3_bind_int64(statement, position, v)
            case .double(let v): sqlite3_bind_double(statement, position, v)
            case .text(let v): sqlite3_bind_text(statement, position, v, -1, transient)
            case .null: sqlite3_bind_null(statement, position)
            }
        }
        var result: [[Value]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw Failure(text: "Query failed: " + String(cString: sqlite3_errmsg(db))) }
            var row: [Value] = []
            for column in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row.append(.int(sqlite3_column_int64(statement, column)))
                case SQLITE_FLOAT: row.append(.double(sqlite3_column_double(statement, column)))
                case SQLITE_TEXT: row.append(.text(String(cString: sqlite3_column_text(statement, column))))
                default: row.append(.null)
                }
            }
            result.append(row)
        }
        return result
    }

    /// Column names of a table, so a query can adapt to another app's schema version.
    func columns(_ table: String) -> Set<String> {
        guard table.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return [] }
        return Set(((try? rows("PRAGMA table_info(\(table))")) ?? []).compactMap { $0.count > 1 ? $0[1].text : nil })
    }

    /// `%` and `_` in typed text match literally in a LIKE pattern that uses `ESCAPE '\'`.
    static func likePattern(_ text: String) -> String {
        "%" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
    }
}
