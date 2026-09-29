import Foundation
import SQLite3

/// A read-write SQLite connection for Jevcast's own mail store. Values are always bound, never
/// joined into SQL text. Not thread-safe: `NativeMailStore` uses it from one actor.
final class MailDatabase {
    enum Value: Equatable {
        case int(Int64), double(Double), text(String), blob(Data), null
        var int: Int64? { if case .int(let v) = self { return v }; if case .double(let v) = self { return Int64(v) }; return nil }
        var double: Double? { if case .double(let v) = self { return v }; if case .int(let v) = self { return Double(v) }; return nil }
        var text: String? { if case .text(let v) = self { return v }; return nil }
    }

    struct Failure: Error, LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    private var db: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db); db = nil
            throw Failure(text: "Could not open the mail store: \(message)")
        }
        sqlite3_busy_timeout(db, 5000)
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close(db)
    }

    /// Runs SQL with no values, such as the schema. Several statements may follow each other.
    func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let text = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw Failure(text: "Mail store: \(text)")
        }
    }

    private func prepared(_ sql: String) throws -> OpaquePointer? {
        if let cached = statements[sql] { return cached }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v3(db, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &statement, nil) == SQLITE_OK else {
            throw Failure(text: "Mail store query failed: " + String(cString: sqlite3_errmsg(db)))
        }
        // Lists of different lengths make different SQL, so the cache has a size limit.
        if statements.count >= 64, let (oldSQL, old) = statements.first { sqlite3_finalize(old); statements.removeValue(forKey: oldSQL) }
        statements[sql] = statement
        return statement
    }

    @discardableResult
    func rows(_ sql: String, _ arguments: [Value] = []) throws -> [[Value]] {
        let statement = try prepared(sql)
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, argument) in arguments.enumerated() {
            let position = Int32(index + 1)
            switch argument {
            case .int(let v): sqlite3_bind_int64(statement, position, v)
            case .double(let v): sqlite3_bind_double(statement, position, v)
            case .text(let v): sqlite3_bind_text(statement, position, v, -1, transient)
            case .blob(let v): _ = v.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32(v.count), transient) }
            case .null: sqlite3_bind_null(statement, position)
            }
        }
        var result: [[Value]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw Failure(text: "Mail store query failed: " + String(cString: sqlite3_errmsg(db))) }
            var row: [Value] = []
            for column in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row.append(.int(sqlite3_column_int64(statement, column)))
                case SQLITE_FLOAT: row.append(.double(sqlite3_column_double(statement, column)))
                case SQLITE_TEXT: row.append(.text(String(cString: sqlite3_column_text(statement, column))))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    row.append(.blob(count == 0 ? Data() : Data(bytes: sqlite3_column_blob(statement, column), count: count)))
                default: row.append(.null)
                }
            }
            result.append(row)
        }
        return result
    }

    func run(_ sql: String, _ arguments: [Value] = []) throws { try rows(sql, arguments) }

    var lastInsertID: Int64 { sqlite3_last_insert_rowid(db) }
    var changes: Int { Int(sqlite3_changes(db)) }

    /// Runs `body` in one transaction, so a batch of rows costs one disk sync.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}
