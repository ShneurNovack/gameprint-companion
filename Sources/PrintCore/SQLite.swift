import Foundation
import SQLite3

/// Minimal SQLite wrapper. All access is serialized on one lock; the
/// database runs in WAL mode with FULL sync so an acknowledged state change
/// survives a crash or power loss.
final class SQLite {
    enum Value { case null, int(Int64), real(Double), text(String) }
    typealias Row = [String: Value]

    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            throw NSError(domain: "sqlite", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot open database at \(path)"])
        }
        sqlite3_busy_timeout(db, 5000)
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=FULL")
    }

    deinit { sqlite3_close(db) }

    var lastError: String { String(cString: sqlite3_errmsg(db)) }

    func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? lastError
            sqlite3_free(err)
            throw NSError(domain: "sqlite", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    @discardableResult
    func run(_ sql: String, _ args: [Value] = []) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw NSError(domain: "sqlite", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: lastError])
        }
        return Int(sqlite3_changes(db))
    }

    func query(_ sql: String, _ args: [Value] = []) throws -> [Row] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        var rows: [Row] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw NSError(domain: "sqlite", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: lastError])
            }
            var row: Row = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(stmt, i)))
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE")
        do {
            let r = try body()
            try exec("COMMIT")
            return r
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ args: [Value]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "sqlite", code: 3, userInfo: [NSLocalizedDescriptionKey: "\(lastError) in: \(sql)"])
        }
        for (i, v) in args.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case .null: sqlite3_bind_null(stmt, idx)
            case .int(let n): sqlite3_bind_int64(stmt, idx, n)
            case .real(let d): sqlite3_bind_double(stmt, idx, d)
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, SQLite.transient)
            }
        }
        return stmt
    }
}

extension SQLite.Value {
    var string: String? { if case .text(let s) = self { return s }; return nil }
    var int: Int? {
        switch self {
        case .int(let n): return Int(n)
        case .real(let d): return Int(d)
        default: return nil
        }
    }
    var double: Double? {
        switch self {
        case .real(let d): return d
        case .int(let n): return Double(n)
        default: return nil
        }
    }
}

extension Optional where Wrapped == String {
    var sql: SQLite.Value { self.map { .text($0) } ?? .null }
}
extension Optional where Wrapped == Double {
    var sql: SQLite.Value { self.map { .real($0) } ?? .null }
}
