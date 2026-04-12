// ============================================================
// UnifiedPluginLoader.swift
// ARO Runtime - Unified Plugin Loader (ARO-0045)
// ============================================================

import Foundation
import AROParser
import Yams

/// Write debug message to stderr (only when ARO_DEBUG is set)
private func debugPrint(_ message: String) {
    guard ProcessInfo.processInfo.environment["ARO_DEBUG"] != nil else { return }
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// MARK: - Unified Plugin Loader

/// Unified plugin loader that supports dual-mode plugins
///
/// This loader scans the `Plugins/` directory for plugins that have a `plugin.yaml`
/// manifest file. It supports:
/// - ARO files (.aro) for declarative feature sets
/// - Swift plugins (existing behavior)
/// - Native plugins (C/C++, Rust) via FFI
/// - Python plugins via embedding
///
/// ## Plugin Discovery
/// ```
/// Plugins/
/// └── my-plugin/
///     ├── plugin.yaml          ← Required manifest
///     ├── features/            ← ARO feature sets
///     │   └── helpers.aro
///     └── Sources/             ← Swift plugin sources
///         └── MyPlugin.swift
/// ```
///
/// ## Lazy Loading
/// Plugins that declare their actions in `plugin.yaml` (via the `actions:` field on
/// a `provides:` entry) are loaded lazily: the manifest is parsed at startup to register
/// action stubs, but `dlopen`/`cargo build`/subprocess-launch is deferred to the first
/// time an action from that plugin is invoked.
public final class UnifiedPluginLoader: @unchecked Sendable {
    /// Shared instance
    public static let shared = UnifiedPluginLoader()

    /// The legacy plugin loader for Swift plugins
    private let legacyLoader = PluginLoader.shared

    /// Loaded ARO file plugins
    private var aroPlugins: [String: AROFilePlugin] = [:]

    /// Loaded native plugins (C/Rust)
    private var nativePlugins: [String: NativePluginHost] = [:]

    /// Loaded Python plugins
    private var pythonPlugins: [String: PythonPluginHost] = [:]

    /// Plugin manifests
    private var manifests: [String: UnifiedPluginManifest] = [:]

    /// Registered handles: maps handle (lowercased) → plugin name that claimed it.
    /// Used to enforce handle uniqueness across plugins.
    private var registeredHandles: [String: String] = [:]

    /// Source directories for loaded plugins, keyed by plugin name.
    /// Stored at load time to enable single-plugin reload.
    private var pluginDirectories: [String: URL] = [:]

    /// Lazy-load state for plugins whose actions are declared in the manifest.
    private var lazyPlugins: [String: LazyPluginEntry] = [:]

    /// Condition variable used to serialise concurrent lazy-load requests.
    private let loadCondition = NSCondition()

    /// Lock for thread safety (for non-load-condition paths)
    private let lock = NSLock()

    private init() {}

    // MARK: - Lazy Load State

    private enum LazyPluginEntry: @unchecked Sendable {
        /// Manifest parsed, library not yet loaded.
        case pendingNative(dir: URL, provide: UnifiedProvideEntry, effectiveHandle: String?)
        /// Manifest parsed, Python subprocess not yet started.
        case pendingPython(dir: URL, provide: UnifiedProvideEntry, effectiveHandle: String?)
        /// A thread is currently performing the load.
        case loading
        /// Successfully loaded native plugin.
        case loadedNative(NativePluginHost)
        /// Successfully loaded Python plugin.
        case loadedPython(PythonPluginHost)
        /// Load failed; error cached to avoid retries.
        case failed(Error)
    }

    // MARK: - Plugin Loading

    /// Load all plugins from the Plugins/ directory
    /// - Parameter directory: Base directory containing the `Plugins/` folder
    public func loadPlugins(from directory: URL) throws {
        let pluginsDir = directory.appendingPathComponent("Plugins")

        // Check if Plugins directory exists
        guard FileManager.default.fileExists(atPath: pluginsDir.path) else {
            // Fall back to legacy plugins/ directory
            try legacyLoader.loadPlugins(from: directory)
            return
        }

        // Scan for plugins with plugin.yaml
        let contents = try FileManager.default.contentsOfDirectory(
            at: pluginsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        debugPrint("[UnifiedPluginLoader] Found \(contents.count) items in Plugins/: \(contents.map { $0.lastPathComponent })")

        for item in contents {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }

            // Check for plugin.yaml
            let manifestPath = item.appendingPathComponent("plugin.yaml")
            if FileManager.default.fileExists(atPath: manifestPath.path) {
                do {
                    debugPrint("[UnifiedPluginLoader] Loading plugin: \(item.lastPathComponent)")
                    try loadPlugin(at: item, manifestPath: manifestPath)
                    debugPrint("[UnifiedPluginLoader] Successfully loaded plugin: \(item.lastPathComponent)")
                } catch {
                    print("[UnifiedPluginLoader] Warning: Failed to load \(item.lastPathComponent): \(error)")
                }
            } else {
                debugPrint("[UnifiedPluginLoader] Warning: \(item.lastPathComponent) missing plugin.yaml, skipping")
            }
        }

        // Also load legacy plugins from plugins/ directory
        try legacyLoader.loadPlugins(from: directory)
    }

    /// Load a single plugin
    private func loadPlugin(at pluginDir: URL, manifestPath: URL) throws {
        // Parse manifest
        let manifestYAML = try String(contentsOf: manifestPath, encoding: .utf8)
        let manifest = try parseManifest(yaml: manifestYAML)

        // Warn (don't fail) if the plugin declares an aro-version constraint that
        // isn't satisfied by the running binary. The plugin is still loaded so that
        // development and testing of newer plugins against older runtimes works.
        if let constraint = manifest.aroVersion {
            let currentVersion = currentAROVersion()
            if !semverSatisfies(version: currentVersion, constraint: constraint) {
                let msg = "[Plugin] Warning: '\(manifest.name)' requires ARO \(constraint), current version is \(currentVersion). Plugin may not work correctly.\n"
                FileHandle.standardError.write(Data(msg.utf8))
            }
        }

        lock.lock()
        manifests[manifest.name] = manifest
        pluginDirectories[manifest.name] = pluginDir
        lock.unlock()

        // Resolve and validate the effective namespace handle
        let effectiveHandle: String?
        if let handle = resolveEffectiveHandle(manifest: manifest) {
            if registerHandle(handle, pluginName: manifest.name) {
                effectiveHandle = handle
            } else {
                effectiveHandle = nil
            }
        } else {
            effectiveHandle = nil
        }

        // Load each provided component
        for provide in manifest.provides {
            let providePath = pluginDir.appendingPathComponent(provide.path)

            switch provide.type {
            case "aro-files":
                debugPrint("[UnifiedPluginLoader] Loading ARO files from: \(providePath.path)")
                try loadAROFiles(at: providePath, pluginName: manifest.name)

            case "aro-templates":
                debugPrint("[UnifiedPluginLoader] Loading ARO templates from: \(providePath.path)")
                try loadAROTemplates(at: providePath, pluginName: manifest.name)

            case "swift-plugin":
                // Swift plugins with @_cdecl are binary-compatible with C ABI
                // Route through NativePluginHost for unified qualifier support
                if let actions = provide.actions, !actions.isEmpty {
                    debugPrint("[UnifiedPluginLoader] Registering lazy stubs for swift-plugin '\(manifest.name)'")
                    registerLazyNativePlugin(
                        at: providePath,
                        pluginName: manifest.name,
                        provide: provide,
                        effectiveHandle: effectiveHandle,
                        actions: actions
                    )
                } else {
                    try loadNativePlugin(
                        at: providePath,
                        pluginName: manifest.name,
                        config: provide,
                        qualifierNamespace: effectiveHandle
                    )
                }

            case "rust-plugin", "c-plugin", "cpp-plugin":
                if let actions = provide.actions, !actions.isEmpty {
                    debugPrint("[UnifiedPluginLoader] Registering lazy stubs for '\(provide.type)' plugin '\(manifest.name)'")
                    registerLazyNativePlugin(
                        at: providePath,
                        pluginName: manifest.name,
                        provide: provide,
                        effectiveHandle: effectiveHandle,
                        actions: actions
                    )
                } else {
                    try loadNativePlugin(
                        at: providePath,
                        pluginName: manifest.name,
                        config: provide,
                        qualifierNamespace: effectiveHandle
                    )
                }

            case "python-plugin":
                if let actions = provide.actions, !actions.isEmpty {
                    debugPrint("[UnifiedPluginLoader] Registering lazy stubs for python-plugin '\(manifest.name)'")
                    registerLazyPythonPlugin(
                        at: providePath,
                        pluginName: manifest.name,
                        provide: provide,
                        effectiveHandle: effectiveHandle,
                        actions: actions
                    )
                } else {
                    try loadPythonPlugin(
                        at: providePath,
                        pluginName: manifest.name,
                        config: provide,
                        qualifierNamespace: effectiveHandle
                    )
                }

            default:
                print("[UnifiedPluginLoader] Warning: Unknown provide type '\(provide.type)'")
            }
        }
    }

    // MARK: - Lazy Plugin Registration

    /// Register lazy action stubs for a native (C/Rust/Swift) plugin whose actions
    /// are declared in `plugin.yaml`. The actual `dlopen`/compile is deferred to
    /// the first invocation.
    private func registerLazyNativePlugin(
        at providePath: URL,
        pluginName: String,
        provide: UnifiedProvideEntry,
        effectiveHandle: String?,
        actions: [ManifestActionEntry]
    ) {
        loadCondition.lock()
        lazyPlugins[pluginName] = .pendingNative(dir: providePath, provide: provide, effectiveHandle: effectiveHandle)
        loadCondition.unlock()

        registerLazyActionStubs(
            pluginName: pluginName,
            effectiveHandle: effectiveHandle,
            actions: actions,
            isNative: true
        )

        // Register lazy service wrapper for Call action support
        let wrapper = LazyNativeServiceWrapper(pluginName: pluginName, loader: self)
        try? ExternalServiceRegistry.shared.register(wrapper, withName: pluginName)
    }

    /// Register lazy action stubs for a Python plugin.
    private func registerLazyPythonPlugin(
        at providePath: URL,
        pluginName: String,
        provide: UnifiedProvideEntry,
        effectiveHandle: String?,
        actions: [ManifestActionEntry]
    ) {
        loadCondition.lock()
        lazyPlugins[pluginName] = .pendingPython(dir: providePath, provide: provide, effectiveHandle: effectiveHandle)
        loadCondition.unlock()

        registerLazyActionStubs(
            pluginName: pluginName,
            effectiveHandle: effectiveHandle,
            actions: actions,
            isNative: false
        )

        let wrapper = LazyPythonServiceWrapper(pluginName: pluginName, loader: self)
        try? ExternalServiceRegistry.shared.register(wrapper, withName: pluginName)
    }

    /// Register action stubs in the ActionRegistry for manifest-declared actions.
    private func registerLazyActionStubs(
        pluginName: String,
        effectiveHandle: String?,
        actions: [ManifestActionEntry],
        isNative: Bool
    ) {
        var semaphoreCount = 0
        let semaphore = DispatchSemaphore(value: 0)

        for action in actions {
            let actionVerbs = action.verbs


            for verb in actionVerbs {
                // Register both plain verb and namespaced verb (e.g. "hash" and "Hash.hash")
                var registeredVerbs: [String] = [verb]
                if let ns = effectiveHandle {
                    registeredVerbs.append("\(ns).\(verb)")
                }

                for registeredVerb in registeredVerbs {
                    let capturedVerb = verb
                    let capturedPlugin = pluginName
                    let capturedLoader = self

                    semaphoreCount += 1
                    Task {
                        await ActionRegistry.shared.registerDynamic(verb: registeredVerb) { result, object, context in
                            // Lazy-load on first invocation
                            let input = Self.buildPluginInput(result: result, object: object, context: context)
                            if isNative {
                                let host = try capturedLoader.ensureNativePluginLoaded(pluginName: capturedPlugin)
                                let output = try host.execute(action: capturedVerb, input: input)
                                context.bind(result.base, value: output)
                                return output
                            } else {
                                let host = try capturedLoader.ensurePythonPluginLoaded(pluginName: capturedPlugin)
                                let output = try host.execute(action: capturedVerb, input: input)
                                context.bind(result.base, value: output)
                                return output
                            }
                        }
                        semaphore.signal()
                    }
                }
            }
        }

        for _ in 0..<semaphoreCount {
            semaphore.wait()
        }
    }

    // MARK: - Lazy Load Execution

    /// Ensure a native plugin is loaded, loading it now if this is the first call.
    /// Thread-safe: concurrent callers wait for the first loader to finish.
    func ensureNativePluginLoaded(pluginName: String) throws -> NativePluginHost {
        loadCondition.lock()

        // Wait out any concurrent load in progress
        while case .loading = lazyPlugins[pluginName] {
            loadCondition.wait()
        }

        switch lazyPlugins[pluginName] {
        case .loadedNative(let host):
            loadCondition.unlock()
            return host
        case .failed(let error):
            loadCondition.unlock()
            throw error
        case .pendingNative(let dir, let provide, let effectiveHandle):
            // Claim the load slot
            lazyPlugins[pluginName] = .loading
            loadCondition.unlock()

            debugPrint("[UnifiedPluginLoader] Lazily loading native plugin '\(pluginName)'")
            do {
                let host = try NativePluginHost(
                    pluginPath: dir,
                    pluginName: pluginName,
                    config: provide,
                    qualifierNamespace: effectiveHandle
                )
                // Note: we do NOT call host.registerActions() here — lazy stubs are
                // already registered in ActionRegistry and delegate here directly.
                // host.init() does call loadPluginInfo() which registers qualifiers.

                loadCondition.lock()
                nativePlugins[pluginName] = host
                lazyPlugins[pluginName] = .loadedNative(host)
                loadCondition.broadcast()
                loadCondition.unlock()

                debugPrint("[UnifiedPluginLoader] Native plugin '\(pluginName)' loaded lazily")
                return host
            } catch {
                loadCondition.lock()
                lazyPlugins[pluginName] = .failed(error)
                loadCondition.broadcast()
                loadCondition.unlock()
                throw error
            }
        default:
            loadCondition.unlock()
            throw ActionError.runtimeError("Plugin '\(pluginName)' is not a lazy native plugin")
        }
    }

    /// Ensure a Python plugin is loaded, loading it now if this is the first call.
    func ensurePythonPluginLoaded(pluginName: String) throws -> PythonPluginHost {
        loadCondition.lock()

        while case .loading = lazyPlugins[pluginName] {
            loadCondition.wait()
        }

        switch lazyPlugins[pluginName] {
        case .loadedPython(let host):
            loadCondition.unlock()
            return host
        case .failed(let error):
            loadCondition.unlock()
            throw error
        case .pendingPython(let dir, let provide, let effectiveHandle):
            lazyPlugins[pluginName] = .loading
            loadCondition.unlock()

            debugPrint("[UnifiedPluginLoader] Lazily loading Python plugin '\(pluginName)'")
            do {
                let host = try PythonPluginHost(
                    pluginPath: dir,
                    pluginName: pluginName,
                    config: provide,
                    qualifierNamespace: effectiveHandle
                )
                loadCondition.lock()
                pythonPlugins[pluginName] = host
                lazyPlugins[pluginName] = .loadedPython(host)
                loadCondition.broadcast()
                loadCondition.unlock()

                debugPrint("[UnifiedPluginLoader] Python plugin '\(pluginName)' loaded lazily")
                return host
            } catch {
                loadCondition.lock()
                lazyPlugins[pluginName] = .failed(error)
                loadCondition.broadcast()
                loadCondition.unlock()
                throw error
            }
        default:
            loadCondition.unlock()
            throw ActionError.runtimeError("Plugin '\(pluginName)' is not a lazy Python plugin")
        }
    }

    // MARK: - Helpers

    /// Build input dict for a plugin call from ARO context — mirrors NativePluginActionWrapper.handle
    static func buildPluginInput(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) -> [String: any Sendable] {
        var input: [String: any Sendable] = [:]
        if let objValue = context.resolveAny(object.base) {
            input["data"] = objValue
            input["object"] = objValue
            input[object.base] = objValue
        }
        if let specifier = object.specifiers.first {
            input["qualifier"] = specifier
        }
        if let withArgs = context.resolveAny("_with_") as? [String: any Sendable] {
            input.merge(withArgs) { _, new in new }
        }
        if let exprArgs = context.resolveAny("_expression_") as? [String: any Sendable] {
            input.merge(exprArgs) { _, new in new }
        }
        return input
    }

    // MARK: - ARO File Loading

    /// Load ARO files as plugin feature sets
    private func loadAROFiles(at path: URL, pluginName: String) throws {
        // Find all .aro files
        let aroFiles: [URL]

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            aroFiles = try FileManager.default.contentsOfDirectory(
                at: path,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "aro" }
        } else if path.pathExtension == "aro" {
            aroFiles = [path]
        } else {
            aroFiles = []
        }

        debugPrint("[UnifiedPluginLoader] Found \(aroFiles.count) ARO files: \(aroFiles.map { $0.lastPathComponent })")

        for aroFile in aroFiles {
            debugPrint("[UnifiedPluginLoader] Loading ARO file: \(aroFile.lastPathComponent)")
            let aroPlugin = try AROFilePlugin(file: aroFile, pluginName: pluginName)

            lock.lock()
            aroPlugins[aroFile.lastPathComponent] = aroPlugin
            lock.unlock()

            // Register feature sets
            debugPrint("[UnifiedPluginLoader] Registering \(aroPlugin.featureSets.count) feature sets from \(aroFile.lastPathComponent)")
            aroPlugin.registerFeatureSets()
        }
    }

    // MARK: - Template Loading

    /// Load template files provided by a plugin (`aro-templates` provide type).
    ///
    /// Scans `path` for template files (`*.mustache`, `*.html`, `*.txt`) and registers
    /// them with the shared `AROTemplateService` when one is available, or logs their
    /// discovery when no template service has been configured.
    ///
    /// Template files are registered under their filename (e.g. `welcome.mustache`).
    /// If the provide path is a directory, all matching files in the directory are
    /// registered.  If it points to a single template file, only that file is registered.
    private func loadAROTemplates(at path: URL, pluginName: String) throws {
        let templateExtensions: Set<String> = ["mustache", "html", "txt"]

        // Collect template files
        var templateFiles: [URL]

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            let contents = try FileManager.default.contentsOfDirectory(
                at: path,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            templateFiles = contents.filter { templateExtensions.contains($0.pathExtension.lowercased()) }
        } else if templateExtensions.contains(path.pathExtension.lowercased()) {
            templateFiles = [path]
        } else {
            templateFiles = []
        }

        guard !templateFiles.isEmpty else {
            debugPrint("[UnifiedPluginLoader] No template files found at: \(path.path)")
            return
        }

        debugPrint("[UnifiedPluginLoader] Found \(templateFiles.count) template(s) in plugin '\(pluginName)'")

        // Register templates with the shared service when available.
        // AROTemplateService is created per-application and not a global singleton;
        // plugins that ship templates rely on the template service being configured
        // with the plugin's template directory (or register them as embedded templates).
        for templateFile in templateFiles {
            let templateName = templateFile.lastPathComponent
            do {
                let content = try String(contentsOf: templateFile, encoding: .utf8)
                // Register with the global embedded template store so that any
                // AROTemplateService instance created later can resolve the template
                // by name without knowing the plugin path.
                PluginTemplateStore.shared.register(name: templateName, content: content, pluginName: pluginName)
                debugPrint("[UnifiedPluginLoader] Registered template '\(templateName)' from plugin '\(pluginName)'")
            } catch {
                print("[UnifiedPluginLoader] Warning: Could not read template '\(templateName)' from '\(pluginName)': \(error)")
            }
        }
    }

    // MARK: - Swift Plugin Loading

    /// Load Swift plugins using legacy loader
    private func loadSwiftPlugin(at path: URL, pluginName: String) throws {
        // Check for Package.swift (Swift package)
        let packageSwift = path.appendingPathComponent("Package.swift")
        if FileManager.default.fileExists(atPath: packageSwift.path) {
            // Load Swift package plugin
            try legacyLoader.loadPackagePlugin(from: path, name: pluginName)
        } else {
            // Find .swift files in the path
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    // Directory of Swift files - find and load them
                    let contents = try FileManager.default.contentsOfDirectory(
                        at: path,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    )
                    let swiftFiles = contents.filter { $0.pathExtension == "swift" }
                    for swiftFile in swiftFiles {
                        do {
                            try legacyLoader.loadPlugin(from: swiftFile)
                        } catch {
                            print("[UnifiedPluginLoader] Warning: Failed to load Swift plugin \(swiftFile.lastPathComponent): \(error)")
                        }
                    }
                } else if path.pathExtension == "swift" {
                    // Single Swift file
                    try legacyLoader.loadPlugin(from: path)
                }
            }
        }
    }

    // MARK: - Native Plugin Loading

    /// Load native (C/C++/Rust) plugins
    private func loadNativePlugin(
        at path: URL,
        pluginName: String,
        config: UnifiedProvideEntry,
        qualifierNamespace: String?
    ) throws {
        let host = try NativePluginHost(
            pluginPath: path,
            pluginName: pluginName,
            config: config,
            qualifierNamespace: qualifierNamespace
        )

        lock.lock()
        nativePlugins[pluginName] = host
        lock.unlock()

        // Register actions from native plugin
        host.registerActions()

        // Register as an external service for Call action support
        let wrapper = NativePluginServiceWrapper(name: pluginName, host: host)
        try ExternalServiceRegistry.shared.register(wrapper, withName: pluginName)
    }

    // MARK: - Python Plugin Loading

    /// Load Python plugins
    private func loadPythonPlugin(
        at path: URL,
        pluginName: String,
        config: UnifiedProvideEntry,
        qualifierNamespace: String?
    ) throws {
        let host = try PythonPluginHost(
            pluginPath: path,
            pluginName: pluginName,
            config: config,
            qualifierNamespace: qualifierNamespace
        )

        lock.lock()
        pythonPlugins[pluginName] = host
        lock.unlock()

        // Register actions from Python plugin
        host.registerActions()

        // Register as an external service for Call action support
        let wrapper = PythonPluginServiceWrapper(name: pluginName, host: host)
        try ExternalServiceRegistry.shared.register(wrapper, withName: pluginName)
    }

    // MARK: - Manifest Parsing

    private func parseManifest(yaml: String) throws -> UnifiedPluginManifest {
        let decoder = YAMLDecoder()
        return try decoder.decode(UnifiedPluginManifest.self, from: yaml)
    }

    // MARK: - Plugin Info

    /// Get all loaded plugins
    public func getLoadedPlugins() -> [String: UnifiedPluginManifest] {
        lock.lock()
        defer { lock.unlock() }
        return manifests
    }

    /// Get a specific plugin
    public func getPlugin(name: String) -> UnifiedPluginManifest? {
        lock.lock()
        defer { lock.unlock() }
        return manifests[name]
    }

    /// Returns true if the plugin has been fully loaded (not just discovered).
    public func isPluginLoaded(name: String) -> Bool {
        loadCondition.lock()
        defer { loadCondition.unlock() }
        switch lazyPlugins[name] {
        case .loadedNative, .loadedPython: return true
        default: break
        }
        lock.lock()
        defer { lock.unlock() }
        return nativePlugins[name] != nil || pythonPlugins[name] != nil
    }

    // MARK: - Unload

    /// Unload all plugins
    public func unloadAll() {
        loadCondition.lock()
        // Unload any lazily-loaded native/python plugins
        for entry in lazyPlugins.values {
            switch entry {
            case .loadedNative(let host): host.unload()
            case .loadedPython(let host): host.unload()
            default: break
            }
        }
        lazyPlugins.removeAll()
        loadCondition.unlock()

        lock.lock()
        aroPlugins.removeAll()
        nativePlugins.values.forEach { $0.unload() }
        nativePlugins.removeAll()
        pythonPlugins.values.forEach { $0.unload() }
        pythonPlugins.removeAll()
        manifests.removeAll()
        registeredHandles.removeAll()
        pluginDirectories.removeAll()
        lock.unlock()

        // Remove all plugin-registered templates
        PluginTemplateStore.shared.removeAll()

        legacyLoader.unloadAll()
    }

    /// Unload a single plugin by name, releasing its library handle and
    /// deregistering its actions and qualifiers from all registries.
    ///
    /// - Parameter pluginName: The name declared in the plugin's `plugin.yaml`
    /// - Returns: `true` if the plugin was loaded and has been unloaded
    @discardableResult
    public func unload(pluginName: String) -> Bool {
        lock.lock()
        guard manifests[pluginName] != nil else {
            lock.unlock()
            return false
        }

        // Remove ARO file plugin (no native handle to close)
        aroPlugins.removeValue(forKey: pluginName)

        // Capture hosts before releasing lock so unload() runs outside it
        let native = nativePlugins.removeValue(forKey: pluginName)
        let python = pythonPlugins.removeValue(forKey: pluginName)

        manifests.removeValue(forKey: pluginName)
        pluginDirectories.removeValue(forKey: pluginName)
        // Release the handle so another plugin can claim it
        registeredHandles = registeredHandles.filter { $0.value != pluginName }
        lock.unlock()

        // Unload after releasing the lock (both call ActionRegistry / dlclose)
        native?.unload()
        python?.unload()

        // Remove plugin-registered templates
        PluginTemplateStore.shared.removeTemplates(forPlugin: pluginName)

        return true
    }

    /// Reload a single plugin: unload the current version then load the plugin
    /// fresh from its source directory on disk.
    ///
    /// - Parameter pluginName: The name declared in the plugin's `plugin.yaml`
    /// - Throws: If the plugin was never loaded or the fresh load fails
    public func reload(pluginName: String) throws {
        lock.lock()
        let dir = pluginDirectories[pluginName]
        lock.unlock()

        guard let pluginDir = dir else {
            throw UnifiedPluginError.notFound(pluginName)
        }

        unload(pluginName: pluginName)

        let manifestPath = pluginDir.appendingPathComponent("plugin.yaml")
        try loadPlugin(at: pluginDir, manifestPath: manifestPath)
    }

    // MARK: - Handle Resolution

    /// Resolve the effective namespace handle for a plugin.
    ///
    /// Priority order:
    /// 1. Root-level `handle:` from plugin.yaml (canonical, PascalCase)
    /// 2. `handler:` from the first `provides:` entry (legacy, emits deprecation warning)
    ///
    /// Returns nil only for plugins that have no native/Python actions (e.g., pure aro-files plugins).
    private func resolveEffectiveHandle(manifest: UnifiedPluginManifest) -> String? {
        // 1. Root-level handle (preferred)
        if let handle = manifest.handle {
            validateHandleFormat(handle, pluginName: manifest.name)
            return handle
        }

        // 2. Legacy: handler inside provides entries
        let legacyHandler = manifest.provides.compactMap { $0.handler }.first
        if let handler = legacyHandler {
            print("[Plugin] Warning: plugin '\(manifest.name)' uses deprecated 'handler:' inside 'provides:'. " +
                  "Move it to a root-level 'handle:' field in plugin.yaml (e.g., handle: \(toPascalCase(handler))).")
            return handler
        }

        return nil
    }

    /// Validate that a handle follows PascalCase convention.
    private func validateHandleFormat(_ handle: String, pluginName: String) {
        guard !handle.isEmpty else {
            print("[Plugin] Warning: plugin '\(pluginName)' has an empty handle.")
            return
        }
        guard handle.first?.isUppercase == true else {
            print("[Plugin] Warning: plugin '\(pluginName)' handle '\(handle)' should be PascalCase " +
                  "(e.g., '\(toPascalCase(handle))'). Handles must start with an uppercase letter.")
            return
        }
        if handle.contains("-") || handle.contains("_") {
            print("[Plugin] Warning: plugin '\(pluginName)' handle '\(handle)' should be PascalCase " +
                  "without hyphens or underscores.")
        }
    }

    /// Register a handle and check for uniqueness conflicts.
    /// - Returns: false if the handle is already claimed by another plugin.
    private func registerHandle(_ handle: String, pluginName: String) -> Bool {
        let key = handle.lowercased()
        if let existing = registeredHandles[key], existing != pluginName {
            print("[Plugin] Error: plugin '\(pluginName)' handle '\(handle)' conflicts with " +
                  "already-loaded plugin '\(existing)'. Plugin will be loaded without namespace.")
            return false
        }
        registeredHandles[key] = pluginName
        return true
    }

    /// Convert a lowercase/kebab-case string to PascalCase (for suggestions).
    private func toPascalCase(_ s: String) -> String {
        s.split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined()
    }
}

