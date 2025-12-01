// ============================================================
// Linker.swift
// AROCompiler - C Compilation and Linking
// ============================================================

import Foundation

/// Compiles and links C code with the ARO runtime
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

    /// Link object files into an executable
    /// - Parameters:
    ///   - objectFiles: Paths to object files
    ///   - outputPath: Path for output executable
    ///   - optimize: Enable link-time optimizations
    public func link(
        objectFiles: [String],
        outputPath: String,
        outputType: OutputType = .executable,
        optimize: Bool = false
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

        // Runtime library
        if let runtimePath = runtimeLibraryPath {
            let libDir = URL(fileURLWithPath: runtimePath).deletingLastPathComponent().path
            args.append("-L\(libDir)")
            args.append("-lAROCRuntime")
            args.append("-Wl,-rpath,\(libDir)")
        }

        // Platform-specific libraries
        #if os(macOS)
        // Link Swift runtime
        if let swiftLibPath = findSwiftLibPath() {
            args.append("-L\(swiftLibPath)")
            args.append("-rpath")
            args.append(swiftLibPath)
        }
        args.append("-lSystem")
        #elseif os(Linux)
        args.append("-lpthread")
        args.append("-ldl")
        args.append("-lm")
        // Swift runtime on Linux
        if let swiftLibPath = findSwiftLibPath() {
            args.append("-L\(swiftLibPath)")
            args.append("-Wl,-rpath,\(swiftLibPath)")
        }
        #endif

        // Optimizations
        if optimize {
            args.append("-O2")
            args.append("-flto")
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

        // Runtime library
        if let runtimePath = runtimeLibraryPath {
            let libDir = URL(fileURLWithPath: runtimePath).deletingLastPathComponent().path
            args.append("-L\(libDir)")
            args.append("-lAROCRuntime")
            args.append("-Wl,-rpath,\(libDir)")
        }

        // Platform-specific
        #if os(macOS)
        if let swiftLibPath = findSwiftLibPath() {
            args.append("-L\(swiftLibPath)")
            args.append("-rpath")
            args.append(swiftLibPath)
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

    private func findSwiftLibPath() -> String? {
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
