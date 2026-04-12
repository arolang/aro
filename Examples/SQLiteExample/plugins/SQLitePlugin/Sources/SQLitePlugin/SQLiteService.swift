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

// MARK: - State Management

/// Global database connection (persists for application lifetime)
private var database: Connection?
private let dbQueue = DispatchQueue(label: "sqlite.plugin")

// MARK: - Plugin Info

/// Returns full plugin metadata as JSON.
/// Declares this plugin provides a "sqlite" service with query/execute methods.
@_cdecl("aro_plugin_info")
public func aroPluginInfo() -> UnsafeMutablePointer<CChar> {
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
    return strdup(info)!
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
) -> UnsafeMutablePointer<CChar> {
    let action = String(cString: actionPtr)
    let inputJSON = String(cString: inputJSONPtr)

    // Parse input JSON
    guard let inputData = inputJSON.data(using: .utf8),
          let input = try? JSONSerialization.jsonObject(with: inputData) as? [String: Any] else {
        return errorResponse("Invalid JSON input")
    }

    // Route service actions via "service:<method>" prefix
    guard action.hasPrefix("service:") else {
        return errorResponse("Unknown action: \(action)")
    }
    let method = String(action.dropFirst("service:".count))

    // Execute in thread-safe manner
    let result: [String: Any]
    do {
        result = try dbQueue.sync {
            try executeMethod(method, args: input)
        }
    } catch {
        return errorResponse(String(describing: error))
    }

    return jsonResponse(result)
}

// MARK: - Free

/// Frees memory allocated by this plugin.
@_cdecl("aro_plugin_free")
public func aroPluginFree(_ ptr: UnsafeMutablePointer<CChar>?) {
    free(ptr)
}

// MARK: - SQL Logic

/// Execute a database method (thread-safe via dbQueue)
private func executeMethod(_ method: String, args: [String: Any]) throws -> [String: Any] {
    let db = try getOrCreateConnection()

    guard let sql = args["sql"] as? String else {
        throw PluginError.missingSQLArgument
    }

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
            // Get value and convert to JSON-compatible type
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

// MARK: - Helpers

/// Build a JSON response string from a dictionary and return as a C string.
private func jsonResponse(_ result: [String: Any]) -> UnsafeMutablePointer<CChar> {
    do {
        let data = try JSONSerialization.data(withJSONObject: result)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return strdup(json)!
    } catch {
        return strdup("{\"error\": \"Failed to encode result\"}")!
    }
}

/// Build an error JSON response and return as a C string.
private func errorResponse(_ message: String) -> UnsafeMutablePointer<CChar> {
    let escaped = message
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
    return strdup("{\"error\": \"\(escaped)\"}")!
}

// MARK: - Error Types

enum PluginError: Error {
    case missingSQLArgument
    case unknownMethod(String)
}
