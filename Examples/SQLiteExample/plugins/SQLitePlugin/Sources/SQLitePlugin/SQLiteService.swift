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
import AROPluginSDK

// MARK: - State Management

/// Global database connection (persists for application lifetime)
private var database: Connection?
private let dbQueue = DispatchQueue(label: "sqlite.plugin")

// MARK: - Plugin Info

/// Returns full plugin metadata as JSON.
/// Declares this plugin provides a "sqlite" service with query/execute methods.
@_cdecl("aro_plugin_info")
public func aroPluginInfo() -> UnsafeMutablePointer<CChar>? {
    let info = """
    {
      "name": "SQLitePlugin",
      "version": "1.0.0",
      "handle": "SQLite",
      "actions": [],
      "qualifiers": [],
      "services": [
        {
          "name": "sqlite",
          "methods": ["query", "execute"]
        }
      ]
    }
    """
    return aroStrdup(info)
}

// MARK: - Lifecycle Hooks

/// Called once when the plugin is loaded. Opens the in-memory database connection.
@_cdecl("aro_plugin_init")
public func aroPluginInit() {
    dbQueue.sync {
        if database == nil {
            database = try? Connection(.inMemory)
        }
    }
}

/// Called when the plugin is unloaded. Releases the database connection.
@_cdecl("aro_plugin_shutdown")
public func aroPluginShutdown() {
    dbQueue.sync {
        database = nil
    }
}

// MARK: - Execute

/// Main dispatch function. Routes service actions via the "service:" prefix.
/// Action format: "service:<method>", e.g. "service:query", "service:execute"
@_cdecl("aro_plugin_execute")
public func aroPluginExecute(
    _ actionPtr: UnsafePointer<CChar>,
    _ inputJSONPtr: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>? {
    let action = String(cString: actionPtr)
    let input  = ActionInput(aroParseJSON(inputJSONPtr))

    // Route service actions via "service:<method>" prefix
    guard action.hasPrefix("service:") else {
        return ActionOutput.failure(.unsupported, "Unknown action: \(action)").toCString()
    }
    let method = String(action.dropFirst("service:".count))

    // SQL is passed in "_with.sql" or top-level "sql"
    let sql = input.with.string("sql") ?? input.string("sql")

    guard let sql else {
        return ActionOutput.failure(.invalidInput, "Missing required argument: sql").toCString()
    }

    // Execute in thread-safe manner
    let result: [String: Any]
    do {
        result = try dbQueue.sync {
            try executeMethod(method, sql: sql)
        }
    } catch {
        return ActionOutput.failure(.executionFailed, String(describing: error)).toCString()
    }

    return ActionOutput.success(result).toCString()
}

// MARK: - Free

/// Frees memory allocated by this plugin.
@_cdecl("aro_plugin_free")
public func aroPluginFree(_ ptr: UnsafeMutablePointer<CChar>?) {
    free(ptr)
}

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
