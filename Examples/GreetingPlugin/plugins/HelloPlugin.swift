// ============================================================
// HelloPlugin.swift
// ARO Plugin - Greeting Service
// ============================================================
//
// Provides greeting functionality with "greet" and "farewell" methods.
//
// Usage in ARO:
//   <Call> the <result> from the <hello-plugin: greet> with { name: "World" }.
//   <Call> the <result> from the <hello-plugin: farewell> with { name: "World" }.

import Foundation

// MARK: - Plugin Initialization

@_cdecl("aro_plugin_init")
public func pluginInit() -> UnsafePointer<CChar> {
    let metadata = """
    {"services": [{"name": "hello-plugin", "symbol": "hello_plugin_call"}]}
    """
    return UnsafePointer(strdup(metadata)!)
}

// MARK: - Service Implementation

@_cdecl("hello_plugin_call")
public func helloPluginCall(
    _ methodPtr: UnsafePointer<CChar>,
    _ argsPtr: UnsafePointer<CChar>,
    _ resultPtr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32 {
    let method = String(cString: methodPtr)
    let argsJSON = String(cString: argsPtr)

    // Parse arguments
    var args: [String: Any] = [:]
    if let data = argsJSON.data(using: .utf8),
       let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        args = parsed
    }

    let name = args["name"] as? String ?? "World"
    let result: [String: Any]

    switch method.lowercased() {
    case "greet":
        result = [
            "message": "Hello, \(name)!",
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]

    case "farewell":
        result = [
            "message": "Goodbye, \(name)! See you soon!",
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]

    default:
        let errorJSON = "{\"error\": \"Unknown method: \(method)\"}"
        resultPtr.pointee = strdup(errorJSON)
        return 1
    }

    // Serialize result to JSON
    if let data = try? JSONSerialization.data(withJSONObject: result),
       let json = String(data: data, encoding: .utf8) {
        resultPtr.pointee = strdup(json)
        return 0
    }

    resultPtr.pointee = strdup("{\"error\": \"Failed to serialize result\"}")
    return 1
}
