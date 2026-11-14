// A very small SQLite wrapper over the system library.
//
// The SDK ships `libsqlite3` with FTS5 and the trigram tokenizer, and the
// Command Line Tools can link it, so no Swift package dependency is needed.

import Foundation
import SQLite3

/// SQLITE_TRANSIENT tells SQLite to copy the bound bytes immediately, which is
/// what makes binding a Swift `Data` safe.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLiteError: Error, CustomStringConvertible {
    case open(String)
    case prepare(String, sql: String)
    case step(String, sql: String)
    case bind(String, sql: String)

    public var description: String {
        switch self {
        case .open(let message): return "SQLite open failed: \(message)"
        case .prepare(let message, let sql): return "SQLite prepare failed: \(message) [\(sql)]"
        case .step(let message, let sql): return "SQLite step failed: \(message) [\(sql)]"
        case .bind(let message, let sql): return "SQLite bind failed: \(message) [\(sql)]"
        }
    }
}

public final class SQLiteDatabase {
    private var handle: OpaquePointer?

    public init(path: String) throws {
        var db: OpaquePointer?
        let result = sqlite3_open_v2(
            path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close_v2(db)
            throw SQLiteError.open(message)
        }
        handle = db
        sqlite3_busy_timeout(db, 5_000)
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
    }

    public convenience init(inMemory: Bool = true) throws {
        // A private named in-memory database keeps every connection to the same
        // store, which the shared-cache free default otherwise does not.
        try self.init(path: inMemory ? ":memory:" : "")
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    public func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        if result != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(errorPointer)
            throw SQLiteError.step(message, sql: sql)
        }
    }

    /// Runs `body` inside a transaction, rolling back if it throws.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw SQLiteError.prepare(String(cString: sqlite3_errmsg(handle)), sql: sql)
        }
        return SQLiteStatement(handle: statement, database: self, sql: sql)
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    public var userVersion: Int32 {
        get { scalarInt("PRAGMA user_version") }
        set { try? execute("PRAGMA user_version = \(newValue)") }
    }

    public var changes: Int { Int(sqlite3_changes(handle)) }

    private func scalarInt(_ sql: String) -> Int32 {
        guard let statement = try? prepare(sql) else { return 0 }
        defer { statement.finalize() }
        guard (try? statement.step()) == true else { return 0 }
        return statement.int(at: 0)
    }
}

public final class SQLiteStatement {
    private var handle: OpaquePointer?
    private let database: SQLiteDatabase
    private let sql: String

    init(handle: OpaquePointer, database: SQLiteDatabase, sql: String) {
        self.handle = handle
        self.database = database
        self.sql = sql
    }

    public func finalize() {
        if let handle { sqlite3_finalize(handle) }
        handle = nil
    }

    deinit { finalize() }

    public func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    // MARK: Binding

    public func bind(_ index: Int32, _ value: String) throws {
        guard sqlite3_bind_text(handle, index, value, -1, SQLITE_TRANSIENT) == SQLITE_OK else {
            throw SQLiteError.bind(String(cString: sqlite3_errmsg(databaseHandle)), sql: sql)
        }
    }

    public func bind(_ index: Int32, _ value: Int64) throws {
        guard sqlite3_bind_int64(handle, index, value) == SQLITE_OK else {
            throw SQLiteError.bind(String(cString: sqlite3_errmsg(databaseHandle)), sql: sql)
        }
    }

    public func bind(_ index: Int32, _ value: Int) throws { try bind(index, Int64(value)) }

    public func bind(_ index: Int32, _ value: Bool) throws { try bind(index, Int64(value ? 1 : 0)) }

    public func bind(_ index: Int32, _ value: Double) throws {
        guard sqlite3_bind_double(handle, index, value) == SQLITE_OK else {
            throw SQLiteError.bind(String(cString: sqlite3_errmsg(databaseHandle)), sql: sql)
        }
    }

    public func bind(_ index: Int32, _ value: Data) throws {
        if value.isEmpty {
            guard sqlite3_bind_zeroblob(handle, index, 0) == SQLITE_OK else {
                throw SQLiteError.bind(String(cString: sqlite3_errmsg(databaseHandle)), sql: sql)
            }
            return
        }
        let result: Int32 = value.withUnsafeBytes { raw in
            sqlite3_bind_blob(handle, index, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
        }
        guard result == SQLITE_OK else {
            throw SQLiteError.bind(String(cString: sqlite3_errmsg(databaseHandle)), sql: sql)
        }
    }

    public func bindNull(_ index: Int32) throws {
        guard sqlite3_bind_null(handle, index) == SQLITE_OK else {
            throw SQLiteError.bind(String(cString: sqlite3_errmsg(databaseHandle)), sql: sql)
        }
    }

    // MARK: Stepping

    /// Steps once. Returns true when a row is available, false when done.
    @discardableResult
    public func step() throws -> Bool {
        let result = sqlite3_step(handle)
        switch result {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default:
            throw SQLiteError.step(String(cString: sqlite3_errmsg(databaseHandle)), sql: sql)
        }
    }

    /// Runs a statement to completion.
    public func run() throws {
        while try step() {}
    }

    // MARK: Columns

    public func int(at index: Int32) -> Int32 { sqlite3_column_int(handle, index) }

    public func int64(at index: Int32) -> Int64 { sqlite3_column_int64(handle, index) }

    public func double(at index: Int32) -> Double { sqlite3_column_double(handle, index) }

    public func bool(at index: Int32) -> Bool { sqlite3_column_int(handle, index) != 0 }

    public func string(at index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(handle, index) else { return nil }
        return String(cString: pointer)
    }

    public func data(at index: Int32) -> Data? {
        guard sqlite3_column_type(handle, index) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(handle, index))
        guard count > 0 else { return Data() }
        guard let pointer = sqlite3_column_blob(handle, index) else { return Data() }
        return Data(bytes: pointer, count: count)
    }

    private var databaseHandle: OpaquePointer {
        // `sqlite3_db_handle` gives back the owning connection for error text.
        sqlite3_db_handle(handle)
    }
}
