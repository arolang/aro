// ============================================================
// GreetingService.swift
// Example ARO Plugin - Custom Greeting Service (ARO-0073 ABI)
// ============================================================
//
// Usage in ARO:
//   <Call> the <result> from the <greeting: hello> with { name: "World" }.

import Foundation

// MARK: - Plugin Info (required)

@_cdecl("aro_plugin_info")
public func aroPluginInfo() -> UnsafeMutablePointer<CChar>? {
    let json = """
    {
      "name": "greeting-service",
      "version": "1.0.0",
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
    return json.withCString { strdup($0) }
}

// MARK: - Plugin Execute (handles service routing)

@_cdecl("aro_plugin_execute")
public func aroPluginExecute(
    _ action: UnsafePointer<CChar>,
    _ inputJson: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar>? {
    let actionStr = String(cString: action)
    let inputStr = String(cString: inputJson)

    // Parse input
    var args: [String: Any] = [:]
    if let data = inputStr.data(using: .utf8),
       let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        args = parsed
    }

    // Extract method from "service:method" prefix
    let method: String
    if actionStr.hasPrefix("service:") {
        method = String(actionStr.dropFirst(8))
    } else {
        method = actionStr
    }

    let name = (args["_with"] as? [String: Any])?["name"] as? String
        ?? args["name"] as? String
        ?? "World"

    let result: String
    switch method.lowercased() {
    case "hello":
        result = "Hello, \(name)!"
    case "goodbye":
        result = "Goodbye, \(name)! See you next time."
    case "greet":
        let style = (args["_with"] as? [String: Any])?["style"] as? String
            ?? args["style"] as? String
            ?? "formal"
        switch style {
        case "casual": result = "Hey \(name)! What's up?"
        case "enthusiastic": result = "WOW! Great to see you, \(name)!"
        default: result = "Good day, \(name). How may I assist you?"
        }
    default:
        let errJSON = "{\"error\":\"Unknown method: \(method)\"}"
        return errJSON.withCString { strdup($0) }
    }

    let resultJSON = "{\"result\":\"\(result)\"}"
    return resultJSON.withCString { strdup($0) }
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
