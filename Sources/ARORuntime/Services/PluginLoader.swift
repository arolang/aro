// ============================================================
// PluginLoader.swift
// ARO Runtime - Dynamic Plugin Loader
// ============================================================

import Foundation

#if os(Windows)
import WinSDK
#endif

// MARK: - Plugin Loader

/// Loads and manages dynamic plugins for ARO
///
/// The PluginLoader discovers Swift plugin files in the `./plugins/` directory,
/// compiles them to dynamic libraries, and loads them at runtime.
///
/// ## Plugin Structure
/// ```
/// MyApp/
/// ├── main.aro
/// ├── plugins/
/// │   └── MyService.swift
/// └── aro.yaml
/// ```
///
/// ## Plugin File Format
/// Each plugin must export an `aro_plugin_init` function that returns
/// a JSON description of the services it provides.
///
/// ```swift
/// import Foundation
///
/// // Service implementation - called via JSON interface
/// @_cdecl("greeting_call")
/// public func greetingCall(
///     _ methodPtr: UnsafePointer<CChar>,
///     _ argsPtr: UnsafePointer<CChar>,
///     _ resultPtr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
/// ) -> Int32 {
///     let method = String(cString: methodPtr)
///     let argsJSON = String(cString: argsPtr)
///
///     // Parse args, execute method, return result
///     // Return 0 for success, non-zero for error
/// }
///
/// // Plugin initialization - returns service metadata as JSON
/// @_cdecl("aro_plugin_init")
/// public func pluginInit() -> UnsafePointer<CChar> {
///     return """
///     {"services": [{"name": "greeting", "symbol": "greeting_call"}]}
///     """.withCString { strdup($0)! }
/// }
/// ```
public final class PluginLoader: @unchecked Sendable {
    /// Shared instance
    public static let shared = PluginLoader()

    /// Cache directory for compiled plugins
    private let cacheDir: URL

    /// Loaded plugin handles (to prevent unloading)
    private var loadedPlugins: [String: UnsafeMutableRawPointer] = [:]

    /// Registered plugin service functions
    private var pluginFunctions: [String: PluginCallFunction] = [:]

    /// Lock for thread safety
    private let lock = NSLock()

    /// Plugin call function type
    typealias PluginCallFunction = @convention(c) (
        UnsafePointer<CChar>,      // method
        UnsafePointer<CChar>,      // args JSON
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>  // result JSON
    ) -> Int32

    /// ARO-0043: Plugin system object read function type
    typealias PluginReadFunction = @convention(c) (
        UnsafePointer<CChar>?,     // property (optional)
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>  // result JSON
    ) -> Int32

    /// ARO-0043: Plugin system object write function type
    typealias PluginWriteFunction = @convention(c) (
        UnsafePointer<CChar>,      // value JSON
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>  // result (optional error message)
    ) -> Int32

    private init() {
        // Use .aro-cache in current directory
        let currentDir = FileManager.default.currentDirectoryPath
        self.cacheDir = URL(fileURLWithPath: currentDir).appendingPathComponent(".aro-cache")
    }

    // MARK: - Public API

    /// Load all plugins from the plugins directory
    /// - Parameter directory: Base directory containing the `plugins/` folder
    public func loadPlugins(from directory: URL) throws {
        let pluginsDir = directory.appendingPathComponent("plugins")

        // Check if plugins directory exists
        guard FileManager.default.fileExists(atPath: pluginsDir.path) else {
            return // No plugins directory, nothing to load
        }

        // Create cache directory if needed
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // Find all .swift files and subdirectories in plugins directory
        let contents = try FileManager.default.contentsOfDirectory(
            at: pluginsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        // Load single-file Swift plugins
        let swiftFiles = contents.filter { $0.pathExtension == "swift" }
        for swiftFile in swiftFiles {
            do {
                try loadPlugin(from: swiftFile)
            } catch {
                print("[PluginLoader] Warning: Failed to load \(swiftFile.lastPathComponent): \(error)")
            }
        }

        // Load Swift package plugins (directories with Package.swift)
        for item in contents {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                let packageSwift = item.appendingPathComponent("Package.swift")
                if FileManager.default.fileExists(atPath: packageSwift.path) {
                    do {
                        try loadPackagePlugin(from: item)
                    } catch {
                        print("[PluginLoader] Warning: Failed to load package plugin \(item.lastPathComponent): \(error)")
                    }
                }
            }
        }
    }