// MARK: - Errors

/// Errors thrown by `UnifiedPluginLoader`
public enum UnifiedPluginError: Error, CustomStringConvertible {
    /// No plugin with the given name is currently loaded
    case notFound(String)

    public var description: String {
        switch self {
        case .notFound(let name):
            return "Plugin '\(name)' is not loaded and cannot be reloaded."
        }
    }
}

// MARK: - Version Helpers (inline; AROPackageManager not imported here)

/// Returns the running ARO version via `git describe`, or `"dev"` as fallback.
/// Uses `"dev"` (non-semver) so that unversioned/CI builds satisfy all plugin
/// version constraints rather than triggering spurious warnings.
private func currentAROVersion() -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    task.arguments = ["-c", "git describe --tags --always --dirty 2>/dev/null || echo 'dev'"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do {
        try task.run()
        task.waitUntilExit()
        if let data = try? pipe.fileHandleForReading.readToEnd(),
           let output = String(data: data, encoding: .utf8) {
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    } catch {}
    return "dev"
}

/// Minimal semver constraint checker for aro-version warnings.
/// Supports `>=`, `<=`, `>`, `<`, `^`, `~`, space-separated compound constraints,
/// and exact matches. Mirrors the logic in `AROVersionChecker`.
private func semverSatisfies(version: String, constraint: String) -> Bool {
    // Non-semver versions (e.g. git SHAs from `git describe --always`) are
    // treated as development builds and always satisfy any constraint.
    func isSemver(_ v: String) -> Bool {
        let s = v.hasPrefix("v") ? String(v.dropFirst()) : v
        let base = s.components(separatedBy: CharacterSet(charactersIn: "-+"))[0]
        return base.split(separator: ".").allSatisfy { Int($0) != nil }
    }
    if !isSemver(version) { return true }

    func strip(_ v: String) -> String {
        var s = v.hasPrefix("v") ? String(v.dropFirst()) : v
        if let i = s.firstIndex(of: "-") { s = String(s[..<i]) }
        if let i = s.firstIndex(of: "+") { s = String(s[..<i]) }
        return s
    }
    func parts(_ v: String) -> [Int] {
        strip(v).split(separator: ".").prefix(3).compactMap { Int($0) }
    }
    func cmp(_ a: String, _ b: String) -> Int {
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x - y }
        }
        return 0
    }
    func satisfiesClause(_ v: String, _ clause: String) -> Bool {
        let clean = strip(v)
        if clause.hasPrefix(">=") { return cmp(clean, String(clause.dropFirst(2))) >= 0 }
        if clause.hasPrefix("<=") { return cmp(clean, String(clause.dropFirst(2))) <= 0 }
        if clause.hasPrefix(">")  { return cmp(clean, String(clause.dropFirst(1))) > 0 }
        if clause.hasPrefix("<")  { return cmp(clean, String(clause.dropFirst(1))) < 0 }
        if clause.hasPrefix("^") {
            let req = parts(String(clause.dropFirst()))
            let ins = parts(clean)
            guard !ins.isEmpty, !req.isEmpty else { return false }
            return ins[0] == req[0] && cmp(clean, String(clause.dropFirst())) >= 0
        }
        if clause.hasPrefix("~") {
            let req = parts(String(clause.dropFirst()))
            let ins = parts(clean)
            guard ins.count >= 2, req.count >= 2 else { return false }
            return ins[0] == req[0] && ins[1] == req[1] && cmp(clean, String(clause.dropFirst())) >= 0
        }
        let norm = clause.hasPrefix("v") ? String(clause.dropFirst()) : clause
        return clean == norm
    }
    let clauses = constraint.split(separator: " ").map { String($0).trimmingCharacters(in: .whitespaces) }
    return clauses.allSatisfy { satisfiesClause(version, $0) }
}

