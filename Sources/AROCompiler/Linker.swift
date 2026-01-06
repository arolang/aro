// ============================================================
// Linker.swift
// AROCompiler - LLVM Object Emission and Linking
// ============================================================

import Foundation

/// Emits LLVM IR to object files using llc command-line tool
public final class LLVMEmitter {
    // MARK: - Properties

    /// Optimization level for llc (O0-O3 only)
    public enum OptimizationLevel: String {
        case none = "-O0"
        case o1 = "-O1"
        case o2 = "-O2"
        case o3 = "-O3"
        // Note: llc doesn't support -Os/-Oz, use -O2 for size optimization
        // (size optimization is applied during linking stage)
    }

    // MARK: - Initialization

    public init() {}

    // MARK: - Object Emission

    /// Emit LLVM IR to object file
    /// - Parameters:
    ///   - irPath: Path to LLVM IR file (.ll)
    ///   - outputPath: Path for output object file
    ///   - optimize: Optimization level
    public func emitObject(
        irPath: String,
        to outputPath: String,
        optimize: OptimizationLevel = .none
    ) throws {
        let llcPath = try findLLC()

        var args = [llcPath]
        args.append("-filetype=obj")
        args.append(optimize.rawValue)
        args.append("-o")
        args.append(outputPath)
        args.append(irPath)

        try runProcess(args)
    }

    /// Emit LLVM IR to assembly
    /// - Parameters:
    ///   - irPath: Path to LLVM IR file (.ll)
    ///   - outputPath: Path for output assembly file
    public func emitAssembly(
        irPath: String,
        to outputPath: String
    ) throws {
        let llcPath = try findLLC()

        var args = [llcPath]
        args.append("-filetype=asm")
        args.append("-o")
        args.append(outputPath)
        args.append(irPath)

        try runProcess(args)
    }

    // MARK: - Private Methods

    private func findLLC() throws -> String {
        // Check common paths
        let paths = [
            "/opt/homebrew/opt/llvm/bin/llc",
            "/usr/local/opt/llvm/bin/llc",
            "/usr/bin/llc",
            "/usr/local/bin/llc"
        ]

        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // Try to find in PATH
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["llc"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return path
            }
        } catch {}

        throw LinkerError.compilationFailed("llc not found. Please install LLVM: brew install llvm")
    }

    private func runProcess(_ args: [String]) throws {
        guard !args.isEmpty else {
            throw LinkerError.compilationFailed("No command specified")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw LinkerError.compilationFailed("Failed to run llc: \(error)")
        }

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw LinkerError.compilationFailed(errorMessage)
        }
    }
}

/// Compiles and links object files with the ARO runtime
public final class CCompiler {
    // MARK: - Properties

    /// Path to the ARO runtime library
    public let runtimeLibraryPath: String?

    /// Target platform (optional override)
    public let targetPlatform: String?

    // MARK: - Output Types

    public enum OutputType: String {
        case executable
        case object
        case sharedLibrary = "shared"
        case assembly
    }

    // MARK: - Initialization

    public init(runtimeLibraryPath: String? = nil, targetPlatform: String? = nil) {
        self.runtimeLibraryPath = runtimeLibraryPath
        self.targetPlatform = targetPlatform
    }

    // MARK: - Compilation

    /// Compile C source to an object file
    /// - Parameters:
    ///   - sourcePath: Path to C source file
    ///   - outputPath: Path for output object file
    ///   - optimize: Enable optimizations
    public func compileToObject(
        sourcePath: String,
        outputPath: String,
        optimize: Bool = false
    ) throws {
        var args = [findCompiler()]
        args.append("-c")
        args.append(sourcePath)
        args.append("-o")
        args.append(outputPath)

        if optimize {
            args.append("-O2")
        } else {
            args.append("-g") // Debug info
        }

        // Standard flags
        args.append("-std=c11")
        args.append("-Wall")

        try runProcess(args)
    }

    /// Linker options for size and stripping
    public struct LinkOptions {
        public var optimize: Bool = false
        public var optimizeForSize: Bool = false
        public var strip: Bool = false
        public var deadStrip: Bool = false

