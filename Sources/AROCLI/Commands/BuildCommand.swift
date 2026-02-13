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

        // Discover application with import resolution
        let discovery = ApplicationDiscovery()
        let appConfig: DiscoveredApplication

        do {
            appConfig = try await discovery.discoverWithImports(at: resolvedPath, includePlugins: true)
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
        // On Windows, executables need .exe extension
        #if os(Windows)
        let binaryName = baseName + ".exe"
        #else
        let binaryName = baseName
        #endif
        let binaryPath = appConfig.rootPath.appendingPathComponent(binaryName).standardizedFileURL

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

        // Discover and serialize templates for embedding (ARO-0045)
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
        let llvmResult: LLVMCodeGenerationResult

        do {
            let codeGenerator = LLVMCodeGenerator()
            llvmResult = try codeGenerator.generate(program: mergedProgram, openAPISpecJSON: openAPISpecJSON, templatesJSON: templatesJSON)
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
            #if os(Linux) || os(Windows)
            FileHandle.standardError.write("[BUILD] ERROR: Runtime library not found\n".data(using: .utf8)!)
            #endif
            print("Error: ARORuntime library not found.")
            throw ExitCode.failure
        }

        #if os(Linux) || os(Windows)
        FileHandle.standardError.write("[BUILD] Runtime library found: \(runtimeLibPath)\n".data(using: .utf8)!)
        print("[BUILD] Runtime library found: \(runtimeLibPath)")
        #endif

        if verbose {
            print("Using runtime: \(runtimeLibPath)")
        }

        // Link to final executable
        if verbose {
            print("Linking executable...")
            // Show Swift library path for debugging
            let linkerTest = CCompiler(runtimeLibraryPath: runtimeLibPath, verbose: verbose)
            if let swiftPath = linkerTest.getSwiftLibPath() {
                print("  Swift libraries: \(swiftPath)")
            } else {
                print("  Warning: Swift library path not found")
            }
        }

        #if os(Linux) || os(Windows)
        FileHandle.standardError.write("[BUILD] Starting linker\n".data(using: .utf8)!)
        FileHandle.standardError.write("[BUILD] Object file: \(objectPath)\n".data(using: .utf8)!)
        FileHandle.standardError.write("[BUILD] Output path: \(binaryPath.path)\n".data(using: .utf8)!)
        print("[BUILD] Starting linker")
        print("[BUILD] Object file: \(objectPath)")
        print("[BUILD] Output path: \(binaryPath.path)")
        #endif

        #if os(Windows)
        print("[BUILD] Creating CCompiler with runtime: \(runtimeLibPath)")
        #endif

        let linker = CCompiler(runtimeLibraryPath: runtimeLibPath, verbose: verbose)

        #if os(Windows)
        print("[BUILD] CCompiler created successfully")
        #endif

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

        // Compile managed plugins if present (installed via aro add)
        let sourceManagedPluginsDir = appConfig.rootPath.appendingPathComponent("Plugins")
        let outputManagedPluginsDir = binaryPath.deletingLastPathComponent().appendingPathComponent("Plugins")

        if FileManager.default.fileExists(atPath: sourceManagedPluginsDir.path) {
            if verbose {
                print("Compiling managed plugins...")
            }

            do {
                // Clean output directory if it exists and is different from source
                let sourceResolved = sourceManagedPluginsDir.standardizedFileURL.path
                let outputResolved = outputManagedPluginsDir.standardizedFileURL.path

                if sourceResolved != outputResolved {
                    if FileManager.default.fileExists(atPath: outputManagedPluginsDir.path) {
                        try FileManager.default.removeItem(at: outputManagedPluginsDir)
                    }
                }

                // Compile managed plugins (Swift, C, etc.) to dynamic libraries
                try PluginLoader.shared.compileManagedPlugins(from: sourceManagedPluginsDir, to: outputManagedPluginsDir)

                if verbose {
                    // Count compiled plugins
                    let pluginDirs = try? FileManager.default.contentsOfDirectory(at: outputManagedPluginsDir, includingPropertiesForKeys: [.isDirectoryKey])
                    let pluginCount = pluginDirs?.filter {
                        var isDir: ObjCBool = false
                        return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue
                    }.count ?? 0
                    print("  \(pluginCount) managed plugin(s) compiled to: \(outputManagedPluginsDir.path)")
                }
            } catch {
                print("Warning: Failed to compile managed plugins: \(error)")
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
        #endif  // !os(Windows)
    }

    private func findARORuntimeLibrary() -> String? {
        let fm = FileManager.default

        // Get the path to the aro executable itself
        let executablePath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let executableDir = executablePath.deletingLastPathComponent()

        // Build search paths array programmatically
        var searchPaths: [String] = []

        // Platform-specific library names to search for
        // Swift uses .a for static libs on all platforms, but we also check .lib for Windows
        #if os(Windows)
        let runtimeLibNames = ["libARORuntime.a", "ARORuntime.lib", "libARORuntime.lib"]
        #else
        let runtimeLibNames = ["libARORuntime.a"]
        #endif

        // 0. Check ARO_BIN environment variable directory (used in CI)
        if let aroBinPath = ProcessInfo.processInfo.environment["ARO_BIN"] {
            #if os(Windows)
            // On Windows, avoid URL manipulation which has path format issues
            // Just do simple string manipulation with backslashes
            var aroBinDir: String
            if let lastBackslash = aroBinPath.lastIndex(of: "\\") {
                aroBinDir = String(aroBinPath[..<lastBackslash])
            } else if let lastSlash = aroBinPath.lastIndex(of: "/") {
                aroBinDir = String(aroBinPath[..<lastSlash])
            } else {
                aroBinDir = "."
            }
            for libName in runtimeLibNames {
                searchPaths.append(aroBinDir + "\\" + libName)
            }
            #else
            let aroBinDir = URL(fileURLWithPath: aroBinPath).deletingLastPathComponent()
            for libName in runtimeLibNames {
                searchPaths.append(aroBinDir.appendingPathComponent(libName).path)
            }
            #endif
        }

        // 1. Same directory as executable (for distributed binaries/artifacts)
        // This is the primary location for CI/CD artifacts
        #if os(Windows)
        // On Windows, use string manipulation to avoid URL path issues
        let execPathStr = executablePath.path
        var execDirStr: String
        if let lastBackslash = execPathStr.lastIndex(of: "\\") {
            execDirStr = String(execPathStr[..<lastBackslash])
        } else if let lastSlash = execPathStr.lastIndex(of: "/") {
            execDirStr = String(execPathStr[..<lastSlash])
        } else {
            execDirStr = "."
        }
        // Remove leading slash if present (URL.path artifact on Windows)
        if execDirStr.hasPrefix("/") && execDirStr.count > 2 && execDirStr.dropFirst().first?.isLetter == true {
            execDirStr = String(execDirStr.dropFirst())
        }
        for libName in runtimeLibNames {
            searchPaths.append(execDirStr + "\\" + libName)
        }
        #else
        for libName in runtimeLibNames {
            searchPaths.append(executableDir.appendingPathComponent(libName).path)
        }
        #endif

        // 2. Sibling lib/ directory relative to executable (standard Unix layout)
        // e.g., /usr/local/bin/aro → /usr/local/lib/libARORuntime.a
        #if !os(Windows)
        let siblingLibDir = executableDir.deletingLastPathComponent().appendingPathComponent("lib")
        for libName in runtimeLibNames {
            searchPaths.append(siblingLibDir.appendingPathComponent(libName).path)
        }
        #endif

        // 3. Homebrew/system install locations (Unix only)
        #if os(macOS)
        searchPaths.append("/opt/homebrew/lib/libARORuntime.a")  // Apple Silicon
        searchPaths.append("/usr/local/lib/libARORuntime.a")     // Intel Mac
        #elseif os(Linux)
        searchPaths.append("/usr/local/lib/libARORuntime.a")
        searchPaths.append("/usr/lib/libARORuntime.a")
        #endif

        // 4. Development build locations (platform-specific)
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
        // Check multiple library name variants on Windows
        for libName in runtimeLibNames {
            searchPaths.append(".build/x86_64-unknown-windows-msvc/release/\(libName)")
            searchPaths.append(".build/x86_64-unknown-windows-msvc/debug/\(libName)")
            searchPaths.append(".build/release/\(libName)")
            searchPaths.append(".build/debug/\(libName)")
        }
        #endif

        #if os(Windows)
        // Debug output for Windows - write to both stderr AND a debug file
        var debugLog = "[BUILD] Searching for runtime library...\n"
        debugLog += "[BUILD] ARO_BIN env: \(ProcessInfo.processInfo.environment["ARO_BIN"] ?? "not set")\n"
        debugLog += "[BUILD] Executable path: \(executablePath.path)\n"
        debugLog += "[BUILD] Executable dir: \(executableDir.path)\n"
        debugLog += "[BUILD] Current working dir: \(fm.currentDirectoryPath)\n"
        debugLog += "[BUILD] Search paths (\(searchPaths.count) total):\n"
        for (index, path) in searchPaths.enumerated() {
            let exists = fm.fileExists(atPath: path)
            debugLog += "[BUILD]   \(index + 1). \(path) [\(exists ? "EXISTS" : "not found")]\n"
        }

        // Write to stderr
        FileHandle.standardError.write(debugLog.data(using: .utf8)!)

        // Also write to stdout so it's captured in test output
        print(debugLog)

        // Also write to a debug file
        let debugFilePath = fm.currentDirectoryPath + "\\aro-build-debug.log"
        try? debugLog.write(toFile: debugFilePath, atomically: true, encoding: .utf8)
        #endif

        for path in searchPaths {
            var fullPath: String
            #if os(Windows)
            // On Windows, use backslashes for path separators
            // First, fix any URL.path artifacts (leading slash before drive letter)
            var cleanPath = path
            if cleanPath.hasPrefix("/") && cleanPath.count > 2 {
                let afterSlash = cleanPath.dropFirst()
                if afterSlash.first?.isLetter == true && afterSlash.dropFirst().first == ":" {
                    // Path like "/D:/..." -> "D:/..."
                    cleanPath = String(afterSlash)
                }
            }

            if cleanPath.contains(":") {
                // Absolute Windows path (e.g., "D:/path" or "D:\path")
                fullPath = cleanPath.replacingOccurrences(of: "/", with: "\\")
            } else if cleanPath.hasPrefix(".") {
                // Relative to current directory
                fullPath = fm.currentDirectoryPath + "\\" + cleanPath.replacingOccurrences(of: "/", with: "\\")
            } else {
                // Relative to current directory
                fullPath = fm.currentDirectoryPath + "\\" + cleanPath.replacingOccurrences(of: "/", with: "\\")
            }
            #else
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
            #endif

            #if os(Windows)
            let exists = fm.fileExists(atPath: fullPath)
            FileHandle.standardError.write("[BUILD] Checking: \(fullPath) -> \(exists ? "FOUND" : "not found")\n".data(using: .utf8)!)
            if exists {
                return fullPath
            }
            #else
            if fm.fileExists(atPath: fullPath) {
                return fullPath
            }
            #endif
        }

        #if os(Windows)
        FileHandle.standardError.write("[BUILD] Runtime library NOT FOUND in standard locations\n".data(using: .utf8)!)

        // Last resort: try to find the library anywhere on disk using where/dir commands
        FileHandle.standardError.write("[BUILD] Attempting filesystem search...\n".data(using: .utf8)!)

        // Try to find libARORuntime.a near the executable
        if let aroBinPath = ProcessInfo.processInfo.environment["ARO_BIN"] {
            // Get the directory containing aro.exe
            let aroBinURL = URL(fileURLWithPath: aroBinPath)
            let aroBinDir = aroBinURL.deletingLastPathComponent()

            // Try listing the directory contents
            do {
                let contents = try fm.contentsOfDirectory(atPath: aroBinDir.path)
                FileHandle.standardError.write("[BUILD] Contents of \(aroBinDir.path):\n".data(using: .utf8)!)
                for item in contents {
                    FileHandle.standardError.write("[BUILD]   - \(item)\n".data(using: .utf8)!)
                    if item.contains("ARORuntime") || item.hasSuffix(".a") || item.hasSuffix(".lib") {
                        let itemPath = aroBinDir.appendingPathComponent(item).path
                        FileHandle.standardError.write("[BUILD] Found potential library: \(itemPath)\n".data(using: .utf8)!)
                        if fm.fileExists(atPath: itemPath) {
                            FileHandle.standardError.write("[BUILD] Returning: \(itemPath)\n".data(using: .utf8)!)
                            return itemPath
                        }
                    }
                }
            } catch {
                FileHandle.standardError.write("[BUILD] Error listing directory: \(error)\n".data(using: .utf8)!)
            }
        }

        FileHandle.standardError.write("[BUILD] Runtime library NOT FOUND anywhere\n".data(using: .utf8)!)
        #endif

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
