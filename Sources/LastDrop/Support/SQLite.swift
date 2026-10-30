import Foundation
import SQLite3

/// The little of SQLite the usage index needs. Not thread-safe: one connection, one thread at a time.
final class SQLite {
    private var handle: OpaquePointer?
    /// Set when a statement fails; a transaction checks it before committing.
    var failed = false
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?(path: String, readOnly: Bool = false) {
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        sqlite3_busy_timeout(handle, 3000)
    }

    deinit { sqlite3_close(handle) }

    /// The last error means the file itself is bad, not that this attempt failed.
    var isCorrupt: Bool {
        let code = sqlite3_errcode(handle) & 0xFF
        return code == SQLITE_CORRUPT || code == SQLITE_NOTADB
    }

    @discardableResult
    func run(_ sql: String) -> Bool { sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK }

    func prepare(_ sql: String) -> Statement? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &statement, nil) == SQLITE_OK, let statement else { return nil }
        return Statement(statement, owner: self)
    }

    /// One compiled statement; compiling once is most of what makes bulk writes fast.
    final class Statement {
        private let handle: OpaquePointer
        /// Keeps the connection open for as long as a statement can run on it.
        private let owner: SQLite

        fileprivate init(_ handle: OpaquePointer, owner: SQLite) {
            self.handle = handle
            self.owner = owner
        }

        deinit { sqlite3_finalize(handle) }

        @discardableResult
        func bind(_ values: SQLiteValue...) -> Statement {
            sqlite3_reset(handle)
            for (i, value) in values.enumerated() {
                let index = Int32(i + 1)
                switch value {
                case .int(let number): sqlite3_bind_int64(handle, index, number)
                case .text(let text): sqlite3_bind_text(handle, index, text, -1, SQLite.transient)
                case .null: sqlite3_bind_null(handle, index)
                }
            }
            return self
        }

        /// Runs to the end; true if it wrote a row, for `INSERT OR IGNORE`.
        @discardableResult
        func write() -> Bool {
            let done = sqlite3_step(handle)
            if done != SQLITE_DONE { owner.failed = true }
            let changed = done == SQLITE_DONE && sqlite3_changes(owner.handle) > 0
            sqlite3_reset(handle)
            return changed
        }

        func next() -> Bool {
            let step = sqlite3_step(handle)
            if step != SQLITE_ROW, step != SQLITE_DONE { owner.failed = true }
            return step == SQLITE_ROW
        }

        func reset() { sqlite3_reset(handle) }
        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }
        func text(_ column: Int32) -> String? { sqlite3_column_text(handle, column).map { String(cString: $0) } }
    }
}

enum SQLiteValue {
    case int(Int64)
    case text(String)
    case null

    static func optional(_ value: String?) -> SQLiteValue { value.map { .text($0) } ?? .null }
}
