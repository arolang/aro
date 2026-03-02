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
public final class PythonPluginHost: @unchecked Sendable {
    /// Plugin name
    public let pluginName: String

    /// Qualifier namespace (handler name from plugin.yaml)
    ///
    /// Used as the prefix when registering qualifiers (e.g., "stats.sort")
    /// and actions (e.g., "markdown.tohtml"). Nil when no explicit handler is set.
    private let qualifierNamespace: String?

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

    /// Qualifier registrations from this plugin
    private var qualifierRegistrations: [QualifierRegistration] = []

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

        // Parse qualifiers array
        var qualifierDescriptors: [PythonQualifierDescriptor] = []
        if let qualifierObjects = json["qualifiers"] as? [[String: Any]] {
            for qualifierObj in qualifierObjects {
                if let qualifierName = qualifierObj["name"] as? String {
                    // Parse input types
                    var inputTypes: Set<QualifierInputType> = []
                    if let typeStrings = qualifierObj["inputTypes"] as? [String] {
                        for typeStr in typeStrings {
                            if let inputType = QualifierInputType(rawValue: typeStr) {
                                inputTypes.insert(inputType)
                            }
                        }
                    }
                    // Default to all types if none specified
                    if inputTypes.isEmpty {
                        inputTypes = Set(QualifierInputType.allCases)
                    }

                    let description = qualifierObj["description"] as? String

                    qualifierDescriptors.append(PythonQualifierDescriptor(
                        name: qualifierName,
                        inputTypes: inputTypes,
                        description: description
                    ))
                }
            }
        }

        pluginInfo = PythonPluginInfo(
            name: json["name"] as? String ?? pluginName,
            version: json["version"] as? String ?? "1.0.0",
            actions: json["actions"] as? [String] ?? [],
            qualifiers: qualifierDescriptors
        )

        actions = Set(pluginInfo?.actions ?? [])

        // Register qualifiers with QualifierRegistry
        for descriptor in qualifierDescriptors {
            let registration = QualifierRegistration(
                qualifier: descriptor.name,
                inputTypes: descriptor.inputTypes,
                pluginName: pluginName,
                namespace: qualifierNamespace,
                description: descriptor.description,
                pluginHost: self
            )
            qualifierRegistrations.append(registration)
            QualifierRegistry.shared.register(registration)
        }
    }

    // MARK: - Execution

    /// Execute an action
    public func execute(action: String, input: [String: any Sendable]) throws -> any Sendable {
        // Serialize input
        let inputData = try JSONSerialization.data(withJSONObject: input)

        // Escape JSON for Python string (using base64 to avoid escaping issues)
        let base64Input = inputData.base64EncodedString()

        // Convert action name to snake_case for Python function
        let pythonFuncName = toSnakeCase(action)

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
        // Use semaphore to ensure all registrations complete before returning
        let semaphore = DispatchSemaphore(value: 0)
        var registrationCount = 0

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

            registrationCount += 1
            Task {
                await ActionRegistry.shared.registerDynamic(
                    verb: registeredVerb,
                    handler: wrapper.handle
                )
                semaphore.signal()
            }
        }

        // Wait for all registrations to complete
        for _ in 0..<registrationCount {
            semaphore.wait()
        }
    }

    // MARK: - Unload

    /// Unload the plugin
    public func unload() {
        // Unregister qualifiers
        QualifierRegistry.shared.unregisterPlugin(pluginName)
        qualifierRegistrations.removeAll()

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
        // Try common Python paths
        let candidates = [
            "/usr/bin/python3",
            "/usr/local/bin/python3",
            "/opt/homebrew/bin/python3",
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

// MARK: - PluginQualifierHost Conformance

extension PythonPluginHost: PluginQualifierHost {
    /// Execute a qualifier transformation via the Python plugin
    ///
    /// - Parameters:
    ///   - qualifier: The qualifier name (e.g., "pick-random")
    ///   - input: The input value to transform
    /// - Returns: The transformed value
    /// - Throws: QualifierError on failure
    public func executeQualifier(_ qualifier: String, input: any Sendable) throws -> any Sendable {
        // Create input JSON using QualifierInput
        let qualifierInput = QualifierInput(value: input)
        let encoder = JSONEncoder()
        let inputData = try encoder.encode(qualifierInput)
        let base64Input = inputData.base64EncodedString()

        // Convert qualifier name to snake_case for Python function
        let pythonQualifierName = toSnakeCase(qualifier)

        // Create execution script that calls aro_plugin_qualifier
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

        // Parse result as QualifierOutput
        guard let resultData = result.data(using: .utf8) else {
            throw QualifierError.executionFailed(
                qualifier: qualifier,
                message: "Invalid UTF-8 in plugin response"
            )
        }

        let decoder = JSONDecoder()
        let output = try decoder.decode(QualifierOutput.self, from: resultData)

        if let error = output.error {
            throw QualifierError.executionFailed(qualifier: qualifier, message: error)
        }

        guard let resultValue = output.result else {
            throw QualifierError.executionFailed(
                qualifier: qualifier,
                message: "Plugin returned neither result nor error"
            )
        }

        return resultValue.value
    }
}

// MARK: - Python Plugin Info

struct PythonPluginInfo: Sendable {
    let name: String
    let version: String
    let actions: [String]
    let qualifiers: [PythonQualifierDescriptor]

    init(name: String, version: String, actions: [String], qualifiers: [PythonQualifierDescriptor] = []) {
        self.name = name
        self.version = version
        self.actions = actions
        self.qualifiers = qualifiers
    }
}

/// Descriptor for a plugin-provided qualifier
struct PythonQualifierDescriptor: Sendable {
    let name: String
    let inputTypes: Set<QualifierInputType>
    let description: String?
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