    /// Load pre-compiled plugins from the plugins directory
    /// This is used by native compiled binaries - no compilation occurs
    /// Plugins are discovered relative to the binary's location
    /// - Parameter binaryPath: Path to the executable binary
    public func loadPrecompiledPlugins(relativeTo binaryPath: URL) throws {
        let binaryDir = binaryPath.deletingLastPathComponent()
        let pluginsDir = binaryDir.appendingPathComponent("plugins")

        #if os(Windows)
        let libraryExtension = "dll"
        #elseif os(Linux)
        let libraryExtension = "so"
        #else
        let libraryExtension = "dylib"
        #endif

        // Check if plugins directory exists
        guard FileManager.default.fileExists(atPath: pluginsDir.path) else {
            return // No plugins directory, nothing to load
        }

        // Find all .dylib/.so/.dll files in plugins directory
        let contents = try FileManager.default.contentsOfDirectory(
            at: pluginsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        let dylibFiles = contents.filter { $0.pathExtension == libraryExtension }

        for dylibFile in dylibFiles {
            let pluginName = dylibFile.deletingPathExtension().lastPathComponent
            do {
                try loadDylib(at: dylibFile, name: pluginName)
            } catch {
                print("[PluginLoader] Warning: Failed to load \(dylibFile.lastPathComponent): \(error)")
            }
        }
    }

    /// Compile plugins to the output directory (for aro build)
    /// - Parameters:
    ///   - sourceDirectory: Source plugins directory (containing .swift files)
    ///   - outputDirectory: Output plugins directory (where .dylib/.so files go)
    public func compilePlugins(from sourceDirectory: URL, to outputDirectory: URL) throws {
        let sourcePluginsDir = sourceDirectory
        let outputPluginsDir = outputDirectory

        #if os(Windows)
        let libraryExtension = "dll"
        #elseif os(Linux)
        let libraryExtension = "so"
        #else
        let libraryExtension = "dylib"
        #endif

        // Check if source plugins directory exists
        guard FileManager.default.fileExists(atPath: sourcePluginsDir.path) else {
            return // No plugins directory, nothing to compile
        }

        // Create output plugins directory
        try FileManager.default.createDirectory(at: outputPluginsDir, withIntermediateDirectories: true)

        // Find all .swift files and subdirectories in source plugins directory
        let contents = try FileManager.default.contentsOfDirectory(
            at: sourcePluginsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        // Compile single-file Swift plugins
        let swiftFiles = contents.filter { $0.pathExtension == "swift" }
        for swiftFile in swiftFiles {
            let pluginName = swiftFile.deletingPathExtension().lastPathComponent
            let outputPath = outputPluginsDir.appendingPathComponent("\(pluginName).\(libraryExtension)")

            do {
                try compilePlugin(source: swiftFile, output: outputPath)
            } catch {
                print("[PluginLoader] Warning: Failed to compile \(swiftFile.lastPathComponent): \(error)")
            }
        }

        // Compile Swift package plugins
        for item in contents {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                let packageSwift = item.appendingPathComponent("Package.swift")
                if FileManager.default.fileExists(atPath: packageSwift.path) {
                    let pluginName = item.lastPathComponent
                    let outputPath = outputPluginsDir.appendingPathComponent("lib\(pluginName).\(libraryExtension)")

                    do {
                        try compilePackagePlugin(source: item, output: outputPath)
                    } catch {
                        print("[PluginLoader] Warning: Failed to compile package plugin \(pluginName): \(error)")
                    }
                }
            }
        }
    }

    /// Load a single plugin from a Swift file
    /// - Parameter sourceFile: Path to the .swift plugin file
    public func loadPlugin(from sourceFile: URL) throws {
        let pluginName = sourceFile.deletingPathExtension().lastPathComponent
        #if os(Windows)
        let libraryExtension = "dll"
        #elseif os(Linux)
        let libraryExtension = "so"
        #else
        let libraryExtension = "dylib"
        #endif
        let dylibPath = cacheDir.appendingPathComponent("\(pluginName).\(libraryExtension)")

        // Check if we need to recompile
        if shouldRecompile(source: sourceFile, dylib: dylibPath) {
            try compilePlugin(source: sourceFile, output: dylibPath)
        }

        // Load the dylib
        try loadDylib(at: dylibPath, name: pluginName)
    }

    /// Call a plugin service method
    /// - Parameters:
    ///   - serviceName: Service name
    ///   - method: Method name
    ///   - args: Arguments dictionary
    /// - Returns: Result value
    func callPlugin(
        _ serviceName: String,
        method: String,
        args: [String: any Sendable]
    ) throws -> any Sendable {
        lock.lock()
        let callFunc = pluginFunctions[serviceName.lowercased()]
        lock.unlock()

        guard let callFunc = callFunc else {
            throw PluginError.serviceNotFound(serviceName)
        }

        // Convert args to JSON
        let argsData = try JSONSerialization.data(withJSONObject: args)
        let argsJSON = String(data: argsData, encoding: .utf8) ?? "{}"

        // Call the plugin
        var resultPtr: UnsafeMutablePointer<CChar>?
        let status = method.withCString { methodCStr in
            argsJSON.withCString { argsCStr in
                callFunc(methodCStr, argsCStr, &resultPtr)
            }
        }

        // Check for error
        if status != 0 {
            let errorMsg = resultPtr.map { String(cString: $0) } ?? "Unknown error"
            resultPtr.map { free($0) }
            throw PluginError.executionFailed(serviceName, method: method, message: errorMsg)
        }

        // Parse result
        guard let resultPtr = resultPtr else {
            return [String: any Sendable]()
        }

        let resultJSON = String(cString: resultPtr)
        free(resultPtr)

        guard let resultData = resultJSON.data(using: .utf8),
              let result = try JSONSerialization.jsonObject(with: resultData) as? [String: Any] else {
            return resultJSON
        }

        return convertToSendable(result)
    }

    // MARK: - Private

    /// Find the Swift executable (swift command) in PATH or common locations
    private func findSwiftExecutable() -> String? {
        #if os(Windows)
        // On Windows, use 'where' command to find swift.exe
        let whereProcess = Process()
        whereProcess.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\where.exe")
        whereProcess.arguments = ["swift"]

        let pipe = Pipe()
        whereProcess.standardOutput = pipe
        whereProcess.standardError = FileHandle.nullDevice

        do {
            try whereProcess.run()
            whereProcess.waitUntilExit()

            if whereProcess.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    // 'where' may return multiple lines, take the first
                    if let path = output.split(separator: "\r\n").first ?? output.split(separator: "\n").first,
                       !path.isEmpty {
                        return String(path).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
        } catch {
            // where failed, try common locations
        }

        // Check common Swift installation paths on Windows
        let commonPaths = [
            "C:\\Program Files\\Swift\\Toolchains\\0.0.0+Asserts\\usr\\bin\\swift.exe",
            "C:\\Library\\Developer\\Toolchains\\unknown-Asserts-development.xctoolchain\\usr\\bin\\swift.exe"
        ]

        for path in commonPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // Last resort: assume swift is in PATH
        return "swift"
        #else
        // On Unix, use 'which' command to find swift
        let whichProcess = Process()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = ["swift"]

        let pipe = Pipe()
        whichProcess.standardOutput = pipe
        whichProcess.standardError = FileHandle.nullDevice

        do {
            try whichProcess.run()
            whichProcess.waitUntilExit()

            if whichProcess.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty {
                    return path
                }
            }
        } catch {
            // which failed, try common locations
        }

        // Check common Swift installation paths
        let commonPaths = [
            "/usr/bin/swift",
            "/usr/local/bin/swift",
            "/usr/share/swift/usr/bin/swift",  // CI installation path
            "/opt/swift/usr/bin/swift",
            "/Library/Developer/Toolchains/swift-latest.xctoolchain/usr/bin/swift"
        ]

        for path in commonPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        return nil
        #endif
    }

    /// Find the Swift compiler in PATH or common locations
    private func findSwiftCompiler() -> String? {
        #if os(Windows)
        // On Windows, use 'where' command to find swiftc.exe
        let whereProcess = Process()
        whereProcess.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\where.exe")
        whereProcess.arguments = ["swiftc"]

        let pipe = Pipe()
        whereProcess.standardOutput = pipe
        whereProcess.standardError = FileHandle.nullDevice

        do {
            try whereProcess.run()
            whereProcess.waitUntilExit()

            if whereProcess.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    // 'where' may return multiple lines, take the first
                    if let path = output.split(separator: "\r\n").first ?? output.split(separator: "\n").first,
                       !path.isEmpty {
                        return String(path).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
        } catch {
            // where failed, try common locations
        }

        // Check common Swift installation paths on Windows
        let commonPaths = [
            "C:\\Program Files\\Swift\\Toolchains\\0.0.0+Asserts\\usr\\bin\\swiftc.exe",
            "C:\\Library\\Developer\\Toolchains\\unknown-Asserts-development.xctoolchain\\usr\\bin\\swiftc.exe"
        ]

        for path in commonPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // Last resort: assume swiftc is in PATH
        return "swiftc"
        #else
        // On Unix, use 'which' command to find swiftc
        let whichProcess = Process()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = ["swiftc"]

        let pipe = Pipe()
        whichProcess.standardOutput = pipe
        whichProcess.standardError = FileHandle.nullDevice

        do {
            try whichProcess.run()
            whichProcess.waitUntilExit()

            if whichProcess.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty {
                    return path
                }
            }
        } catch {
            // which failed, try common locations
        }

        // Check common Swift installation paths
        let commonPaths = [
            "/usr/bin/swiftc",
            "/usr/local/bin/swiftc",
            "/usr/share/swift/usr/bin/swiftc",  // CI installation path
            "/opt/swift/usr/bin/swiftc",
            "/Library/Developer/Toolchains/swift-latest.xctoolchain/usr/bin/swiftc"
        ]

        for path in commonPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        return nil
        #endif
    }

    /// Check if source file is newer than compiled dylib
    private func shouldRecompile(source: URL, dylib: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: dylib.path) else {
            return true // No dylib yet, need to compile
        }

        do {
            let sourceAttrs = try FileManager.default.attributesOfItem(atPath: source.path)
            let dylibAttrs = try FileManager.default.attributesOfItem(atPath: dylib.path)

            guard let sourceDate = sourceAttrs[.modificationDate] as? Date,
                  let dylibDate = dylibAttrs[.modificationDate] as? Date else {
                return true
            }

            return sourceDate > dylibDate
        } catch {
            return true
        }
    }

