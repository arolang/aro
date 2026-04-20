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

// MARK: - CPluginString (RAII wrapper)

/// RAII wrapper for C-allocated strings returned by plugin functions.
///
/// Ensures the string is freed when the wrapper goes out of scope, preventing
/// memory leaks even when exceptions are thrown between allocation and cleanup.
///
/// ```swift
/// let managed = CPluginString(ptr: resultPtr, freeFunc: freeFunc)
/// defer { managed.release() }
/// let json = managed.string
/// ```
struct CPluginString {
    let ptr: UnsafeMutablePointer<CChar>
    private let freeFunc: ((UnsafeMutablePointer<CChar>?) -> Void)?

    /// The C string as a Swift `String`.
    var string: String { String(cString: ptr) }

    init(ptr: UnsafeMutablePointer<CChar>, freeFunc: ((UnsafeMutablePointer<CChar>?) -> Void)?) {
        self.ptr = ptr
        self.freeFunc = freeFunc
    }

    /// Free the underlying C memory. Safe to call multiple times (no-op after first).
    func release() {
        freeFunc?(ptr)
    }
}

// MARK: - Native Plugin Host

/// Host for native plugins written in C, C++, or Rust
///
/// Native plugins communicate through a C ABI interface using JSON strings.
///
/// ## Memory Ownership
///
/// All `char*` pointers returned by plugin functions are **owned by the caller**.
/// The caller MUST free them via `aro_plugin_free()`. Conversely, pointers passed
/// INTO plugin functions (e.g., `action`, `input_json`) are borrowed — the plugin
/// must NOT free them.
///
/// The runtime uses `defer { freeFunc?(ptr) }` or `CPluginString` to guarantee
/// cleanup even when exceptions occur between allocation and use.
///
/// ## Required C Interface (ARO-0073)
/// ```c
/// // Get plugin info as JSON (name, version, actions[], qualifiers[], etc.)
/// // Ownership: caller must free the returned pointer via aro_plugin_free().
/// char* aro_plugin_info(void);
///
/// // Free memory allocated by the plugin (required for all returned char* pointers)
/// void aro_plugin_free(char* ptr);
/// ```
///
/// ## Optional C Interface
/// ```c
/// // Execute an action with JSON input, return JSON output
/// // Ownership: caller must free the returned pointer via aro_plugin_free().
/// char* aro_plugin_execute(const char* action, const char* input_json);
///
/// // Execute a qualifier transformation
/// // Ownership: caller must free the returned pointer via aro_plugin_free().
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
/// // Ownership: caller must free the returned pointer via aro_plugin_free().
/// char* aro_object_read(const char* identifier, const char* qualifier);
///
/// // System object write
/// // Ownership: caller must free the returned pointer via aro_plugin_free().
/// char* aro_object_write(const char* identifier, const char* qualifier, const char* value_json);
///
/// // System object list
/// // Ownership: caller must free the returned pointer via aro_plugin_free().
/// char* aro_object_list(const char* pattern);
/// ```
public final class NativePluginHost: @unchecked Sendable, PluginHostProtocol {
    /// Plugin name
    public let pluginName: String

    /// Qualifier namespace (handler name from plugin.yaml)
    ///
    /// Used as the prefix when registering qualifiers (e.g., "collections.reverse")
    /// and actions (e.g., "greeting.greet"). Nil when no explicit handler is set.
    public let qualifierNamespace: String?

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
    typealias InvokeFunc = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
    typealias SetInvokeFunc = @convention(c) (InvokeFunc?) -> Void

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
    public var qualifierRegistrations: [QualifierRegistration] = []

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

