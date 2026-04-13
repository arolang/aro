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
///
/// ## Required C Interface (ARO-0073)
/// ```c
/// // Get plugin info as JSON (name, version, actions[], qualifiers[], etc.)
/// char* aro_plugin_info(void);
///
/// // Free memory allocated by the plugin
/// void aro_plugin_free(char* ptr);
/// ```
///
/// ## Optional C Interface
/// ```c
/// // Execute an action with JSON input, return JSON output
/// char* aro_plugin_execute(const char* action, const char* input_json);
///
/// // Execute a qualifier transformation
/// char* aro_plugin_qualifier(const char* name, const char* input_json);
///
/// // One-time initialization (DB connections, model loading, etc.)
/// void aro_plugin_init(void);
///
/// // Cleanup on unload (close connections, flush buffers, etc.)
/// void aro_plugin_shutdown(void);
///
/// // Event handler (called when subscribed events fire)
/// void aro_plugin_on_event(const char* event_type, const char* data_json);
///
/// // System object read
/// char* aro_object_read(const char* identifier, const char* qualifier);
///
/// // System object write
/// char* aro_object_write(const char* identifier, const char* qualifier, const char* value_json);
///
/// // System object list
/// char* aro_object_list(const char* pattern);
/// ```
public final class NativePluginHost: @unchecked Sendable {
    /// Plugin name
    public let pluginName: String

