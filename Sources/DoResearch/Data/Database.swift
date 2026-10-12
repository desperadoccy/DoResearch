import Foundation
import SQLite3

enum SQLValue: Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)

    var string: String? { if case .text(let s) = self { s } else { nil } }
    var int: Int? {
        switch self {
        case .int(let v): Int(v)
        case .double(let v): Int(v)
        default: nil
        }
    }
    var double: Double? {
        switch self {
        case .double(let v): v
        case .int(let v): Double(v)
        default: nil
        }
    }
    var date: Date? {
        switch self {
        case .double(let v): Date(timeIntervalSince1970: v)
        case .int(let v): Date(timeIntervalSince1970: Double(v))
        default: nil
        }
    }
}

protocol SQLConvertible { var sqlValue: SQLValue { get } }
extension String: SQLConvertible { var sqlValue: SQLValue { .text(self) } }
extension Int: SQLConvertible { var sqlValue: SQLValue { .int(Int64(self)) } }
extension Bool: SQLConvertible { var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension Double: SQLConvertible { var sqlValue: SQLValue { .double(self) } }
extension Date: SQLConvertible { var sqlValue: SQLValue { .double(timeIntervalSince1970) } }
extension Optional: SQLConvertible where Wrapped: SQLConvertible {
    var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

typealias Row = [String: SQLValue]

struct DatabaseError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Minimal synchronous SQLite wrapper. All access happens on the main actor via `Store`.
final class Database {
    private var handle: OpaquePointer?
    /// True when this launch added `items.position`; the store then seeds it from the previous automatic order.
    private(set) var didAddPositions = false
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else {
            throw DatabaseError(message: "Cannot open database at \(url.path)")
        }
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA foreign_keys = ON")
        try migrate()
    }

    deinit { sqlite3_close(handle) }

    static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["DORESEARCH_DB"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DoResearch/doresearch.sqlite")
    }

    private var lastError: String { String(cString: sqlite3_errmsg(handle)) }

    private func prepare(_ sql: String, _ params: [SQLConvertible]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError(message: "\(lastError) — \(sql)")
        }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p.sqlValue {
            case .null: sqlite3_bind_null(stmt, idx)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
            }
        }
        return stmt
    }

    func execute(_ sql: String, _ params: [SQLConvertible] = []) throws {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw DatabaseError(message: "\(lastError) — \(sql)")
        }
    }

    func query(_ sql: String, _ params: [SQLConvertible] = []) throws -> [Row] {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var rows: [Row] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw DatabaseError(message: "\(lastError) — \(sql)") }
            var row: Row = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: row[name] = .double(sqlite3_column_double(stmt, c))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(stmt, c)))
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: Schema

    private func migrate() throws {
        let version = try query("PRAGMA user_version").first?["user_version"]?.int ?? 0
        if version < 1 {
            try transaction {
                try execute("""
                CREATE TABLE projects (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    summary TEXT NOT NULL DEFAULT '',
                    color TEXT NOT NULL DEFAULT 'blue',
                    symbol TEXT NOT NULL DEFAULT 'folder',
                    status TEXT NOT NULL DEFAULT 'active',
                    deadline REAL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                )
                """)
                try execute("""
                CREATE TABLE items (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    notes TEXT NOT NULL DEFAULT '',
                    kind TEXT NOT NULL,
                    status TEXT NOT NULL,
                    priority INTEGER NOT NULL DEFAULT 0,
                    project_id TEXT REFERENCES projects(id) ON DELETE SET NULL,
                    tags TEXT NOT NULL DEFAULT '[]',
                    due_date REAL,
                    flagged_today INTEGER NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    completed_at REAL,
                    repo TEXT NOT NULL DEFAULT '',
                    branch TEXT NOT NULL DEFAULT '',
                    link TEXT NOT NULL DEFAULT '',
                    hypothesis TEXT NOT NULL DEFAULT '',
                    setup TEXT NOT NULL DEFAULT '',
                    compute TEXT NOT NULL DEFAULT '',
                    results TEXT NOT NULL DEFAULT '',
                    conclusion TEXT NOT NULL DEFAULT '',
                    outcome TEXT NOT NULL DEFAULT 'pending',
                    metrics TEXT NOT NULL DEFAULT '[]',
                    run_started_at REAL,
                    run_ended_at REAL
                )
                """)
                try execute("""
                CREATE TABLE checklist (
                    id TEXT PRIMARY KEY,
                    item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
                    title TEXT NOT NULL,
                    done INTEGER NOT NULL DEFAULT 0,
                    position INTEGER NOT NULL DEFAULT 0
                )
                """)
                try execute("""
                CREATE TABLE logs (
                    id TEXT PRIMARY KEY,
                    item_id TEXT REFERENCES items(id) ON DELETE CASCADE,
                    project_id TEXT REFERENCES projects(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL,
                    text TEXT NOT NULL,
                    author TEXT NOT NULL DEFAULT 'user',
                    created_at REAL NOT NULL
                )
                """)
                try execute("CREATE INDEX idx_items_project ON items(project_id)")
                try execute("CREATE INDEX idx_checklist_item ON checklist(item_id)")
                try execute("CREATE INDEX idx_logs_item ON logs(item_id)")
                try execute("CREATE INDEX idx_logs_created ON logs(created_at)")
                try execute("PRAGMA user_version = 1")
            }
        }
        if version < 2 {
            try transaction {
                try execute("ALTER TABLE items ADD COLUMN position REAL NOT NULL DEFAULT 0")
                try execute("CREATE INDEX idx_items_position ON items(position)")
                try execute("PRAGMA user_version = 2")
            }
            didAddPositions = true
        }
        if version < 3 {
            try transaction {
                let columns = try query("PRAGMA table_info(projects)").compactMap { $0["name"]?.string }
                if !columns.contains("type") {
                    // Every project before this version was a research project.
                    try execute("ALTER TABLE projects ADD COLUMN type TEXT NOT NULL DEFAULT 'research'")
                }
                try execute("PRAGMA user_version = 3")
            }
        }
        if version < 4 {
            try transaction {
                let columns = try query("PRAGMA table_info(items)").compactMap { $0["name"]?.string }
                if !columns.contains("progress_current") {
                    try execute("ALTER TABLE items ADD COLUMN progress_current INTEGER NOT NULL DEFAULT 0")
                    try execute("ALTER TABLE items ADD COLUMN progress_target INTEGER")
                    try execute("ALTER TABLE items ADD COLUMN progress_unit TEXT NOT NULL DEFAULT ''")
                }
                try execute("PRAGMA user_version = 4")
            }
        }
        if version < 5 {
            try transaction {
                let columns = try query("PRAGMA table_info(items)").compactMap { $0["name"]?.string }
                if !columns.contains("revision") {
                    try execute("ALTER TABLE items ADD COLUMN revision INTEGER NOT NULL DEFAULT 1")
                    try execute("ALTER TABLE items ADD COLUMN chat_ids TEXT NOT NULL DEFAULT '[]'")
                }
                let logColumns = try query("PRAGMA table_info(logs)").compactMap { $0["name"]?.string }
                if !logColumns.contains("idempotency_key") {
                    try execute("ALTER TABLE logs ADD COLUMN source_chat_id TEXT")
                    try execute("ALTER TABLE logs ADD COLUMN idempotency_key TEXT")
                }
                try execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_logs_idempotency ON logs(idempotency_key)")
                try execute("PRAGMA user_version = 5")
            }
        }
    }
}
