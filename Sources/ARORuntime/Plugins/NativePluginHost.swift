// ============================================================
// NativePluginHost.swift
// ARO Runtime - Native (C/C++/Rust) Plugin Host (ARO-0045)
// ============================================================

import Foundation

#if os(Windows)
import WinSDK
#endif

// MARK: - Native Plugin Host

/// Host for native plugins written in C, C++, or Rust
///
/// Native plugins communicate through a C ABI interface using JSON strings.
/// The execute function takes an action name and JSON input, returns JSON output.
///
/// ## Required C Interface
/// ```c
/// // Execute an action with JSON input, return JSON output
/// // Caller must free the returned string using aro_plugin_free
/// char* aro_plugin_execute(const char* action, const char* input_json);
///
/// // Free memory allocated by the plugin
/// void aro_plugin_free(char* ptr);
/// ```
///
/// ## Optional C Interface
/// ```c
/// // Get plugin info as JSON (name, version, actions[])
/// char* aro_plugin_info(void);
/// ```
public final class NativePluginHost: @unchecked Sendable {
    /// Plugin name
    public let pluginName: String

    /// Path to the plugin
    public let pluginPath: URL

    /// Loaded library handle
    private var libraryHandle: UnsafeMutableRawPointer?

    /// Plugin info
    private var pluginInfo: NativePluginInfo?

    /// Registered actions
    private var actions: [String: NativeActionDescriptor] = [:]

    // MARK: - Function Types (using raw pointers for C ABI compatibility)

    typealias PluginInfoFunc = @convention(c) () -> UnsafeMutablePointer<CChar>?
    typealias ExecuteFunc = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
    typealias FreeFunc = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

    private var executeFunc: ExecuteFunc?
    private var freeFunc: FreeFunc?

    // MARK: - Initialization

    /// Initialize with a plugin path and configuration
    public init(pluginPath: URL, pluginName: String, config: UnifiedProvideEntry) throws {
        self.pluginName = pluginName
        self.pluginPath = pluginPath

        // Find and load the library
        try loadLibrary(config: config)

        // Load plugin info
        try loadPluginInfo()
    }

    // MARK: - Library Loading