        public init(
            optimize: Bool = false,
            optimizeForSize: Bool = false,
            strip: Bool = false,
            deadStrip: Bool = false
        ) {
            self.optimize = optimize
            self.optimizeForSize = optimizeForSize
            self.strip = strip
            self.deadStrip = deadStrip
        }
    }

    /// Link object files into an executable
    /// - Parameters:
    ///   - objectFiles: Paths to object files
    ///   - outputPath: Path for output executable
    ///   - optimize: Enable link-time optimizations (deprecated, use options)
    public func link(
        objectFiles: [String],
        outputPath: String,
        outputType: OutputType = .executable,
        optimize: Bool = false
    ) throws {
        try link(
            objectFiles: objectFiles,
            outputPath: outputPath,
            outputType: outputType,
            options: LinkOptions(optimize: optimize)
        )
    }

    /// Link object files into an executable with full options
    /// - Parameters:
    ///   - objectFiles: Paths to object files
    ///   - outputPath: Path for output executable
    ///   - outputType: Type of output
    ///   - options: Link options for optimization, stripping, etc.
    public func link(
        objectFiles: [String],
        outputPath: String,
        outputType: OutputType = .executable,
        options: LinkOptions
    ) throws {
        var args = [findCompiler()]

        // Output type
        switch outputType {
        case .executable:
            break // default
        case .object:
            args.append("-c")
        case .sharedLibrary:
            args.append("-shared")
            #if os(macOS)
            args.append("-dynamiclib")
            #else
            args.append("-fPIC")
            #endif
        case .assembly:
            args.append("-S")
        }

        // Object files
        args.append(contentsOf: objectFiles)

        // Output
        args.append("-o")
        args.append(outputPath)

        // Runtime library (ARORuntime contains C-callable bridge via @_cdecl)
        if let runtimePath = runtimeLibraryPath {
            let libDir = URL(fileURLWithPath: runtimePath).deletingLastPathComponent().path
            args.append("-L\(libDir)")
            args.append("-lARORuntime")
            args.append("-Wl,-rpath,\(libDir)")
        }

        // Platform-specific libraries
        #if os(macOS)
        // Link Swift runtime libraries needed by libARORuntime.a
        if let swiftLibPath = findSwiftLibPath() {
            args.append("-L\(swiftLibPath)")
            args.append("-Wl,-rpath,\(swiftLibPath)")
        }

        // Dead code stripping (macOS specific)
        if options.deadStrip {
            args.append("-Wl,-dead_strip")
        }
        #elseif os(Linux)
        args.append("-lpthread")
        args.append("-ldl")
        args.append("-lm")
        // Swift runtime on Linux
        if let swiftLibPath = findSwiftLibPath() {
            args.append("-L\(swiftLibPath)")
            args.append("-Wl,-rpath,\(swiftLibPath)")

            // Explicitly link Swift runtime libraries
            args.append("-lswiftCore")
            args.append("-lswift_Concurrency")
        }

        // Dead code stripping on Linux
        if options.deadStrip {
            args.append("-Wl,--gc-sections")
        }
        #endif

        // Optimizations
        if options.optimize || options.optimizeForSize {
            if options.optimizeForSize {
                args.append("-Os")
            } else {
                args.append("-O2")
            }
            args.append("-flto=thin")  // Thin LTO for faster linking
        }

        // Strip symbols
        if options.strip {
            #if os(macOS)
            args.append("-Wl,-S")  // Strip debug symbols
            args.append("-Wl,-x")  // Strip local symbols
            #else
            args.append("-s")  // Strip all symbols
            #endif
        }

        try runProcess(args)
    }