// MARK: - Unified Plugin Manifest (Simplified)

/// Simplified manifest for internal use
public struct UnifiedPluginManifest: Codable, Sendable {
    let name: String
    let version: String
    let description: String?
    let author: String?
    let license: String?
    let aroVersion: String?
    let source: UnifiedSourceInfo?
    let provides: [UnifiedProvideEntry]
    let dependencies: [String: UnifiedDependencySpec]?

    /// Root-level namespace handle (PascalCase, e.g. `Markdown`, `Hash`, `Collections`).
    let handle: String?

    /// Platform-specific configuration (ARO-0073)
    let platforms: UnifiedPlatformConfig?

    enum CodingKeys: String, CodingKey {
        case name, version, description, author, license, handle, platforms
        case aroVersion = "aro-version"
        case source, provides, dependencies
    }
}

/// Platform-specific configuration (ARO-0073)
public struct UnifiedPlatformConfig: Codable, Sendable {
    let macos: PlatformRequirement?
    let linux: PlatformRequirement?
    let windows: PlatformRequirement?
}

/// Requirements for a specific platform
public struct PlatformRequirement: Codable, Sendable {
    let minVersion: String?
    let architectures: [String]?
    let distributions: [String]?

    enum CodingKeys: String, CodingKey {
        case minVersion = "min-version"
        case architectures, distributions
    }
}

