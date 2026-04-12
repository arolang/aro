// ============================================================
// HelloPlugin.swift
// ARO Plugin - Swift Hello World Example (ARO-0073 ABI)
// ============================================================

import Foundation

/// A simple Swift plugin that provides greeting functionality.
///
/// This plugin demonstrates the ARO-0073 plugin ABI:
///   - aro_plugin_info      (required) — comprehensive metadata JSON
///   - aro_plugin_init      (lifecycle) — called once after the plugin is loaded
///   - aro_plugin_shutdown  (lifecycle) — called once before the plugin is unloaded
///   - aro_plugin_execute   (optional)  — present because this plugin has actions
///   - aro_plugin_free      (required)  — frees every string the plugin allocates
public struct HelloPlugin {

    /// Plugin metadata
    public static let name    = "plugin-swift-hello"
    public static let version = "1.0.0"
}

// MARK: - C ABI Interface

/// Returns plugin metadata as a comprehensive JSON string.
///
/// Required by ARO-0073. The runtime calls this once during plugin discovery
/// to learn which actions the plugin provides, their roles, and which verbs
/// and prepositions trigger them.
@_cdecl("aro_plugin_info")
public func aroPluginInfo() -> UnsafeMutablePointer<CChar>? {

    // NSDictionary / NSArray are used intentionally here instead of Swift
    // Dictionary / Array literals. When a Swift plugin is loaded as a
    // dynamic library via dlopen(), the Foundation bridging machinery that
    // normally coerces Swift collections to NSObject-compatible types may
    // not have run yet, causing JSONSerialization to silently drop keys or
    // crash. Using explicit NS-prefixed types guarantees correct bridging
    // across the dylib boundary regardless of load order.

    let greetAction: NSDictionary = [
        "name":         "Greet",
        "role":         "own",
        "verbs":        ["greet", "hello"] as NSArray,
        "prepositions": ["with", "for"]    as NSArray,
        "description":  "Generate a personalized greeting."
    ]

    let farewellAction: NSDictionary = [
        "name":         "Farewell",
        "role":         "own",
        "verbs":        ["farewell", "goodbye"] as NSArray,
        "prepositions": ["with", "for"]         as NSArray,
        "description":  "Generate a personalized farewell message."
    ]

    let info: NSDictionary = [
        "name":        "plugin-swift-hello",
        "version":     "1.0.0",
        "handle":      "Greeting",
        "description": "A simple Swift plugin that provides greeting functionality.",
        "abi":         "ARO-0073",
        "actions":     [greetAction, farewellAction] as NSArray
    ]

    guard let jsonData   = try? JSONSerialization.data(withJSONObject: info),
          let jsonString = String(data: jsonData, encoding: .utf8) else {
        return nil
    }

    return strdup(jsonString)
}

/// Called once immediately after the plugin dylib is loaded.
///
/// Use this hook to allocate long-lived resources (thread pools, connections,
/// caches). The runtime does not pass any arguments; return value is void.
/// Even if you have nothing to initialise, declaring this function signals to
/// the runtime that the plugin is lifecycle-aware.
@_cdecl("aro_plugin_init")
public func aroPluginInit() {
    // Nothing to initialise for this simple plugin.
    // A real plugin might open a database connection or warm up a cache here.
}

/// Called once just before the plugin dylib is unloaded (graceful shutdown).
///
/// Use this hook to flush buffers, close connections, or release resources
/// acquired in aro_plugin_init. The runtime guarantees no further calls to
/// aro_plugin_execute will be made after this returns.
@_cdecl("aro_plugin_shutdown")
public func aroPluginShutdown() {
    // Nothing to tear down for this simple plugin.
    // A real plugin might close a database connection or flush a write buffer.
}

