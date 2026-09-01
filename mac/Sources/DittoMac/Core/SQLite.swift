import Foundation
import SQLite3

/// Thrown for any sqlite failure; mirrors `CppSQLite3Exception`.
struct SQLiteError: Error, CustomStringConvertible {
    let code: Int32
    let message: String
    let sql: String?

    var description: String {
        if let sql = sql {
            return "sqlite error \(code): \(message) [\(sql)]"
        }
        return "sqlite error \(code): \(message)"
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A prepared statement. Bind with 1-based indexes exactly like
/// `CppSQLite3Statement::bind`.
final class SQLiteStatement {

    fileprivate let handle: OpaquePointer
    private let sql: String

    fileprivate init(handle: OpaquePointer, sql: String) {
        self.handle = handle
        self.sql = sql
    }

    deinit {
        sqlite3_finalize(handle)
    }

    @discardableResult
    func bind(_ index: Int32, _ value: Int) -> SQLiteStatement {
        sqlite3_bind_int64(handle, index, Int64(value))
        return self
    }

    @discardableResult
    func bind(_ index: Int32, _ value: Int64) -> SQLiteStatement {
        sqlite3_bind_int64(handle, index, value)
        return self
    }

    @discardableResult
    func bind(_ index: Int32, _ value: Double) -> SQLiteStatement {
        sqlite3_bind_double(handle, index, value)
        return self
    }

    @discardableResult
    func bind(_ index: Int32, _ value: String) -> SQLiteStatement {
        sqlite3_bind_text(handle, index, value, -1, SQLITE_TRANSIENT)
        return self
    }

    @discardableResult
    func bind(_ index: Int32, _ value: Data) -> SQLiteStatement {
        if value.isEmpty {
            sqlite3_bind_zeroblob(handle, index, 0)
            return self
        }
        value.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            _ = sqlite3_bind_blob(handle, index, raw.baseAddress,
                                  Int32(value.count), SQLITE_TRANSIENT)
        }
        return self
    }

    @discardableResult
    func bindNull(_ index: Int32) -> SQLiteStatement {
        sqlite3_bind_null(handle, index)
        return self
    }

    func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    /// Run a statement that returns no rows.
    func execute(on db: SQLiteDatabase) throws {
        let rc = sqlite3_step(handle)
        if rc != SQLITE_DONE && rc != SQLITE_ROW {
            throw db.error(sql: sql)
        }
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    /// Step once and hand the caller a cursor over the current row.
    func step() -> Bool {
        return sqlite3_step(handle) == SQLITE_ROW
    }

    var row: SQLiteRow {
        return SQLiteRow(handle: handle)
    }
}

/// One row of a result set; column accessors mirror `CppSQLite3Query`.
struct SQLiteRow {

    fileprivate let handle: OpaquePointer

    private func index(of name: String) -> Int32? {
        let count = sqlite3_column_count(handle)
        var i: Int32 = 0
        while i < count {
            if let raw = sqlite3_column_name(handle, i),
               String(cString: raw).caseInsensitiveCompare(name) == .orderedSame {
                return i
            }
            i += 1
        }
        return nil
    }

    func int(_ name: String, _ fallback: Int = 0) -> Int {
        guard let i = index(of: name) else { return fallback }
        if sqlite3_column_type(handle, i) == SQLITE_NULL { return fallback }
        return Int(sqlite3_column_int64(handle, i))
    }

    func double(_ name: String, _ fallback: Double = 0) -> Double {
        guard let i = index(of: name) else { return fallback }
        if sqlite3_column_type(handle, i) == SQLITE_NULL { return fallback }
        return sqlite3_column_double(handle, i)
    }

    func string(_ name: String, _ fallback: String = "") -> String {
        guard let i = index(of: name) else { return fallback }
        guard let raw = sqlite3_column_text(handle, i) else { return fallback }
        return String(cString: raw)
    }

    func data(_ name: String) -> Data {
        guard let i = index(of: name) else { return Data() }
        let length = sqlite3_column_bytes(handle, i)
        guard length > 0, let raw = sqlite3_column_blob(handle, i) else { return Data() }
        return Data(bytes: raw, count: Int(length))
    }

    func isNull(_ name: String) -> Bool {
        guard let i = index(of: name) else { return true }
        return sqlite3_column_type(handle, i) == SQLITE_NULL
    }

    func intAt(_ column: Int32) -> Int {
        return Int(sqlite3_column_int64(handle, column))
    }

    func stringAt(_ column: Int32) -> String {
        guard let raw = sqlite3_column_text(handle, column) else { return "" }
        return String(cString: raw)
    }
}

/// Port of `CppSQLite3DB` - the thin sqlite wrapper Ditto uses throughout.
///
/// Every call is funnelled through one serial queue. Windows Ditto guards the
/// same handle with a critical section and opens extra connections on worker
/// threads; a serial queue gives the same guarantee with less ceremony.
final class SQLiteDatabase {

    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "io.ditto.sqlite")
    let url: URL

    init(url: URL) throws {
        self.url = url
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let opened = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            sqlite3_close_v2(handle)
            throw SQLiteError(code: rc, message: message, sql: url.path)
        }
        self.handle = opened
        sqlite3_busy_timeout(opened, 5000)
    }