public struct UnifiedSourceInfo: Codable, Sendable {
    let git: String?
    let ref: String?
    let commit: String?
}

public struct UnifiedProvideEntry: Codable, Sendable {
    let type: String
    let path: String
    /// The qualifier namespace (handler) for this plugin component.
    ///
    /// When set, qualifiers from this plugin are accessed as `handler.qualifier`
    /// in ARO code (e.g., `<list: collections.reverse>` where `handler: collections`).
    /// Falls back to the plugin name if not specified.
    let handler: String?
    let build: UnifiedBuildConfig?
    let python: UnifiedPythonConfig?
    /// Manifest-declared actions for this component.
    ///
    /// When present, the loader registers lazy action stubs at startup and defers
    /// `dlopen`/`cargo build`/subprocess-launch to the first invocation.
    let actions: [ManifestActionEntry]?
}

/// An action declared in a plugin manifest's `provides[].actions[]` array.
///
/// Used for lazy loading: the loader can register action stubs from the manifest
/// without loading the plugin library.
public struct ManifestActionEntry: Codable, Sendable {
    /// Canonical action name (e.g. "Hash", "Greet").
    let name: String
    /// Verbs that invoke this action (e.g. ["hash", "digest"]).
    let verbs: [String]
    /// Semantic role ("own", "request", "response", "export"). Optional.
    let role: String?
    /// Valid prepositions ("from", "with", …). Optional.
    let prepositions: [String]?
    /// Human-readable description. Optional.
    let description: String?
    /// Version when this action was introduced. Optional.
    let since: String?
}

