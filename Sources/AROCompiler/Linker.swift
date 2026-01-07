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

        // Add -opaque-pointers flag only for LLVM 14-16
        // LLVM 14: Flag enables opaque pointers (typed pointers are default)
        // LLVM 15-16: Opaque pointers are default, flag is accepted but deprecated
        // LLVM 17+: Flag removed (opaque pointers are the only mode)
        if let version = getLLVMMajorVersion(llcPath), version >= 14 && version < 17 {
            args.append("-opaque-pointers")
        }

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

        // Add -opaque-pointers flag only for LLVM 14-16
        if let version = getLLVMMajorVersion(llcPath), version >= 14 && version < 17 {
            args.append("-opaque-pointers")
        }

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

    /// Get LLVM major version from llc
    private func getLLVMMajorVersion(_ llcPath: String) -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: llcPath)
        process.arguments = ["--version"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                // Look for version pattern like "LLVM version 14.0.0" or "version 20.1.8"
                let pattern = #"version (\d+)\."#
                if let regex = try? NSRegularExpression(pattern: pattern, options: []),
                   let match = regex.firstMatch(in: output, options: [], range: NSRange(output.startIndex..., in: output)),
                   let range = Range(match.range(at: 1), in: output) {
                    return Int(output[range])
                }
            }
        } catch {}

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
        #if os(Linux)
        FileHandle.standardError.write("[LINKER] ===== ENTERED link() method =====\n".data(using: .utf8)!)
        FileHandle.standardError.write("[LINKER] link() called with objectFiles: \(objectFiles)\n".data(using: .utf8)!)
        FileHandle.standardError.write("[LINKER] outputPath: \(outputPath)\n".data(using: .utf8)!)
        FileHandle.standardError.write("[LINKER] Finding compiler...\n".data(using: .utf8)!)
        #endif

        var args = [findCompiler()]

        #if os(Linux)
        FileHandle.standardError.write("[LINKER] Array created with compiler: \(args[0])\n".data(using: .utf8)!)
        FileHandle.standardError.write("[LINKER] Building arguments...\n".data(using: .utf8)!)
        #endif

        #if os(Linux)
        FileHandle.standardError.write("[LINKER] 1. Handling output type...\n".data(using: .utf8)!)
        #endif

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

        #if os(Linux)
        FileHandle.standardError.write("[LINKER] 2. Adding object files...\n".data(using: .utf8)!)
        #endif

        // Object files
        args.append(contentsOf: objectFiles)

        #if os(Linux)
        FileHandle.standardError.write("[LINKER] 3. Adding output path...\n".data(using: .utf8)!)
        #endif

        // Output
        args.append("-o")
        args.append(outputPath)

        #if os(Linux)
        FileHandle.standardError.write("[LINKER] 4. Processing runtime library...\n".data(using: .utf8)!)
        #endif

        // Runtime library (ARORuntime contains C-callable bridge via @_cdecl)
        if let runtimePath = runtimeLibraryPath {
            let libDir = URL(fileURLWithPath: runtimePath).deletingLastPathComponent().path
            args.append("-L\(libDir)")
            args.append("-lARORuntime")

            // Add rpath - format depends on compiler
            #if os(Linux)
            // swiftc requires -Xlinker format
            args.append("-Xlinker")
            args.append("-rpath")
            args.append("-Xlinker")
            args.append(libDir)
            #else
            // clang uses -Wl, format
            args.append("-Wl,-rpath,\(libDir)")
            #endif
        }

        #if os(Linux)
        FileHandle.standardError.write("[LINKER] 5. Checking platform-specific libraries...\n".data(using: .utf8)!)
        #endif

        // Platform-specific libraries
        #if os(macOS)
        // Link Swift runtime libraries needed by libARORuntime.a
        if let swiftLibPath = findSwiftLibPath() {
            args.append("-L\(swiftLibPath)")
            args.append("-Wl,-rpath,\(swiftLibPath)")

            // Explicitly link Swift libraries with -l flags
            // These must come after -lARORuntime so the linker can resolve symbols
            // Order matters: Core first, then platform libs, then others
            args.append("-lswiftCore")
            args.append("-lswift_Concurrency")
            args.append("-lswiftDarwin")          // Platform library (POSIX/Darwin)
            args.append("-lswiftDispatch")        // Grand Central Dispatch
            args.append("-lswiftFoundation")      // Foundation framework (macOS uses different name)
            args.append("-lswift_StringProcessing")
            args.append("-lswift_RegexParser")
            args.append("-lswiftSwiftOnoneSupport")
        }
        args.append("-lSystem")

        // Dead code stripping (macOS specific)
        if options.deadStrip {
            args.append("-Wl,-dead_strip")
        }
        #elseif os(Linux)
        // Add Swift library path for runtime libraries
        if let swiftLibPath = findSwiftLibPath() {
            // Check which compiler we're using
            let compiler = args[0]
            let usingSwiftc = compiler.contains("swiftc")

            FileHandle.standardError.write("[LINKER] Swift lib path: \(swiftLibPath)\n".data(using: .utf8)!)
            FileHandle.standardError.write("[LINKER] Using compiler: \(usingSwiftc ? "swiftc" : "clang")\n".data(using: .utf8)!)

            args.append("-L\(swiftLibPath)")

            if usingSwiftc {
                // swiftc needs -Xlinker format for rpath
                args.append("-Xlinker")
                args.append("-rpath")
                args.append("-Xlinker")
                args.append(swiftLibPath)

                // CRITICAL: Explicitly link Swift runtime libraries when linking object files
                // swiftc doesn't automatically link these when given .o files instead of .swift files
                // These must come AFTER -lARORuntime so linker can resolve symbols
                args.append("-lswiftGlibc")           // Platform library (POSIX/Glibc)
                args.append("-lswiftDispatch")        // Grand Central Dispatch
                args.append("-lBlocksRuntime")        // Blocks runtime
                args.append("-lswift_Concurrency")    // Swift Concurrency (TaskLocal)
                args.append("-lFoundation")           // Foundation framework
                args.append("-lFoundationEssentials") // Foundation essentials
                args.append("-lFoundationNetworking") // HTTP/networking
                args.append("-lswift_StringProcessing")
                args.append("-lswift_RegexParser")
            } else {
                // clang uses -Wl format for rpath
                args.append("-Wl,-rpath,\(swiftLibPath)")

                // CRITICAL: Explicitly link Swift runtime libraries when using clang
                // These must come AFTER -lARORuntime so linker can resolve symbols
                // Order matters: Core must be first, then platform libs, then others
                args.append("-lswiftCore")
                args.append("-lswift_Concurrency")
                args.append("-lswiftGlibc")           // Platform library (POSIX/Glibc)
                args.append("-lswiftDispatch")        // Grand Central Dispatch
                args.append("-lBlocksRuntime")        // Blocks runtime
                args.append("-lFoundation")           // Foundation framework
                args.append("-lFoundationEssentials") // Foundation essentials
                args.append("-lFoundationNetworking") // HTTP/networking
                args.append("-lswift_StringProcessing")
                args.append("-lswift_RegexParser")
                args.append("-lswiftSwiftOnoneSupport")
            }
        } else {
            FileHandle.standardError.write("[LINKER] WARNING: Swift library path not found\n".data(using: .utf8)!)
        }

        args.append("-lpthread")
        args.append("-ldl")
        args.append("-lm")
        args.append("-lstdc++")  // C++ standard library for BoringSSL
        args.append("-lz")       // zlib for compression

        // Dead code stripping on Linux
        if options.deadStrip {
            args.append("-Xlinker")
            args.append("--gc-sections")
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

        #if os(Linux)
        FileHandle.standardError.write("[LINKER] Arguments built, calling runProcess...\n".data(using: .utf8)!)
        FileHandle.standardError.write("[LINKER] Total args: \(args.count)\n".data(using: .utf8)!)
        #endif

        try runProcess(args)

        #if os(Linux)
        FileHandle.standardError.write("[LINKER] runProcess completed successfully\n".data(using: .utf8)!)
        #endif
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
        #if os(Linux)
        FileHandle.standardError.write("[LINKER] findCompiler() called on Linux\n".data(using: .utf8)!)

        // On Linux, prefer swiftc for linking Swift static libraries
        // swiftc handles Swift runtime initialization and library dependencies automatically
        let fixed_compilers = [
            "/usr/bin/swiftc",    // Swift compiler handles runtime init properly
            "/usr/bin/clang-14",  // Fallback to clang
            "/usr/bin/clang"
        ]
        for compiler in fixed_compilers {
            FileHandle.standardError.write("[LINKER] Checking if compiler exists: \(compiler)\n".data(using: .utf8)!)
            if FileManager.default.fileExists(atPath: compiler) {
                FileHandle.standardError.write("[LINKER] Found compiler (direct check): \(compiler)\n".data(using: .utf8)!)
                return compiler
            }
            FileHandle.standardError.write("[LINKER] Compiler not found at: \(compiler)\n".data(using: .utf8)!)
        }

        // Try to find swiftc or clang in PATH using which
        FileHandle.standardError.write("[LINKER] Trying to find compiler in PATH using which\n".data(using: .utf8)!)
        for compiler_name in ["swiftc", "clang-14", "clang"] {
            do {
                let whichProcess = Process()
                whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
                whichProcess.arguments = [compiler_name]

                let whichPipe = Pipe()
                whichProcess.standardOutput = whichPipe
                whichProcess.standardError = FileHandle.nullDevice

                try whichProcess.run()
                whichProcess.waitUntilExit()

                if whichProcess.terminationStatus == 0 {
                    let data = whichPipe.fileHandleForReading.readDataToEndOfFile()
                    if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !path.isEmpty {
                        FileHandle.standardError.write("[LINKER] Found \(compiler_name) in PATH: \(path)\n".data(using: .utf8)!)
                        return path
                    }
                }
            } catch {}
        }

        FileHandle.standardError.write("[LINKER] WARNING: No compiler found, falling back to clang-14\n".data(using: .utf8)!)
        return "clang-14"
        #else
        // macOS/Windows fallback: Prefer clang, fall back to gcc
        let compilers = [
            "/usr/bin/clang",
            "/usr/bin/clang-14",     // Ubuntu 22.04 LLVM package
            "/opt/homebrew/bin/clang",
            "/usr/bin/gcc",
            "clang",
            "gcc"
        ]

        for compiler in compilers {
            if FileManager.default.fileExists(atPath: compiler) {
                return compiler
            }
        }

        // Try to find in PATH
        do {
            let whichProcess = Process()
            whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            whichProcess.arguments = ["clang"]

            let whichPipe = Pipe()
            whichProcess.standardOutput = whichPipe
            whichProcess.standardError = FileHandle.nullDevice

            try whichProcess.run()
            whichProcess.waitUntilExit()
            let data = whichPipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return path
            }
        } catch {}

        return "clang" // Hope it's in PATH
        #endif
    }

    /// Public accessor for Swift library path (for debugging)
    public func getSwiftLibPath() -> String? {
        return findSwiftLibPath()
    }

    private func findSwiftLibPath() -> String? {
        // First, try to get the Swift library path from the Swift toolchain itself
        let process = Process()

        #if os(macOS)
        // macOS: use xcrun to find swift
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--find", "swift"]
        #else
        // Linux/Windows: use which to find swift
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["swift"]
        #endif

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
        // Check standard system location
        let swiftLib = "/usr/lib/swift/linux"
        if FileManager.default.fileExists(atPath: swiftLib) {
            return swiftLib
        }

        // Check GitHub Actions / common Swift installation location
        let shareSwiftLib = "/usr/share/swift/usr/lib/swift/linux"
        if FileManager.default.fileExists(atPath: shareSwiftLib) {
            return shareSwiftLib
        }

        FileHandle.standardError.write("[LINKER] WARNING: Could not find Swift library path\n".data(using: .utf8)!)
        #endif

        return nil
    }

    private func runProcess(_ args: [String]) throws {
        guard !args.isEmpty else {
            throw LinkerError.compilationFailed("No command specified")
        }

        #if os(Linux)
        FileHandle.standardError.write("[LINKER] runProcess() called with \(args.count) args\n".data(using: .utf8)!)
        #endif

        // Debug: Print command being run (helpful for CI debugging)
        let command = args.joined(separator: " ")
        #if DEBUG
        print("Running: \(command)")
        #else
        // Always print on Linux for debugging integration test issues
        #if os(Linux)
        FileHandle.standardError.write("[LINKER] Running: \(command)\n".data(using: .utf8)!)
        #endif
        #endif

        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        #if os(Linux)
        FileHandle.standardError.write("[LINKER] Starting process...\n".data(using: .utf8)!)
        #endif

        // Thread-safe data storage
        final class DataBox: @unchecked Sendable {
            var data = Data()
            let lock = NSLock()

            func append(_ newData: Data) {
                lock.lock()
                defer { lock.unlock() }
                data.append(newData)
            }

            func get() -> Data {
                lock.lock()
                defer { lock.unlock() }
                return data
            }
        }

        let outputBox = DataBox()
        let errorBox = DataBox()

        do {
            try process.run()
            #if os(Linux)
            FileHandle.standardError.write("[LINKER] Process started, waiting for exit...\n".data(using: .utf8)!)
            #endif

            // Read pipes in background to prevent deadlock
            let outputHandle = outputPipe.fileHandleForReading
            let errorHandle = errorPipe.fileHandleForReading

            DispatchQueue.global().async {
                let data = outputHandle.readDataToEndOfFile()
                outputBox.append(data)
            }

            DispatchQueue.global().async {
                let data = errorHandle.readDataToEndOfFile()
                errorBox.append(data)
            }

            process.waitUntilExit()

            // Give a moment for pipe reading to complete
            Thread.sleep(forTimeInterval: 0.1)

            #if os(Linux)
            FileHandle.standardError.write("[LINKER] Process exited with status: \(process.terminationStatus)\n".data(using: .utf8)!)
            #endif
        } catch {
            throw LinkerError.compilationFailed("Failed to run compiler: \(error)")
        }

        // Convert captured data to strings
        let errorMessage = String(data: errorBox.get(), encoding: .utf8) ?? ""
        let outputMessage = String(data: outputBox.get(), encoding: .utf8) ?? ""

        #if os(Linux)
        // On Linux, always print compiler output for debugging
        if !errorMessage.isEmpty {
            print("[LINKER] stderr: \(errorMessage)")
        }
        if !outputMessage.isEmpty {
            print("[LINKER] stdout: \(outputMessage)")
        }
        #endif

        if process.terminationStatus != 0 {
            let combined = [errorMessage, outputMessage].filter { !$0.isEmpty }.joined(separator: "\n")
            throw LinkerError.compilationFailed(combined.isEmpty ? "Unknown error" : combined)
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
