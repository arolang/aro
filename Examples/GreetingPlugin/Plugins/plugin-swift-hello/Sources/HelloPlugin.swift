// ============================================================
// HelloPlugin.swift
// ARO Plugin - Swift Hello World Example
// ============================================================

import Foundation

/// A simple Swift plugin that provides greeting functionality
///
/// This plugin demonstrates how to create a Swift plugin for ARO.
/// It provides custom actions: Greet and Farewell.
public struct HelloPlugin {

    /// Plugin metadata
    public static let name = "plugin-swift-hello"
    public static let version = "1.0.0"
}

// MARK: - C ABI Interface

/// Returns plugin metadata as JSON string with custom action definitions
@_cdecl("aro_plugin_info")
public func aroPluginInfo() -> UnsafeMutablePointer<CChar>? {
    let info: [String: Any] = [
        "name": "plugin-swift-hello",
        "version": "1.0.0",
        "actions": [
            [
                "name": "Greet",
                "role": "own",
                "verbs": ["greet", "hello"],
                "prepositions": ["with", "for"]
            ],
            [
                "name": "Farewell",
                "role": "own",
                "verbs": ["farewell", "goodbye"],
                "prepositions": ["with", "for"]
            ]
        ]
    ]

    guard let jsonData = try? JSONSerialization.data(withJSONObject: info),
          let jsonString = String(data: jsonData, encoding: .utf8) else {
        return nil
    }

    return strdup(jsonString)
}

/// Execute a plugin action
@_cdecl("aro_plugin_execute")
public func aroPluginExecute(
    action: UnsafePointer<CChar>?,
    inputJson: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    guard let action = action.map({ String(cString: $0) }),
          let inputJson = inputJson.map({ String(cString: $0) }) else {
        return strdup("{\"error\":\"Invalid input\"}")
    }

    guard let jsonData = inputJson.data(using: .utf8),
          let input = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
        return strdup("{\"error\":\"Invalid JSON input\"}")
    }

    let result: [String: Any]
    switch action {
    case "greet", "hello":
        result = HelloPlugin.greet(input: input)
    case "farewell", "goodbye":
        result = HelloPlugin.farewell(input: input)
    default:
        result = ["error": "Unknown action: \(action)"]
    }

    guard let resultData = try? JSONSerialization.data(withJSONObject: result),
          let resultString = String(data: resultData, encoding: .utf8) else {
        return strdup("{\"error\":\"Failed to serialize result\"}")
    }

    return strdup(resultString)
}

/// Free memory allocated by the plugin
@_cdecl("aro_plugin_free")
public func aroPluginFree(ptr: UnsafeMutablePointer<CChar>?) {
    if let ptr = ptr {
        free(ptr)
    }
}

// MARK: - Action Implementations

extension HelloPlugin {

    // MARK: - Actions

    /// Greet action - generates a personalized greeting
    /// - Parameter input: Dictionary containing "name" key
    /// - Returns: Greeting message
    public static func greet(input: [String: Any]) -> [String: Any] {
        let name = input["name"] as? String ?? "World"
        let greeting = "Hello, \(name)!"

        return [
            "message": greeting,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "plugin": name
        ]
    }

    /// Farewell action - generates a goodbye message
    /// - Parameter input: Dictionary containing "name" key
    /// - Returns: Farewell message
    public static func farewell(input: [String: Any]) -> [String: Any] {
        let name = input["name"] as? String ?? "World"
        let farewell = "Goodbye, \(name)! See you soon!"

        return [
            "message": farewell,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "plugin": name
        ]
    }
}