    /// Find a built library in the Swift build directory
    /// Swift 5.9+ uses arch-specific paths like .build/arm64-apple-macosx/release/
    /// Older Swift uses .build/release/
    /// - Parameters:
    ///   - buildDir: The .build directory
    ///   - name: Plugin name (e.g., "CounterPlugin")
    ///   - extension: File extension (dylib, so, dll)
    /// - Returns: Path to the built library, or nil if not found
    private func findBuiltLibrary(in buildDir: URL, name: String, extension ext: String) -> URL? {
        // Possible library names: libCounterPlugin.dylib or CounterPlugin.dylib
        let libNames = ["lib\(name).\(ext)", "\(name).\(ext)"]

        // First, try the legacy path: .build/release/
        let legacyReleaseDir = buildDir.appendingPathComponent("release")
        for libName in libNames {
            let path = legacyReleaseDir.appendingPathComponent(libName)
            if FileManager.default.fileExists(atPath: path.path) {
                return path
            }
        }

        // Next, search for arch-specific directories like:
        // .build/arm64-apple-macosx/release/
        // .build/x86_64-apple-macosx/release/
        // .build/x86_64-unknown-linux-gnu/release/
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: buildDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            for item in contents {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    // Check if this looks like an arch directory (contains hyphen and has release subdir)
                    let dirName = item.lastPathComponent
                    if dirName.contains("-") && dirName != "checkouts" {
                        let releaseDir = item.appendingPathComponent("release")
                        for libName in libNames {
                            let path = releaseDir.appendingPathComponent(libName)
                            if FileManager.default.fileExists(atPath: path.path) {
                                return path
                            }
                        }
                    }
                }
            }
        } catch {
            // Ignore directory enumeration errors
        }

        return nil
    }

    /// Compile a Swift plugin to a dynamic library
    private func compilePlugin(source: URL, output: URL) throws {
        let process = Process()
        #if os(Windows)
        // On Windows, swiftc is in PATH
        process.executableURL = URL(fileURLWithPath: "swiftc.exe")
        #else
        // Find swiftc from PATH or common locations
        let swiftcPath = findSwiftCompiler() ?? "/usr/bin/swiftc"
        process.executableURL = URL(fileURLWithPath: swiftcPath)
        #endif

        // Build arguments for compiling to dylib
        var arguments = [
            "-emit-library",
            "-o", output.path,
            source.path
        ]

        // Add platform-specific flags
        #if os(macOS)
        arguments.append(contentsOf: ["-framework", "Foundation"])
        #endif

        // Enable optimization in release builds
        #if !DEBUG
        arguments.append("-O")
        #endif

        process.arguments = arguments

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw PluginError.compilationFailed(source.lastPathComponent, message: errorMessage)
        }
    }

    /// Load a Swift package plugin
    /// - Parameter packageDir: Path to the package directory containing Package.swift
    private func loadPackagePlugin(from packageDir: URL) throws {
        let pluginName = packageDir.lastPathComponent

        #if os(Windows)
        let libraryExtension = "dll"
        #elseif os(Linux)
        let libraryExtension = "so"
        #else
        let libraryExtension = "dylib"
        #endif

        // Build the package using swift build
        let process = Process()
        let swiftPath = findSwiftExecutable() ?? "/usr/bin/swift"
        process.executableURL = URL(fileURLWithPath: swiftPath)
        process.currentDirectoryURL = packageDir
        process.arguments = ["build", "-c", "release"]

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw PluginError.compilationFailed(pluginName, message: errorMessage)
        }

        // Find the built dynamic library
        // Swift now uses arch-specific paths like .build/arm64-apple-macosx/release/
        guard let dylibPath = findBuiltLibrary(
            in: packageDir.appendingPathComponent(".build"),
            name: pluginName,
            extension: libraryExtension
        ) else {
            throw PluginError.loadFailed(pluginName, message: "Built library not found in \(packageDir.appendingPathComponent(".build").path)")
        }

        try loadDylib(at: dylibPath, name: pluginName)
    }

    /// Compile a Swift package plugin to a dynamic library
    /// - Parameters:
    ///   - source: Path to the package directory
    ///   - output: Output path for the compiled library
    private func compilePackagePlugin(source: URL, output: URL) throws {
        let pluginName = source.lastPathComponent

        // Build the package using swift build
        let process = Process()
        let swiftPath = findSwiftExecutable() ?? "/usr/bin/swift"
        process.executableURL = URL(fileURLWithPath: swiftPath)
        process.currentDirectoryURL = source
        process.arguments = ["build", "-c", "release"]

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw PluginError.compilationFailed(pluginName, message: errorMessage)
        }

        #if os(Windows)
        let libraryExtension = "dll"
        #elseif os(Linux)
        let libraryExtension = "so"
        #else
        let libraryExtension = "dylib"
        #endif

        // Find the built dynamic library
        // Swift now uses arch-specific paths like .build/arm64-apple-macosx/release/
        guard let builtLibPath = findBuiltLibrary(
            in: source.appendingPathComponent(".build"),
            name: pluginName,
            extension: libraryExtension
        ) else {
            throw PluginError.loadFailed(pluginName, message: "Built library not found in \(source.appendingPathComponent(".build").path)")
        }

        // Copy to output location
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        try FileManager.default.copyItem(at: builtLibPath, to: output)
    }

    /// Load a dynamic library and register its services
    private func loadDylib(at path: URL, name: String) throws {
        lock.lock()
        defer { lock.unlock() }

        // Check if already loaded
        if loadedPlugins[name] != nil {
            return
        }

        // Load the library (platform-specific)
        #if os(Windows)
        let handle = path.path.withCString(encodedAs: UTF16.self) { LoadLibraryW($0) }
        guard let handle = handle else {
            let error = getWindowsError()
            throw PluginError.loadFailed(name, message: error)
        }
        let rawHandle = UnsafeMutableRawPointer(handle)
        #else
        guard let handle = dlopen(path.path, RTLD_NOW | RTLD_LOCAL) else {
            let error = String(cString: dlerror())
            throw PluginError.loadFailed(name, message: error)
        }
        let rawHandle = handle
        #endif

        loadedPlugins[name] = rawHandle

        // Find the init function
        #if os(Windows)
        let initSymbol = GetProcAddress(handle, "aro_plugin_init")
        #else
        let initSymbol = dlsym(handle, "aro_plugin_init")
        #endif

        guard let initSymbol = initSymbol else {
            // No init function, try to load as simple service
            // Look for a function named after the plugin
            let serviceSymbol = "\(name.lowercased())_call"
            #if os(Windows)
            let callSymbol = GetProcAddress(handle, serviceSymbol)
            #else
            let callSymbol = dlsym(handle, serviceSymbol)
            #endif

            if let callSymbol = callSymbol {
                let callFunc = unsafeBitCast(callSymbol, to: PluginCallFunction.self)
                pluginFunctions[name.lowercased()] = callFunc

                // Register as AROService
                let wrapper = PluginServiceWrapper(name: name, loader: self)
                try ExternalServiceRegistry.shared.register(wrapper, withName: name)

                return
            }
            throw PluginError.initFunctionNotFound(name)
        }

        // Call init function to get service metadata
        typealias InitFunc = @convention(c) () -> UnsafePointer<CChar>
        let initFunc = unsafeBitCast(initSymbol, to: InitFunc.self)
        let metadataPtr = initFunc()
        let metadataJSON = String(cString: metadataPtr)

        // Parse metadata
        guard let metadataData = metadataJSON.data(using: .utf8),
              let metadata = try JSONSerialization.jsonObject(with: metadataData) as? [String: Any],
              let services = metadata["services"] as? [[String: Any]] else {
            throw PluginError.invalidMetadata(name, message: "Invalid JSON metadata")
        }

        // Register each service
        for service in services {
            guard let serviceName = service["name"] as? String,
                  let symbolName = service["symbol"] as? String else {
                continue
            }

            #if os(Windows)
            let callSymbol = GetProcAddress(handle, symbolName)
            #else
            let callSymbol = dlsym(handle, symbolName)
            #endif

            guard let callSymbol = callSymbol else {
                print("[PluginLoader] Warning: Symbol '\(symbolName)' not found in \(name)")
                continue
            }

            let callFunc = unsafeBitCast(callSymbol, to: PluginCallFunction.self)
            pluginFunctions[serviceName.lowercased()] = callFunc

            // Register as AROService
            let wrapper = PluginServiceWrapper(name: serviceName, loader: self)
            try ExternalServiceRegistry.shared.register(wrapper, withName: serviceName)

        }

        // ARO-0043: Register system objects from plugin metadata
        if let systemObjects = metadata["systemObjects"] as? [[String: Any]] {
            for objDef in systemObjects {
                guard let identifier = objDef["identifier"] as? String else {
                    continue
                }

                let description = objDef["description"] as? String ?? "Plugin system object"

                // Parse capabilities
                var capabilities: SystemObjectCapabilities = []
                if let caps = objDef["capabilities"] as? [String] {
                    for cap in caps {
                        switch cap.lowercased() {
                        case "readable", "source":
                            capabilities.insert(.readable)
                        case "writable", "sink":
                            capabilities.insert(.writable)
                        default:
                            break
                        }
                    }
                }

                // Get symbol names
                let readSymbol = objDef["readSymbol"] as? String
                let writeSymbol = objDef["writeSymbol"] as? String

                // Load read function
                var readFunc: PluginReadFunction? = nil
                if let symbolName = readSymbol {
                    #if os(Windows)
                    let symbol = GetProcAddress(handle, symbolName)
                    #else
                    let symbol = dlsym(rawHandle, symbolName)
                    #endif
                    if let symbol = symbol {
                        readFunc = unsafeBitCast(symbol, to: PluginReadFunction.self)
                    }
                }

                // Load write function
                var writeFunc: PluginWriteFunction? = nil
                if let symbolName = writeSymbol {
                    #if os(Windows)
                    let symbol = GetProcAddress(handle, symbolName)
                    #else
                    let symbol = dlsym(rawHandle, symbolName)
                    #endif
                    if let symbol = symbol {
                        writeFunc = unsafeBitCast(symbol, to: PluginWriteFunction.self)
                    }
                }

                // Capture values as constants for the closure (Swift concurrency safety)
                let capturedIdentifier = identifier
                let capturedDescription = description
                let capturedCapabilities = capabilities
                let capturedReadFunc = readFunc
                let capturedWriteFunc = writeFunc

                // Register the system object with the registry
                SystemObjectRegistry.shared.register(
                    identifier,
                    description: description,
                    capabilities: capabilities
                ) { _ in
                    PluginSystemObjectWrapper(
                        pluginIdentifier: capturedIdentifier,
                        pluginDescription: capturedDescription,
                        pluginCapabilities: capturedCapabilities,
                        readFunc: capturedReadFunc,
                        writeFunc: capturedWriteFunc
                    )
                }

            }
        }
    }

    #if os(Windows)
    /// Get Windows error message
    private func getWindowsError() -> String {
        let errorCode = GetLastError()
        return "Windows error code: \(errorCode)"
    }
    #endif

    /// Convert Any to Sendable
    private func convertToSendable(_ value: Any) -> any Sendable {
        switch value {
        case let str as String:
            return str
        case let num as NSNumber:
            // Check if it's a boolean (Apple platforms have CFBoolean APIs)
            #if canImport(Darwin)
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                return num.boolValue
            }
            #else
            // On Linux, check type encoding for boolean
            let objCType = String(cString: num.objCType)
            if objCType == "B" || objCType == "c" {
                if num.intValue == 0 || num.intValue == 1 {
                    return num.boolValue
                }
            }
            #endif
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
        case let array as [Any]:
            return array.map { convertToSendable($0) }
        default:
            return String(describing: value)
        }
    }

    /// Unload all plugins
    public func unloadAll() {
        lock.lock()
        defer { lock.unlock() }

        for (name, handle) in loadedPlugins {
            #if os(Windows)
            let hmodule = unsafeBitCast(handle, to: HMODULE.self)
            FreeLibrary(hmodule)
            #else
            dlclose(handle)
            #endif
        }
        loadedPlugins.removeAll()
        pluginFunctions.removeAll()
        pluginMetadata.removeAll()
    }

    // MARK: - Plugin Metadata Storage

    /// Plugin metadata for listing
    private var pluginMetadata: [String: LocalPluginInfo] = [:]

    /// Get list of all local plugins with their metadata
    /// - Parameter directory: Application directory containing `plugins/` folder
    /// - Returns: Array of LocalPluginInfo
    public func listLocalPlugins(from directory: URL) throws -> [LocalPluginInfo] {
        let pluginsDir = directory.appendingPathComponent("plugins")

        guard FileManager.default.fileExists(atPath: pluginsDir.path) else {
            return []
        }

        var plugins: [LocalPluginInfo] = []

        let contents = try FileManager.default.contentsOfDirectory(
            at: pluginsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        // Single-file Swift plugins
        let swiftFiles = contents.filter { $0.pathExtension == "swift" }
        for swiftFile in swiftFiles {
            let pluginName = swiftFile.deletingPathExtension().lastPathComponent
            let relativePath = "plugins/\(swiftFile.lastPathComponent)"

            // Check if we have cached metadata
            if let cached = pluginMetadata[pluginName] {
                plugins.append(cached)
                continue
            }

            // Try to compile and get metadata
            do {
                let info = try loadPluginMetadata(from: swiftFile, name: pluginName, relativePath: relativePath)
                pluginMetadata[pluginName] = info
                plugins.append(info)
            } catch {
                // Plugin exists but failed to load - show without methods
                plugins.append(LocalPluginInfo(
                    name: pluginName,
                    source: relativePath,
                    type: .swiftFile,
                    services: [],
                    error: error.localizedDescription
                ))
            }
        }

        // Swift package plugins
        for item in contents {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                let packageSwift = item.appendingPathComponent("Package.swift")
                if FileManager.default.fileExists(atPath: packageSwift.path) {
                    let pluginName = item.lastPathComponent
                    let relativePath = "plugins/\(pluginName)"

                    // Check if we have cached metadata
                    if let cached = pluginMetadata[pluginName] {
                        plugins.append(cached)
                        continue
                    }

                    // Try to build and get metadata
                    do {
                        let info = try loadPackagePluginMetadata(from: item, name: pluginName, relativePath: relativePath)
                        pluginMetadata[pluginName] = info
                        plugins.append(info)
                    } catch {
                        plugins.append(LocalPluginInfo(
                            name: pluginName,
                            source: relativePath,
                            type: .swiftPackage,
                            services: [],
                            error: error.localizedDescription
                        ))
                    }
                }
            }
        }

        return plugins
    }

    /// Load plugin metadata from a single Swift file
    private func loadPluginMetadata(from sourceFile: URL, name: String, relativePath: String) throws -> LocalPluginInfo {
        #if os(Windows)
        let libraryExtension = "dll"
        #elseif os(Linux)
        let libraryExtension = "so"
        #else
        let libraryExtension = "dylib"
        #endif
        let dylibPath = cacheDir.appendingPathComponent("\(name).\(libraryExtension)")

        // Compile if needed
        if shouldRecompile(source: sourceFile, dylib: dylibPath) {
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            try compilePlugin(source: sourceFile, output: dylibPath)
        }

        // Load and get metadata
        return try getPluginInfo(from: dylibPath, name: name, relativePath: relativePath, type: .swiftFile)
    }

    /// Load plugin metadata from a Swift package
    private func loadPackagePluginMetadata(from packageDir: URL, name: String, relativePath: String) throws -> LocalPluginInfo {
        #if os(Windows)
        let libraryExtension = "dll"
        #elseif os(Linux)
        let libraryExtension = "so"
        #else
        let libraryExtension = "dylib"
        #endif

        // Check for existing build
        if let existingLib = findBuiltLibrary(
            in: packageDir.appendingPathComponent(".build"),
            name: name,
            extension: libraryExtension
        ) {
            return try getPluginInfo(from: existingLib, name: name, relativePath: relativePath, type: .swiftPackage)
        }

        // Build the package
        let process = Process()
        let swiftPath = findSwiftExecutable() ?? "/usr/bin/swift"
        process.executableURL = URL(fileURLWithPath: swiftPath)
        process.currentDirectoryURL = packageDir
        process.arguments = ["build", "-c", "release"]

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw PluginError.compilationFailed(name, message: errorMessage)
        }

        guard let dylibPath = findBuiltLibrary(
            in: packageDir.appendingPathComponent(".build"),
            name: name,
            extension: libraryExtension
        ) else {
            throw PluginError.loadFailed(name, message: "Built library not found")
        }

        return try getPluginInfo(from: dylibPath, name: name, relativePath: relativePath, type: .swiftPackage)
    }

    /// Get plugin info by loading its metadata
    private func getPluginInfo(from dylibPath: URL, name: String, relativePath: String, type: LocalPluginType) throws -> LocalPluginInfo {
        // Load the library temporarily
        #if os(Windows)
        let handle = dylibPath.path.withCString(encodedAs: UTF16.self) { LoadLibraryW($0) }
        guard let handle = handle else {
            throw PluginError.loadFailed(name, message: getWindowsError())
        }
        defer { FreeLibrary(handle) }
        #else
        guard let handle = dlopen(dylibPath.path, RTLD_NOW | RTLD_LOCAL) else {
            let error = String(cString: dlerror())
            throw PluginError.loadFailed(name, message: error)
        }
        defer { dlclose(handle) }
        #endif

        // Find init function
        #if os(Windows)
        let initSymbol = GetProcAddress(handle, "aro_plugin_init")
        #else
        let initSymbol = dlsym(handle, "aro_plugin_init")
        #endif

        var services: [LocalPluginService] = []

        if let initSymbol = initSymbol {
            // Call init to get metadata
            typealias InitFunc = @convention(c) () -> UnsafePointer<CChar>
            let initFunc = unsafeBitCast(initSymbol, to: InitFunc.self)
            let metadataPtr = initFunc()
            let metadataJSON = String(cString: metadataPtr)

            // Parse metadata
            if let metadataData = metadataJSON.data(using: .utf8),
               let metadata = try? JSONSerialization.jsonObject(with: metadataData) as? [String: Any],
               let servicesArray = metadata["services"] as? [[String: Any]] {
                for serviceDict in servicesArray {
                    if let serviceName = serviceDict["name"] as? String {
                        let methods = serviceDict["methods"] as? [String] ?? []
                        services.append(LocalPluginService(name: serviceName, methods: methods))
                    }
                }
            }
        } else {
            // Try simple service (function named after plugin)
            let serviceSymbol = "\(name.lowercased())_call"
            #if os(Windows)
            let callSymbol = GetProcAddress(handle, serviceSymbol)
            #else
            let callSymbol = dlsym(handle, serviceSymbol)
            #endif

            if callSymbol != nil {
                // Plugin exports a simple service - methods unknown
                services.append(LocalPluginService(name: name.lowercased(), methods: []))
            }
        }

        return LocalPluginInfo(
            name: name,
            source: relativePath,
            type: type,
            services: services,
            error: nil
        )
    }
}

