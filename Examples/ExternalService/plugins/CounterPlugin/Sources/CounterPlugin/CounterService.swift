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

// MARK: - Plugin Info (ARO-0073)

@_cdecl("aro_plugin_info")
public func aroPluginInfo() -> UnsafeMutablePointer<CChar>? {
    let info = """
    {
      "name": "CounterPlugin",
      "version": "1.0.0",
      "handle": "Counter",
      "actions": [],
      "qualifiers": [],
      "services": [
        {
          "name": "counter",
          "methods": ["increment", "get", "reset"]
        }
      ]
    }
    """
    return strdup(info)
}

// MARK: - Execute (ARO-0073)

@_cdecl("aro_plugin_execute")
public func aroPluginExecute(
    _ actionPtr: UnsafePointer<CChar>,
    _ inputJSONPtr: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>? {
    let action = String(cString: actionPtr)

    // Route service actions — strip "service:" prefix if present
    let method: String
    if action.hasPrefix("service:") {
        method = String(action.dropFirst("service:".count))
    } else {
        method = action
    }

    let result: [String: Any]
    do {
        result = try executeMethod(method)
    } catch {
        return strdup("{\"error\": \"\(escapeJSON(String(describing: error)))\"}")
    }

    do {
        let resultJSON = try encodeResult(result)
        return strdup(resultJSON)
    } catch {
        return strdup("{\"error\": \"Failed to encode result\"}")
    }
}

// MARK: - Free

@_cdecl("aro_plugin_free")
public func aroPluginFree(_ ptr: UnsafeMutablePointer<CChar>?) {
    ptr.map { free($0) }
}

// MARK: - Implementation

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