    /// Qualifier namespace (handler name from plugin.yaml)
    ///
    /// Used as the prefix when registering qualifiers (e.g., "collections.reverse")
    /// and actions (e.g., "greeting.greet"). Nil when no explicit handler is set.
    private let qualifierNamespace: String?

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
    typealias InitFunc = @convention(c) () -> Void
    typealias ShutdownFunc = @convention(c) () -> Void
    typealias OnEventFunc = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Void
    typealias ObjectReadFunc = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
    typealias ObjectWriteFunc = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
    typealias ObjectListFunc = @convention(c) (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?

    private var executeFunc: ExecuteFunc?
    private var freeFunc: FreeFunc?
    private var qualifierFunc: QualifierFunc?
    private var initFunc: InitFunc?
    private var shutdownFunc: ShutdownFunc?
    private var onEventFunc: OnEventFunc?
    private var objectReadFunc: ObjectReadFunc?
    private var objectWriteFunc: ObjectWriteFunc?
    private var objectListFunc: ObjectListFunc?

    /// Event subscriptions from plugin info
    private var eventSubscriptions: [String] = []

    /// System objects declared by this plugin
    private var systemObjects: [SystemObjectDescriptor] = []

    /// Invoke callback: set by the runtime so plugins can call ARO feature sets
    private nonisolated(unsafe) static var invokeCallback: ((_ featureSet: String, _ inputJSON: String) -> String)?

    /// Qualifier registrations from this plugin
    private var qualifierRegistrations: [QualifierRegistration] = []

    /// Reused encoder/decoder — safe because NativePluginHost is @unchecked Sendable
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
            do {
                libraryPath = try compileNativePlugin(config: config, ext: ext)
            } catch let NativePluginError.compilationFailed(name, message) {
                throw ActionError.runtimeError("Plugin '\(name)' failed to compile: \(message)")
            }
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

        // Check for Package.swift (Swift Package plugin with dependencies)
        let packageSwift = pluginPath.appendingPathComponent("Package.swift")
        if FileManager.default.fileExists(atPath: packageSwift.path) {
            debugPrint("[NativePluginHost] Found Package.swift, compiling Swift package plugin: \(pluginName)")
            let outputPath = pluginPath.appendingPathComponent("lib\(pluginName).\(ext)")
            try compileSwiftPackagePlugin(packageDir: pluginPath, output: outputPath, ext: ext)
            return outputPath
        }

        // Check for C source files (in src/ or plugin root)
        var cFiles = findSourceFiles(withExtension: "c")
        let srcDir = pluginPath.appendingPathComponent("src")
        if cFiles.isEmpty, FileManager.default.fileExists(atPath: srcDir.path) {
            let srcContents = (try? FileManager.default.contentsOfDirectory(
                at: srcDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []
            cFiles = srcContents.filter { $0.pathExtension == "c" }
        }
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

        let errorMessage = "Library not found in '\(targetDir.path)' after successful cargo build"
        debugPrint("[NativePluginHost] \(errorMessage)")
        throw NativePluginError.compilationFailed(pluginName, message: errorMessage)
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

    /// Compile a Swift Package plugin using `swift build`
    private func compileSwiftPackagePlugin(packageDir: URL, output: URL, ext: String) throws {
        let swiftPath = findSwiftExecutable() ?? "/usr/bin/swift"

        debugPrint("[NativePluginHost] Building Swift package at \(packageDir.path)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: swiftPath)
        process.currentDirectoryURL = packageDir
        process.arguments = ["build", "-c", "release"]

        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw NativePluginError.compilationFailed(pluginName, message: errorMessage)
        }

        // Find the built dynamic library in .build/release/ or .build/<arch>/release/
        let buildDir = packageDir.appendingPathComponent(".build")
        if let builtLib = findBuiltLibrary(in: buildDir, name: pluginName, extension: ext) {
            if FileManager.default.fileExists(atPath: output.path) {
                try FileManager.default.removeItem(at: output)
            }
            try FileManager.default.copyItem(at: builtLib, to: output)
            debugPrint("[NativePluginHost] Swift package plugin compiled to: \(output.path)")
        } else {
            throw NativePluginError.compilationFailed(pluginName, message: "Built library not found in \(buildDir.path)")
        }
    }

    /// Find a built dynamic library by searching common Swift build output directories
    private func findBuiltLibrary(in buildDir: URL, name: String, extension ext: String) -> URL? {
        let fm = FileManager.default
        let libName = "lib\(name).\(ext)"

        // Check release/ directly
        let releasePath = buildDir.appendingPathComponent("release").appendingPathComponent(libName)
        if fm.fileExists(atPath: releasePath.path) { return releasePath }

        // Check arch-specific paths (e.g. .build/arm64-apple-macosx/release/)
        if let contents = try? fm.contentsOfDirectory(at: buildDir, includingPropertiesForKeys: nil) {
            for dir in contents {
                let candidate = dir.appendingPathComponent("release").appendingPathComponent(libName)
                if fm.fileExists(atPath: candidate.path) { return candidate }
            }
        }

        return nil
    }

    /// Find swift executable
    private func findSwiftExecutable() -> String? {
        let paths = [
            "/usr/bin/swift",
            "/usr/share/swift/usr/bin/swift",
            "/opt/swift/usr/bin/swift",
            "/opt/homebrew/bin/swift",
            "/usr/local/bin/swift",
        ]
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    /// Compile C source files to a dynamic library
    private func compileCPlugin(sources: [URL], output: URL) throws {
        // Find clang/gcc
        let compiler: String
        let clangCandidates = [
            "/usr/bin/clang",
            "/usr/share/swift/usr/bin/clang",
        ]
        if let found = clangCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            compiler = found
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

        // Add include paths for SDK headers (check include/ in plugin root and parent)
        let includeDir = pluginPath.appendingPathComponent("include")
        if FileManager.default.fileExists(atPath: includeDir.path) {
            args.insert(contentsOf: ["-I", includeDir.path], at: 1)
        }
        let parentIncludeDir = pluginPath.deletingLastPathComponent().appendingPathComponent("include")
        if FileManager.default.fileExists(atPath: parentIncludeDir.path) {
            args.insert(contentsOf: ["-I", parentIncludeDir.path], at: 1)
        }

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

    /// Resolve a symbol from the loaded library handle
    private func resolveSymbol(_ name: String) -> UnsafeMutableRawPointer? {
        guard let handle = libraryHandle else { return nil }
        #if os(Windows)
        let hmodule = unsafeBitCast(handle, to: HMODULE.self)
        return GetProcAddress(hmodule, name).map { UnsafeMutableRawPointer($0) }
        #else
        return dlsym(handle, name)
        #endif
    }

    private func loadPluginInfo() throws {
        guard libraryHandle != nil else {
            throw NativePluginError.notLoaded(pluginName)
        }

        // --- Required: aro_plugin_info ---
        guard let infoSymbol = resolveSymbol("aro_plugin_info") else {
            throw NativePluginError.missingFunction(pluginName, function: "aro_plugin_info")
        }
        let infoFunc = unsafeBitCast(infoSymbol, to: PluginInfoFunc.self)

        // --- Required: aro_plugin_free ---
        if let freeSymbol = resolveSymbol("aro_plugin_free") {
            freeFunc = unsafeBitCast(freeSymbol, to: FreeFunc.self)
        }

        // --- Optional: aro_plugin_execute (only needed if plugin provides actions/services) ---
        if let execSymbol = resolveSymbol("aro_plugin_execute") {
            executeFunc = unsafeBitCast(execSymbol, to: ExecuteFunc.self)
        }

        // --- Optional: aro_plugin_qualifier ---
        if let qualifierSymbol = resolveSymbol("aro_plugin_qualifier") {
            qualifierFunc = unsafeBitCast(qualifierSymbol, to: QualifierFunc.self)
            debugPrint("[NativePluginHost] Found aro_plugin_qualifier in \(pluginName)")
        }

        // --- Optional: aro_plugin_init (lifecycle) ---
        if let initSymbol = resolveSymbol("aro_plugin_init") {
            initFunc = unsafeBitCast(initSymbol, to: InitFunc.self)
        }

        // --- Optional: aro_plugin_shutdown (lifecycle) ---
        if let shutdownSymbol = resolveSymbol("aro_plugin_shutdown") {
            shutdownFunc = unsafeBitCast(shutdownSymbol, to: ShutdownFunc.self)
        }

        // --- Optional: aro_plugin_on_event ---
        if let eventSymbol = resolveSymbol("aro_plugin_on_event") {
            onEventFunc = unsafeBitCast(eventSymbol, to: OnEventFunc.self)
            debugPrint("[NativePluginHost] Found aro_plugin_on_event in \(pluginName)")
        }

        // --- Optional: system object functions ---
        if let readSymbol = resolveSymbol("aro_object_read") {
            objectReadFunc = unsafeBitCast(readSymbol, to: ObjectReadFunc.self)
        }
        if let writeSymbol = resolveSymbol("aro_object_write") {
            objectWriteFunc = unsafeBitCast(writeSymbol, to: ObjectWriteFunc.self)
        }
        if let listSymbol = resolveSymbol("aro_object_list") {
            objectListFunc = unsafeBitCast(listSymbol, to: ObjectListFunc.self)
        }

        // Load and parse plugin info JSON
        if let infoPtr = infoFunc() {
            defer { freeFunc?(infoPtr) }
            let infoJSON = String(cString: infoPtr)
            parsePluginInfo(json: infoJSON)
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

        // Call init lifecycle hook after everything is loaded
        initFunc?()
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
                    let acceptsParams = qualifierObj["accepts_parameters"] as? Bool ?? false

                    qualifierDescriptors.append(NativeQualifierDescriptor(
                        name: qualifierName,
                        inputTypes: inputTypes,
                        description: description,
                        acceptsParameters: acceptsParams
                    ))
                }
            }
        }

        // Parse services (declared in plugin info, routed through aro_plugin_execute)
        var serviceDescriptors: [NativeServiceDescriptor] = []
        if let serviceObjects = dict["services"] as? [[String: Any]] {
            for serviceObj in serviceObjects {
                if let serviceName = serviceObj["name"] as? String {
                    let methods = serviceObj["methods"] as? [String] ?? []
                    serviceDescriptors.append(NativeServiceDescriptor(
                        name: serviceName,
                        methods: methods
                    ))
                }
            }
        }

        // Parse event subscriptions
        if let events = dict["events"] as? [String: Any] {
            if let subscribes = events["subscribes"] as? [String] {
                eventSubscriptions = subscribes
            }
        }

        // Parse system objects
        var sysObjDescriptors: [SystemObjectDescriptor] = []
        if let sysObjects = dict["system_objects"] as? [[String: Any]] {
            for sysObj in sysObjects {
                if let identifier = sysObj["identifier"] as? String {
                    let capabilities = sysObj["capabilities"] as? [String] ?? []
                    let description = sysObj["description"] as? String
                    sysObjDescriptors.append(SystemObjectDescriptor(
                        identifier: identifier,
                        capabilities: Set(capabilities),
                        description: description
                    ))
                }
            }
        }
        systemObjects = sysObjDescriptors

        // Parse deprecations
        var deprecationList: [DeprecationDescriptor] = []
        if let deprecations = dict["deprecations"] as? [[String: Any]] {
            for dep in deprecations {
                if let feature = dep["feature"] as? String {
                    deprecationList.append(DeprecationDescriptor(
                        feature: feature,
                        message: dep["message"] as? String ?? "",
                        since: dep["since"] as? String,
                        removeIn: dep["remove_in"] as? String
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
            qualifiers: qualifierDescriptors,
            services: serviceDescriptors,
            deprecations: deprecationList
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
        debugPrint("[NativePluginHost] Plugin \(pluginName) has \(qualifierDescriptors.count) qualifiers declared, qualifierFunc=\(qualifierFunc != nil), namespace=\(qualifierNamespace ?? "none")")
        if qualifierFunc != nil {
            for descriptor in qualifierDescriptors {
                debugPrint("[NativePluginHost] Registering qualifier: \(qualifierNamespace ?? pluginName).\(descriptor.name)")
                let registration = QualifierRegistration(
                    qualifier: descriptor.name,
                    inputTypes: descriptor.inputTypes,
                    pluginName: pluginName,
                    namespace: qualifierNamespace,
                    description: descriptor.description,
                    acceptsParameters: descriptor.acceptsParameters,
                    pluginHost: self
                )
                qualifierRegistrations.append(registration)
                QualifierRegistry.shared.register(registration)
            }
        }

        // Subscribe to domain events if plugin has on_event function
        if onEventFunc != nil && !eventSubscriptions.isEmpty {
            debugPrint("[NativePluginHost] Subscribing \(pluginName) to events: \(eventSubscriptions)")
            EventBus.shared.subscribe(to: DomainEvent.self) { [weak self] event in
                guard let self = self else { return }
                // Check if this event matches any of the plugin's subscriptions
                let matches = self.eventSubscriptions.contains { pattern in
                    if pattern == "*" { return true }
                    if pattern.hasSuffix("*") {
                        let prefix = String(pattern.dropLast())
                        return event.domainEventType.hasPrefix(prefix)
                    }
                    return pattern == event.domainEventType
                }
                if matches {
                    self.deliverEvent(type: event.domainEventType, data: event.payload)
                }
            }
        }

        // Log deprecation warnings
        for dep in deprecationList {
            debugPrint("[NativePluginHost] ⚠ Deprecation in \(pluginName): \(dep.feature) - \(dep.message)")
        }
    }

    // MARK: - Execution

    /// Execute an action
    public func execute(action: String, input: [String: any Sendable]) throws -> any Sendable {
        guard let execFunc = executeFunc else {
            throw NativePluginError.missingFunction(pluginName, function: "aro_plugin_execute")
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

            // Register with ActionRegistry under all verbs.
            // When a qualifier namespace is set (via handle: or handler:), register as both
            // "namespace.verb" (for Namespace.Verb style ARO code) and the plain verb.
            for verb in verbs {
                var registeredVerbs: [String] = [verb]
                if let ns = qualifierNamespace {
                    registeredVerbs.append("\(ns).\(verb)")
                }

                for registeredVerb in registeredVerbs {
                    let wrapper = NativePluginActionWrapper(
                        pluginName: pluginName,
                        actionName: name,
                        verb: registeredVerb,
                        pluginVerb: verb,
                        host: self,
                        descriptor: descriptor
                    )

                    registrationCount += 1
                    Task {
                        await ActionRegistry.shared.registerDynamic(
                            verb: registeredVerb,
                            handler: wrapper.handle,
                            pluginName: pluginName
                        )
                        semaphore.signal()
                    }
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

        // Call shutdown lifecycle hook before unloading
        shutdownFunc?()

        // Unregister dynamic actions from ActionRegistry
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await ActionRegistry.shared.unregisterPlugin(pluginName)
            semaphore.signal()
        }
        semaphore.wait()

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
        initFunc = nil
        shutdownFunc = nil
        onEventFunc = nil
        objectReadFunc = nil
        objectWriteFunc = nil
        objectListFunc = nil
        eventSubscriptions.removeAll()
        systemObjects.removeAll()
        actions.removeAll()
    }

    // MARK: - Event Delivery (ARO-0073)

    /// Deliver an event to this plugin
    public func deliverEvent(type: String, data: [String: any Sendable]) {
        guard let onEventFunc = onEventFunc else { return }

        var dataJSON = "{}"
        if let jsonData = try? JSONSerialization.data(withJSONObject: data),
           let json = String(data: jsonData, encoding: .utf8) {
            dataJSON = json
        }

        type.withCString { typeCStr in
            dataJSON.withCString { dataCStr in
                onEventFunc(typeCStr, dataCStr)
            }
        }
    }

    /// Check if plugin has event subscriptions
    public var hasEventSubscriptions: Bool { !eventSubscriptions.isEmpty }

    /// Get event types this plugin subscribes to
    public var subscribedEventTypes: [String] { eventSubscriptions }

    // MARK: - System Objects (ARO-0073)

    /// Read from a system object
    public func objectRead(identifier: String, qualifier: String) throws -> any Sendable {
        guard let readFunc = objectReadFunc else {
            throw NativePluginError.missingFunction(pluginName, function: "aro_object_read")
        }

        let resultPtr = identifier.withCString { idCStr in
            qualifier.withCString { qualCStr in
                readFunc(idCStr, qualCStr)
            }
        }

        defer { if let ptr = resultPtr { freeFunc?(ptr) } }

        guard let resultPtr = resultPtr else {
            return [String: any Sendable]()
        }

        let resultJSON = String(cString: resultPtr)
        guard let data = resultJSON.data(using: .utf8),
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return resultJSON
        }
        return convertToSendable(result)
    }

    /// Write to a system object
    public func objectWrite(identifier: String, qualifier: String, value: any Sendable) throws -> any Sendable {
        guard let writeFunc = objectWriteFunc else {
            throw NativePluginError.missingFunction(pluginName, function: "aro_object_write")
        }

        var valueJSON = "{}"
        if let dict = value as? [String: any Sendable] {
            if let data = try? JSONSerialization.data(withJSONObject: dict),
               let json = String(data: data, encoding: .utf8) {
                valueJSON = json
            }
        } else {
            valueJSON = "\(value)"
        }

        let resultPtr = identifier.withCString { idCStr in
            qualifier.withCString { qualCStr in
                valueJSON.withCString { valCStr in
                    writeFunc(idCStr, qualCStr, valCStr)
                }
            }
        }

        defer { if let ptr = resultPtr { freeFunc?(ptr) } }

        guard let resultPtr = resultPtr else {
            return [String: any Sendable]()
        }

        let resultJSON = String(cString: resultPtr)
        guard let data = resultJSON.data(using: .utf8),
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return resultJSON
        }
        return convertToSendable(result)
    }

    /// List from a system object
    public func objectList(pattern: String) throws -> any Sendable {
        guard let listFunc = objectListFunc else {
            throw NativePluginError.missingFunction(pluginName, function: "aro_object_list")
        }

        let resultPtr = pattern.withCString { patCStr in
            listFunc(patCStr)
        }

        defer { if let ptr = resultPtr { freeFunc?(ptr) } }

        guard let resultPtr = resultPtr else {
            return [any Sendable]()
        }

        let resultJSON = String(cString: resultPtr)
        guard let data = resultJSON.data(using: .utf8),
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return resultJSON
        }
        return convertToSendable(result)
    }

    /// Get system object descriptors
    public var systemObjectDescriptors: [SystemObjectDescriptor] { systemObjects }

    /// Check if plugin provides a specific system object
    public func providesSystemObject(_ identifier: String) -> Bool {
        systemObjects.contains { $0.identifier == identifier }
    }

    // MARK: - Plugin Invoke Callback (ARO-0073)

    /// Set the invoke callback so plugins can call ARO feature sets
    ///
    /// This should be called by the runtime after the execution engine is ready.
    /// The callback takes a feature set name and input JSON string, returns result JSON.
    public static func setInvokeCallback(_ callback: @escaping (_ featureSet: String, _ inputJSON: String) -> String) {
        invokeCallback = callback
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
    /// Execute a qualifier transformation via the native plugin (ARO-0073: with parameters)
    ///
    /// - Parameters:
    ///   - qualifier: The qualifier name (e.g., "pick-random")
    ///   - input: The input value to transform
    ///   - withParams: Optional parameters from the `with` clause
    /// - Returns: The transformed value
    /// - Throws: QualifierError on failure
    public func executeQualifier(_ qualifier: String, input: any Sendable, withParams: [String: any Sendable]? = nil) throws -> any Sendable {
        guard let qualifierFunc = qualifierFunc else {
            throw QualifierError.executionFailed(
                qualifier: qualifier,
                message: "Plugin '\(pluginName)' does not provide aro_plugin_qualifier function"
            )
        }

        // Create input JSON using QualifierInput (ARO-0073: includes _with params)
        let qualifierInput = QualifierInput(value: input, withParams: withParams)
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
    /// Services provided by this plugin (routed through aro_plugin_execute)
    let services: [NativeServiceDescriptor]
    /// Deprecated features
    let deprecations: [DeprecationDescriptor]

    init(name: String, version: String, language: String, actions: [String], verbsMap: [String: [String]] = [:], qualifiers: [NativeQualifierDescriptor] = [], services: [NativeServiceDescriptor] = [], deprecations: [DeprecationDescriptor] = []) {
        self.name = name
        self.version = version
        self.language = language
        self.actions = actions
        self.verbsMap = verbsMap
        self.qualifiers = qualifiers
        self.services = services
        self.deprecations = deprecations
    }
}

/// Descriptor for a plugin-provided qualifier
struct NativeQualifierDescriptor: Sendable {
    let name: String
    let inputTypes: Set<QualifierInputType>
    let description: String?
    let acceptsParameters: Bool

    init(name: String, inputTypes: Set<QualifierInputType>, description: String? = nil, acceptsParameters: Bool = false) {
        self.name = name
        self.inputTypes = inputTypes
        self.description = description
        self.acceptsParameters = acceptsParameters
    }
}

/// Action descriptor
struct NativeActionDescriptor: Sendable {
    let name: String
    let inputSchema: String?
    let outputSchema: String?
}

/// Service descriptor (ARO-0073)
struct NativeServiceDescriptor: Sendable {
    let name: String
    let methods: [String]
}

/// System object descriptor (ARO-0073)
public struct SystemObjectDescriptor: Sendable {
    public let identifier: String
    public let capabilities: Set<String>
    public let description: String?
}

/// Deprecation descriptor (ARO-0073)
struct DeprecationDescriptor: Sendable {
    let feature: String
    let message: String
    let since: String?
    let removeIn: String?
}

// MARK: - Native Plugin Action Wrapper

/// Wrapper for native plugin action execution
final class NativePluginActionWrapper: @unchecked Sendable {
    let pluginName: String
    let actionName: String
    /// The verb used to invoke this action (may differ from actionName)
    let verb: String
    /// The plain verb passed to the plugin's aro_plugin_execute (no namespace prefix, lowercase).
    /// Plugins declare verbs like "greet" / "hash" and handle them in aro_plugin_execute.
    /// The registered verb (verb) may carry a namespace prefix (e.g., "greeting.greet").
    let pluginVerb: String
    let host: NativePluginHost
    let descriptor: NativeActionDescriptor

    init(pluginName: String, actionName: String, verb: String, pluginVerb: String, host: NativePluginHost, descriptor: NativeActionDescriptor) {
        self.pluginName = pluginName
        self.actionName = actionName
        self.verb = verb
        self.pluginVerb = pluginVerb
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
            input["object"] = objValue
            input[object.base] = objValue
        }

        // Add specifiers if present
        if let specifier = object.specifiers.first {
            input["qualifier"] = specifier
        }

        // ARO-0073: Add result and source descriptors
        input["result"] = [
            "base": result.base,
            "specifiers": result.specifiers,
        ] as [String: any Sendable]

        input["source"] = [
            "base": object.base,
            "specifiers": object.specifiers,
        ] as [String: any Sendable]

        // ARO-0073: Add preposition
        input["preposition"] = String(describing: object.preposition)

        // ARO-0073: Add execution context
        var contextInfo: [String: any Sendable] = [:]
        if let reqId = context.resolveAny("_requestId_") {
            contextInfo["requestId"] = reqId
        }
        if let fsName = context.resolveAny("_featureSet_") {
            contextInfo["featureSet"] = fsName
        }
        if let ba = context.resolveAny("_businessActivity_") {
            contextInfo["businessActivity"] = ba
        }
        if !contextInfo.isEmpty {
            input["_context"] = contextInfo
        }

        // ARO-0073: Add with-clause arguments as nested _with key
        if let withArgs = context.resolveAny("_with_") as? [String: any Sendable] {
            input["_with"] = withArgs
        }
        // Also merge expression args at top level for backward compat
        if let exprArgs = context.resolveAny("_expression_") as? [String: any Sendable] {
            input.merge(exprArgs) { _, new in new }
        }

        // Execute native action
        let output = try host.execute(action: pluginVerb, input: input)

        // ARO-0073: Parse _events from response and publish to EventBus
        if let outputDict = output as? [String: any Sendable],
           let events = outputDict["_events"] as? [[String: any Sendable]] {
            for event in events {
                if let eventType = event["type"] as? String {
                    let eventData = event["data"] as? [String: any Sendable] ?? [:]
                    EventBus.shared.publish(DomainEvent(eventType: eventType, payload: eventData))
                }
            }
            // Strip _events from the result before binding
            var cleanOutput = outputDict
            cleanOutput.removeValue(forKey: "_events")
            context.bind(result.base, value: cleanOutput)
            return cleanOutput
        }

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
