// ============================================================
// EmbeddedPythonHost.swift
// ARO Runtime - Embedded Python Interpreter Host
// ============================================================
//
// Provides in-process Python execution for compiled binaries.
// Uses dlsym(RTLD_DEFAULT) to call Python C API functions that
// are statically linked into the binary via libpython3.a.
//
// No Python installation needed on the target machine.

import Foundation

/// Host for executing Python plugins in-process via the embedded Python interpreter.
///
/// When `aro build` detects Python plugins, it links `libpython3` into the binary
/// and embeds the plugin source, stdlib, and pip dependencies. This host initializes
/// the embedded interpreter and executes plugins directly — no subprocess, no /tmp.
///
/// ## Architecture
///
/// ```
/// Binary startup
///   → aro_register_embedded_python_plugin(name, yaml, source, depsZip)
///   → aro_load_precompiled_plugins()
///     → EmbeddedPythonHost.shared.initialize()
///     → Extract deps to ~/.aro/cache/<hash>/
///     → Py_Initialize() via dlsym
///     → Execute plugin source in-process
/// ```
public final class EmbeddedPythonHost: @unchecked Sendable {

    // MARK: - Singleton

    public static let shared = EmbeddedPythonHost()

    // MARK: - State

    private var initialized = false
    private let lock = NSLock()

    /// Cache directory for extracted Python dependencies
    private var cacheDir: URL?

    /// Python stdlib path (extracted from embedded data)
    private var stdlibPath: URL?

    /// Site-packages path (extracted from embedded deps)
    private var sitePackagesPath: URL?

    // MARK: - Python C API Function Types