// MARK: - Local Plugin Info

/// Information about a local plugin
public struct LocalPluginInfo: Sendable {
    /// Plugin name (derived from filename)
    public let name: String

    /// Source path relative to app directory
    public let source: String

    /// Plugin type
    public let type: LocalPluginType

    /// Services provided by the plugin
    public let services: [LocalPluginService]

    /// Error message if plugin failed to load
    public let error: String?
}

/// Type of local plugin
public enum LocalPluginType: Sendable {
    case swiftFile
    case swiftPackage
}

/// Service provided by a local plugin
public struct LocalPluginService: Sendable {
    /// Service name (used in ARO code as <service-plugin>)
    public let name: String

    /// Methods available on this service
    public let methods: [String]
}

// MARK: - Plugin Service Wrapper

/// Wraps a plugin as an AROService
private struct PluginServiceWrapper: AROService {
    static let name: String = "_plugin_"

    private let serviceName: String
    private let loader: PluginLoader

    init(name: String, loader: PluginLoader) {
        self.serviceName = name
        self.loader = loader
    }

    init() throws {
        fatalError("PluginServiceWrapper requires name and loader")
    }

    func call(_ method: String, args: [String: any Sendable]) async throws -> any Sendable {
        return try loader.callPlugin(serviceName, method: method, args: args)
    }
}