    deinit {
        if let handle = handle {
            sqlite3_close_v2(handle)
        }
    }

    /// The raw connection, for the few places that need the C API directly
    /// (registering the search functions). Only touch it inside `sync`.
    var rawHandle: OpaquePointer? {
        return handle
    }

    func close() {
        queue.sync {
            if let handle = handle {
                sqlite3_close_v2(handle)
            }
            handle = nil
        }
    }

    fileprivate func error(sql: String?) -> SQLiteError {
        guard let handle = handle else {
            return SQLiteError(code: SQLITE_MISUSE, message: "database is closed", sql: sql)
        }
        return SQLiteError(code: sqlite3_errcode(handle),
                           message: String(cString: sqlite3_errmsg(handle)),
                           sql: sql)
    }

    /// Run work against the connection on the serial queue.
    func sync<T>(_ body: () throws -> T) rethrows -> T {
        return try queue.sync(execute: body)
    }

    // MARK: - Statements

    private func prepareLocked(_ sql: String) throws -> SQLiteStatement {
        guard let handle = handle else { throw error(sql: sql) }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let prepared = stmt else {
            sqlite3_finalize(stmt)
            throw error(sql: sql)
        }
        return SQLiteStatement(handle: prepared, sql: sql)
    }

    /// `execDML` - run a statement, return the number of affected rows.
    @discardableResult
    func execute(_ sql: String, _ bindings: [SQLiteBindable] = []) throws -> Int {
        return try queue.sync {
            try executeLocked(sql, bindings)
        }
    }

