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

        // Inform about writable .store files — compiled binaries persist changes
        // back to the .store file placed next to the executable (issue #442),
        // matching `aro run`. The o+w bit is preserved into the bundle.
        let writableStores = appConfig.storeFiles.filter { $0.isWritable }
        if !writableStores.isEmpty {
            print("Note: Writable store files persist changes to the .store file next to the binary.")
            for store in writableStores {
                print("  - \(store.filePath.lastPathComponent) -> \(store.repositoryName) (writable, persisted next to the binary)")
            }
            print("Hint: the .store file next to the binary must be writable by the running user; chmod o-w <file>.store for a read-only (seed-only) store.")
        }

        // Compile all source files to AST
        let compiler = Compiler()
        var allDiagnostics: [Diagnostic] = []
        var compiledPrograms: [AnalyzedProgram] = []

        // Issue #231 — DWARF source-mapping provenance. The AST does not
        // track which file a feature set came from, so we record it here
        // while we still know the origin file: map each feature-set name
        // to its `.aro` basename, and remember the file that holds
        // `Application-Start` (the entry / fallback file).
        var sourceFileMap: [String: String] = [:]
        var entryFilename: String?

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
                let basename = sourceFile.lastPathComponent
                for afs in result.analyzedProgram.featureSets {
                    let name = afs.featureSet.name
                    sourceFileMap[name] = basename
                    if name == "Application-Start" {
                        entryFilename = basename
                    }
                }
            }
        }

        // Absolute app source directory becomes DW_AT_comp_dir; a real
        // (non-empty) comp_dir is what makes macOS `ld64` emit an N_OSO
        // stab for our object so `dsymutil` relocates our DWARF (#231).
        let sourceDirectory = appConfig.rootPath.standardizedFileURL.path
        let resolvedEntryFilename = entryFilename
            ?? appConfig.sourceFiles.first?.lastPathComponent
            ?? "aro_program.aro"

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

        // Determine output paths. Binary layout + platform-flag concerns (the
        // Windows .exe suffix, .build intermediates, managed-plugin dirs) live in
        // BuildLayout (#354) so the command stays a thin coordinator.
        let layout = BuildLayout(rootPath: appConfig.rootPath, output: output)
        let binaryPath = layout.binaryPath
        let buildDir = layout.buildDir
        let llPath = layout.llPath
        let objectPath = layout.objectPath
        let sourceManagedPluginsDirEarly = layout.sourceManagedPluginsDir
        let outputManagedPluginsDirEarly = layout.outputManagedPluginsDir

        AROLogger.debug("Binary path: \(binaryPath.path)", subsystem: "build")

        // Create build directory and binary parent dir (needed when --output points outside rootPath)
        await FileOps.createDirectoryIfNeeded(at: buildDir)
        await FileOps.createDirectoryIfNeeded(at: binaryPath.deletingLastPathComponent())

        // Pre-compile managed plugins for inclusion in the binary.
        // Native plugins (C/Rust/Swift) are statically linked via symbol renaming.
        // Python plugins fall back to base64 embedding (they run via subprocess).
        // The full pipeline lives in PluginCompiler (#366) so it stays reusable.
        let pluginCompiler = PluginCompiler(
            sourcePluginsDir: sourceManagedPluginsDirEarly,
            outputPluginsDir: outputManagedPluginsDirEarly,
            staticBuildDir: layout.staticPluginsDir,
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

        // Gather assets embedded into the binary (OpenAPI contract + templates).
        // The serialization / directory-walking lives in BuildAssetCollector (#354);
        // both return nil to fall back to file-based loading at runtime.
        let openAPISpecJSON = BuildAssetCollector.openAPISpecJSON(from: appConfig.openAPISpec, verbose: verbose)
        let templatesJSON = BuildAssetCollector.templatesJSON(rootPath: appConfig.rootPath, verbose: verbose)

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
            sourceDirectory: sourceDirectory,
            sourceFileMap: sourceFileMap,
            entryFilename: resolvedEntryFilename,
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
