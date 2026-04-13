// ============================================================
// GreetingService.swift
// Example ARO Plugin - Custom Greeting Service
// ============================================================
//
// This plugin demonstrates the ARO plugin system.
// It provides a "greeting" service with "hello" and "goodbye" methods.
//
// Usage in ARO:
//   <Call> the <result> from the <greeting: hello> with { name: "World" }.

import Foundation

// MARK: - Plugin Info (ARO-0073)

@_cdecl("aro_plugin_info")
public func aroPluginInfo() -> UnsafeMutablePointer<CChar>? {
    let info = """
    {
      "name": "GreetingService",
      "version": "1.0.0",
      "handle": "Greeting",
      "actions": [],
      "qualifiers": [],
      "services": [
        {
          "name": "greeting",
          "methods": ["hello", "goodbye", "greet"]
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
    let inputJSON = String(cString: inputJSONPtr)

    // Parse input arguments
    var args: [String: Any] = [:]
    if let data = inputJSON.data(using: .utf8),
       let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        args = parsed
        // Flatten _with into top-level for service method args
        if let withArgs = args["_with"] as? [String: Any] {
            for (k, v) in withArgs { args[k] = v }
        }
    }

    // Route service actions — strip "service:" prefix if present
    let method: String
    if action.hasPrefix("service:") {
        method = String(action.dropFirst("service:".count))
    } else {
        method = action
    }

    let result: String
    do {
        result = try executeMethod(method, args: args)
    } catch {
        return strdup("{\"error\": \"\(error)\"}")
    }

    return strdup("{\"result\": \"\(result)\"}")
}

// MARK: - Free

@_cdecl("aro_plugin_free")
public func aroPluginFree(_ ptr: UnsafeMutablePointer<CChar>?) {
    ptr.map { free($0) }
}

// MARK: - Implementation

/// Execute a greeting method
private func executeMethod(_ method: String, args: [String: Any]) throws -> String {
    let name = args["name"] as? String ?? "World"

    switch method.lowercased() {
    case "hello":
        return "Hello, \(name)!"

    case "goodbye":
        return "Goodbye, \(name)! See you next time."

    case "greet":
        let style = args["style"] as? String ?? "formal"
        switch style {
        case "casual":
            return "Hey \(name)! What's up?"
        case "enthusiastic":
            return "WOW! Great to see you, \(name)!"
        default:
            return "Good day, \(name). How may I assist you?"
        }

    default:
        throw PluginError.unknownMethod(method)
    }
}

/// Plugin-specific errors
enum PluginError: Error, CustomStringConvertible {
    case unknownMethod(String)

    var description: String {
        switch self {
        case .unknownMethod(let method):
            return "Unknown method: \(method)"
        }
    }
}