    /// Compile C source directly to executable (single step)
    /// - Parameters:
    ///   - sourcePath: Path to C source file
    ///   - outputPath: Path for output executable
    ///   - optimize: Enable optimizations
    public func compileAndLink(
        sourcePath: String,
        outputPath: String,
        optimize: Bool = false
    ) throws {
        var args = [findCompiler()]
        args.append(sourcePath)
        args.append("-o")
        args.append(outputPath)

        // Standard flags
        args.append("-std=c11")
        args.append("-Wall")

        // Runtime library (ARORuntime contains C-callable bridge via @_cdecl)
        if let runtimePath = runtimeLibraryPath {
            let libDir = URL(fileURLWithPath: runtimePath).deletingLastPathComponent().path
            args.append("-L\(libDir)")
            args.append("-lARORuntime")
            args.append("-Wl,-rpath,\(libDir)")
        }

        // Platform-specific
        #if os(macOS)
        if let swiftLibPath = findSwiftLibPath() {
            args.append("-L\(swiftLibPath)")
            args.append("-Wl,-rpath,\(swiftLibPath)")
        }
        args.append("-lSystem")
        #elseif os(Linux)
        args.append("-lpthread")
        args.append("-ldl")
        args.append("-lm")
        if let swiftLibPath = findSwiftLibPath() {
            args.append("-L\(swiftLibPath)")
            args.append("-Wl,-rpath,\(swiftLibPath)")
        }
        #endif

        if optimize {
            args.append("-O2")
        } else {
            args.append("-g")
        }

        try runProcess(args)
    }

    // MARK: - Private Methods

    private func findCompiler() -> String {
        // Prefer clang, fall back to gcc
        let compilers = ["/usr/bin/clang", "/opt/homebrew/bin/clang", "/usr/bin/gcc", "clang", "gcc"]

        for compiler in compilers {
            if FileManager.default.fileExists(atPath: compiler) {
                return compiler
            }
        }

        // Try to find in PATH
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["clang"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return path
            }
        } catch {}

        return "clang" // Hope it's in PATH
    }

    /// Public accessor for Swift library path (for debugging)
    public func getSwiftLibPath() -> String? {
        return findSwiftLibPath()
    }

    private func findSwiftLibPath() -> String? {
        // First, try to get the Swift library path from the Swift toolchain itself
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--find", "swift"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let swiftPath = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !swiftPath.isEmpty {
                    // Swift is at: /path/to/toolchain/usr/bin/swift
                    // Libraries are at: /path/to/toolchain/usr/lib/swift/macosx (or linux)
                    let swiftURL = URL(fileURLWithPath: swiftPath)
                    let toolchainLib = swiftURL
                        .deletingLastPathComponent()  // Remove 'bin'
                        .deletingLastPathComponent()  // Remove 'usr'
                        .appendingPathComponent("usr")
                        .appendingPathComponent("lib")
                        .appendingPathComponent("swift")

                    #if os(macOS)
                    let platformLib = toolchainLib.appendingPathComponent("macosx").path
                    #elseif os(Linux)
                    let platformLib = toolchainLib.appendingPathComponent("linux").path
                    #else
                    let platformLib = toolchainLib.path
                    #endif

                    if FileManager.default.fileExists(atPath: platformLib) {
                        return platformLib
                    }
                }
            }
        } catch {}

        // Fallback to standard paths
        #if os(macOS)
        // Check Xcode toolchain
        let xcodeLib = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx"
        if FileManager.default.fileExists(atPath: xcodeLib) {
            return xcodeLib
        }

        // Check usr/lib/swift
        let usrLib = "/usr/lib/swift"
        if FileManager.default.fileExists(atPath: usrLib) {
            return usrLib
        }

        // Check Homebrew Swift installation
        let homebrewLib = "/opt/homebrew/opt/swift/lib/swift/macosx"
        if FileManager.default.fileExists(atPath: homebrewLib) {
            return homebrewLib
        }
        #elseif os(Linux)
        let swiftLib = "/usr/lib/swift/linux"
        if FileManager.default.fileExists(atPath: swiftLib) {
            return swiftLib
        }
        #endif
        return nil
    }

    private func runProcess(_ args: [String]) throws {
        guard !args.isEmpty else {
            throw LinkerError.compilationFailed("No command specified")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw LinkerError.compilationFailed("Failed to run compiler: \(error)")
        }

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw LinkerError.compilationFailed(errorMessage)
        }
    }
}

// MARK: - Linker Errors

public enum LinkerError: Error, CustomStringConvertible {
    case compilationFailed(String)
    case linkFailed(String)
    case runtimeNotFound(String)

    public var description: String {
        switch self {
        case .compilationFailed(let message):
            return "Compilation failed: \(message)"
        case .linkFailed(let message):
            return "Linking failed: \(message)"
        case .runtimeNotFound(let path):
            return "Runtime library not found: \(path)"
        }
    }
}
