import Foundation
import SQLite3

public actor Catalog {
    private let db: SQLite

    public init(databaseURL: URL) throws {
        if databaseURL.path != ":memory:" {
            let directory = databaseURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        db = try SQLite(path: databaseURL.path)
        try db.exec(
            """
            CREATE TABLE IF NOT EXISTS accounts (
              id TEXT PRIMARY KEY,
              kind TEXT NOT NULL,
              display_name TEXT NOT NULL,
              config_json TEXT NOT NULL,
              status TEXT NOT NULL,
              last_error TEXT,
              last_sync REAL,
              cursor_json TEXT,
              item_count INTEGER NOT NULL DEFAULT 0,
              replace_generation INTEGER
            );
            CREATE TABLE IF NOT EXISTS items (
              account_id TEXT NOT NULL,
              remote_id TEXT NOT NULL,
              parent_remote_id TEXT,
              name TEXT NOT NULL,
              relative_path TEXT NOT NULL,
              mirror_path TEXT NOT NULL,
              size INTEGER NOT NULL,
              mtime INTEGER NOT NULL,
              kind TEXT NOT NULL,
              etag TEXT,
              web_url TEXT,
              generation INTEGER NOT NULL DEFAULT 0,
              PRIMARY KEY (account_id, remote_id)
            );
            CREATE INDEX IF NOT EXISTS items_mirror ON items(account_id, mirror_path);
            """
        )
    }

    public func accounts() throws -> [Account] {
        try db.query("SELECT * FROM accounts ORDER BY display_name") { row in
            try self.account(row)
        }
    }

    public func account(_ id: UUID) throws -> Account? {
        try db.query("SELECT * FROM accounts WHERE id = ?", bindings: [.text(id.uuidString)]) { row in
            try self.account(row)
        }.first
    }

    public func upsertAccount(_ account: Account) throws {
        let config = try JSONEncoder.drive.encode(account.config)
        let cursor = try account.cursor.map { try JSONEncoder.drive.encode($0) }
        try db.run(
            """
            INSERT INTO accounts (id, kind, display_name, config_json, status, last_error, last_sync, cursor_json, item_count, replace_generation)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              kind = excluded.kind,
              display_name = excluded.display_name,
              config_json = excluded.config_json,
              status = excluded.status,
              last_error = excluded.last_error,
              last_sync = excluded.last_sync,
              cursor_json = excluded.cursor_json,
              item_count = excluded.item_count,
              replace_generation = excluded.replace_generation
            """,
            bindings: [
                .text(account.id.uuidString),
                .text(account.kind.rawValue),
                .text(account.displayName),
                .text(String(decoding: config, as: UTF8.self)),
                .text(account.status.rawValue),
                account.lastError.map(SQLValue.text) ?? .null,
                account.lastSync.map { .double($0.timeIntervalSince1970) } ?? .null,
                cursor.map { .text(String(decoding: $0, as: UTF8.self)) } ?? .null,
                .int(Int64(account.itemCount)),
                account.replaceGeneration.map(SQLValue.int) ?? .null,
            ]
        )
    }

    public func deleteAccount(_ id: UUID) throws {
        try db.run("DELETE FROM items WHERE account_id = ?", bindings: [.text(id.uuidString)])
        try db.run("DELETE FROM accounts WHERE id = ?", bindings: [.text(id.uuidString)])
    }

    public func items(account id: UUID) throws -> [RemoteItem] {
        try db.query(
            "SELECT * FROM items WHERE account_id = ? ORDER BY relative_path",
            bindings: [.text(id.uuidString)]
        ) { row in
            self.item(row)
        }
    }

    public func item(account id: UUID, mirrorPath: String) throws -> RemoteItem? {
        try db.query(
            "SELECT * FROM items WHERE account_id = ? AND mirror_path = ? LIMIT 1",
            bindings: [.text(id.uuidString), .text(mirrorPath)]
        ) { row in
            self.item(row)
        }.first
    }

    public func replaceItems(account id: UUID, _ items: [RemoteItem], generation: Int64) throws {
        try db.transaction {
            try db.run("DELETE FROM items WHERE account_id = ?", bindings: [.text(id.uuidString)])
            for item in items {
                try insert(item, account: id, generation: generation)
            }
            try db.run(
                "UPDATE accounts SET item_count = ? WHERE id = ?",
                bindings: [.int(Int64(items.count)), .text(id.uuidString)]
            )
        }
    }

    public func upsertItems(account id: UUID, _ items: [RemoteItem], generation: Int64) throws {
        try db.transaction {
            for item in items {
                try insert(item, account: id, generation: generation)
            }
            try refreshCount(id)
        }
    }

    public func deleteItems(account id: UUID, remoteIDs: [String], relativePaths: [String]) throws {
        try db.transaction {
            for remoteID in remoteIDs {
                try db.run(
                    "DELETE FROM items WHERE account_id = ? AND remote_id = ?",
                    bindings: [.text(id.uuidString), .text(remoteID)]
                )
            }
            for path in relativePaths where !path.isEmpty {
                try db.run(
                    "DELETE FROM items WHERE account_id = ? AND relative_path = ?",
                    bindings: [.text(id.uuidString), .text(path)]
                )
            }
            try refreshCount(id)
        }
    }

    public func deleteStale(account id: UUID, keeping generation: Int64) throws {
        try db.transaction {
            try db.run(
                "DELETE FROM items WHERE account_id = ? AND generation != ?",
                bindings: [.text(id.uuidString), .int(generation)]
            )
            try refreshCount(id)
        }
    }

    public func setSyncState(
        _ id: UUID,
        status: SyncStatus,
        error: String?,
        lastSync: Date?,
        cursor: SyncCursor?,
        replaceGeneration: Int64?,
        itemCount: Int? = nil
    ) throws {
        let cursorJSON = try cursor.map { String(decoding: try JSONEncoder.drive.encode($0), as: UTF8.self) }
        var sql = "UPDATE accounts SET status = ?, last_error = ?, cursor_json = ?, replace_generation = ?"
        var bindings: [SQLValue] = [
            .text(status.rawValue),
            error.map(SQLValue.text) ?? .null,
            cursorJSON.map(SQLValue.text) ?? .null,
            replaceGeneration.map(SQLValue.int) ?? .null,
        ]
        if let lastSync {
            sql += ", last_sync = ?"
            bindings.append(.double(lastSync.timeIntervalSince1970))
        }
        if let itemCount {
            sql += ", item_count = ?"
            bindings.append(.int(Int64(itemCount)))
        }
        sql += " WHERE id = ?"
        bindings.append(.text(id.uuidString))
        try db.run(sql, bindings: bindings)
    }

    private func refreshCount(_ id: UUID) throws {
        let count = try db.query("SELECT COUNT(*) FROM items WHERE account_id = ?", bindings: [.text(id.uuidString)]) { row in
            row.int(0)
        }.first ?? 0
        try db.run(
            "UPDATE accounts SET item_count = ? WHERE id = ?",
            bindings: [.int(count), .text(id.uuidString)]
        )
    }

    private func insert(_ item: RemoteItem, account id: UUID, generation: Int64) throws {
        try db.run(
            """
            INSERT INTO items (account_id, remote_id, parent_remote_id, name, relative_path, mirror_path, size, mtime, kind, etag, web_url, generation)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(account_id, remote_id) DO UPDATE SET
              parent_remote_id = excluded.parent_remote_id,
              name = excluded.name,
              relative_path = excluded.relative_path,
              mirror_path = excluded.mirror_path,
              size = excluded.size,
              mtime = excluded.mtime,
              kind = excluded.kind,
              etag = excluded.etag,
              web_url = excluded.web_url,
              generation = excluded.generation
            """,
            bindings: [
                .text(id.uuidString),
                .text(item.remoteID),
                item.parentRemoteID.map(SQLValue.text) ?? .null,
                .text(item.name),
                .text(item.relativePath),
                .text(item.mirrorPath),
                .int(Int64(bitPattern: item.size)),
                .int(Int64(item.modified.timeIntervalSince1970)),
                .text(item.kind.rawValue),
                item.etag.map(SQLValue.text) ?? .null,
                item.webURL.map { SQLValue.text($0.absoluteString) } ?? .null,
                .int(generation),
            ]
        )
    }

    private nonisolated func account(_ row: SQLRow) throws -> Account {
        let config = try JSONDecoder.drive.decode(AccountConfig.self, from: Data(row.text("config_json").utf8))
        let cursor = try row.textOrNil("cursor_json").map { try JSONDecoder.drive.decode(SyncCursor.self, from: Data($0.utf8)) }
        return Account(
            id: UUID(uuidString: row.text("id")) ?? UUID(),
            kind: ProviderKind(rawValue: row.text("kind")) ?? .googleDrive,
            displayName: row.text("display_name"),
            config: config,
            status: SyncStatus(rawValue: row.text("status")) ?? .idle,
            lastError: row.textOrNil("last_error"),
            lastSync: row.doubleOrNil("last_sync").map(Date.init(timeIntervalSince1970:)),
            cursor: cursor,
            itemCount: Int(row.intByName("item_count")),
            replaceGeneration: row.intOrNil("replace_generation")
        )
    }

    private nonisolated func item(_ row: SQLRow) -> RemoteItem {
        RemoteItem(
            remoteID: row.text("remote_id"),
            parentRemoteID: row.textOrNil("parent_remote_id"),
            name: row.text("name"),
            relativePath: row.text("relative_path"),
            mirrorPath: row.text("mirror_path"),
            size: UInt64(bitPattern: row.intByName("size")),
            modified: Date(timeIntervalSince1970: TimeInterval(row.intByName("mtime"))),
            kind: ItemKind(rawValue: row.text("kind")) ?? .file,
            etag: row.textOrNil("etag"),
            webURL: row.textOrNil("web_url").flatMap(URL.init(string:))
        )
    }
}

enum SQLValue {
    case text(String)
    case int(Int64)
    case double(Double)
    case null
}

struct SQLRow {
    let names: [String: Int32]
    let statement: OpaquePointer

    func text(_ name: String) -> String {
        textOrNil(name) ?? ""
    }

    func textOrNil(_ name: String) -> String? {
        guard let index = names[name], sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    func int(_ index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    func intByName(_ name: String) -> Int64 {
        guard let index = names[name] else { return 0 }
        return sqlite3_column_int64(statement, index)
    }

    func intOrNil(_ name: String) -> Int64? {
        guard let index = names[name], sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, index)
    }

    func doubleOrNil(_ name: String) -> Double? {
        guard let index = names[name], sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, index)
    }
}

final class SQLite: @unchecked Sendable {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
            throw ProviderError.transport("Could not open the local catalog.")
        }
        try exec("PRAGMA foreign_keys = ON")
    }

    deinit {
        sqlite3_close(db)
    }

    func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "sqlite"
            sqlite3_free(error)
            throw ProviderError.transport(message)
        }
    }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func run(_ sql: String, bindings: [SQLValue] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(statement, bindings)
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else {
            throw ProviderError.transport(String(cString: sqlite3_errmsg(db)))
        }
    }

    func query<T>(_ sql: String, bindings: [SQLValue] = [], map: (SQLRow) throws -> T) throws -> [T] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(statement, bindings)
        var names: [String: Int32] = [:]
        let columns = sqlite3_column_count(statement)
        for index in 0..<columns {
            if let name = sqlite3_column_name(statement, index) {
                names[String(cString: name)] = index
            }
        }
        var rows: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(try map(SQLRow(names: names, statement: statement!)))
        }
        return rows
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            throw ProviderError.transport(String(cString: sqlite3_errmsg(db)))
        }
        return statement
    }

    private func bind(_ statement: OpaquePointer?, _ bindings: [SQLValue]) throws {
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .text(let text):
                status = text.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
            case .int(let number):
                status = sqlite3_bind_int64(statement, index, number)
            case .double(let number):
                status = sqlite3_bind_double(statement, index, number)
            case .null:
                status = sqlite3_bind_null(statement, index)
            }
            if status != SQLITE_OK {
                throw ProviderError.transport("Could not bind a catalog value.")
            }
        }
    }
}