    private func loadLibrary(config: UnifiedProvideEntry) throws {
        // Determine library path
        let libraryPath: URL

        if let output = config.build?.output {
            // Output path may be relative to plugin root or to the path
            // Try both: relative to pluginPath and relative to parent (plugin root)
            let pluginRoot = pluginPath.deletingLastPathComponent()
            let candidates = [
                pluginPath.appendingPathComponent(output),
                pluginRoot.appendingPathComponent(output),
            ]

            guard let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                throw NativePluginError.libraryNotFound(pluginName)
            }
            libraryPath = found
        } else {
            // Look for default library names
            #if os(Windows)
            let ext = "dll"
            #elseif os(Linux)
            let ext = "so"
            #else
            let ext = "dylib"
            #endif

            // Try common patterns
            let candidates = [
                pluginPath.appendingPathComponent("lib\(pluginName).\(ext)"),
                pluginPath.appendingPathComponent("\(pluginName).\(ext)"),
                pluginPath.appendingPathComponent("target/release/lib\(pluginName).\(ext)"),  // Rust
            ]

            guard let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                throw NativePluginError.libraryNotFound(pluginName)
            }
            libraryPath = found
        }

        // Load the library
        #if os(Windows)
        let handle = libraryPath.path.withCString(encodedAs: UTF16.self) { LoadLibraryW($0) }
        guard let handle = handle else {
            throw NativePluginError.loadFailed(pluginName, message: "LoadLibraryW failed")
        }
        libraryHandle = UnsafeMutableRawPointer(handle)
        #else
        guard let handle = dlopen(libraryPath.path, RTLD_NOW | RTLD_LOCAL) else {
            let error = String(cString: dlerror())
            throw NativePluginError.loadFailed(pluginName, message: error)
        }
        libraryHandle = handle
        #endif
    }

    private func loadPluginInfo() throws {
        guard let handle = libraryHandle else {
            throw NativePluginError.notLoaded(pluginName)
        }

        // Get execute function (required)
        #if os(Windows)
        let hmodule = unsafeBitCast(handle, to: HMODULE.self)
        let execSymbol = GetProcAddress(hmodule, "aro_plugin_execute")
        #else
        let execSymbol = dlsym(handle, "aro_plugin_execute")
        #endif

        guard let execSymbol = execSymbol else {
            throw NativePluginError.missingFunction(pluginName, function: "aro_plugin_execute")
        }
        executeFunc = unsafeBitCast(execSymbol, to: ExecuteFunc.self)

        // Get free function (optional but recommended)
        #if os(Windows)
        let freeSymbol = GetProcAddress(hmodule, "aro_plugin_free")
        #else
        let freeSymbol = dlsym(handle, "aro_plugin_free")
        #endif

        if let freeSymbol = freeSymbol {
            freeFunc = unsafeBitCast(freeSymbol, to: FreeFunc.self)
        }

        // Get plugin info function (optional)
        #if os(Windows)
        let infoSymbol = GetProcAddress(hmodule, "aro_plugin_info")
        #else
        let infoSymbol = dlsym(handle, "aro_plugin_info")
        #endif

        if let infoSymbol = infoSymbol {
            let infoFunc = unsafeBitCast(infoSymbol, to: PluginInfoFunc.self)
            if let infoPtr = infoFunc() {
                defer { freeFunc?(infoPtr) }
                let infoJSON = String(cString: infoPtr)
                parsePluginInfo(json: infoJSON)
            }
        }

        // If no info was loaded, use defaults
        if pluginInfo == nil {
            pluginInfo = NativePluginInfo(
                name: pluginName,
                version: "1.0.0",
                language: "native",
                actions: []
            )
        }
    }

    private func parsePluginInfo(json: String) {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let name = dict["name"] as? String ?? pluginName
        let version = dict["version"] as? String ?? "1.0.0"
        let language = dict["language"] as? String ?? "native"
        let actionNames = dict["actions"] as? [String] ?? []

        pluginInfo = NativePluginInfo(
            name: name,
            version: version,
            language: language,
            actions: actionNames
        )

        // Create action descriptors
        for actionName in actionNames {
            actions[actionName] = NativeActionDescriptor(
                name: actionName,
                inputSchema: nil,
                outputSchema: nil
            )
        }
    }

    // MARK: - Execution

    /// Execute an action
    public func execute(action: String, input: [String: any Sendable]) throws -> any Sendable {
        guard let execFunc = executeFunc else {
            throw NativePluginError.notLoaded(pluginName)
        }

        // Serialize input to JSON
        let inputData = try JSONSerialization.data(withJSONObject: input)
        let inputJSON = String(data: inputData, encoding: .utf8) ?? "{}"

        // Call the plugin
        let resultPtr = action.withCString { actionCStr in
            inputJSON.withCString { inputCStr in
                execFunc(actionCStr, inputCStr)
            }
        }

        defer {
            if let ptr = resultPtr {
                freeFunc?(ptr)
            }
        }

        guard let resultPtr = resultPtr else {
            return [String: any Sendable]()
        }

        let resultJSON = String(cString: resultPtr)

        // Parse result
        guard let resultData = resultJSON.data(using: .utf8),
              let result = try JSONSerialization.jsonObject(with: resultData) as? [String: Any] else {
            return resultJSON
        }

        return convertToSendable(result)
    }

    // MARK: - Action Registration

    /// Register actions with the global action registry
    public func registerActions() {
        for (name, descriptor) in actions {
            // Create a wrapper action that calls the native plugin
            let wrapper = NativePluginActionWrapper(
                pluginName: pluginName,
                actionName: name,
                host: self,
                descriptor: descriptor
            )

            // Register with ActionRegistry using dynamic verb
            Task {
                await ActionRegistry.shared.registerDynamic(
                    verb: name,
                    handler: wrapper.handle
                )
            }
        }
    }

    // MARK: - Unload

    /// Unload the plugin
    public func unload() {
        guard let handle = libraryHandle else { return }

        #if os(Windows)
        let hmodule = unsafeBitCast(handle, to: HMODULE.self)
        FreeLibrary(hmodule)
        #else
        dlclose(handle)
        #endif

        libraryHandle = nil
        executeFunc = nil
        freeFunc = nil
        actions.removeAll()
    }

    // MARK: - Helpers

    private func convertToSendable(_ value: Any) -> any Sendable {
        switch value {
        case let str as String:
            return str
        case let num as NSNumber:
            if floor(num.doubleValue) == num.doubleValue {
                return num.intValue
            }
            return num.doubleValue
        case let dict as [String: Any]:
            var result: [String: any Sendable] = [:]
            for (k, v) in dict {
                result[k] = convertToSendable(v)
            }
            return result
        case let arr as [Any]:
            return arr.map { convertToSendable($0) }
        case let bool as Bool:
            return bool
        default:
            return String(describing: value)
        }
    }
}