// MARK: - Plugin Errors

/// Errors that can occur during plugin loading
public enum PluginError: Error, CustomStringConvertible {
    case compilationFailed(String, message: String)
    case loadFailed(String, message: String)
    case initFunctionNotFound(String)
    case invalidMetadata(String, message: String)
    case serviceNotFound(String)
    case executionFailed(String, method: String, message: String)

    public var description: String {
        switch self {
        case .compilationFailed(let name, let message):
            return "Failed to compile plugin '\(name)': \(message)"
        case .loadFailed(let name, let message):
            return "Failed to load plugin '\(name)': \(message)"
        case .initFunctionNotFound(let name):
            return "Plugin '\(name)' missing aro_plugin_init or <name>_call function"
        case .invalidMetadata(let name, let message):
            return "Plugin '\(name)' has invalid metadata: \(message)"
        case .serviceNotFound(let name):
            return "Plugin service not found: \(name)"
        case .executionFailed(let service, let method, let message):
            return "Plugin '\(service).\(method)' failed: \(message)"
        }
    }
}

// MARK: - Plugin System Object Wrapper (ARO-0043)

/// Wraps a plugin-provided system object for use with SystemObjectRegistry
///
/// This allows plugins to provide custom system objects that can be used
/// in ARO code like built-in objects.
///
/// ## Plugin Metadata Example
/// ```json
/// {
///   "systemObjects": [
///     {
///       "identifier": "redis",
///       "description": "Redis key-value store",
///       "capabilities": ["readable", "writable"],
///       "readSymbol": "redis_read",
///       "writeSymbol": "redis_write"
///     }
///   ]
/// }
/// ```
///
/// ## Plugin Implementation
/// ```swift
/// @_cdecl("redis_read")
/// public func redisRead(
///     _ propertyPtr: UnsafePointer<CChar>?,
///     _ resultPtr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
/// ) -> Int32 {
///     let key = propertyPtr.map { String(cString: $0) } ?? ""
///     guard let value = redis.get(key) else { return 1 }
///     resultPtr.pointee = strdup(value)
///     return 0
/// }
/// ```
public struct PluginSystemObjectWrapper: SystemObject {
    public static let identifier = "plugin"
    public static let description = "Plugin-provided system object"

