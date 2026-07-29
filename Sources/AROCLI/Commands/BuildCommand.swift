// ============================================================
// BuildCommand.swift
// ARO CLI - Build Command (Native Compilation)
// ============================================================

import ArgumentParser
import Foundation
import AROParser
import ARORuntime
#if !os(Windows)
import AROCompiler
#endif
import AROVersion

struct BuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Compile ARO application to native binary"
    )

    @Argument(help: "Path to the application directory or .aro file")
    var path: String

    @Option(name: .shortAndLong, help: "Output binary name")
    var output: String?

    @Flag(name: .customLong("optimize"), help: "Enable optimizations")
    var optimize: Bool = false

    @Flag(name: .long, help: "Optimize for size instead of speed")
    var size: Bool = false

    @Flag(name: .long, help: "Strip symbols from binary")
    var strip: Bool = false

    @Flag(name: .long, help: "Release build (optimize + size + strip)")
    var release: Bool = false

    @Flag(name: .customLong("static"), help: "Statically link the Swift runtime into the binary (default; one self-contained file)")
    var staticLink: Bool = false

    @Flag(name: .customLong("dynamic"), help: "Dynamically link the Swift runtime and copy required .so files next to the binary (rpath=$ORIGIN)")
    var dynamicLink: Bool = false

    @Flag(name: .shortAndLong, help: "Enable verbose logging")
    var verbose: Bool = false

    @Flag(name: .long, help: "Keep intermediate files (.ll, .o)")
    var keepIntermediate: Bool = false

    @Flag(name: .long, help: "Emit LLVM IR text instead of binary")
    var emitLLVM: Bool = false

    #if os(macOS)
    @Option(name: .long, help: "Code signing identity (e.g. 'Apple Development: Name (TEAMID)' or '-' for ad-hoc)")
    var sign: String?

    @Flag(name: .long, help: "Enable hardened runtime (required for notarization)")
    var hardenedRuntime: Bool = false
    #endif


    func run() async throws {
        let resolvedPath = URL(fileURLWithPath: path)
        let startTime = Date()

        if verbose {
            AROLogger.setLevel(.debug)
        }

        AROLogger.debug("Starting aro build for \(resolvedPath.path)", subsystem: "build")

        if verbose {
            print("ARO Compiler v\(AROVersion.shortVersion)")
            print("Build: \(AROVersion.buildDate)")
            print("========================")
            print("Source: \(resolvedPath.path)")
            print()
        }

        // Discover application with import resolution (#361 — shared helper)
        let appConfig: DiscoveredApplication
        do {
            appConfig = try await ApplicationResolver.resolve(
                at: resolvedPath,
                includePlugins: true
            )
            AROLogger.debug("Discovery completed, found \(appConfig.sourceFiles.count) files", subsystem: "build")
        } catch {
            AROLogger.error("Discovery failed: \(error)", subsystem: "build")
            throw error
        }

        if verbose {
            print("Discovered application:")
            print("  Root: \(appConfig.rootPath.path)")
            print("  Source files: \(appConfig.sourceFiles.count)")
            for file in appConfig.sourceFiles {
                print("    - \(file.lastPathComponent)")
            }
            if !appConfig.storeFiles.isEmpty {
                print("  Store files: \(appConfig.storeFiles.count)")
                for store in appConfig.storeFiles {
                    let mode = store.isWritable ? "writable" : "read-only"
                    print("    - \(store.filePath.lastPathComponent) -> \(store.repositoryName) (\(mode))")
                }
            }
            print()
        }

        // Warn about writable .store files — compiled binaries always load them
        // as read-only, so the o+w bit is harmless (but may surprise the user).
        let writableStores = appConfig.storeFiles.filter { $0.isWritable }
        if !writableStores.isEmpty {
            print("Warning: Store files with world-write permission will be treated as read-only in compiled binaries.")
            for store in writableStores {
                print("  - \(store.filePath.lastPathComponent) has o+w permission set")
            }
            print("Hint: chmod o-w <file>.store to silence this warning.")
        }

        // Compile all source files to AST
        let compiler = Compiler()
        var allDiagnostics: [Diagnostic] = []
        var compiledPrograms: [AnalyzedProgram] = []

        AROLogger.debug("Starting compilation of \(appConfig.sourceFiles.count) files", subsystem: "build")

        for sourceFile in appConfig.sourceFiles {
            if verbose {
                print("Parsing: \(sourceFile.lastPathComponent)")
            }

            let source: String
            do {
                source = try String(contentsOf: sourceFile, encoding: .utf8)
            } catch {
                print("Error reading \(sourceFile.lastPathComponent): \(error)")
                throw ExitCode.failure
            }

            let result = compiler.compile(source)
            allDiagnostics.append(contentsOf: result.diagnostics)

            if result.isSuccess {
                compiledPrograms.append(result.analyzedProgram)
            }
        }

        AROLogger.debug("Compilation completed, \(compiledPrograms.count) programs", subsystem: "build")

        // Report compilation errors
        let errors = allDiagnostics.filter { $0.severity == .error }
        let warnings = allDiagnostics.filter { $0.severity == .warning }

        if !warnings.isEmpty && verbose {
            print("\nWarnings:")
            for warning in warnings {
                print("  \(warning)")
            }
        }

        if !errors.isEmpty {
            AROLogger.error("Compilation errors found: \(errors.count)", subsystem: "build")
            print("\nCompilation errors:")
            for error in errors {
                print("  \(error)")
            }
            throw ExitCode.failure
        }

        // Merge programs
        guard let mergedProgram = mergePrograms(compiledPrograms) else {
            AROLogger.error("No programs to merge", subsystem: "build")
            print("Error: No programs to compile")
            throw ExitCode.failure
        }

        AROLogger.debug("Merged \(mergedProgram.featureSets.count) feature sets", subsystem: "build")

        if verbose {
            print("\nParsing successful!")
            print("Feature sets found:")
            for fs in mergedProgram.featureSets {
                print("  - \(fs.featureSet.name): \(fs.featureSet.businessActivity)")
            }
            print()
        }

        // Determine output paths.
        // --output may be a bare name (resolved against rootPath, in-place) or an
        // absolute/relative path (out-of-place). Intermediate .ll/.o always stay in
        // the workspace's .build dir keyed by the binary's filename, never the full
        // path — otherwise an absolute --output produces nested junk dirs.
        let outputArg = output ?? appConfig.rootPath.lastPathComponent
        let buildDir = appConfig.rootPath.appendingPathComponent(".build")

        // On Windows, executables need .exe extension
        #if os(Windows)
        let outputArgWithExt = outputArg.hasSuffix(".exe") ? outputArg : outputArg + ".exe"
        #else
        let outputArgWithExt = outputArg
        #endif

        let binaryPath = URL(fileURLWithPath: outputArgWithExt, relativeTo: appConfig.rootPath)
            .standardizedFileURL
        let intermediateBaseName = binaryPath.deletingPathExtension().lastPathComponent
        let llPath = buildDir.appendingPathComponent("\(intermediateBaseName).ll")
        let objectPath = buildDir.appendingPathComponent("\(intermediateBaseName).o").path

        AROLogger.debug("Binary path: \(binaryPath.path)", subsystem: "build")

        // Create build directory and binary parent dir (needed when --output points outside rootPath)
        await FileOps.createDirectoryIfNeeded(at: buildDir)
        await FileOps.createDirectoryIfNeeded(at: binaryPath.deletingLastPathComponent())

        // Pre-compile managed plugins for inclusion in the binary.
        // Native plugins (C/Rust/Swift) are statically linked via symbol renaming.
        // Python plugins fall back to base64 embedding (they run via subprocess).
        // The full pipeline lives in PluginCompiler (#366) so it stays reusable.
        // Check both "Plugins" (canonical) and "plugins" (convention) — Linux is case-sensitive
        let pluginsDirCandidates = [
            appConfig.rootPath.appendingPathComponent("Plugins"),
            appConfig.rootPath.appendingPathComponent("plugins"),
        ]
        let sourceManagedPluginsDirEarly = pluginsDirCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
            ?? appConfig.rootPath.appendingPathComponent("Plugins")
        let outputManagedPluginsDirEarly = binaryPath.deletingLastPathComponent().appendingPathComponent("Plugins")

        let pluginCompiler = PluginCompiler(
            sourcePluginsDir: sourceManagedPluginsDirEarly,
            outputPluginsDir: outputManagedPluginsDirEarly,
            staticBuildDir: buildDir.appendingPathComponent("static-plugins"),
            verbose: verbose
        )
        let compiledPlugins = try await pluginCompiler.compile(buildDir: buildDir)
        let embeddedPlugins = compiledPlugins.embeddedPlugins
        let staticPluginInfos = compiledPlugins.staticPluginInfos
        let staticPluginIRInfos = compiledPlugins.staticPluginIRInfos
        let pythonPluginIRInfos = compiledPlugins.pythonPluginIRInfos
        let pythonLinkerFlags = compiledPlugins.pythonLinkerFlags

        // Generate LLVM IR
        if verbose {
            print("Generating LLVM IR...")
        }

        AROLogger.debug("Starting LLVM IR generation", subsystem: "build")

        // Serialize OpenAPI spec to JSON for embedding (if present)
        var openAPISpecJSON: String? = nil
        if let spec = appConfig.openAPISpec {
            do {
                let encoder = JSONEncoder()
                let jsonData = try encoder.encode(spec)
                openAPISpecJSON = String(data: jsonData, encoding: .utf8)
                if verbose {
                    print("  Embedding OpenAPI spec (\(jsonData.count) bytes)")
                }
            } catch {
                print("Warning: Could not serialize OpenAPI spec: \(error)")
                // Continue without embedding - fall back to file-based loading at runtime
            }
        }

        // Discover and serialize templates for embedding (ARO-0050)
        var templatesJSON: String? = nil
        let templatesDir = appConfig.rootPath.appendingPathComponent("templates")
        if FileManager.default.fileExists(atPath: templatesDir.path) {
            do {
                var templates: [String: String] = [:]
                let enumerator = FileManager.default.enumerator(at: templatesDir, includingPropertiesForKeys: nil)
                while let fileURL = enumerator?.nextObject() as? URL {
                    var isDirectory: ObjCBool = false
                    FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
                    if !isDirectory.boolValue {
                        // Get relative path from templates directory
                        let relativePath = fileURL.path.replacingOccurrences(
                            of: templatesDir.path + "/",
                            with: ""
                        )
                        let content = try String(contentsOf: fileURL, encoding: .utf8)
                        templates[relativePath] = content
                    }
                }
                if !templates.isEmpty {
                    let jsonData = try JSONSerialization.data(withJSONObject: templates)
                    templatesJSON = String(data: jsonData, encoding: .utf8)
                    if verbose {
                        print("  Embedding \(templates.count) template(s) (\(jsonData.count) bytes)")
                    }
                }
            } catch {
                print("Warning: Could not serialize templates: \(error)")
                // Continue without embedding - fall back to file-based loading at runtime
            }
        }

        #if os(Windows)
        print("Error: Native compilation is not yet supported on Windows.")
        print("The 'aro build' command requires LLVM which is not available on Windows.")
        print("Use 'aro run' to execute ARO programs in interpreter mode instead.")
        throw ExitCode.failure
        #else
        // Hand the native-compilation pipeline to CompilationStrategy (#354):
        // LLVM IR generation → object emission → link → strip → .so bundling
        // (Linux) → codesign (macOS) → intermediate cleanup. BuildCommand stays
        // a thin coordinator around discovery, merging, and plugin pre-compile.
        let strategy = CompilationStrategy()
        var request = CompilationStrategy.Request(
            mergedProgram: mergedProgram,
            binaryPath: binaryPath,
            llPath: llPath,
            objectPath: objectPath,
            buildDir: buildDir,
            openAPISpecJSON: openAPISpecJSON,
            templatesJSON: templatesJSON,
            embeddedPlugins: embeddedPlugins,
            staticPluginInfos: staticPluginInfos,
            staticPluginIRInfos: staticPluginIRInfos,
            pythonPluginIRInfos: pythonPluginIRInfos,
            pythonLinkerFlags: pythonLinkerFlags,
            optimize: optimize,
            size: size,
            strip: strip,
            release: release,
            staticLink: staticLink,
            dynamicLink: dynamicLink,
            verbose: verbose,
            keepIntermediate: keepIntermediate,
            emitLLVM: emitLLVM
        )
        #if os(macOS)
        request.sign = sign
        request.hardenedRuntime = hardenedRuntime
        #endif

        switch try strategy.execute(request) {
        case .emittedLLVMOnly:
            return
        case .built:
            break
        }

        // Compile legacy plugins/ if present (ARO-0031: plugins are compiled during build, not at runtime)
        // Skip if it resolves to the same directory as Plugins/ (case-insensitive FS).
        let sourcePluginsDir = appConfig.rootPath.appendingPathComponent("plugins")
        let outputPluginsDir = binaryPath.deletingLastPathComponent().appendingPathComponent("plugins")

        // On case-insensitive filesystems (macOS, Docker virtiofs mounts), "plugins/" and
        // "Plugins/" resolve to the same directory. Skip legacy compilation in that case to
        // avoid double-compiling managed plugins and causing module-cache conflicts.
        let isLegacySameAsManaged: Bool = {
            guard let legacyAttrs = try? FileManager.default.attributesOfItem(atPath: sourcePluginsDir.path),
                  let managedAttrs = try? FileManager.default.attributesOfItem(atPath: sourceManagedPluginsDirEarly.path),
                  let legacyInode = legacyAttrs[.systemFileNumber] as? UInt,
                  let managedInode = managedAttrs[.systemFileNumber] as? UInt else {
                return false
            }
            return legacyInode == managedInode
        }()

        if FileManager.default.fileExists(atPath: sourcePluginsDir.path) && !isLegacySameAsManaged {
            if verbose {
                print("Compiling plugins...")
            }

            do {
                try await PluginLoader.shared.compilePluginsParallel(from: sourcePluginsDir, to: outputPluginsDir)
                if verbose {
                    // Count compiled plugins
                    let pluginFiles = try? FileManager.default.contentsOfDirectory(at: outputPluginsDir, includingPropertiesForKeys: nil)
                    let dylibCount = pluginFiles?.filter { $0.pathExtension == "dylib" || $0.pathExtension == "so" }.count ?? 0
                    print("  \(dylibCount) plugin(s) compiled to: \(outputPluginsDir.path)")
                }
            } catch {
                print("Warning: Plugin compilation failed: \(error)")
                // Continue - plugins are optional
            }
        }

        // Managed plugins were pre-compiled above (before LLVM IR generation) so they
        // could be embedded in the binary. Report the count if verbose.
        if verbose && !embeddedPlugins.isEmpty {
            print("  \(embeddedPlugins.count) managed plugin(s) embedded in binary")
        }

        // All managed plugins are now baked into the binary (statically linked or
        // embedded). For out-of-place builds, drop the next-to-binary Plugins/ —
        // shipping it duplicates the bake and can let the runtime re-invoke
        // cargo/swift on a missing artifact. For in-place builds (source == output)
        // we leave the user's source tree alone.
        do {
            let sourceResolved = sourceManagedPluginsDirEarly.standardizedFileURL.path
            let outputResolved = outputManagedPluginsDirEarly.standardizedFileURL.path
            if sourceResolved != outputResolved,
               FileManager.default.fileExists(atPath: outputManagedPluginsDirEarly.path) {
                await FileOps.removeItemIfPresent(at: outputManagedPluginsDirEarly)
                if verbose {
                    print("  Cleaned next-to-binary Plugins/ (all plugins baked into binary)")
                }
            }
        }

        let elapsed = Date().timeIntervalSince(startTime)

        AROLogger.debug("Binary created successfully", subsystem: "build")
        AROLogger.debug("Path: \(binaryPath.path)", subsystem: "build")
        if FileManager.default.fileExists(atPath: binaryPath.path) {
            AROLogger.debug("Binary exists, size: \(String(describing: try? FileManager.default.attributesOfItem(atPath: binaryPath.path)[.size]))", subsystem: "build")
        } else {
            AROLogger.error("Binary NOT found after build!", subsystem: "build")
        }

        print("Built: \(binaryPath.path)")
        if verbose {
            print("Completed in \(String(format: "%.2f", elapsed))s")
        }
        #endif  // !os(Windows)
    }

    private func mergePrograms(_ programs: [AnalyzedProgram]) -> AnalyzedProgram? {
        guard !programs.isEmpty else { return nil }

        var allFeatureSets: [AnalyzedFeatureSet] = []
        let globalRegistry = GlobalSymbolRegistry()

        for program in programs {
            allFeatureSets.append(contentsOf: program.featureSets)

            for (_, info) in program.globalRegistry.allPublished {
                globalRegistry.register(symbol: info.symbol, fromFeatureSet: info.featureSet)
            }
        }

        // Filter out test feature sets (ARO-0015: Tests run only in interpreter mode)
        // Test feature sets have business activity ending in "Test" or "Tests"
        // Never strip Application-Start or Application-End feature sets
        let productionFeatureSets = allFeatureSets.filter { fs in
            let name = fs.featureSet.name
            let activity = fs.featureSet.businessActivity
            // Always keep Application-Start and Application-End
            if name == "Application-Start" || name.hasPrefix("Application-End") {
                return true
            }
            return !activity.hasSuffix("Test") && !activity.hasSuffix("Tests")
        }

        if verbose && productionFeatureSets.count < allFeatureSets.count {
            let testCount = allFeatureSets.count - productionFeatureSets.count
            print("  Stripped \(testCount) test feature set(s) from binary")
        }

        let mergedASTFeatureSets = productionFeatureSets.map { $0.featureSet }
        let mergedAST = Program(
            featureSets: mergedASTFeatureSets,
            span: programs[0].program.span
        )

        return AnalyzedProgram(
            program: mergedAST,
            featureSets: productionFeatureSets,
            globalRegistry: globalRegistry
        )
    }
}