public struct UnifiedBuildConfig: Codable, Sendable {
    let cargoTarget: String?
    let compiler: String?
    let flags: [String]?
    let output: String?

    enum CodingKeys: String, CodingKey {
        case cargoTarget = "cargo-target"
        case compiler, flags, output
    }
}

public struct UnifiedPythonConfig: Codable, Sendable {
    let minVersion: String?
    let requirements: String?

    enum CodingKeys: String, CodingKey {
        case minVersion = "min-version"
        case requirements
    }
}

public struct UnifiedDependencySpec: Codable, Sendable {
    let git: String
    let ref: String?
}

// MARK: - Native Plugin Service Wrapper

/// Wraps a native (C/C++/Rust) plugin as an AROService for Call action support
struct NativePluginServiceWrapper: AROService {
    static let name: String = "_native_plugin_"

    private let serviceName: String
    private let host: NativePluginHost

    init(name: String, host: NativePluginHost) {
        self.serviceName = name
        self.host = host
    }

    init() throws {
        fatalError("NativePluginServiceWrapper requires name and host")
    }

    func call(_ method: String, args: [String: any Sendable]) async throws -> any Sendable {
        return try host.execute(action: method, input: args)
    }
}

// MARK: - Lazy Service Wrappers

/// Lazy service wrapper for native plugins — triggers load on first Call action use.
struct LazyNativeServiceWrapper: AROService {
    static let name: String = "_lazy_native_plugin_"