    private let pluginIdentifier: String
    private let pluginDescription: String
    private let pluginCapabilities: SystemObjectCapabilities
    private let readFunc: PluginLoader.PluginReadFunction?
    private let writeFunc: PluginLoader.PluginWriteFunction?

    init(
        pluginIdentifier: String,
        pluginDescription: String,
        pluginCapabilities: SystemObjectCapabilities,
        readFunc: PluginLoader.PluginReadFunction?,
        writeFunc: PluginLoader.PluginWriteFunction?
    ) {
        self.pluginIdentifier = pluginIdentifier
        self.pluginDescription = pluginDescription
        self.pluginCapabilities = pluginCapabilities
        self.readFunc = readFunc
        self.writeFunc = writeFunc
    }

    public var capabilities: SystemObjectCapabilities {
        pluginCapabilities
    }

    public func read(property: String?) async throws -> any Sendable {
        guard let readFunc = readFunc else {
            throw SystemObjectError.notReadable(pluginIdentifier)
        }

        // Prepare result pointer
        var resultPtr: UnsafeMutablePointer<CChar>? = nil

        // Call the plugin function
        let status: Int32
        if let prop = property {
            status = prop.withCString { propPtr in
                readFunc(propPtr, &resultPtr)
            }
        } else {
            status = readFunc(nil, &resultPtr)
        }

        guard status == 0 else {
            let errorMessage = resultPtr.map { String(cString: $0) } ?? "Unknown error"
            resultPtr?.deallocate()
            throw SystemObjectError.readFailed(pluginIdentifier, message: errorMessage)
        }

        guard let resultPtr = resultPtr else {
            return ""
        }

        let result = String(cString: resultPtr)
        resultPtr.deallocate()

        // Parse JSON result
        if let data = result.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            return convertToSendable(json)
        }

