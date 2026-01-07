// ============================================================
// BuildCommand.swift
// ARO CLI - Build Command (Native Compilation)
// ============================================================

import ArgumentParser
import Foundation
import AROParser
import ARORuntime
import AROCompiler
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

    @Flag(name: .shortAndLong, help: "Enable verbose logging")
    var verbose: Bool = false

    @Flag(name: .long, help: "Keep intermediate files (.ll, .o)")
    var keepIntermediate: Bool = false

    @Flag(name: .long, help: "Emit LLVM IR text instead of binary")
    var emitLLVM: Bool = false

    func run() async throws {
        let resolvedPath = URL(fileURLWithPath: path)
        let startTime = Date()

        #if os(Linux)
        // Debug: Always print on Linux to verify command is running
        // Use FileHandle to write directly to stderr to bypass any buffering
        let debugMsg = "[BUILD] Starting aro build on Linux for \(resolvedPath.path)\n"
        FileHandle.standardError.write(debugMsg.data(using: .utf8)!)
        #endif

        if verbose {
            print("ARO Compiler v\(AROVersion.shortVersion)")
            print("Build: \(AROVersion.buildDate)")
            print("========================")
            print("Source: \(resolvedPath.path)")
            print()
        }

        // Discover application
        let discovery = ApplicationDiscovery()
        let appConfig: DiscoveredApplication

        do {
            appConfig = try await discovery.discover(at: resolvedPath)
            #if os(Linux)
            FileHandle.standardError.write("[BUILD] Discovery completed, found \(appConfig.sourceFiles.count) files\n".data(using: .utf8)!)
            #endif
        } catch {
            #if os(Linux)
            FileHandle.standardError.write("[BUILD] Discovery failed: \(error)\n".data(using: .utf8)!)
            #endif
            print("Error: \(error)")
            throw ExitCode.failure
        }

        if verbose {
            print("Discovered application:")
            print("  Root: \(appConfig.rootPath.path)")
            print("  Source files: \(appConfig.sourceFiles.count)")
            for file in appConfig.sourceFiles {
                print("    - \(file.lastPathComponent)")
            }
            print()
        }

        // Compile all source files to AST
        let compiler = Compiler()
        var allDiagnostics: [Diagnostic] = []
        var compiledPrograms: [AnalyzedProgram] = []

        #if os(Linux)
        FileHandle.standardError.write("[BUILD] Starting compilation of \(appConfig.sourceFiles.count) files\n".data(using: .utf8)!)
        #endif

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

        #if os(Linux)
        FileHandle.standardError.write("[BUILD] Compilation completed, \(compiledPrograms.count) programs\n".data(using: .utf8)!)
        #endif

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
            #if os(Linux)
            FileHandle.standardError.write("[BUILD] Compilation errors found: \(errors.count)\n".data(using: .utf8)!)
            #endif
            print("\nCompilation errors:")
            for error in errors {
                print("  \(error)")
            }
            throw ExitCode.failure
        }

        // Merge programs
        guard let mergedProgram = mergePrograms(compiledPrograms) else {
            #if os(Linux)
            FileHandle.standardError.write("[BUILD] ERROR: No programs to merge\n".data(using: .utf8)!)
            #endif
            print("Error: No programs to compile")
            throw ExitCode.failure
        }

        #if os(Linux)
        FileHandle.standardError.write("[BUILD] Merged \(mergedProgram.featureSets.count) feature sets\n".data(using: .utf8)!)
        #endif

        if verbose {
            print("\nParsing successful!")
            print("Feature sets found:")
            for fs in mergedProgram.featureSets {
                print("  - \(fs.featureSet.name): \(fs.featureSet.businessActivity)")
            }
            print()
        }

        // Determine output paths
        let baseName = output ?? appConfig.rootPath.lastPathComponent
        let buildDir = appConfig.rootPath.appendingPathComponent(".build")
        let llPath = buildDir.appendingPathComponent("\(baseName).ll")
        let objectPath = buildDir.appendingPathComponent("\(baseName).o").path
        // Ensure binary path is absolute and standardized
        let binaryPath = appConfig.rootPath.appendingPathComponent(baseName).standardizedFileURL

        #if os(Linux)
        FileHandle.standardError.write("[BUILD] Binary path: \(binaryPath.path)\n".data(using: .utf8)!)
        #endif

        // Create build directory
        try? FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)

        // Generate LLVM IR
        if verbose {
            print("Generating LLVM IR...")
        }

        #if os(Linux)
        FileHandle.standardError.write("[BUILD] Starting LLVM IR generation\n".data(using: .utf8)!)
        #endif

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

        let codeGenerator = LLVMCodeGenerator()
        let llvmResult: LLVMCodeGenerationResult

        do {
            llvmResult = try codeGenerator.generate(program: mergedProgram, openAPISpecJSON: openAPISpecJSON)
            #if os(Linux)
            FileHandle.standardError.write("[BUILD] LLVM IR generated successfully\n".data(using: .utf8)!)
            #endif
        } catch {
            #if os(Linux)
            FileHandle.standardError.write("[BUILD] ERROR: LLVM generation failed: \(error)\n".data(using: .utf8)!)
            #endif
            print("Code generation error: \(error)")
            throw ExitCode.failure
        }

        if verbose {
            print("  LLVM module generated")
        }

        // Write LLVM IR text if requested
        if emitLLVM {
            do {
                try llvmResult.irText.write(toFile: llPath.path, atomically: true, encoding: .utf8)
                print("LLVM IR written to: \(llPath.path)")
            } catch {
                print("Error writing LLVM IR: \(error)")
                throw ExitCode.failure
            }
            return
        }

        // Write LLVM IR to file for llc
        do {
            try llvmResult.irText.write(toFile: llPath.path, atomically: true, encoding: .utf8)
            if verbose {
                print("  LLVM IR written: \(llPath.lastPathComponent)")
            }
        } catch {
            print("Error writing LLVM IR: \(error)")
            throw ExitCode.failure
        }

        // Compile LLVM IR to object file using llc
        if verbose {
            print("Emitting object file...")
        }

        // Release mode enables all optimizations
        let effectiveOptimize = optimize || release
        let effectiveSize = size || release
        let effectiveStrip = strip || release

        let emitter = LLVMEmitter()
        // llc only supports O0-O3, use O2 for both speed and size optimization
        // (size optimization is applied during linking stage with -Os)
        let optLevel: LLVMEmitter.OptimizationLevel = (effectiveOptimize || effectiveSize) ? .o2 : .none

        do {
            try emitter.emitObject(irPath: llPath.path, to: objectPath, optimize: optLevel)
            if verbose {
                print("  Object file created")
            }
        } catch {
            print("LLVM emission error: \(error)")
            print("LLVM IR at: \(llPath.path) for debugging")
            throw ExitCode.failure
        }

        // Find the ARORuntime library (contains C-callable bridge via @_cdecl)
        guard let runtimeLibPath = findARORuntimeLibrary() else {
            #if os(Linux)
            FileHandle.standardError.write("[BUILD] ERROR: Runtime library not found\n".data(using: .utf8)!)
            #endif
            print("Error: ARORuntime library not found.")
            print("Please run 'swift build' first to build the runtime library.")
            throw ExitCode.failure
        }

        #if os(Linux)
        FileHandle.standardError.write("[BUILD] Runtime library: \(runtimeLibPath)\n".data(using: .utf8)!)
        #endif

        if verbose {
            print("Using runtime: \(runtimeLibPath)")
        }

        // Link to final executable
        if verbose {
            print("Linking executable...")
            // Show Swift library path for debugging
            let linkerTest = CCompiler(runtimeLibraryPath: runtimeLibPath)
            if let swiftPath = linkerTest.getSwiftLibPath() {
                print("  Swift libraries: \(swiftPath)")
            } else {
                print("  Warning: Swift library path not found")
            }
        }

        #if os(Linux)
        FileHandle.standardError.write("[BUILD] Starting linker\n".data(using: .utf8)!)
        FileHandle.standardError.write("[BUILD] Object file: \(objectPath)\n".data(using: .utf8)!)
        FileHandle.standardError.write("[BUILD] Output path: \(binaryPath.path)\n".data(using: .utf8)!)
        #endif

        let linker = CCompiler(runtimeLibraryPath: runtimeLibPath)

        #if os(Linux)
        FileHandle.standardError.write("[BUILD] CCompiler created\n".data(using: .utf8)!)
        #endif

        let linkOptions = CCompiler.LinkOptions(
            optimize: effectiveOptimize,
            optimizeForSize: effectiveSize,
            strip: effectiveStrip,
            deadStrip: effectiveStrip || effectiveSize  // Enable dead stripping when stripping or optimizing for size
        )

        #if os(Linux)
        FileHandle.standardError.write("[BUILD] LinkOptions created\n".data(using: .utf8)!)
        FileHandle.standardError.write("[BUILD] About to call linker.link() with objectFiles: [\(objectPath)], outputPath: \(binaryPath.path)\n".data(using: .utf8)!)
        #endif

        do {
            #if os(Linux)
            FileHandle.standardError.write("[BUILD] Inside do block, calling link...\n".data(using: .utf8)!)
            #endif

            try linker.link(
                objectFiles: [objectPath],
                outputPath: binaryPath.path,
                outputType: .executable,
                options: linkOptions
            )

            #if os(Linux)
            FileHandle.standardError.write("[BUILD] Linking completed\n".data(using: .utf8)!)
            #endif

            if verbose {
                print("  Executable created")
            }
        } catch {
            #if os(Linux)
            FileHandle.standardError.write("[BUILD] ERROR: Linking failed: \(error)\n".data(using: .utf8)!)
            #endif
            print("Linking error: \(error)")
            throw ExitCode.failure
        }

        // Post-build strip for maximum size reduction
        if effectiveStrip {
            if verbose {
                print("Stripping symbols...")
            }
            try? runStripCommand(on: binaryPath.path)
        }

        // Cleanup intermediate files
        if !keepIntermediate {
            try? FileManager.default.removeItem(at: llPath)
            try? FileManager.default.removeItem(atPath: objectPath)
        } else if verbose {
            print("  Intermediate files kept at: \(buildDir.path)")
        }

        // Compile plugins if present (ARO-0031: plugins are compiled during build, not at runtime)
        let sourcePluginsDir = appConfig.rootPath.appendingPathComponent("plugins")
        let outputPluginsDir = binaryPath.deletingLastPathComponent().appendingPathComponent("plugins")

        if FileManager.default.fileExists(atPath: sourcePluginsDir.path) {
            if verbose {
                print("Compiling plugins...")
            }

            do {
                try PluginLoader.shared.compilePlugins(from: sourcePluginsDir, to: outputPluginsDir)
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

        let elapsed = Date().timeIntervalSince(startTime)

        #if os(Linux)
        print("[BUILD] Binary created successfully")
        print("[BUILD] Path: \(binaryPath.path)")
        print("[BUILD] Checking if binary exists...")
        if FileManager.default.fileExists(atPath: binaryPath.path) {
            print("[BUILD] ✓ Binary exists")
            print("[BUILD] Size: \(try? FileManager.default.attributesOfItem(atPath: binaryPath.path)[.size] ?? 0) bytes")
        } else {
            print("[BUILD] ✗ Binary NOT found!")
        }
        #endif

        print("Built: \(binaryPath.path)")
        if verbose {
            print("Completed in \(String(format: "%.2f", elapsed))s")
        }
    }

    private func findARORuntimeLibrary() -> String? {
        let fm = FileManager.default

        // Get the path to the aro executable itself
        let executablePath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let executableDir = executablePath.deletingLastPathComponent()

        // Platform-specific library name
        // Note: All platforms use libARORuntime.a (Swift uses .a for static libs on all platforms)
        let runtimeLibName = "libARORuntime.a"

        // Build search paths array programmatically
        var searchPaths: [String] = []

        // 1. Same directory as executable (for distributed binaries/artifacts)
        searchPaths.append(executableDir.appendingPathComponent(runtimeLibName).path)

        // 2. Homebrew/system install locations (Unix only)
        #if os(macOS)
        searchPaths.append("/opt/homebrew/lib/libARORuntime.a")  // Apple Silicon
        searchPaths.append("/usr/local/lib/libARORuntime.a")     // Intel Mac
        #elseif os(Linux)
        searchPaths.append("/usr/local/lib/libARORuntime.a")
        searchPaths.append("/usr/lib/libARORuntime.a")
        #endif

        // 3. Development build locations (platform-specific)
        #if os(macOS)
        searchPaths.append(".build/arm64-apple-macosx/release/libARORuntime.a")
        searchPaths.append(".build/arm64-apple-macosx/debug/libARORuntime.a")
        searchPaths.append(".build/x86_64-apple-macosx/release/libARORuntime.a")
        searchPaths.append(".build/x86_64-apple-macosx/debug/libARORuntime.a")
        searchPaths.append(".build/release/libARORuntime.a")
        searchPaths.append(".build/debug/libARORuntime.a")
        #elseif os(Linux)
        searchPaths.append(".build/x86_64-unknown-linux-gnu/release/libARORuntime.a")
        searchPaths.append(".build/x86_64-unknown-linux-gnu/debug/libARORuntime.a")
        searchPaths.append(".build/aarch64-unknown-linux-gnu/release/libARORuntime.a")
        searchPaths.append(".build/aarch64-unknown-linux-gnu/debug/libARORuntime.a")
        searchPaths.append(".build/release/libARORuntime.a")
        searchPaths.append(".build/debug/libARORuntime.a")
        #elseif os(Windows)
        searchPaths.append(".build/x86_64-unknown-windows-msvc/release/libARORuntime.a")
        searchPaths.append(".build/x86_64-unknown-windows-msvc/debug/libARORuntime.a")
        searchPaths.append(".build/release/libARORuntime.a")
        searchPaths.append(".build/debug/libARORuntime.a")
        #endif

        for path in searchPaths {
            let fullPath: String
            if path.hasPrefix("/") {
                // Absolute path
                fullPath = path
            } else if path.hasPrefix(".") {
                // Relative to current directory
                fullPath = fm.currentDirectoryPath + "/" + path
            } else {
                // Relative to current directory
                fullPath = fm.currentDirectoryPath + "/" + path
            }

            if fm.fileExists(atPath: fullPath) {
                return fullPath
            }
        }

        return nil
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
        let productionFeatureSets = allFeatureSets.filter { fs in
            let activity = fs.featureSet.businessActivity
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

    private func runStripCommand(on binaryPath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/strip")
        #if os(macOS)
        // -S: Remove debug symbols only, keep global symbols for dynamic linking
        // -x: Remove local symbols (non-global)
        process.arguments = ["-S", "-x", binaryPath]
        #else
        // Linux: strip all symbols
        process.arguments = ["-s", binaryPath]
        #endif

        try process.run()
        process.waitUntilExit()
    }
}
