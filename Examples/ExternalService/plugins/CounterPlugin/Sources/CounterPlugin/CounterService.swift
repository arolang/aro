// ============================================================
// CounterService.swift
// Example ARO Plugin - Stateful Counter Service
// ============================================================
//
// This plugin demonstrates the Call action with stateful services.
// It answers: "Why does Call exist when Request handles HTTP and Exec handles commands?"
//
// - Request: Stateless HTTP - each call is independent
// - Exec: Command execution - no persistence between calls
// - Call: Stateful services - maintain connections/state for application lifetime
//
// Usage in ARO:
//   <Call> the <result> from the <counter: increment> with {}.
//   <Call> the <result> from the <counter: get> with {}.
//   <Call> the <result> from the <counter: reset> with {}.

import Foundation

// MARK: - State Management

/// Global counter state (persists for application lifetime)
private var globalCount: Int = 0
private let counterQueue = DispatchQueue(label: "counter.service")

// MARK: - Plugin Initialization

/// Plugin initialization - returns service metadata as JSON
/// This tells ARO what services and symbols this plugin provides
@_cdecl("aro_plugin_init")
public func pluginInit() -> UnsafePointer<CChar> {
    let metadata = "{\"services\": [{\"name\": \"counter\", \"symbol\": \"counter_call\"}]}"
    let cstr = strdup(metadata)!
    return UnsafePointer(cstr)
}

// MARK: - Service Implementation

/// Main entry point for the counter service
/// - Parameters:
///   - methodPtr: Method name (C string)
///   - argsPtr: Arguments as JSON (C string)
///   - resultPtr: Output - result as JSON (caller must free)
/// - Returns: 0 for success, non-zero for error
@_cdecl("counter_call")
public func counterCall(
    _ methodPtr: UnsafePointer<CChar>,
    _ argsPtr: UnsafePointer<CChar>,
    _ resultPtr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32 {
    let method = String(cString: methodPtr)

    // Execute method (all methods are synchronous and thread-safe)
    let result: [String: Any]
    do {
        result = try executeMethod(method)
    } catch {
        // Return error message
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

/// Execute a counter method (thread-safe)
private func executeMethod(_ method: String) throws -> [String: Any] {
    return counterQueue.sync {
        switch method.lowercased() {
        case "increment":
            globalCount += 1
            return ["count": globalCount, "message": "Incremented"]

        case "get":
            return ["count": globalCount]

        case "reset":
            globalCount = 0
            return ["count": 0, "message": "Reset"]

        default:
            return ["error": "Unknown method: \(method). Available: increment, get, reset"]
        }
    }
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