    private func executeLocked(_ sql: String, _ bindings: [SQLiteBindable]) throws -> Int {
        let stmt = try prepareLocked(sql)
        for (offset, value) in bindings.enumerated() {
            value.bind(to: stmt, at: Int32(offset + 1))
        }
        let rc = sqlite3_step(stmt.handle)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw error(sql: sql) }
        guard let handle = handle else { throw error(sql: sql) }
        return Int(sqlite3_changes(handle))
    }

    /// Run several statements in order, e.g. the schema script.
    func executeScript(_ statements: [String]) throws {
        try queue.sync {
            for sql in statements {
                _ = try executeLocked(sql, [])
            }
        }
    }

    /// `execQuery` - walk every row of a result set.
    ///
    /// The closure runs on the serial queue, so it must not call back into the
    /// database. Callers that need to do more work per row collect the rows
    /// first and act on them afterwards.
    func query(_ sql: String,
               _ bindings: [SQLiteBindable] = [],
               _ body: (SQLiteRow) throws -> Void) throws {
        try queue.sync {
            let stmt = try prepareLocked(sql)
            for (offset, value) in bindings.enumerated() {
                value.bind(to: stmt, at: Int32(offset + 1))
            }
            while sqlite3_step(stmt.handle) == SQLITE_ROW {
                try body(stmt.row)
            }
        }
    }

    /// Walk rows but stop early when `body` returns false.
    func queryUntil(_ sql: String,
                    _ bindings: [SQLiteBindable] = [],
                    _ body: (SQLiteRow) throws -> Bool) throws {
        try queue.sync {
            let stmt = try prepareLocked(sql)
            for (offset, value) in bindings.enumerated() {
                value.bind(to: stmt, at: Int32(offset + 1))
            }
            while sqlite3_step(stmt.handle) == SQLITE_ROW {
                if try body(stmt.row) == false { break }
            }
        }
    }

    /// `execScalar` - first column of the first row as an Int.
    func scalarInt(_ sql: String, _ bindings: [SQLiteBindable] = []) throws -> Int? {
        return try queue.sync {
            let stmt = try prepareLocked(sql)
            for (offset, value) in bindings.enumerated() {
                value.bind(to: stmt, at: Int32(offset + 1))
            }
            guard sqlite3_step(stmt.handle) == SQLITE_ROW else { return nil }
            if sqlite3_column_type(stmt.handle, 0) == SQLITE_NULL { return nil }
            return Int(sqlite3_column_int64(stmt.handle, 0))
        }
    }

    func scalarDouble(_ sql: String, _ bindings: [SQLiteBindable] = []) throws -> Double? {
        return try queue.sync {
            let stmt = try prepareLocked(sql)
            for (offset, value) in bindings.enumerated() {
                value.bind(to: stmt, at: Int32(offset + 1))
            }
            guard sqlite3_step(stmt.handle) == SQLITE_ROW else { return nil }
            if sqlite3_column_type(stmt.handle, 0) == SQLITE_NULL { return nil }
            return sqlite3_column_double(stmt.handle, 0)
        }
    }

    func scalarString(_ sql: String, _ bindings: [SQLiteBindable] = []) throws -> String? {
        return try queue.sync {
            let stmt = try prepareLocked(sql)
            for (offset, value) in bindings.enumerated() {
                value.bind(to: stmt, at: Int32(offset + 1))
            }
            guard sqlite3_step(stmt.handle) == SQLITE_ROW else { return nil }
            guard let raw = sqlite3_column_text(stmt.handle, 0) else { return nil }
            return String(cString: raw)
        }
    }

    var lastInsertRowID: Int {
        return queue.sync {
            guard let handle = handle else { return 0 }
            return Int(sqlite3_last_insert_rowid(handle))
        }
    }

    // MARK: - Transactions

    func transaction<T>(_ body: () throws -> T) throws -> T {
        _ = try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let result = try body()
            _ = try execute("COMMIT TRANSACTION")
            return result
        } catch {
            _ = try? execute("ROLLBACK TRANSACTION")
            throw error
        }
    }

    // MARK: - Introspection

    func tableExists(_ name: String) -> Bool {
        let sql = "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?"
        guard let count = try? scalarInt(sql, [name]) else { return false }
        return (count ?? 0) > 0
    }

    func columnExists(table: String, column: String) -> Bool {
        var found = false
        try? query("PRAGMA table_info(\(table))") { row in
            if row.string("name").caseInsensitiveCompare(column) == .orderedSame {
                found = true
            }
        }
        return found
    }

    var userVersion: Int {
        get { ((try? scalarInt("PRAGMA user_version")) ?? 0) ?? 0 }
        set { _ = try? execute("PRAGMA user_version = \(newValue)") }
    }
}

/// Anything that can be bound to a statement parameter.
protocol SQLiteBindable {
    func bind(to statement: SQLiteStatement, at index: Int32)
}

extension Int: SQLiteBindable {
    func bind(to statement: SQLiteStatement, at index: Int32) { statement.bind(index, self) }
}

extension Int64: SQLiteBindable {
    func bind(to statement: SQLiteStatement, at index: Int32) { statement.bind(index, self) }
}

extension Double: SQLiteBindable {
    func bind(to statement: SQLiteStatement, at index: Int32) { statement.bind(index, self) }
}

extension String: SQLiteBindable {
    func bind(to statement: SQLiteStatement, at index: Int32) { statement.bind(index, self) }
}

extension Data: SQLiteBindable {
    func bind(to statement: SQLiteStatement, at index: Int32) { statement.bind(index, self) }
}

extension Bool: SQLiteBindable {
    func bind(to statement: SQLiteStatement, at index: Int32) {
        statement.bind(index, self ? 1 : 0)
    }
}

/// Explicit NULL binding.
struct SQLiteNull: SQLiteBindable {
    func bind(to statement: SQLiteStatement, at index: Int32) { statement.bindNull(index) }
}