/// Execute a plugin action.
///
/// Optional (per ARO-0073) but present here because this plugin provides
/// actions. The runtime passes a normalised JSON envelope with the following
/// structure:
///
/// ```json
/// {
///   "action":      "greet",
///   "result":      { "base": "greeting", "specifiers": [] },
///   "source":      { "base": "name",     "specifiers": [] },
///   "preposition": "with",
///   "data":        "ARO Developer",
///   "_with":       { "name": "ARO Developer" },
///   "_context":    {
///     "requestId":       "abc-123",
///     "featureSet":      "Application-Start",
///     "businessActivity": "Greeting Plugin Demo"
///   }
/// }
/// ```
///
/// - `result`      — descriptor for the ARO result slot (variable being bound)
/// - `source`      — descriptor for the primary input slot
/// - `preposition` — the preposition used in the statement ("with", "for", …)
/// - `data`        — the resolved primary value (convenience shorthand)
/// - `_with`       — all named arguments from the `with { … }` block (nested)
/// - `_context`    — runtime context for tracing / logging
@_cdecl("aro_plugin_execute")
public func aroPluginExecute(
    action:    UnsafePointer<CChar>?,
    inputJson: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {

    guard let action    = action.map({ String(cString: $0) }),
          let inputJson = inputJson.map({ String(cString: $0) }) else {
        return strdup(#"{"error":"Invalid input"}"#)
    }

    guard let jsonData = inputJson.data(using: .utf8),
          let envelope = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
        return strdup(#"{"error":"Invalid JSON input"}"#)
    }

    // Primary value is in "data"; fall back to "_with" for named parameters.
    // The ARO-0073 ABI delivers the primary value in "data" and all named
    // arguments as a nested dictionary in "_with".
    let withArgs = envelope["_with"] as? [String: Any] ?? [:]
    let primaryData = envelope["data"] as? String

    // Build a flat input dict for the action implementations (preserves the
    // existing greet/farewell logic unchanged).
    var actionInput: [String: Any] = withArgs
    if let name = primaryData {
        actionInput["name"] = name
    }

    let result: [String: Any]
    switch action.lowercased() {
    case "greet", "hello":
        result = HelloPlugin.greet(input: actionInput)
    case "farewell", "goodbye":
        result = HelloPlugin.farewell(input: actionInput)
    default:
        result = ["error": "Unknown action: \(action)"]
    }

    guard let resultData   = try? JSONSerialization.data(withJSONObject: result),
          let resultString = String(data: resultData, encoding: .utf8) else {
        return strdup(#"{"error":"Failed to serialize result"}"#)
    }

    return strdup(resultString)
}

/// Free a string that was allocated by this plugin.
///
/// Required by ARO-0073. The runtime calls this for every pointer returned by
/// aro_plugin_info, aro_plugin_execute, or any other function that allocates
/// memory. Plugins must never free memory allocated by the runtime, and the
/// runtime must never free memory allocated by the plugin — this function is
/// the single agreed-upon deallocation path.
@_cdecl("aro_plugin_free")
public func aroPluginFree(ptr: UnsafeMutablePointer<CChar>?) {
    guard let ptr else { return }
    free(ptr)
}

// MARK: - Action Implementations

extension HelloPlugin {

    /// Greet action — generates a personalized greeting.
    ///
    /// - Parameter input: Dictionary that may contain a `"name"` key.
    /// - Returns: JSON-serialisable result with `message`, `timestamp`, and `plugin`.
    public static func greet(input: [String: Any]) -> [String: Any] {
        let name     = input["name"] as? String ?? "World"
        let greeting = "Hello, \(name)!"

        return [
            "message":   greeting,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "plugin":    name
        ]
    }

    /// Farewell action — generates a goodbye message.
    ///
    /// - Parameter input: Dictionary that may contain a `"name"` key.
    /// - Returns: JSON-serialisable result with `message`, `timestamp`, and `plugin`.
    public static func farewell(input: [String: Any]) -> [String: Any] {
        let name     = input["name"] as? String ?? "World"
        let farewell = "Goodbye, \(name)! See you soon!"

        return [
            "message":   farewell,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "plugin":    name
        ]
    }
}
