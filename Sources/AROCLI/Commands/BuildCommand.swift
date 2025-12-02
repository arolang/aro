// ============================================================
// BuildCommand.swift
// ARO CLI - Build Command (Native Compilation)
// ============================================================

import ArgumentParser
import Foundation
import AROParser
import ARORuntime
import AROCompiler

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

    @Flag(name: .shortAndLong, help: "Enable verbose logging")
    var verbose: Bool = false

    @Flag(name: .long, help: "Keep intermediate files (.ll, .o)")
    var keepIntermediate: Bool = false

    @Flag(name: .long, help: "Emit LLVM IR text instead of binary")
    var emitLLVM: Bool = false

    func run() async throws {
        let resolvedPath = URL(fileURLWithPath: path)
        let startTime = Date()

        if verbose {
            print("ARO Compiler v1.0.0")
            print("========================")
            print("Source: \(resolvedPath.path)")
            print()
        }

        // Discover application
        let discovery = ApplicationDiscovery()
        let appConfig: DiscoveredApplication

        do {
            appConfig = try await discovery.discover(at: resolvedPath)
        } catch {
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
            print("\nCompilation errors:")
            for error in errors {
                print("  \(error)")
            }
            throw ExitCode.failure
        }

        // Merge programs
        guard let mergedProgram = mergePrograms(compiledPrograms) else {
            print("Error: No programs to compile")
            throw ExitCode.failure
        }

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
        let binaryPath = appConfig.rootPath.appendingPathComponent(baseName)

        // Create build directory
        try? FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)

        // Generate LLVM IR
        if verbose {
            print("Generating LLVM IR...")
        }

        let codeGenerator = LLVMCodeGenerator()
        let llvmResult: LLVMCodeGenerationResult

        do {
            llvmResult = try codeGenerator.generate(program: mergedProgram)
        } catch {
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

        let emitter = LLVMEmitter()
        let optLevel: LLVMEmitter.OptimizationLevel = optimize ? .o2 : .none

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

        // Find the AROCRuntime library
        guard let runtimeLibPath = findAROCRuntimeLibrary() else {
            print("Error: AROCRuntime library not found.")
            print("Please run 'swift build' first to build the runtime library.")
            throw ExitCode.failure
        }

        if verbose {
            print("Using runtime: \(runtimeLibPath)")
        }

        // Link to final executable
        if verbose {
            print("Linking executable...")
        }

        let linker = CCompiler(runtimeLibraryPath: runtimeLibPath)

        do {
            try linker.link(
                objectFiles: [objectPath],
                outputPath: binaryPath.path,
                outputType: .executable,
                optimize: optimize
            )

            if verbose {
                print("  Executable created")
            }
        } catch {
            print("Linking error: \(error)")
            throw ExitCode.failure
        }

        // Cleanup intermediate files
        if !keepIntermediate {
            try? FileManager.default.removeItem(at: llPath)
            try? FileManager.default.removeItem(atPath: objectPath)
        } else if verbose {
            print("  Intermediate files kept at: \(buildDir.path)")
        }

        let elapsed = Date().timeIntervalSince(startTime)

        print("Built: \(binaryPath.path)")
        if verbose {
            print("Completed in \(String(format: "%.2f", elapsed))s")
        }
    }

    private func findAROCRuntimeLibrary() -> String? {
        let fm = FileManager.default

        // Get the path to the aro executable itself
        let executablePath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let executableDir = executablePath.deletingLastPathComponent()

        // Common search paths relative to the executable
        let searchPaths: [String] = [
            // Same directory as executable (typical for swift build)
            executableDir.appendingPathComponent("libAROCRuntime.a").path,
            // Parent .build directory structures
            executableDir.deletingLastPathComponent().appendingPathComponent("libAROCRuntime.a").path,
            // Standard Swift build output locations
            ".build/debug/libAROCRuntime.a",
            ".build/release/libAROCRuntime.a",
            ".build/arm64-apple-macosx/debug/libAROCRuntime.a",
            ".build/arm64-apple-macosx/release/libAROCRuntime.a",
            ".build/x86_64-apple-macosx/debug/libAROCRuntime.a",
            ".build/x86_64-apple-macosx/release/libAROCRuntime.a",
            // Linux paths
            ".build/x86_64-unknown-linux-gnu/debug/libAROCRuntime.a",
            ".build/x86_64-unknown-linux-gnu/release/libAROCRuntime.a",
        ]

        for path in searchPaths {
            let fullPath: String
            if path.hasPrefix("/") || path.hasPrefix(".") {
                fullPath = path
            } else {
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

        if programs.count == 1 {
            return programs[0]
        }

        var allFeatureSets: [AnalyzedFeatureSet] = []
        let globalRegistry = GlobalSymbolRegistry()

        for program in programs {
            allFeatureSets.append(contentsOf: program.featureSets)

            for (name, info) in program.globalRegistry.allPublished {
                globalRegistry.register(symbol: info.symbol, fromFeatureSet: info.featureSet)
            }
        }

        let mergedASTFeatureSets = allFeatureSets.map { $0.featureSet }
        let mergedAST = Program(
            featureSets: mergedASTFeatureSets,
            span: programs[0].program.span
        )

        return AnalyzedProgram(
            program: mergedAST,
            featureSets: allFeatureSets,
            globalRegistry: globalRegistry
        )
    }
}
