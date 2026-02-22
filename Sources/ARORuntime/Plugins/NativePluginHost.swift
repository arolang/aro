// ============================================================
// NativePluginHost.swift
// ARO Runtime - Native (C/C++/Rust) Plugin Host (ARO-0045)
// ============================================================

import Foundation

#if os(Windows)
import WinSDK
#endif

/// Write debug message to stderr (only when ARO_DEBUG is set)
private func debugPrint(_ message: String) {
    guard ProcessInfo.processInfo.environment["ARO_DEBUG"] != nil else { return }
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

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

    /// Qualifier namespace (handler name from plugin.yaml)
    ///
    /// Used as the prefix when registering qualifiers (e.g., "collections.reverse").
    /// Defaults to the plugin name if not specified in plugin.yaml.
    private let qualifierNamespace: String

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
    typealias QualifierFunc = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?

    private var executeFunc: ExecuteFunc?
    private var freeFunc: FreeFunc?
    private var qualifierFunc: QualifierFunc?

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
        self.qualifierNamespace = qualifierNamespace ?? pluginName
        self.pluginPath = pluginPath

        // Find and load the library
        try loadLibrary(config: config)

        // Load plugin info
        try loadPluginInfo()
    }

    // MARK: - Library Loading

    private func loadLibrary(config: UnifiedProvideEntry) throws {
        // Determine library path
        var libraryPath: URL?

        #if os(Windows)
        let ext = "dll"
        #elseif os(Linux)
        let ext = "so"
        #else
        let ext = "dylib"
        #endif

        if let output = config.build?.output {
            // Output path may be relative to plugin root or to the path
            // Try both: relative to pluginPath and relative to parent (plugin root)
            let pluginRoot = pluginPath.deletingLastPathComponent()
            let candidates = [
                pluginPath.appendingPathComponent(output),
                pluginRoot.appendingPathComponent(output),
            ]

            libraryPath = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
        } else {
            // Try common patterns
            let candidates = [
                pluginPath.appendingPathComponent("lib\(pluginName).\(ext)"),
                pluginPath.appendingPathComponent("\(pluginName).\(ext)"),
                pluginPath.appendingPathComponent("target/release/lib\(pluginName).\(ext)"),  // Rust
            ]

            libraryPath = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
        }

        // If library not found, try to compile it
        if libraryPath == nil {
            debugPrint("[NativePluginHost] No pre-built library found for \(pluginName), attempting compilation...")
            libraryPath = try compileNativePlugin(config: config, ext: ext)
        }

        guard let libraryPath = libraryPath else {
            debugPrint("[NativePluginHost] Failed to find or compile library for \(pluginName)")
            throw NativePluginError.libraryNotFound(pluginName)
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

    /// Compile native plugin from source if library doesn't exist
    private func compileNativePlugin(config: UnifiedProvideEntry, ext: String) throws -> URL? {
        // Check for Cargo.toml (Rust plugin) - check current path and parent
        let cargoTomlCandidates = [
            pluginPath.appendingPathComponent("Cargo.toml"),
            pluginPath.deletingLastPathComponent().appendingPathComponent("Cargo.toml"),
        ]

        if let cargoToml = cargoTomlCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            debugPrint("[NativePluginHost] Found Cargo.toml at \(cargoToml.path), compiling Rust plugin: \(pluginName)")
            let rustProjectDir = cargoToml.deletingLastPathComponent()
            return try compileRustPlugin(projectDir: rustProjectDir, ext: ext)
        }

        // Check for C source files
        let cFiles = findSourceFiles(withExtension: "c")
        if !cFiles.isEmpty {
            let outputPath = pluginPath.appendingPathComponent("\(pluginName).\(ext)")
            try compileCPlugin(sources: cFiles, output: outputPath)
            return outputPath
        }

        // Check for Swift source files
        let swiftFiles = findSourceFiles(withExtension: "swift")
        if !swiftFiles.isEmpty {
            debugPrint("[NativePluginHost] Found Swift files: \(swiftFiles.map { $0.lastPathComponent })")
            let outputPath = pluginPath.appendingPathComponent("lib\(pluginName).\(ext)")
            try compileSwiftPlugin(sources: swiftFiles, output: outputPath)
            return outputPath
        }

        debugPrint("[NativePluginHost] No compilable sources found for plugin: \(pluginName)")
        return nil
    }

    /// Compile Swift source files to a dynamic library
    private func compileSwiftPlugin(sources: [URL], output: URL) throws {
        // Find swiftc
        // Check SWIFTC environment variable first
        var swiftcPath: String? = nil
        if let swiftcEnv = ProcessInfo.processInfo.environment["SWIFTC"],
           !swiftcEnv.isEmpty,
           FileManager.default.isExecutableFile(atPath: swiftcEnv) {
            swiftcPath = swiftcEnv
        }

        // Try 'which swiftc' to find swiftc in PATH
        if swiftcPath == nil {
            let whichProcess = Process()
            whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            whichProcess.arguments = ["swiftc"]
            let pipe = Pipe()
            whichProcess.standardOutput = pipe
            whichProcess.standardError = FileHandle.nullDevice
            if let _ = try? whichProcess.run() {
                whichProcess.waitUntilExit()
                if whichProcess.terminationStatus == 0,
                   let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                       .trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty {
                    swiftcPath = path
                }
            }
        }

        // Fall back to common installation paths
        if swiftcPath == nil {
            let commonPaths = [
                "/usr/bin/swiftc",
                "/usr/share/swift/usr/bin/swiftc",  // CI Docker image path
                "/opt/swift/usr/bin/swiftc",
                "/opt/homebrew/bin/swiftc",
                "/usr/local/bin/swiftc",
            ]
            swiftcPath = commonPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        }

        guard let swiftcPath = swiftcPath else {
            throw NativePluginError.compilationFailed(pluginName, message: "swiftc not found")
        }

        debugPrint("[NativePluginHost] Compiling Swift plugin with \(swiftcPath)")

        var args: [String] = []
        args.append(contentsOf: sources.map { $0.path })
        args.append("-emit-library")
        args.append("-o")
        args.append(output.path)

        // Add optimization for release, debug info for debug
        #if DEBUG
        args.append("-g")
        #else
        args.append("-O")
        #endif

        let process = Process()
        process.executableURL = URL(fileURLWithPath: swiftcPath)
        process.arguments = args

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            debugPrint("[NativePluginHost] Swift compilation failed: \(errorMessage)")
            throw NativePluginError.compilationFailed(pluginName, message: "swiftc failed: \(errorMessage)")
        }

        debugPrint("[NativePluginHost] Swift plugin compiled to: \(output.path)")
    }

    /// Compile Rust plugin using cargo
    private func compileRustPlugin(projectDir: URL, ext: String) throws -> URL? {
        // Find cargo executable
        let cargoPaths = [
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.cargo/bin/cargo",
            "/root/.cargo/bin/cargo",
            "/opt/homebrew/bin/cargo",  // Homebrew on Apple Silicon
            "/usr/local/bin/cargo",     // Homebrew on Intel Mac / Linux
            "/usr/bin/cargo",
        ]

        debugPrint("[NativePluginHost] Looking for cargo in: \(cargoPaths)")

        guard let cargoPath = cargoPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            debugPrint("[NativePluginHost] Cargo not found!")
            throw NativePluginError.compilationFailed(pluginName, message: "Cargo not found. Install Rust to compile this plugin.")
        }

        debugPrint("[NativePluginHost] Using cargo at: \(cargoPath)")
        debugPrint("[NativePluginHost] Building in: \(projectDir.path)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cargoPath)
        process.arguments = ["build", "--release"]
        process.currentDirectoryURL = projectDir

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            debugPrint("[NativePluginHost] Cargo build failed: \(errorMessage)")
            throw NativePluginError.compilationFailed(pluginName, message: "Cargo build failed: \(errorMessage)")
        }

        debugPrint("[NativePluginHost] Cargo build succeeded")

        // Find the built library in target/release
        let targetDir = projectDir.appendingPathComponent("target/release")
        debugPrint("[NativePluginHost] Looking for library in: \(targetDir.path) with extension: \(ext)")

        // Look for library file (lib*.dylib on macOS, lib*.so on Linux)
        if let contents = try? FileManager.default.contentsOfDirectory(at: targetDir, includingPropertiesForKeys: nil) {
            debugPrint("[NativePluginHost] Files in target/release: \(contents.map { $0.lastPathComponent })")
            // Find lib*.dylib or lib*.so
            if let lib = contents.first(where: { $0.pathExtension == ext && $0.lastPathComponent.hasPrefix("lib") }) {
                debugPrint("[NativePluginHost] Found library: \(lib.path)")
                return lib
            }
        }

        debugPrint("[NativePluginHost] Library not found after cargo build")
        return nil
    }

    /// Find source files with a given extension in the plugin path
    private func findSourceFiles(withExtension ext: String) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: pluginPath,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents.filter { $0.pathExtension == ext }
    }

    /// Compile C source files to a dynamic library
    private func compileCPlugin(sources: [URL], output: URL) throws {
        // Find clang/gcc
        let compiler: String
        if FileManager.default.fileExists(atPath: "/usr/bin/clang") {
            compiler = "/usr/bin/clang"
        } else if FileManager.default.fileExists(atPath: "/usr/bin/gcc") {
            compiler = "/usr/bin/gcc"
        } else {
            throw NativePluginError.compilationFailed(pluginName, message: "C compiler not found")
        }

        var args = [compiler]
        args.append(contentsOf: sources.map { $0.path })
        args.append("-shared")
        args.append("-fPIC")
        args.append("-o")
        args.append(output.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw NativePluginError.compilationFailed(pluginName, message: errorMessage)
        }
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

        // Get qualifier function (optional - for plugins providing qualifiers)
        #if os(Windows)
        let qualifierSymbol = GetProcAddress(hmodule, "aro_plugin_qualifier")
        #else
        let qualifierSymbol = dlsym(handle, "aro_plugin_qualifier")
        #endif

        if let qualifierSymbol = qualifierSymbol {
            qualifierFunc = unsafeBitCast(qualifierSymbol, to: QualifierFunc.self)
            debugPrint("[NativePluginHost] Found aro_plugin_qualifier function in \(pluginName)")
        } else {
            debugPrint("[NativePluginHost] No aro_plugin_qualifier function in \(pluginName)")
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

        // Parse actions - supports both old format (string array) and new format (object array with verbs)
        var actionNames: [String] = []
        var verbsMap: [String: [String]] = [:]  // Maps action name to its verbs

        if let actionStrings = dict["actions"] as? [String] {
            // Old format: ["action1", "action2"]
            actionNames = actionStrings
        } else if let actionObjects = dict["actions"] as? [[String: Any]] {
            // New format: [{ "name": "ParseCSV", "verbs": ["parsecsv", "readcsv"], ... }]
            for actionObj in actionObjects {
                if let actionName = actionObj["name"] as? String {
                    actionNames.append(actionName)
                    // Store verbs for this action
                    if let verbs = actionObj["verbs"] as? [String] {
                        verbsMap[actionName] = verbs
                    }
                }
            }
        }

        // Parse qualifiers array
        var qualifierDescriptors: [NativeQualifierDescriptor] = []
        if let qualifierObjects = dict["qualifiers"] as? [[String: Any]] {
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

                    qualifierDescriptors.append(NativeQualifierDescriptor(
                        name: qualifierName,
                        inputTypes: inputTypes,
                        description: description
                    ))
                }
            }
        }

        pluginInfo = NativePluginInfo(
            name: name,
            version: version,
            language: language,
            actions: actionNames,
            verbsMap: verbsMap,
            qualifiers: qualifierDescriptors
        )

        // Create action descriptors
        for actionName in actionNames {
            actions[actionName] = NativeActionDescriptor(
                name: actionName,
                inputSchema: nil,
                outputSchema: nil
            )
        }

        // Register qualifiers with QualifierRegistry if plugin provides aro_plugin_qualifier
        debugPrint("[NativePluginHost] Plugin \(pluginName) has \(qualifierDescriptors.count) qualifiers declared, qualifierFunc=\(qualifierFunc != nil), namespace=\(qualifierNamespace)")
        if qualifierFunc != nil {
            for descriptor in qualifierDescriptors {
                debugPrint("[NativePluginHost] Registering qualifier: \(qualifierNamespace).\(descriptor.name)")
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
        // Use semaphore to ensure all registrations complete before returning
        let semaphore = DispatchSemaphore(value: 0)
        var registrationCount = 0

        for (name, descriptor) in actions {
            // Get verbs for this action (or use the action name itself as a fallback)
            let verbs: [String]
            if let mappedVerbs = pluginInfo?.verbsMap[name], !mappedVerbs.isEmpty {
                verbs = mappedVerbs
            } else {
                verbs = [name]
            }

            // Register with ActionRegistry under all verbs
            for verb in verbs {
                // Create a wrapper action that calls the native plugin with this verb
                let wrapper = NativePluginActionWrapper(
                    pluginName: pluginName,
                    actionName: name,
                    verb: verb,
                    host: self,
                    descriptor: descriptor
                )

                registrationCount += 1
                Task {
                    await ActionRegistry.shared.registerDynamic(
                        verb: verb,
                        handler: wrapper.handle
                    )
                    semaphore.signal()
                }
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
        guard let handle = libraryHandle else { return }

        // Unregister qualifiers
        QualifierRegistry.shared.unregisterPlugin(pluginName)
        qualifierRegistrations.removeAll()

        #if os(Windows)
        let hmodule = unsafeBitCast(handle, to: HMODULE.self)
        FreeLibrary(hmodule)
        #else
        dlclose(handle)
        #endif

        libraryHandle = nil
        executeFunc = nil
        freeFunc = nil
        qualifierFunc = nil
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

// MARK: - PluginQualifierHost Conformance

extension NativePluginHost: PluginQualifierHost {
    /// Execute a qualifier transformation via the native plugin
    ///
    /// - Parameters:
    ///   - qualifier: The qualifier name (e.g., "pick-random")
    ///   - input: The input value to transform
    /// - Returns: The transformed value
    /// - Throws: QualifierError on failure
    public func executeQualifier(_ qualifier: String, input: any Sendable) throws -> any Sendable {
        guard let qualifierFunc = qualifierFunc else {
            throw QualifierError.executionFailed(
                qualifier: qualifier,
                message: "Plugin '\(pluginName)' does not provide aro_plugin_qualifier function"
            )
        }

        // Create input JSON using QualifierInput
        let qualifierInput = QualifierInput(value: input)
        let encoder = JSONEncoder()
        let inputData = try encoder.encode(qualifierInput)
        let inputJSON = String(data: inputData, encoding: .utf8) ?? "{}"

        // Call the plugin
        let resultPtr = qualifier.withCString { qualifierCStr in
            inputJSON.withCString { inputCStr in
                qualifierFunc(qualifierCStr, inputCStr)
            }
        }

        defer {
            if let ptr = resultPtr {
                freeFunc?(ptr)
            }
        }

        guard let resultPtr = resultPtr else {
            throw QualifierError.executionFailed(
                qualifier: qualifier,
                message: "Plugin returned null"
            )
        }

        let resultJSON = String(cString: resultPtr)

        // Parse result as QualifierOutput
        guard let resultData = resultJSON.data(using: .utf8) else {
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

        guard let result = output.result else {
            throw QualifierError.executionFailed(
                qualifier: qualifier,
                message: "Plugin returned neither result nor error"
            )
        }

        return result.value
    }
}

// MARK: - Swift Types

/// Plugin info
struct NativePluginInfo: Sendable {
    let name: String
    let version: String
    let language: String
    let actions: [String]
    /// Maps action names to their verbs (e.g., "ParseCSV" -> ["parsecsv", "readcsv"])
    let verbsMap: [String: [String]]
    /// Qualifiers provided by this plugin
    let qualifiers: [NativeQualifierDescriptor]

    init(name: String, version: String, language: String, actions: [String], verbsMap: [String: [String]] = [:], qualifiers: [NativeQualifierDescriptor] = []) {
        self.name = name
        self.version = version
        self.language = language
        self.actions = actions
        self.verbsMap = verbsMap
        self.qualifiers = qualifiers
    }
}

/// Descriptor for a plugin-provided qualifier
struct NativeQualifierDescriptor: Sendable {
    let name: String
    let inputTypes: Set<QualifierInputType>
    let description: String?
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
    /// The verb used to invoke this action (may differ from actionName)
    let verb: String
    let host: NativePluginHost
    let descriptor: NativeActionDescriptor

    init(pluginName: String, actionName: String, verb: String, host: NativePluginHost, descriptor: NativeActionDescriptor) {
        self.pluginName = pluginName
        self.actionName = actionName
        self.verb = verb
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

        // Execute native action using the verb (plugins expect lowercase verb, not action name)
        let output = try host.execute(action: verb, input: input)

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
    case compilationFailed(String, message: String)

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
        case .compilationFailed(let name, let message):
            return "Failed to compile native plugin '\(name)': \(message)"
        }
    }
}
