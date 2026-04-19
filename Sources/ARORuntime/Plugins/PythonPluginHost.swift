// ============================================================
// PythonPluginHost.swift
// ARO Runtime - Python Plugin Host (ARO-0045)
// ============================================================

import Foundation

// MARK: - Python Plugin Host

/// Host for Python plugins
///
/// Python plugins are loaded dynamically and communicate through a JSON interface.
/// This implementation uses a subprocess approach for isolation and simplicity.
///
/// ## Python Plugin Structure
/// ```python
/// # plugin.py
///
/// def aro_plugin_info():
///     return {
///         "name": "my-plugin",
///         "version": "1.0.0",
///         "actions": ["analyze", "transform"]
///     }
///
/// def aro_action_analyze(input_json):
///     import json
///     params = json.loads(input_json)
///     result = {"analyzed": True}
///     return json.dumps(result)
/// ```
///
/// Note: For production use with better performance, consider using PythonKit
/// for direct Python embedding. This subprocess approach is simpler and more
/// portable but has higher overhead per call.
public final class PythonPluginHost: @unchecked Sendable, PluginHostProtocol {
    /// Plugin name
    public let pluginName: String

    /// Qualifier namespace (handler name from plugin.yaml)
    ///
    /// Used as the prefix when registering qualifiers (e.g., "stats.sort")
    /// and actions (e.g., "markdown.tohtml"). Nil when no explicit handler is set.
    public let qualifierNamespace: String?

    /// Path to the plugin
    public let pluginPath: URL

    /// Main Python file
    private let mainFile: URL

    /// Python executable
    private let pythonPath: String

    /// Module name (derived from main file)
    private let moduleName: String

    /// Plugin info
    private var pluginInfo: PythonPluginInfo?

    /// Registered actions
    private var actions: Set<String> = []

    /// Maps verb → canonical action name for structured action descriptors (SDK format)
    private var verbToActionName: [String: String] = [:]

    /// Qualifier registrations from this plugin
    public var qualifierRegistrations: [QualifierRegistration] = []

    /// Reused encoder/decoder — safe because PythonPluginHost is @unchecked Sendable
    /// and qualifier calls are serialised through the plugin host.
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Initialization

    /// Initialize with a plugin path and configuration
    public init(
        pluginPath: URL,
        pluginName: String,
        config: UnifiedProvideEntry,
        qualifierNamespace: String? = nil
    ) throws {
        self.pluginName = pluginName
        self.qualifierNamespace = qualifierNamespace
        self.pluginPath = pluginPath

        // Find Python executable
        pythonPath = PythonPluginHost.findPython()

        // Find main Python file
        let candidates = [
            pluginPath.appendingPathComponent("plugin.py"),
            pluginPath.appendingPathComponent("\(pluginName.replacingOccurrences(of: "-", with: "_")).py"),
            pluginPath.appendingPathComponent("__init__.py"),
            pluginPath.appendingPathComponent("main.py"),
        ]

        guard let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw PythonPluginError.mainFileNotFound(pluginName)
        }
        mainFile = found
        moduleName = mainFile.deletingPathExtension().lastPathComponent

