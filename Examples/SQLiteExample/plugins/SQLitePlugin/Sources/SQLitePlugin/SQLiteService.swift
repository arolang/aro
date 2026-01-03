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

// MARK: - Plugin Initialization

/// Plugin initialization - returns service metadata as JSON
/// This tells ARO what services and symbols this plugin provides
@_cdecl("aro_plugin_init")
public func pluginInit() -> UnsafePointer<CChar> {
    let metadata = "{\"services\": [{\"name\": \"sqlite\", \"symbol\": \"sqlite_call\"}]}"
    let cstr = strdup(metadata)!
    return UnsafePointer(cstr)
}

// MARK: - Service Implementation

/// Main entry point for the sqlite service
/// - Parameters:
///   - methodPtr: Method name (C string)
///   - argsPtr: Arguments as JSON (C string)
///   - resultPtr: Output - result as JSON (caller must free)
/// - Returns: 0 for success, non-zero for error
@_cdecl("sqlite_call")
public func sqliteCall(
    _ methodPtr: UnsafePointer<CChar>,
    _ argsPtr: UnsafePointer<CChar>,
    _ resultPtr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32 {
    let method = String(cString: methodPtr)
    let argsJSON = String(cString: argsPtr)

    // Parse args
    guard let argsData = argsJSON.data(using: .utf8),
          let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] else {
        let error = "{\"error\": \"Invalid JSON arguments\"}"
        resultPtr.pointee = error.withCString { strdup($0) }
        return 1
    }

    // Execute method in thread-safe manner
    let result: [String: Any]
    do {
        result = try dbQueue.sync {
            try executeMethod(method, args: args)
        }
    } catch {
        let errorJSON = "{\"error\": \"\(escapeJSON(String(describing: error)))\"}"
        resultPtr.pointee = errorJSON.withCString { strdup($0) }
        return 1
    }

    // Return success result as JSON
    do {
        let resultJSON = try encodeResult(result)
        resultPtr.pointee = resultJSON.withCString { strdup($0) }
        return 0
    } catch {
        let errorJSON = "{\"error\": \"Failed to encode result\"}"
        resultPtr.pointee = errorJSON.withCString { strdup($0) }
        return 1
    }
}

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

/// Encode result as JSON string
private func encodeResult(_ result: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: result)
    return String(data: data, encoding: .utf8) ?? "{}"
}

/// Escape string for JSON
private func escapeJSON(_ string: String) -> String {
    return string
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
}

// MARK: - Error Types

enum PluginError: Error {
    case missingSQLArgument
    case unknownMethod(String)
}