    private typealias Py_InitializeExFunc = @convention(c) (Int32) -> Void
    private typealias Py_FinalizeExFunc = @convention(c) () -> Int32
    private typealias Py_IsInitializedFunc = @convention(c) () -> Int32
    private typealias PyRun_SimpleStringFunc = @convention(c) (UnsafePointer<CChar>) -> Int32
    private typealias Py_SetPythonHomeFunc = @convention(c) (UnsafePointer<wchar_t>) -> Void
    private typealias Py_SetPathFunc = @convention(c) (UnsafePointer<wchar_t>) -> Void
    private typealias PyImport_ImportModuleFunc = @convention(c) (UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
    private typealias PyObject_GetAttrStringFunc = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
    private typealias PyObject_CallFunctionFunc = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
    private typealias PyObject_CallMethodFunc = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CChar>, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
    private typealias PyUnicode_AsUTF8Func = @convention(c) (UnsafeMutableRawPointer) -> UnsafePointer<CChar>?
    private typealias PyUnicode_FromStringFunc = @convention(c) (UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
    private typealias Py_DecRefFunc = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias PyErr_PrintFunc = @convention(c) () -> Void
    private typealias PyErr_OccurredFunc = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias PyTuple_NewFunc = @convention(c) (Int) -> UnsafeMutableRawPointer?
    private typealias PyTuple_SetItemFunc = @convention(c) (UnsafeMutableRawPointer, Int, UnsafeMutableRawPointer) -> Int32
    private typealias PyObject_CallObjectFunc = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?

    // MARK: - Resolved Function Pointers

    private var pyInitializeEx: Py_InitializeExFunc?
    private var pyFinalizeEx: Py_FinalizeExFunc?
    private var pyIsInitialized: Py_IsInitializedFunc?
    private var pyRunSimpleString: PyRun_SimpleStringFunc?
    private var pySetPythonHome: Py_SetPythonHomeFunc?
    private var pySetPath: Py_SetPathFunc?
    private var pyImportImportModule: PyImport_ImportModuleFunc?
    private var pyObjectGetAttrString: PyObject_GetAttrStringFunc?
    private var pyUnicodeAsUTF8: PyUnicode_AsUTF8Func?
    private var pyUnicodeFromString: PyUnicode_FromStringFunc?
    private var pyDecRef: Py_DecRefFunc?
    private var pyErrPrint: PyErr_PrintFunc?
    private var pyErrOccurred: PyErr_OccurredFunc?
    private var pyTupleNew: PyTuple_NewFunc?
    private var pyTupleSetItem: PyTuple_SetItemFunc?
    private var pyObjectCallObject: PyObject_CallObjectFunc?

    // MARK: - Initialization

    private init() {}

    /// Check whether the Python C API symbols are available in this binary.
    public var isAvailable: Bool {
        return dlsym(nil, "Py_InitializeEx") != nil
    }

    /// Initialize the embedded Python interpreter.
    ///
    /// - Parameter pythonHome: Path to the extracted Python home directory (stdlib + deps)
    /// - Returns: true if initialization succeeded
    public func initialize(pythonHome: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if initialized { return true }

        // Resolve all needed Python C API functions via dlsym
        guard resolveFunctions() else {
            print("[EmbeddedPython] Python C API not found in binary — libpython not linked")
            return false
        }

        // Set Python home before initialization
        let homePath = pythonHome.path
        let wideHome = homePath.withCString { cStr -> [wchar_t] in
            let len = mbstowcs(nil, cStr, 0)
            var buf = [wchar_t](repeating: 0, count: len + 1)
            mbstowcs(&buf, cStr, len + 1)
            return buf
        }
        wideHome.withUnsafeBufferPointer { ptr in
            pySetPythonHome?(ptr.baseAddress!)
        }

        // Initialize Python (0 = don't register signal handlers)
        pyInitializeEx?(0)

        guard pyIsInitialized?() != 0 else {
            print("[EmbeddedPython] Py_Initialize failed")
            return false
        }

        // Add site-packages to sys.path if available
        if let sitePkgs = sitePackagesPath {
            let code = "import sys; sys.path.insert(0, '\(sitePkgs.path)')"
            _ = pyRunSimpleString?(code)
        }

        initialized = true
        return true
    }

    /// Shut down the embedded Python interpreter.
    public func finalize() {
        lock.lock()
        defer { lock.unlock() }

        if initialized {
            _ = pyFinalizeEx?()
            initialized = false
        }
    }

    // MARK: - Plugin Execution

    /// Call a Python plugin function and return its JSON result.
    ///
    /// - Parameters:
    ///   - modulePath: Directory containing the plugin .py file
    ///   - moduleName: Python module name (filename without .py)
    ///   - functionName: Function to call (e.g., "aro_plugin_info", "aro_plugin_execute")
    ///   - args: Arguments as strings (passed positionally)
    /// - Returns: JSON string result, or nil on error
    public func callPluginFunction(
        modulePath: String,
        moduleName: String,
        functionName: String,
        args: [String] = []
    ) -> String? {
        lock.lock()
        defer { lock.unlock() }

        guard initialized else { return nil }

        // Add module path to sys.path
        let addPathCode = "import sys\nif '\(modulePath)' not in sys.path: sys.path.insert(0, '\(modulePath)')"
        _ = pyRunSimpleString?(addPathCode)

        // Import the module
        guard let module = moduleName.withCString({ pyImportImportModule?($0) }) else {
            pyErrPrint?()
            return nil
        }

        // Get the function
        guard let func_ = functionName.withCString({ pyObjectGetAttrString?(module, $0) }) else {
            pyDecRef?(module)
            pyErrPrint?()
            return nil
        }

        // Build arguments tuple
        let result: UnsafeMutableRawPointer?
        if args.isEmpty {
            result = pyObjectCallObject?(func_, nil)
        } else {
            guard let tuple = pyTupleNew?(args.count) else {
                pyDecRef?(func_)
                pyDecRef?(module)
                return nil
            }
            for (i, arg) in args.enumerated() {
                if let pyStr = arg.withCString({ pyUnicodeFromString?($0) }) {
                    _ = pyTupleSetItem?(tuple, i, pyStr)
                    // Note: PyTuple_SetItem steals the reference, don't decref pyStr
                }
            }
            result = pyObjectCallObject?(func_, tuple)
            pyDecRef?(tuple)
        }

        pyDecRef?(func_)
        pyDecRef?(module)

        guard let result else {
            pyErrPrint?()
            return nil
        }

        // Convert result to string
        let resultStr: String?
        if let utf8 = pyUnicodeAsUTF8?(result) {
            resultStr = String(cString: utf8)
        } else {
            // Try str(result)
            let code = """
            import json as __json
            __aro_result = __json.dumps(\(functionName)_result) if not isinstance(\(functionName)_result, str) else \(functionName)_result
            """
            _ = pyRunSimpleString?(code)
            resultStr = nil
        }
        pyDecRef?(result)

        return resultStr
    }

    // MARK: - Cache Management

    /// Set up the cache directory for extracted Python dependencies.
    ///
    /// - Parameter binaryHash: Hash of the binary to key the cache
    /// - Returns: The cache directory URL
    public func setupCache(binaryHash: String) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cache = home.appendingPathComponent(".aro/cache/python-\(binaryHash)")
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        self.cacheDir = cache
        return cache
    }

    /// Extract embedded stdlib zip to the cache directory.
    ///
    /// - Parameters:
    ///   - data: Zip data containing Python stdlib
    ///   - cacheDir: Target cache directory
    /// - Returns: Path to extracted stdlib, or nil on failure
    public func extractStdlib(_ data: Data, to cacheDir: URL) -> URL? {
        let stdlibDir = cacheDir.appendingPathComponent("lib")
        if FileManager.default.fileExists(atPath: stdlibDir.path) {
            self.stdlibPath = stdlibDir
            return stdlibDir  // Already extracted
        }

        let zipPath = cacheDir.appendingPathComponent("stdlib.zip")
        do {
            try data.write(to: zipPath)
            // Use Python's zipfile or system unzip to extract
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-qo", zipPath.path, "-d", stdlibDir.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()

            try? FileManager.default.removeItem(at: zipPath)
            self.stdlibPath = stdlibDir
            return stdlibDir
        } catch {
            return nil
        }
    }

    /// Extract embedded site-packages to the cache directory.
    ///
    /// - Parameters:
    ///   - data: Zip data containing installed packages
    ///   - cacheDir: Target cache directory
    /// - Returns: Path to site-packages, or nil on failure
    public func extractSitePackages(_ data: Data, to cacheDir: URL) -> URL? {
        let sitePkgs = cacheDir.appendingPathComponent("site-packages")
        if FileManager.default.fileExists(atPath: sitePkgs.path) {
            self.sitePackagesPath = sitePkgs
            return sitePkgs  // Already extracted
        }

        let zipPath = cacheDir.appendingPathComponent("site-packages.zip")
        do {
            try data.write(to: zipPath)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-qo", zipPath.path, "-d", sitePkgs.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()

            try? FileManager.default.removeItem(at: zipPath)
            self.sitePackagesPath = sitePkgs
            return sitePkgs
        } catch {
            return nil
        }
    }

    /// Extract a plugin's source files to the cache directory.
    ///
    /// - Parameters:
    ///   - name: Plugin name
    ///   - source: Plugin source code
    ///   - cacheDir: Target cache directory
    /// - Returns: Tuple of (module directory path, module name)
    public func extractPluginSource(name: String, source: String, to cacheDir: URL) -> (path: String, module: String)? {
        let pluginDir = cacheDir.appendingPathComponent("plugins/\(name)")
        try? FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        let moduleName = "plugin"
        let filePath = pluginDir.appendingPathComponent("\(moduleName).py")

        // Only write if different (avoid unnecessary I/O)
        if let existing = try? String(contentsOf: filePath, encoding: .utf8), existing == source {
            return (pluginDir.path, moduleName)
        }

        do {
            try source.write(to: filePath, atomically: true, encoding: .utf8)
            return (pluginDir.path, moduleName)
        } catch {
            return nil
        }
    }

    // MARK: - Private

    private func resolveFunctions() -> Bool {
        pyInitializeEx = resolve("Py_InitializeEx")
        pyFinalizeEx = resolve("Py_FinalizeEx")
        pyIsInitialized = resolve("Py_IsInitialized")
        pyRunSimpleString = resolve("PyRun_SimpleString")
        pySetPythonHome = resolve("Py_SetPythonHome")
        pySetPath = resolve("Py_SetPath")
        pyImportImportModule = resolve("PyImport_ImportModule")
        pyObjectGetAttrString = resolve("PyObject_GetAttrString")
        pyUnicodeAsUTF8 = resolve("PyUnicode_AsUTF8")
        pyUnicodeFromString = resolve("PyUnicode_FromString")
        pyDecRef = resolve("Py_DecRef")
        pyErrPrint = resolve("PyErr_Print")
        pyErrOccurred = resolve("PyErr_Occurred")
        pyTupleNew = resolve("PyTuple_New")
        pyTupleSetItem = resolve("PyTuple_SetItem")
        pyObjectCallObject = resolve("PyObject_CallObject")

        // Minimum required: init + run string + import + call
        return pyInitializeEx != nil && pyRunSimpleString != nil
            && pyImportImportModule != nil && pyObjectCallObject != nil
    }

    private func resolve<T>(_ name: String) -> T? {
        // RTLD_DEFAULT (nil on Darwin/Linux) searches all loaded images
        guard let sym = dlsym(nil, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }
}
