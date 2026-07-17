// ============================================================
// PluginCompiler.swift
// ARO CLI - Managed plugin pre-compilation for native builds
// ============================================================
//
// Extracted from BuildCommand (#366): the plugin clone/compile/rename/embed
// pipeline used to live inline in `BuildCommand.run()`. Pulling it into a
// dedicated type keeps the build flow readable and lets other commands reuse
// the same static-linking logic.
//
// Behaviour is intentionally identical to the previous inline version:
// verbose output text, warnings, and error/exit paths are preserved verbatim.

#if !os(Windows)

import ArgumentParser
import Foundation
import AROCompiler
import ARORuntime

/// Pre-compiles managed plugins (from a `Plugins/` directory) for inclusion in
/// a native binary produced by `aro build`.
///
/// - Native plugins (C/Rust/Swift) are compiled, their symbols renamed to avoid
///   collisions, and returned as `StaticPluginInfo` for static linking plus
///   `StaticPluginIRInfo` for LLVM IR generation.
/// - Python plugins are returned as `EmbeddedPythonPluginIRInfo` (they run via an
///   embedded interpreter) or, when python3 is unavailable, fall back to legacy
///   base64 embedding.
///
/// The type is a `struct` with explicit inputs; it holds no mutable shared state,
/// matching the `Sendable`, value-typed style of the CLI layer.
struct PluginCompiler: Sendable {

    /// Directory containing the managed plugin sources (`Plugins/` or `plugins/`).
    let sourcePluginsDir: URL
    /// Directory the managed plugin compiler writes compiled artifacts into.
    let outputPluginsDir: URL
    /// Directory under `.build` where renamed static object files are staged.
    let staticBuildDir: URL
    /// Whether to print progress to stdout.
    let verbose: Bool

    init(sourcePluginsDir: URL, outputPluginsDir: URL, staticBuildDir: URL, verbose: Bool) {
        self.sourcePluginsDir = sourcePluginsDir
        self.outputPluginsDir = outputPluginsDir
        self.staticBuildDir = staticBuildDir
        self.verbose = verbose
    }

    /// Everything the build flow needs from plugin pre-compilation, ready to feed
    /// into LLVM IR generation and linking.
    struct Result {
        /// Python plugins that fall back to legacy base64 embedding (run via subprocess).
        var embeddedPlugins: [(name: String, yaml: String, base64Library: String)] = []
        /// Native plugins ready to statically link (renamed .o files + symbols).
        var staticPluginInfos: [StaticPluginInfo] = []
        /// Native plugin metadata for LLVM IR generation.
        var staticPluginIRInfos: [StaticPluginIRInfo] = []
        /// Python plugins embedded via the in-binary interpreter.
        var pythonPluginIRInfos: [EmbeddedPythonPluginIRInfo] = []
        /// Extra linker flags (e.g. `-lpython3.12`) required by embedded Python plugins.
        var pythonLinkerFlags: [String] = []
    }