// MARK: - Swift Types

/// Plugin info
struct NativePluginInfo: Sendable {
    let name: String
    let version: String
    let language: String
    let actions: [String]
}

/// Action descriptor
struct NativeActionDescriptor: Sendable {
    let name: String
    let inputSchema: String?
    let outputSchema: String?
}

// MARK: - Native Plugin Action Wrapper

/// Wrapper for native plugin action execution
final class NativePluginActionWrapper: @unchecked Sendable {
    let pluginName: String
    let actionName: String
    let host: NativePluginHost
    let descriptor: NativeActionDescriptor

    init(pluginName: String, actionName: String, host: NativePluginHost, descriptor: NativeActionDescriptor) {
        self.pluginName = pluginName
        self.actionName = actionName
        self.host = host
        self.descriptor = descriptor
    }

    func handle(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        // Gather input from context
        var input: [String: any Sendable] = [:]

        // Add object value if bound (use multiple keys for compatibility)
        if let objValue = context.resolveAny(object.base) {
            input["data"] = objValue
            input["object"] = objValue  // Also include as "object" for backward compat
            input[object.base] = objValue  // Also include using original variable name
        }

        // Add specifiers if present
        if let specifier = object.specifiers.first {
            input["qualifier"] = specifier
        }

        // Add with clause arguments if present
        if let withArgs = context.resolveAny("_with_") as? [String: any Sendable] {
            input.merge(withArgs) { _, new in new }
        }
        if let exprArgs = context.resolveAny("_expression_") as? [String: any Sendable] {
            input.merge(exprArgs) { _, new in new }
        }

        // Execute native action
        let output = try host.execute(action: actionName, input: input)

        // Bind result
        context.bind(result.base, value: output)

        return output
    }
}

// MARK: - Native Plugin Errors

/// Errors for native plugin operations
public enum NativePluginError: Error, CustomStringConvertible {
    case libraryNotFound(String)
    case loadFailed(String, message: String)
    case notLoaded(String)
    case missingFunction(String, function: String)
    case executionFailed(String, message: String)

    public var description: String {
        switch self {
        case .libraryNotFound(let name):
            return "Native library not found for plugin '\(name)'"
        case .loadFailed(let name, let message):
            return "Failed to load native plugin '\(name)': \(message)"
        case .notLoaded(let name):
            return "Native plugin '\(name)' is not loaded"
        case .missingFunction(let name, let function):
            return "Native plugin '\(name)' missing required function '\(function)'"
        case .executionFailed(let name, let message):
            return "Native plugin '\(name)' execution failed: \(message)"
        }
    }
}
