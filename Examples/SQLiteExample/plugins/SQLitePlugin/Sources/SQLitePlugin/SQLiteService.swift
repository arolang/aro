// ============================================================
// SQLiteService.swift
// ARO Plugin - SQLite Database Service
// ============================================================
//
// This plugin demonstrates the Call action with database operations.
// It provides query (SELECT) and execute (INSERT/UPDATE/DELETE/CREATE) methods.
//
// Usage in ARO:
//   <Call> the <users> from the <sqlite: query> with { sql: "SELECT * FROM users" }.
//   <Call> the <result> from the <sqlite: execute> with { sql: "INSERT INTO users ..." }.

import Foundation
import SQLite
import AROPluginSDKExport

// MARK: - State Management

/// Global database connection (persists for application lifetime)
private var database: Connection?
private let dbQueue = DispatchQueue(label: "sqlite.plugin")

// MARK: - Plugin Registration

private let plugin = AROPlugin(name: "SQLitePlugin", version: "1.0.0", handle: "SQLite")
    .service("sqlite", methods: ["query", "execute"]) { method, input in
        // SQL is passed in "_with.sql" or top-level "sql"
        let sql = input.with.string("sql") ?? input.string("sql")

        guard let sql else {
            return .failure(.invalidInput, "Missing required argument: sql")
        }

        do {
            let result: [String: Any] = try dbQueue.sync {
                try executeMethod(method, sql: sql)
            }
            return .success(result)
        } catch {
            return .failure(.executionFailed, String(describing: error))
        }
    }
    .onInit {
        dbQueue.sync {
            if database == nil {
                database = try? Connection(.inMemory)
            }
        }
    }
    .onShutdown {
        dbQueue.sync {
            database = nil
        }
    }

private let _registration: Void = { AROPluginExport.register(plugin) }()

// MARK: - SQL Logic

/// Execute a database method (thread-safe via dbQueue)
private func executeMethod(_ method: String, sql: String) throws -> [String: Any] {
    let db = try getOrCreateConnection()

    switch method.lowercased() {
    case "query":
        return try executeQuery(db: db, sql: sql)
    case "execute":
        return try executeStatement(db: db, sql: sql)
    default:
        throw PluginError.unknownMethod(method)
    }
}

/// Get or create database connection (in-memory)
private func getOrCreateConnection() throws -> Connection {
    if let db = database {
        return db
    }
    let db = try Connection(.inMemory)
    database = db
    return db
}

/// Execute a SELECT query
private func executeQuery(db: Connection, sql: String) throws -> [String: Any] {
    let stmt = try db.prepare(sql)
    var rows: [[String: Any]] = []

    for row in stmt {
        var dict: [String: Any] = [:]
        for (index, name) in stmt.columnNames.enumerated() {
            if let value = row[index] {
                dict[name] = value
            } else {
                dict[name] = NSNull()
            }
        }
        rows.append(dict)
    }

    return ["rows": rows]
}

/// Execute an INSERT/UPDATE/DELETE/CREATE statement
private func executeStatement(db: Connection, sql: String) throws -> [String: Any] {
    try db.run(sql)
    return [
        "changes": db.changes,
        "lastInsertRowid": db.lastInsertRowid ?? 0
    ]
}

// MARK: - Error Types

enum PluginError: Error {
    case unknownMethod(String)
}
