// ============================================================
// CollectionPlugin.swift
// ARO Plugin - Swift Qualifier Example
// ============================================================

import Foundation

/// A Swift plugin that provides collection qualifiers
///
/// This plugin demonstrates how to implement plugin qualifiers.
/// Qualifiers transform values in ARO expressions like <list: pick-random>.
public struct CollectionPlugin {
    public static let name = "plugin-swift-collection"
    public static let version = "1.0.0"
}

// MARK: - C ABI Interface

/// Returns plugin metadata as JSON string with qualifier definitions
@_cdecl("aro_plugin_info")
public func aroPluginInfo() -> UnsafeMutablePointer<CChar>? {
    // Define qualifiers this plugin provides
    let pickRandomQualifier: NSDictionary = [
        "name": "pick-random",
        "inputTypes": ["List"] as NSArray,
        "description": "Picks a random element from a list"
    ]

    let shuffleQualifier: NSDictionary = [
        "name": "shuffle",
        "inputTypes": ["List", "String"] as NSArray,
        "description": "Shuffles elements in a list or characters in a string"
    ]

    let reverseQualifier: NSDictionary = [
        "name": "reverse",
        "inputTypes": ["List", "String"] as NSArray,
        "description": "Reverses elements in a list or characters in a string"
    ]

    let info: NSDictionary = [
        "name": "plugin-swift-collection",
        "version": "1.0.0",
        "actions": [] as NSArray,
        "qualifiers": [pickRandomQualifier, shuffleQualifier, reverseQualifier] as NSArray
    ]

    guard let jsonData = try? JSONSerialization.data(withJSONObject: info),
          let jsonString = String(data: jsonData, encoding: .utf8) else {
        return nil
    }

    return strdup(jsonString)
}

/// Execute a qualifier transformation
@_cdecl("aro_plugin_qualifier")
public func aroPluginQualifier(
    qualifier: UnsafePointer<CChar>?,
    inputJson: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    guard let qualifier = qualifier.map({ String(cString: $0) }),
          let inputJson = inputJson.map({ String(cString: $0) }) else {
        return strdup("{\"error\":\"Invalid input\"}")
    }

    guard let jsonData = inputJson.data(using: .utf8),
          let input = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
        return strdup("{\"error\":\"Invalid JSON input\"}")
    }

    // Get the value and type from input
    let value = input["value"]
    let type = input["type"] as? String ?? "Unknown"

    let result: [String: Any]
    switch qualifier {
    case "pick-random":
        result = CollectionPlugin.pickRandom(value: value, type: type)
    case "shuffle":
        result = CollectionPlugin.shuffle(value: value, type: type)
    case "reverse":
        result = CollectionPlugin.reverse(value: value, type: type)
    default:
        result = ["error": "Unknown qualifier: \(qualifier)"]
    }

    guard let resultData = try? JSONSerialization.data(withJSONObject: result),
          let resultString = String(data: resultData, encoding: .utf8) else {
        return strdup("{\"error\":\"Failed to serialize result\"}")
    }

    return strdup(resultString)
}

/// Execute a plugin action (not used but required)
@_cdecl("aro_plugin_execute")
public func aroPluginExecute(
    action: UnsafePointer<CChar>?,
    inputJson: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    return strdup("{\"error\":\"No actions defined\"}")
}

/// Free memory allocated by the plugin
@_cdecl("aro_plugin_free")
public func aroPluginFree(ptr: UnsafeMutablePointer<CChar>?) {
    if let ptr = ptr {
        free(ptr)
    }
}

// MARK: - Qualifier Implementations

extension CollectionPlugin {

    /// Pick a random element from a list
    static func pickRandom(value: Any?, type: String) -> [String: Any] {
        guard let array = value as? [Any], !array.isEmpty else {
            return ["error": "pick-random requires a non-empty list"]
        }

        let randomIndex = Int.random(in: 0..<array.count)
        return ["result": array[randomIndex]]
    }

    /// Shuffle elements in a list or characters in a string
    static func shuffle(value: Any?, type: String) -> [String: Any] {
        if let array = value as? [Any] {
            return ["result": array.shuffled()]
        }

        if let string = value as? String {
            let shuffled = String(string.shuffled())
            return ["result": shuffled]
        }

        return ["error": "shuffle requires a list or string"]
    }

    /// Reverse elements in a list or characters in a string
    static func reverse(value: Any?, type: String) -> [String: Any] {
        if let array = value as? [Any] {
            return ["result": Array(array.reversed())]
        }

        if let string = value as? String {
            return ["result": String(string.reversed())]
        }

        return ["error": "reverse requires a list or string"]
    }
}