    private let pluginName: String
    private let loader: UnifiedPluginLoader

    init(pluginName: String, loader: UnifiedPluginLoader) {
        self.pluginName = pluginName
        self.loader = loader
    }

    init() throws {
        fatalError("LazyNativeServiceWrapper requires pluginName and loader")
    }

    func call(_ method: String, args: [String: any Sendable]) async throws -> any Sendable {
        let host = try loader.ensureNativePluginLoaded(pluginName: pluginName)
        return try host.execute(action: method, input: args)
    }
}

/// Lazy service wrapper for Python plugins — triggers load on first Call action use.
struct LazyPythonServiceWrapper: AROService {
    static let name: String = "_lazy_python_plugin_"

    private let pluginName: String
    private let loader: UnifiedPluginLoader

    init(pluginName: String, loader: UnifiedPluginLoader) {
        self.pluginName = pluginName
        self.loader = loader
    }

    init() throws {
        fatalError("LazyPythonServiceWrapper requires pluginName and loader")
    }

    func call(_ method: String, args: [String: any Sendable]) async throws -> any Sendable {
        let host = try loader.ensurePythonPluginLoaded(pluginName: pluginName)
        return try host.execute(action: method, input: args)
    }
}

// MARK: - Plugin Template Store

/// Thread-safe store for templates registered by plugins at load time.
///
/// Plugins that ship templates via the `aro-templates` provide type register
/// their files here during `loadPlugins(from:)`.  The `AROTemplateService`
/// consults this store via `PluginTemplateStore.shared.allTemplates` when
/// initialising embedded templates, enabling plugin-supplied templates to be
/// resolved by name without knowing plugin paths.
///
/// ## Usage in AROTemplateService
/// ```swift
/// let pluginTemplates = PluginTemplateStore.shared.allTemplates
/// templateService.registerEmbeddedTemplates(pluginTemplates)
/// ```
public final class PluginTemplateStore: @unchecked Sendable {
    /// Shared instance
    public static let shared = PluginTemplateStore()