        // Load plugin info
        try loadPluginInfo()
    }

    // MARK: - Plugin Info

    private func loadPluginInfo() throws {
        // Create a Python script to get plugin info
        let script = """
        import sys
        import json
        sys.path.insert(0, '\(pluginPath.path.replacingOccurrences(of: "'", with: "\\'"))')
        try:
            from \(moduleName) import aro_plugin_info
            info = aro_plugin_info()
            print(json.dumps(info))
        except ImportError:
            # No info function, provide defaults
            print(json.dumps({"name": "\(pluginName)", "version": "1.0.0", "actions": []}))
        except Exception as e:
            print(json.dumps({"error": str(e)}))
        """

        let result = try runPython(script: script)

        guard let data = result.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PythonPluginError.invalidInfo(pluginName)
        }

        if let error = json["error"] as? String {
            throw PythonPluginError.loadFailed(pluginName, message: error)
        }

        // Parse qualifiers and actions using shared helpers
        let qualifierDescriptors = Self.parseQualifierDescriptors(from: json)

        // Parse actions: supports both flat [String] (legacy) and structured [[String: Any]] (SDK)
        // Python uses a flattened verb list with verb→action mapping for SDK format
        var parsedActions: [String] = []
        let parsedActionList = Self.parseActionList(from: json)
        if !parsedActionList.verbsMap.isEmpty {
            // SDK format: flatten verbs and build reverse mapping
            for name in parsedActionList.names {
                if let verbs = parsedActionList.verbsMap[name], !verbs.isEmpty {
                    parsedActions.append(contentsOf: verbs)
                    for verb in verbs {
                        verbToActionName[verb] = name
                    }
                } else {
                    parsedActions.append(name)
                }
            }
        } else {
            parsedActions = parsedActionList.names
        }

        pluginInfo = PythonPluginInfo(
            name: json["name"] as? String ?? pluginName,
            version: json["version"] as? String ?? "1.0.0",
            actions: parsedActions,
            qualifiers: qualifierDescriptors
        )

        actions = Set(pluginInfo?.actions ?? [])

        // Register qualifiers using shared helper
        registerQualifiers(qualifierDescriptors)
    }

    // MARK: - Execution

    /// Execute an action
    public func execute(action: String, input: [String: any Sendable]) throws -> any Sendable {
        // Serialize input
        let inputData = try JSONSerialization.data(withJSONObject: input)

        // Escape JSON for Python string (using base64 to avoid escaping issues)
        let base64Input = inputData.base64EncodedString()

        // Resolve verb → canonical action name (SDK format), then convert to snake_case
        let resolvedAction = verbToActionName[action] ?? action
        let pythonFuncName = toSnakeCase(resolvedAction)

        // Create execution script
        let script = """
        import sys
        import json
        import base64
        sys.path.insert(0, '\(pluginPath.path.replacingOccurrences(of: "'", with: "\\'"))')
        try:
            from \(moduleName) import aro_action_\(pythonFuncName)
            input_json = base64.b64decode('\(base64Input)').decode('utf-8')
            result = aro_action_\(pythonFuncName)(input_json)
            print(result)
        except Exception as e:
            import traceback
            print(json.dumps({"error": str(e), "traceback": traceback.format_exc()}))
        """

        let result = try runPython(script: script)

        // Parse result
        guard let data = result.data(using: .utf8) else {
            return result
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? String {
                throw PythonPluginError.executionFailed(pluginName, action: action, message: error)
            }
            return convertToSendable(json)
        }

        if let json = try? JSONSerialization.jsonObject(with: data) {
            return convertToSendable(json)
        }

        return result
    }

    // MARK: - Action Registration

    /// Register actions with the global action registry
    public func registerActions() {
        var entries: [(verb: String, pluginName: String, handler: @Sendable (ResultDescriptor, ObjectDescriptor, any ExecutionContext) async throws -> any Sendable)] = []

        for action in actions {
            // When a handler namespace is set, register only as "handler.verb".
            // Without a handler, register only the plain verb.
            let registeredVerb: String
            if let ns = qualifierNamespace {
                registeredVerb = "\(ns).\(action)"
            } else {
                registeredVerb = action
            }

            let wrapper = PythonPluginActionWrapper(
                pluginName: pluginName,
                actionName: action,
                host: self
            )
            entries.append((verb: registeredVerb, pluginName: pluginName, handler: wrapper.handle))
        }

        syncRegisterActions(entries)
    }

    // MARK: - Unload

    /// Unload the plugin
    public func unload() {
        // Unregister from ActionRegistry and QualifierRegistry (shared logic)
        unloadFromRegistries()

        actions.removeAll()
        pluginInfo = nil
    }

    // MARK: - Python Execution

    private func runPython(script: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = ["-c", script]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
            throw PythonPluginError.executionFailed(pluginName, action: "script", message: errorOutput)
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Python Discovery

    private static func findPython() -> String {
        // First, resolve python3 via which — picks up the user's preferred Python
        // (e.g., Homebrew, pyenv, framework install) which likely has the ARO SDK
        let whichProcess = Process()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = ["python3"]
        let pipe = Pipe()
        whichProcess.standardOutput = pipe
        whichProcess.standardError = FileHandle.nullDevice
        if let _ = try? whichProcess.run() {
            whichProcess.waitUntilExit()
            if whichProcess.terminationStatus == 0,
               let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                   .trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty,
               FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Try common Python paths as fallback
        let candidates = [
            "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
            "/usr/bin/python",
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Fall back to PATH
        return "python3"
    }

    // MARK: - Helpers

    /// Convert action name to Python function name (snake_case)
    /// Handles both kebab-case (to-html) and camelCase (toHtml)
    private func toSnakeCase(_ name: String) -> String {
        var result = ""
        for (i, char) in name.enumerated() {
            if char == "-" {
                result.append("_")
            } else if char.isUppercase {
                // Add underscore before uppercase letter (except at start)
                if i > 0 {
                    result.append("_")
                }
                result.append(char.lowercased())
            } else {
                result.append(char)
            }
        }
        return result
    }

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

// MARK: - Qualifier Execution

extension PythonPluginHost {
    /// Execute a qualifier transformation via the Python plugin
    public func executeQualifier(_ qualifier: String, input: any Sendable, withParams: [String: any Sendable]? = nil) throws -> any Sendable {
        // Create input JSON using QualifierInput (ARO-0073: includes _with params)
        let qualifierInput = QualifierInput(value: input, withParams: withParams)
        let inputData = try encoder.encode(qualifierInput)
        let base64Input = inputData.base64EncodedString()

        // Convert qualifier name to snake_case for Python function
        let pythonQualifierName = toSnakeCase(qualifier)

        // Language-specific: call via Python subprocess
        let script = """
        import sys
        import json
        import base64
        sys.path.insert(0, '\(pluginPath.path.replacingOccurrences(of: "'", with: "\\'"))')
        try:
            from \(moduleName) import aro_plugin_qualifier
            input_json = base64.b64decode('\(base64Input)').decode('utf-8')
            result = aro_plugin_qualifier('\(pythonQualifierName)', input_json)
            print(result)
        except ImportError:
            print(json.dumps({"error": "Plugin does not provide aro_plugin_qualifier function"}))
        except Exception as e:
            import traceback
            print(json.dumps({"error": str(e), "traceback": traceback.format_exc()}))
        """

        let result = try runPython(script: script)

        // Shared result decoding
        guard let resultData = result.data(using: .utf8) else {
            throw QualifierError.executionFailed(
                qualifier: qualifier,
                message: "Invalid UTF-8 in plugin response"
            )
        }

        return try decodeQualifierResult(from: resultData, qualifier: qualifier, decoder: decoder)
    }
}

// MARK: - Python Plugin Info

struct PythonPluginInfo: Sendable {
    let name: String
    let version: String
    let actions: [String]
    let qualifiers: [PluginQualifierDescriptor]

    init(name: String, version: String, actions: [String], qualifiers: [PluginQualifierDescriptor] = []) {
        self.name = name
        self.version = version
        self.actions = actions
        self.qualifiers = qualifiers
    }
}

// MARK: - Python Plugin Action Wrapper

/// Wrapper for Python plugin action execution
final class PythonPluginActionWrapper: @unchecked Sendable {
    let pluginName: String
    let actionName: String
    let host: PythonPluginHost

    init(pluginName: String, actionName: String, host: PythonPluginHost) {
        self.pluginName = pluginName
        self.actionName = actionName
        self.host = host
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

        // Execute Python action
        let output = try host.execute(action: actionName, input: input)

        // Bind result
        context.bind(result.base, value: output)

        return output
    }
}

// MARK: - Python Plugin Errors

/// Errors for Python plugin operations
public enum PythonPluginError: Error, CustomStringConvertible {
    case mainFileNotFound(String)
    case invalidInfo(String)
    case loadFailed(String, message: String)
    case executionFailed(String, action: String, message: String)
    case pythonNotFound

    public var description: String {
        switch self {
        case .mainFileNotFound(let name):
            return "Python main file not found for plugin '\(name)'"
        case .invalidInfo(let name):
            return "Invalid plugin info from Python plugin '\(name)'"
        case .loadFailed(let name, let message):
            return "Failed to load Python plugin '\(name)': \(message)"
        case .executionFailed(let name, let action, let message):
            return "Python plugin '\(name)' action '\(action)' failed: \(message)"
        case .pythonNotFound:
            return "Python interpreter not found"
        }
    }
}