    /// Initialize from statically-linked function pointers (no dlopen).
    ///
    /// Used by compiled binaries where plugin object files are linked directly
    /// into the executable. The function pointers point to renamed symbols
    /// (e.g., `aro_static_GreetingService__aro_plugin_info`).
    public init(
        pluginName: String,
        qualifierNamespace: String?,
        infoFunc: UnsafeRawPointer?,
        executeFunc: UnsafeRawPointer?,
        freeFunc: UnsafeRawPointer?,
        qualifierFunc: UnsafeRawPointer?,
        initFuncPtr: UnsafeRawPointer?,
        shutdownFunc: UnsafeRawPointer?
    ) throws {
        self.pluginName = pluginName
        self.qualifierNamespace = qualifierNamespace
        self.pluginPath = URL(fileURLWithPath: "/static/\(pluginName)")
        self.libraryHandle = nil  // No dynamic library

        // Cast raw pointers to typed function pointers
        if let ptr = executeFunc {
            self.executeFunc = unsafeBitCast(ptr, to: ExecuteFunc.self)
        }
        if let ptr = freeFunc {
            self.freeFunc = unsafeBitCast(ptr, to: FreeFunc.self)
        }
        if let ptr = qualifierFunc {
            self.qualifierFunc = unsafeBitCast(ptr, to: QualifierFunc.self)
        }
        if let ptr = initFuncPtr {
            self.initFunc = unsafeBitCast(ptr, to: InitFunc.self)
        }
        if let ptr = shutdownFunc {
            self.shutdownFunc = unsafeBitCast(ptr, to: ShutdownFunc.self)
        }

        // Call aro_plugin_register equivalent (init lifecycle) if present
        self.initFunc?()

        // Load plugin info from the info function
        guard let infoPtr = infoFunc else {
            throw NativePluginError.missingFunction(pluginName, function: "aro_plugin_info")
        }
        let typedInfoFunc = unsafeBitCast(infoPtr, to: PluginInfoFunc.self)
        if let resultPtr = typedInfoFunc() {
            defer { self.freeFunc?(resultPtr) }
            let infoJSON = String(cString: resultPtr)
            parsePluginInfo(json: infoJSON)
        }

        if pluginInfo == nil {
            pluginInfo = NativePluginInfo(
                name: pluginName,
                version: "1.0.0",
                language: "native",
                actions: []
            )
        }
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
            // Try common patterns (pluginPath is typically the Sources/ subdirectory)
            let pluginRoot = pluginPath.deletingLastPathComponent()
            var candidates = [
                pluginPath.appendingPathComponent("lib\(pluginName).\(ext)"),
                pluginPath.appendingPathComponent("\(pluginName).\(ext)"),
                pluginPath.appendingPathComponent("target/release/lib\(pluginName).\(ext)"),  // Rust
            ]

            // Also check SPM build output (for Package.swift-based plugins).
            // The library may live under .build/<triple>/release/ in the plugin root.
            let spmBuildDir = pluginRoot.appendingPathComponent(".build")
            if FileManager.default.fileExists(atPath: spmBuildDir.path) {
                // Try .build/release/ first (simple SPM layout)
                let releaseDir = spmBuildDir.appendingPathComponent("release")
                candidates.append(releaseDir.appendingPathComponent("lib\(pluginName).\(ext)"))
                candidates.append(releaseDir.appendingPathComponent("\(pluginName).\(ext)"))

                // Search arch-specific dirs: .build/<triple>/release/
                if let buildContents = try? FileManager.default.contentsOfDirectory(
                    at: spmBuildDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
                ) {
                    for dir in buildContents where dir.lastPathComponent.contains("-") && dir.lastPathComponent != "checkouts" {
                        let archRelease = dir.appendingPathComponent("release")
                        // Look for any dynamic library matching the extension
                        if let libs = try? FileManager.default.contentsOfDirectory(
                            at: archRelease, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                        ) {
                            for lib in libs where lib.pathExtension == ext {
                                candidates.append(lib)
                            }
                        }
                    }
                }
            }

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
        // On Linux, Swift-built .so files can crash the dynamic linker with RTLD_NOW
        // due to TLS exhaustion.  Use RTLD_LAZY | RTLD_GLOBAL so symbol resolution is
        // deferred and the plugin can share the host process's Swift runtime.
        #if os(Linux)
        let dlopenFlags = RTLD_LAZY | RTLD_GLOBAL
        #else
        let dlopenFlags = RTLD_NOW | RTLD_LOCAL
        #endif

        #if os(Linux)
        // Pre-load dependency libraries (e.g. AROPluginSDK, AROPluginKit) from the same
        // directory with RTLD_GLOBAL so their symbols merge with the host process's Swift
        // runtime. Without this, Swift-built plugins crash on Linux (TLS exhaustion).
        let libDir = libraryPath.deletingLastPathComponent()
        if let siblings = try? FileManager.default.contentsOfDirectory(
            at: libDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) {
            for dep in siblings where dep.pathExtension == ext && dep != libraryPath {
                _ = dlopen(dep.path, Int32(dlopenFlags))
            }
        }
        #endif

        guard let handle = dlopen(libraryPath.path, Int32(dlopenFlags)) else {
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

        // Check for Swift source files — try standalone swiftc first (fast, produces a simple
        // C-ABI .so that loads safely via dlopen on all platforms).
        let swiftFiles = findSourceFiles(withExtension: "swift")
        if !swiftFiles.isEmpty {
            debugPrint("[NativePluginHost] Found Swift files: \(swiftFiles.map { $0.lastPathComponent })")
            let outputPath = pluginPath.appendingPathComponent("lib\(pluginName).\(ext)")
            do {
                try compileSwiftPlugin(sources: swiftFiles, output: outputPath)
                return outputPath
            } catch {
                debugPrint("[NativePluginHost] Standalone swiftc failed (\(error)), trying Package.swift...")
                // Clean up partial output so SPM doesn't complain about unhandled files
                try? FileManager.default.removeItem(at: outputPath)
            }
        }

        // Fallback: check for Package.swift (Swift package plugin with SPM dependencies)
        let packageSwiftCandidates = [
            pluginPath.appendingPathComponent("Package.swift"),
            pluginPath.deletingLastPathComponent().appendingPathComponent("Package.swift"),
        ]

        if let packageSwift = packageSwiftCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            let packageDir = packageSwift.deletingLastPathComponent()
            debugPrint("[NativePluginHost] Found Package.swift at \(packageSwift.path), building Swift package plugin: \(pluginName)")
            return try compileSwiftPackagePlugin(packageDir: packageDir, ext: ext)
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

    /// Compile Swift plugin using Package.swift (swift build)
    private func compileSwiftPackagePlugin(packageDir: URL, ext: String) throws -> URL? {
        // Find swift executable
        var swiftPath: String? = nil
        if let swiftEnv = ProcessInfo.processInfo.environment["SWIFT_PATH"],
           !swiftEnv.isEmpty,
           FileManager.default.isExecutableFile(atPath: swiftEnv) {
            swiftPath = swiftEnv
        }

        if swiftPath == nil {
            let whichProcess = Process()
            whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            whichProcess.arguments = ["swift"]
            let pipe = Pipe()
            whichProcess.standardOutput = pipe
            whichProcess.standardError = FileHandle.nullDevice
            if let _ = try? whichProcess.run() {
                whichProcess.waitUntilExit()
                if whichProcess.terminationStatus == 0,
                   let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                       .trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty {
                    swiftPath = path
                }
            }
        }

        if swiftPath == nil {
            let commonPaths = [
                "/usr/bin/swift",
                "/usr/share/swift/usr/bin/swift",
                "/opt/swift/usr/bin/swift",
                "/opt/homebrew/bin/swift",
                "/usr/local/bin/swift",
            ]
            swiftPath = commonPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        }

        guard let swiftPath = swiftPath else {
            throw NativePluginError.compilationFailed(pluginName, message: "swift not found")
        }

        debugPrint("[NativePluginHost] Building Swift package plugin with \(swiftPath) in \(packageDir.path)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: swiftPath)
        process.arguments = ["build", "-c", "release"]
        process.currentDirectoryURL = packageDir

        // Capture both stdout and stderr so we can report the full error on failure.
        let outPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus != 0 {
            let stderrStr = String(data: errorData, encoding: .utf8) ?? ""
            let stdoutStr = String(data: outData, encoding: .utf8) ?? ""
            let combined = [stderrStr, stdoutStr].filter { !$0.isEmpty }.joined(separator: "\n")
            let errorMessage = combined.isEmpty ? "exit code \(process.terminationStatus), reason: \(process.terminationReason.rawValue)" : combined
            debugPrint("[NativePluginHost] Swift package build failed: \(errorMessage)")
            throw NativePluginError.compilationFailed(pluginName, message: "swift build failed: \(errorMessage)")
        }

        // Use `swift build --show-bin-path` to find the actual output directory
        // (on Linux this may be .build/x86_64-unknown-linux-gnu/release/ rather than .build/release/)
        var binDir: URL? = nil
        let binPathProcess = Process()
        binPathProcess.executableURL = URL(fileURLWithPath: swiftPath)
        binPathProcess.arguments = ["build", "-c", "release", "--show-bin-path"]
        binPathProcess.currentDirectoryURL = packageDir
        let binPathPipe = Pipe()
        binPathProcess.standardOutput = binPathPipe
        binPathProcess.standardError = FileHandle.nullDevice
        if let _ = try? binPathProcess.run() {
            binPathProcess.waitUntilExit()
            if binPathProcess.terminationStatus == 0,
               let path = String(data: binPathPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                   .trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                binDir = URL(fileURLWithPath: path)
            }
        }

        // Fallback to .build/release/ if --show-bin-path didn't work
        let searchDirs = [
            binDir,
            packageDir.appendingPathComponent(".build/release"),
        ].compactMap { $0 }

        for releaseDir in searchDirs {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: releaseDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            let libFiles = contents.filter { $0.pathExtension == ext }
            if let lib = libFiles.first(where: { $0.lastPathComponent.lowercased().contains(pluginName.lowercased().replacingOccurrences(of: "-", with: "")) }) ?? libFiles.first {
                // Return the library in-place from the build directory.
                // Do NOT copy it out — the RPATH in the .so references sibling
                // dependencies (e.g. AROPluginKit) that live in the same build dir.
                // Copying breaks those references and causes dlopen to crash.
                debugPrint("[NativePluginHost] Swift package plugin built: \(lib.path)")
                return lib
            }
        }

        debugPrint("[NativePluginHost] Swift package built but no dynamic library found")
        return nil
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

    /// Compile a Swift Package plugin using `swift build`, copying the result to `output`.
    ///
    /// Delegates to the returning variant and copies the built library.
    private func compileSwiftPackagePlugin(packageDir: URL, output: URL, ext: String) throws {
        guard let builtLib = try compileSwiftPackagePlugin(packageDir: packageDir, ext: ext) else {
            let buildDir = packageDir.appendingPathComponent(".build")
            throw NativePluginError.compilationFailed(pluginName, message: "Built library not found in \(buildDir.path)")
        }
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        try FileManager.default.copyItem(at: builtLib, to: output)
        debugPrint("[NativePluginHost] Swift package plugin copied to: \(output.path)")
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

        // Add include paths: check for include/ directory in plugin root (parent of source path)
        let pluginRoot = pluginPath.deletingLastPathComponent()
        let includeDir = pluginRoot.appendingPathComponent("include")
        if FileManager.default.fileExists(atPath: includeDir.path) {
            args.append("-I\(includeDir.path)")
        }
        // Also check for include/ in the source directory itself
        let localIncludeDir = pluginPath.appendingPathComponent("include")
        if FileManager.default.fileExists(atPath: localIncludeDir.path) {
            args.append("-I\(localIncludeDir.path)")
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

        // --- Optional: aro_plugin_set_invoke (for plugin-to-runtime invocation) ---
        if let setInvokeSymbol = resolveSymbol("aro_plugin_set_invoke") {
            let setInvokeFn = unsafeBitCast(setInvokeSymbol, to: SetInvokeFunc.self)
            // Pass the invoke callback if one has been registered by the runtime
            if NativePluginHost.invokeCallback != nil {
                // Ownership: the returned strdup'd pointer is owned by the plugin.
                // The plugin MUST free it via aro_plugin_free() or free().
                // This follows the same convention as aro_plugin_execute return values.
                let callback: InvokeFunc = { featureSetPtr, inputPtr in
                    guard let invoke = NativePluginHost.invokeCallback else { return nil }
                    let featureSet = String(cString: featureSetPtr)
                    let inputJSON = String(cString: inputPtr)
                    let resultJSON = invoke(featureSet, inputJSON)
                    // strdup: ownership transfers to the plugin (caller must free)
                    return resultJSON.withCString { strdup($0) }
                }
                setInvokeFn(callback)
                debugPrint("[NativePluginHost] Passed invoke callback to \(pluginName)")
            }
        }

        // ARO-0073: Call aro_plugin_register (if exported) to trigger plugin's
        // file-scope initialization before querying aro_plugin_info.
        // Swift SDK plugins need this because file-scope let is lazy.
        if let registerSymbol = resolveSymbol("aro_plugin_register") {
            let registerFn = unsafeBitCast(registerSymbol, to: InitFunc.self)
            registerFn()
            debugPrint("[NativePluginHost] Called aro_plugin_register for \(pluginName)")
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

        // Parse actions using shared helper (supports both flat and structured formats)
        let parsedActions = Self.parseActionList(from: dict)
        let actionNames = parsedActions.names
        let verbsMap = parsedActions.verbsMap

        // Parse qualifiers using shared helper
        let qualifierDescriptors = Self.parseQualifierDescriptors(from: dict)

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
            }
            registerQualifiers(qualifierDescriptors)
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
        var entries: [(verb: String, pluginName: String, handler: @Sendable (ResultDescriptor, ObjectDescriptor, any ExecutionContext) async throws -> any Sendable)] = []

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
                    entries.append((verb: registeredVerb, pluginName: pluginName, handler: wrapper.handle))
                }
            }
        }

        syncRegisterActions(entries)
    }

    // MARK: - Unload

    /// Unload the plugin
    public func unload() {
        guard let handle = libraryHandle else { return }

        // Call shutdown lifecycle hook before unloading
        shutdownFunc?()

        // Unregister from ActionRegistry and QualifierRegistry (shared logic)
        unloadFromRegistries()

        // Language-specific cleanup: close the dynamic library
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

    /// Service names declared in aro_plugin_info (ARO-0073)
    public var declaredServiceNames: [String] {
        pluginInfo?.services.map { $0.name } ?? []
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

// MARK: - Qualifier Execution

extension NativePluginHost {
    /// Execute a qualifier transformation via the native plugin (ARO-0073: with parameters)
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

        // Language-specific: call the C ABI function
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

        // Shared result decoding
        guard let resultData = resultJSON.data(using: .utf8) else {
            throw QualifierError.executionFailed(
                qualifier: qualifier,
                message: "Invalid UTF-8 in plugin response"
            )
        }

        return try decodeQualifierResult(from: resultData, qualifier: qualifier, decoder: decoder)
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
    let qualifiers: [PluginQualifierDescriptor]
    /// Services provided by this plugin (routed through aro_plugin_execute)
    let services: [NativeServiceDescriptor]
    /// Deprecated features
    let deprecations: [DeprecationDescriptor]

    init(name: String, version: String, language: String, actions: [String], verbsMap: [String: [String]] = [:], qualifiers: [PluginQualifierDescriptor] = [], services: [NativeServiceDescriptor] = [], deprecations: [DeprecationDescriptor] = []) {
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