    private let lock = NSLock()

    /// Registered templates: template name → (content, plugin name)
    private var templates: [String: (content: String, pluginName: String)] = [:]

    private init() {}

    /// Register a template.
    /// - Parameters:
    ///   - name: Template filename (e.g. `welcome.mustache`)
    ///   - content: Raw template content
    ///   - pluginName: The plugin that owns this template
    public func register(name: String, content: String, pluginName: String) {
        lock.lock()
        defer { lock.unlock() }
        if let existing = templates[name] {
            print("[PluginTemplateStore] Warning: template '\(name)' from plugin '\(pluginName)' " +
                  "overwrites existing entry from plugin '\(existing.pluginName)'.")
        }
        templates[name] = (content: content, pluginName: pluginName)
    }

    /// All registered templates as a `[name: content]` dictionary.
    public var allTemplates: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return templates.mapValues { $0.content }
    }

    /// Look up a single template by name.
    public func template(named name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return templates[name]?.content
    }

    /// Remove all registered templates (used in tests / unload scenarios).
    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        templates.removeAll()
    }

    /// Remove all templates registered by a specific plugin.
    public func removeTemplates(forPlugin pluginName: String) {
        lock.lock()
        defer { lock.unlock() }
        templates = templates.filter { $0.value.pluginName != pluginName }
    }
}

// MARK: - Python Plugin Service Wrapper

/// Wraps a Python plugin as an AROService for Call action support
struct PythonPluginServiceWrapper: AROService {
    static let name: String = "_python_plugin_"

    private let serviceName: String
    private let host: PythonPluginHost

    init(name: String, host: PythonPluginHost) {
        self.serviceName = name
        self.host = host
    }

    init() throws {
        fatalError("PythonPluginServiceWrapper requires name and host")
    }

    func call(_ method: String, args: [String: any Sendable]) async throws -> any Sendable {
        return try host.execute(action: method, input: args)
    }
}
