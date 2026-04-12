// ============================================================
// CounterService.swift
// Example ARO Plugin - Stateful Counter Service (ARO-0073 ABI)
// ============================================================
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

// MARK: - Plugin Info (required)

@_cdecl("aro_plugin_info")
public func aroPluginInfo() -> UnsafeMutablePointer<CChar>? {
    let json = """
    {
      "name": "counter-plugin",
      "version": "1.0.0",
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
    return json.withCString { strdup($0) }
}

// MARK: - Plugin Execute (handles service routing)

@_cdecl("aro_plugin_execute")
public func aroPluginExecute(
    _ action: UnsafePointer<CChar>,
    _ inputJson: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>? {
    let actionStr = String(cString: action)

    // Extract method from "service:method" prefix
    let method: String
    if actionStr.hasPrefix("service:") {
        method = String(actionStr.dropFirst(8))
    } else {
        method = actionStr
    }

    // Execute method (thread-safe)
    let result: [String: Any] = counterQueue.sync {
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

    guard let data = try? JSONSerialization.data(withJSONObject: result),
          let json = String(data: data, encoding: .utf8) else {
        return "{}".withCString { strdup($0) }
    }
    return json.withCString { strdup($0) }
}

// MARK: - Lifecycle

@_cdecl("aro_plugin_init")
public func aroPluginInit() {}

@_cdecl("aro_plugin_shutdown")
public func aroPluginShutdown() {}

// MARK: - Free

@_cdecl("aro_plugin_free")
public func aroPluginFree(_ ptr: UnsafeMutablePointer<CChar>?) {
    guard let ptr else { return }
    free(ptr)
}