        return result
    }

    public func write(_ value: any Sendable) async throws {
        guard let writeFunc = writeFunc else {
            throw SystemObjectError.notWritable(pluginIdentifier)
        }

        // Serialize value to JSON
        let valueJSON: String
        if let str = value as? String {
            valueJSON = "\"\(str.replacingOccurrences(of: "\"", with: "\\\""))\""
        } else if let data = try? JSONSerialization.data(withJSONObject: value),
                  let json = String(data: data, encoding: .utf8) {
            valueJSON = json
        } else {
            valueJSON = "\"\(value)\""
        }

        // Prepare result pointer
        var resultPtr: UnsafeMutablePointer<CChar>? = nil

        // Call the plugin function
        let status = valueJSON.withCString { valuePtr in
            writeFunc(valuePtr, &resultPtr)
        }

        guard status == 0 else {
            let errorMessage = resultPtr.map { String(cString: $0) } ?? "Unknown error"
            resultPtr?.deallocate()
            throw SystemObjectError.writeFailed(pluginIdentifier, message: errorMessage)
        }

        resultPtr?.deallocate()
    }

    /// Convert Any to Sendable for JSON parsing
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
            for (key, val) in dict {
                result[key] = convertToSendable(val)
            }
            return result
        case let arr as [Any]:
            return arr.map { convertToSendable($0) }
        case let bool as Bool:
            return bool
        default:
            return "\(value)"
        }
    }
}
