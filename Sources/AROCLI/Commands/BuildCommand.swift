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

    @Flag(name: .long, help: "Keep intermediate files (.c)")
    var keepIntermediate: Bool = false

    @Flag(name: .long, help: "Emit C code only (no compilation)")
    var emitC: Bool = false

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
        let cPath = buildDir.appendingPathComponent("\(baseName).c")
        let binaryPath = appConfig.rootPath.appendingPathComponent(baseName)

        // Create build directory
        try? FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)

        // Generate C code
        if verbose {
            print("Generating C code...")
        }

        let codeGenerator = CCodeGenerator()
        let cCode: String

        do {
            cCode = try codeGenerator.generate(program: mergedProgram)
        } catch {
            print("Code generation error: \(error)")
            throw ExitCode.failure
        }

        // Write C code
        do {
            try cCode.write(toFile: cPath.path, atomically: true, encoding: .utf8)
            if verbose {
                print("  Written: \(cPath.lastPathComponent)")
            }
        } catch {
            print("Error writing C file: \(error)")
            throw ExitCode.failure
        }

        if emitC {
            print("C code written to: \(cPath.path)")
            return
        }

        // Compile C to binary
        if verbose {
            print("Compiling to native binary...")
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

        let cCompiler = CCompiler(runtimeLibraryPath: runtimeLibPath)
        let objectPath = buildDir.appendingPathComponent("\(baseName).o").path

        do {
            // Compile C to object file
            try cCompiler.compileToObject(
                sourcePath: cPath.path,
                outputPath: objectPath,
                optimize: optimize
            )

            if verbose {
                print("  Object file created")
            }

            // Link to final executable
            if verbose {
                print("Linking executable...")
            }

            try cCompiler.link(
                objectFiles: [objectPath],
                outputPath: binaryPath.path,
                outputType: .executable,
                optimize: optimize
            )

            if verbose {
                print("  Executable created")
            }
        } catch {
            print("Compilation error: \(error)")
            print("Generated C code is at: \(cPath.path)")
            throw ExitCode.failure
        }

        // Cleanup intermediate files
        if !keepIntermediate {
            try? FileManager.default.removeItem(at: cPath)
            try? FileManager.default.removeItem(atPath: objectPath)
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
