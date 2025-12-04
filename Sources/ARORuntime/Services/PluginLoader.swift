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

        // Find all .swift files in plugins directory
        let contents = try FileManager.default.contentsOfDirectory(
            at: pluginsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        let swiftFiles = contents.filter { $0.pathExtension == "swift" }

        for swiftFile in swiftFiles {
            do {
                try loadPlugin(from: swiftFile)
            } catch {
                print("[PluginLoader] Warning: Failed to load \(swiftFile.lastPathComponent): \(error)")
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

    /// Compile a Swift plugin to a dynamic library
    private func compilePlugin(source: URL, output: URL) throws {
        print("[PluginLoader] Compiling plugin: \(source.lastPathComponent)")

        let process = Process()
        #if os(Windows)
        // On Windows, swiftc is in PATH
        process.executableURL = URL(fileURLWithPath: "swiftc.exe")
        #else
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
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

        print("[PluginLoader] Compiled: \(output.lastPathComponent)")
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

                print("[PluginLoader] Loaded plugin service: \(name)")
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
              let services = metadata["services"] as? [[String: String]] else {
            throw PluginError.invalidMetadata(name, message: "Invalid JSON metadata")
        }

        // Register each service
        for service in services {
            guard let serviceName = service["name"],
                  let symbolName = service["symbol"] else {
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

            print("[PluginLoader] Registered plugin service: \(serviceName)")
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
            print("[PluginLoader] Unloaded plugin: \(name)")
        }
        loadedPlugins.removeAll()
        pluginFunctions.removeAll()
    }
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