    /// Run the full plugin pre-compilation pipeline.
    ///
    /// - Parameter buildDir: the application's `.build` directory, used for the
    ///   Python venv when embedded Python plugins declare requirements.
    /// - Throws: `ExitCode.failure` when a native plugin fails to produce object
    ///   files or is missing the `aro_plugin_info` symbol — matching the previous
    ///   inline behaviour that aborts the build.
    func compile(buildDir: URL) async throws -> Result {
        var result = Result()

        guard FileManager.default.fileExists(atPath: sourcePluginsDir.path) else {
            return result
        }

        if verbose { print("Compiling managed plugins...") }

        var hasPythonPlugins = false
        var pythonRequirementsFiles: [URL] = []

        do {
            let sourceResolved = sourcePluginsDir.standardizedFileURL.path
            let outputResolved = outputPluginsDir.standardizedFileURL.path
            if sourceResolved != outputResolved,
               FileManager.default.fileExists(atPath: outputPluginsDir.path) {
                try FileManager.default.removeItem(at: outputPluginsDir)
            }
            let pluginCompileFailures = try await PluginLoader.shared.compileManagedPluginsParallel(
                from: sourcePluginsDir, to: outputPluginsDir
            )
            for (failedPlugin, compileError) in pluginCompileFailures.sorted(by: { $0.key < $1.key }) {
                print("Warning: plugin '\(failedPlugin)' failed to compile:")
                print("  \(compileError)")
            }

            let symbolRenamer = PluginSymbolRenamer(verbose: verbose)
            try? FileManager.default.createDirectory(at: staticBuildDir, withIntermediateDirectories: true)

            // Process each compiled plugin
            let pluginDirs = (try? FileManager.default.contentsOfDirectory(
                at: outputPluginsDir,
                includingPropertiesForKeys: [.isDirectoryKey]
            )) ?? []
            for pluginDir in pluginDirs {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: pluginDir.path, isDirectory: &isDir),
                      isDir.boolValue else { continue }
                let pluginName = pluginDir.lastPathComponent
                let yamlPath = pluginDir.appendingPathComponent("plugin.yaml")
                let yamlContent = (try? String(contentsOf: yamlPath, encoding: .utf8)) ?? ""

                // Check if this is a Python plugin
                let isPythonPlugin = yamlContent.contains("python-plugin")
                if isPythonPlugin {
                    // Embedded Python: read source, install deps, link libpython
                    let searchDirs = [
                        pluginDir,
                        pluginDir.appendingPathComponent("src"),
                        sourcePluginsDir.appendingPathComponent(pluginName).appendingPathComponent("src"),
                    ]
                    for searchDir in searchDirs {
                        guard FileManager.default.fileExists(atPath: searchDir.path) else { continue }
                        let contents = (try? FileManager.default.contentsOfDirectory(at: searchDir, includingPropertiesForKeys: nil)) ?? []
                        if let pyFile = contents.first(where: { $0.pathExtension == "py" }) {
                            if let source = try? String(contentsOf: pyFile, encoding: .utf8) {
                                result.pythonPluginIRInfos.append(EmbeddedPythonPluginIRInfo(
                                    name: pluginName,
                                    yaml: yamlContent,
                                    source: source
                                ))
                                hasPythonPlugins = true
                                if verbose {
                                    print("  Python plugin '\(pluginName)' (\(source.count) bytes source)")
                                }
                            }
                            break
                        }
                    }

                    // Check for requirements.txt and install deps
                    let reqCandidates = [
                        pluginDir.appendingPathComponent("requirements.txt"),
                        sourcePluginsDir.appendingPathComponent(pluginName).appendingPathComponent("requirements.txt"),
                    ]
                    if let reqFile = reqCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                        pythonRequirementsFiles.append(reqFile)
                    }

                    continue
                }

                // Skip plugins that declare no native code (e.g. aro-files-only
                // plugins that ship feature sets and nothing to statically link).
                // Without this guard, the hard-error path below fires on any
                // plugin that legitimately has no .o files to bake.
                let hasNativeType = yamlContent.contains("swift-plugin")
                    || yamlContent.contains("c-plugin")
                    || yamlContent.contains("cpp-plugin")
                    || yamlContent.contains("rust-plugin")
                if !hasNativeType {
                    if verbose {
                        print("  Skipping '\(pluginName)' — no native plugin code to statically link")
                    }
                    continue
                }

                // Native plugin: find .o files from SPM/cargo build, rename symbols, link statically
                var objectFiles: [String] = []

                // Create a working directory for this plugin's renamed object files.
                // Wipe it on every build: extractObjectFiles lists every .o in the
                // dir, so leftover renamed files from a previous build would be
                // treated as fresh extracts and renamed-again, producing duplicate
                // symbols at link time.
                let pluginWorkDir = staticBuildDir.appendingPathComponent(pluginName)
                try? FileManager.default.removeItem(at: pluginWorkDir)
                try? FileManager.default.createDirectory(at: pluginWorkDir, withIntermediateDirectories: true)

                // Strategy 1: Find .o files from SPM build directory (Swift package plugins)
                // After `swift build`, .o files are in .build/<triple>/release/<Module>.build/*.o
                // The managed plugin compiler uses .build-aro as the build directory
                let sourcePluginDir = sourcePluginsDir.appendingPathComponent(pluginName)
                let spmBuildCandidates = [
                    pluginDir.appendingPathComponent(".build-aro"),
                    pluginDir.appendingPathComponent(".build"),
                    sourcePluginDir.appendingPathComponent(".build-aro"),
                    sourcePluginDir.appendingPathComponent(".build"),
                ]
                let spmBuildDir = spmBuildCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
                    ?? sourcePluginDir.appendingPathComponent(".build")
                // Determine which directory contains the Package.swift for --show-bin-path
                let packageDir = FileManager.default.fileExists(atPath: pluginDir.appendingPathComponent("Package.swift").path) ? pluginDir : sourcePluginDir
                if FileManager.default.fileExists(atPath: spmBuildDir.path) {
                    // Use `swift build --show-bin-path` to find the correct build directory.
                    // `/usr/bin/swift` does not exist on every host — the Linux CI image
                    // installs Swift to /usr/share/swift/usr/bin — so probe known locations
                    // and respect a $SWIFT override before giving up.
                    var binPath: String? = nil
                    let swiftPath = Self.resolveSwiftExecutable() ?? "/usr/bin/swift"
                    let showBinProcess = Process()
                    showBinProcess.executableURL = URL(fileURLWithPath: swiftPath)
                    showBinProcess.arguments = ["build", "-c", "release", "--show-bin-path", "--scratch-path", spmBuildDir.path]
                    showBinProcess.currentDirectoryURL = packageDir
                    let binPipe = Pipe()
                    showBinProcess.standardOutput = binPipe
                    showBinProcess.standardError = FileHandle.nullDevice
                    if let _ = try? showBinProcess.run() {
                        showBinProcess.waitUntilExit()
                        if showBinProcess.terminationStatus == 0,
                           let path = String(data: binPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                               .trimmingCharacters(in: .whitespacesAndNewlines),
                           !path.isEmpty {
                            binPath = path
                        }
                    }

                    if let releaseDir = binPath {
                        // Collect .o files from all module build directories
                        // Include the plugin itself + its dependencies (e.g., AROPluginSDK, AROPluginKit)
                        let releaseDirURL = URL(fileURLWithPath: releaseDir)
                        if let buildDirContents = try? FileManager.default.contentsOfDirectory(
                            at: releaseDirURL, includingPropertiesForKeys: [.isDirectoryKey]
                        ) {
                            for dir in buildDirContents where dir.pathExtension == "build" {
                                let moduleName = dir.deletingPathExtension().lastPathComponent
                                // Skip compiler plugin / macro modules (they end in -tool or are swift-syntax related)
                                if moduleName.hasSuffix("-tool") || moduleName.contains("SwiftSyntax") ||
                                   moduleName.contains("SwiftParser") || moduleName.contains("SwiftOperators") ||
                                   moduleName.contains("SwiftBasicFormat") || moduleName.contains("SwiftDiagnostics") ||
                                   moduleName.contains("SwiftLexicalLookup") || moduleName.contains("SwiftCompiler") ||
                                   moduleName.contains("_SwiftSyntax") || moduleName.contains("SwiftIfConfig") ||
                                   moduleName.contains("SwiftRefactor") || moduleName.contains("SwiftIDEUtils") ||
                                   moduleName == "_SwiftSyntaxCShims" || moduleName.contains("GenericTestSupport") {
                                    continue
                                }
                                if let oFiles = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                                    for oFile in oFiles where oFile.pathExtension == "o" {
                                        objectFiles.append(oFile.path)
                                    }
                                }
                            }
                        }
                    }
                }

                // Strategy 2: Find .o from Rust cargo build.
                // Cargo can be in plugin root or in src/, and most plugins ship a
                // cdylib-only crate-type. Static linking needs a libfoo.a, so if no
                // staticlib is present we run `cargo rustc --crate-type=staticlib`
                // ourselves — Rust users no longer need to add `staticlib` manually.
                if objectFiles.isEmpty {
                    let cargoCandidates: [(project: URL, target: URL)] = [
                        (sourcePluginDir, sourcePluginDir.appendingPathComponent("target/release")),
                        (sourcePluginDir.appendingPathComponent("src"),
                         sourcePluginDir.appendingPathComponent("src/target/release")),
                    ]

                    for candidate in cargoCandidates {
                        let cargoToml = candidate.project.appendingPathComponent("Cargo.toml")
                        guard FileManager.default.fileExists(atPath: cargoToml.path) else { continue }

                        var aFile = Self.findRustStaticLib(in: candidate.target)
                        if aFile == nil {
                            if verbose {
                                print("  No staticlib for '\(pluginName)', running cargo rustc --crate-type=staticlib")
                            }
                            do {
                                try Self.produceRustStaticLib(at: candidate.project, verbose: verbose)
                            } catch {
                                print("Error: cargo failed to produce staticlib for '\(pluginName)': \(error)")
                                print("  Hint: ensure cargo is on PATH and the crate compiles cleanly.")
                                throw ExitCode.failure
                            }
                            aFile = Self.findRustStaticLib(in: candidate.target)
                        }

                        if let aFile {
                            objectFiles = try symbolRenamer.extractObjectFiles(from: aFile.path, to: pluginWorkDir.path)
                            break
                        }
                    }
                }

                // Strategy 3: Find .o from direct C compilation. Also search
                // the source plugin dir: compileSingleManagedPlugin only writes
                // a .dylib to the output, so any pre-existing .o files live
                // alongside the C sources in the source tree.
                if objectFiles.isEmpty {
                    let searchDirs = [
                        pluginDir, pluginDir.appendingPathComponent("src"),
                        sourcePluginDir, sourcePluginDir.appendingPathComponent("src"),
                    ]
                    for searchDir in searchDirs {
                        guard FileManager.default.fileExists(atPath: searchDir.path) else { continue }
                        let contents = (try? FileManager.default.contentsOfDirectory(at: searchDir, includingPropertiesForKeys: nil)) ?? []
                        objectFiles.append(contentsOf: contents.filter { $0.pathExtension == "o" }.map { $0.path })
                    }
                }

                // Strategy 4: Recompile from .c source files to .o. Search the
                // source plugin dir too (the output dir only holds the .dylib),
                // and pass -I for include/ so headers like aro_plugin_sdk.h
                // resolve — same lookup NativePluginHost uses.
                if objectFiles.isEmpty {
                    let searchDirs = [
                        pluginDir, pluginDir.appendingPathComponent("src"),
                        sourcePluginDir, sourcePluginDir.appendingPathComponent("src"),
                    ]
                    var includeFlags: [String] = []
                    for root in [pluginDir, sourcePluginDir] {
                        let rootInc = root.appendingPathComponent("include")
                        if FileManager.default.fileExists(atPath: rootInc.path) {
                            includeFlags.append("-I\(rootInc.path)")
                        }
                        let srcInc = root.appendingPathComponent("src/include")
                        if FileManager.default.fileExists(atPath: srcInc.path) {
                            includeFlags.append("-I\(srcInc.path)")
                        }
                    }
                    for searchDir in searchDirs {
                        guard FileManager.default.fileExists(atPath: searchDir.path) else { continue }
                        let contents = (try? FileManager.default.contentsOfDirectory(at: searchDir, includingPropertiesForKeys: nil)) ?? []
                        let cFiles = contents.filter { $0.pathExtension == "c" }
                        for cFile in cFiles {
                            let oPath = pluginWorkDir.appendingPathComponent(cFile.deletingPathExtension().lastPathComponent + ".o").path
                            let compileProcess = Process()
                            compileProcess.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
                            compileProcess.arguments = ["-c", "-fPIC", "-O2"] + includeFlags + ["-o", oPath, cFile.path]
                            compileProcess.standardOutput = FileHandle.nullDevice
                            compileProcess.standardError = FileHandle.nullDevice
                            try? compileProcess.run()
                            compileProcess.waitUntilExit()
                            if compileProcess.terminationStatus == 0 {
                                objectFiles.append(oPath)
                            }
                        }
                        if !objectFiles.isEmpty { break }
                    }
                }

                if objectFiles.isEmpty {
                    print("Error: No object files found for plugin '\(pluginName)' — cannot statically link.")
                    if let compileError = pluginCompileFailures[pluginName] {
                        print("  Root cause — the plugin failed to compile:")
                        print("  \(compileError)")
                    } else {
                        print("  Static linking requires .o files:")
                        print("    • Rust:  cargo must be installed and the crate must build (`cargo rustc --crate-type=staticlib` is invoked automatically)")
                        print("    • Swift: use a Package.swift so SPM produces .o files")
                        print("    • C:     place .c files in the plugin's src/ or root directory")
                    }
                    throw ExitCode.failure
                }

                // Rename plugin symbols to avoid collisions
                let renamedFiles = try symbolRenamer.renamePluginSymbols(
                    objectFiles: objectFiles,
                    pluginName: pluginName,
                    outputDir: pluginWorkDir.path
                )

                // Discover which symbols this plugin actually exports
                let availableSymbols = try symbolRenamer.discoverSymbols(in: renamedFiles, pluginName: pluginName)

                if !availableSymbols.contains("aro_plugin_info") {
                    print("Error: Plugin '\(pluginName)' is missing the aro_plugin_info symbol — cannot statically link.")
                    print("  Define aro_plugin_info() with C ABI:")
                    print("    • Rust:  #[no_mangle] pub extern \"C\" fn aro_plugin_info() -> *mut c_char")
                    print("    • C/C++: use the ARO_PLUGIN(...) macro from aro_plugin_sdk.h")
                    print("    • Swift: apply @AROExport to your AROPlugin definition")
                    throw ExitCode.failure
                }

                result.staticPluginInfos.append(StaticPluginInfo(
                    name: pluginName,
                    yaml: yamlContent,
                    objectFiles: renamedFiles,
                    availableSymbols: availableSymbols
                ))
                result.staticPluginIRInfos.append(StaticPluginIRInfo(
                    name: pluginName,
                    yaml: yamlContent,
                    availableSymbols: availableSymbols
                ))

                if verbose {
                    let totalSize = renamedFiles.compactMap { try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? Int }.reduce(0, +)
                    print("  Static plugin '\(pluginName)' (\(totalSize) bytes, \(availableSymbols.count) symbols)")
                }
            }
        } catch let exit as ExitCode {
            // Plugin baking errors raised inside the loop should abort the build.
            throw exit
        } catch {
            print("Warning: Failed to compile managed plugins: \(error)")
        }

        // If Python plugins were found, find libpython and prepare deps
        if hasPythonPlugins {
            let pythonFinder = PythonLibraryFinder(verbose: verbose)
            if let pythonPaths = pythonFinder.findPython() {
                result.pythonLinkerFlags = pythonPaths.linkerFlags
                if verbose {
                    print("Python \(pythonPaths.version) found: \(pythonPaths.executable)")
                    print("  Linker flags: \(pythonPaths.linkerFlags.joined(separator: " "))")
                }

                // Install requirements to a temporary venv if needed
                if !pythonRequirementsFiles.isEmpty {
                    let venvDir = buildDir.appendingPathComponent("python-venv")
                    if verbose { print("  Installing Python dependencies...") }

                    // Create venv
                    let venvProcess = Process()
                    venvProcess.executableURL = URL(fileURLWithPath: pythonPaths.executable)
                    venvProcess.arguments = ["-m", "venv", venvDir.path]
                    venvProcess.standardOutput = FileHandle.nullDevice
                    venvProcess.standardError = FileHandle.nullDevice
                    try? venvProcess.run()
                    venvProcess.waitUntilExit()

                    // Install requirements
                    let pip = venvDir.appendingPathComponent("bin/pip").path
                    for reqFile in pythonRequirementsFiles {
                        let pipProcess = Process()
                        pipProcess.executableURL = URL(fileURLWithPath: pip)
                        pipProcess.arguments = ["install", "-r", reqFile.path, "--quiet"]
                        pipProcess.standardOutput = verbose ? FileHandle.standardOutput : FileHandle.nullDevice
                        pipProcess.standardError = verbose ? FileHandle.standardError : FileHandle.nullDevice
                        try? pipProcess.run()
                        pipProcess.waitUntilExit()
                    }

                    if verbose { print("  Python dependencies installed") }
                }
            } else {
                print("Warning: Python plugins found but python3 not available on build machine")
                print("  Python plugins will use legacy base64 embedding")
                // Fall back: convert Python IR infos back to legacy base64 embedded plugins
                for pyPlugin in result.pythonPluginIRInfos {
                    if let data = pyPlugin.source.data(using: .utf8) {
                        result.embeddedPlugins.append((
                            name: pyPlugin.name,
                            yaml: pyPlugin.yaml,
                            base64Library: data.base64EncodedString()
                        ))
                    }
                }
                result.pythonPluginIRInfos.removeAll()
            }
        }

        return result
    }

    // MARK: - Toolchain Helpers

    /// Locate the `swift` executable across known install paths so
    /// `swift build --show-bin-path` works on hosts where /usr/bin/swift
    /// does not exist (notably the Linux CI image at /usr/share/swift).
    static func resolveSwiftExecutable() -> String? {
        if let env = ProcessInfo.processInfo.environment["SWIFT"],
           !env.isEmpty,
           FileManager.default.isExecutableFile(atPath: env) {
            return env
        }
        let candidates = [
            "/usr/bin/swift",
            "/usr/local/bin/swift",
            "/usr/share/swift/usr/bin/swift",
            "/opt/swift/usr/bin/swift",
            "/Library/Developer/Toolchains/swift-latest.xctoolchain/usr/bin/swift",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Locate a Rust staticlib (lib*.a) inside cargo's target/release directory.
    static func findRustStaticLib(in dir: URL) -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        return contents.first { $0.pathExtension == "a" && $0.lastPathComponent.hasPrefix("lib") }
    }

    /// Run `cargo rustc --release --crate-type=staticlib` to produce a libfoo.a.
    /// Most ARO Rust plugins only declare `cdylib`, but static linking into the
    /// host binary needs a staticlib — we build it transparently rather than
    /// asking every plugin author to edit their Cargo.toml.
    static func produceRustStaticLib(at projectDir: URL, verbose: Bool) throws {
        let cargoCandidates = [
            ProcessInfo.processInfo.environment["CARGO"],
            "/root/.cargo/bin/cargo",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.cargo/bin/cargo",
            "/usr/local/cargo/bin/cargo",
            "/opt/homebrew/bin/cargo",
            "/usr/local/bin/cargo",
            "/usr/bin/cargo",
        ].compactMap { $0 }

        guard let cargoPath = cargoCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw StaticLibBuildError.cargoNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cargoPath)
        process.arguments = ["rustc", "--release", "--crate-type=staticlib"]
        process.currentDirectoryURL = projectDir

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = verbose ? FileHandle.standardOutput : FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8) ?? "unknown error"
            throw StaticLibBuildError.cargoFailed(message)
        }
    }

    enum StaticLibBuildError: Error, CustomStringConvertible {
        case cargoNotFound
        case cargoFailed(String)

        var description: String {
            switch self {
            case .cargoNotFound:
                return "cargo not found — install Rust to build Rust plugins, or set $CARGO"
            case .cargoFailed(let msg):
                return "cargo rustc --crate-type=staticlib failed: \(msg)"
            }
        }
    }
}

#endif  // !os(Windows)
