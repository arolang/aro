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
        #if os(Windows)
        // On Windows, use clang to compile LLVM IR to object files
        // The standard LLVM Windows distribution doesn't include llc
        let clangPath = try findClang()
        var args = [clangPath]
        args.append("-c")  // Compile only, don't link
        args.append(optimize.rawValue)
        args.append("-o")
        args.append(outputPath)
        args.append(irPath)
        try runProcess(args)
        #else
        let llcPath = try findLLC()

        var args = [llcPath]

        // Add -opaque-pointers flag only for LLVM 14-16
        // LLVM 14: Flag enables opaque pointers (typed pointers are default)
        // LLVM 15-16: Opaque pointers are default, flag is accepted but deprecated
        // LLVM 17+: Flag removed (opaque pointers are the only mode)
        if let version = getLLVMMajorVersion(llcPath), version >= 14 && version < 17 {
            args.append("-opaque-pointers")
        }

        // On Linux, generate position-independent code for PIE executables
        // Modern Linux distributions require PIE by default; without this flag,
        // x86_64 gets R_X86_64_32 relocations that are incompatible with PIE
        #if os(Linux)
        args.append("-relocation-model=pic")
        #endif

        args.append("-filetype=obj")
        args.append(optimize.rawValue)
        args.append("-o")
        args.append(outputPath)
        args.append(irPath)

        try runProcess(args)
        #endif
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
        #if os(Windows)
        // On Windows, check common LLVM installation paths
        let windowsPaths = [
            "C:\\Program Files\\LLVM\\bin\\llc.exe",
            "C:\\Program Files (x86)\\LLVM\\bin\\llc.exe"
        ]

        for path in windowsPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // Fallback to PATH (may not work reliably on Windows)
        return "llc"
        #else
        // Unix-like systems (macOS, Linux)
        let paths = [
            "/opt/homebrew/opt/llvm/bin/llc",
            "/usr/local/opt/llvm/bin/llc",
            "/usr/bin/llc",
            "/usr/local/bin/llc",
            "/usr/bin/llc-14"  // Ubuntu 24.04
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

        #if os(macOS)
        throw LinkerError.compilationFailed("llc not found. Please install LLVM: brew install llvm")
        #else
        throw LinkerError.compilationFailed("llc not found. Please install LLVM: apt-get install llvm-14")
        #endif
        #endif
    }

    /// Find clang executable (used on Windows for LLVM IR compilation)
    private func findClang() throws -> String {
        #if os(Windows)
        let windowsPaths = [
            "C:\\Program Files\\LLVM\\bin\\clang.exe",
            "C:\\Program Files (x86)\\LLVM\\bin\\clang.exe"
        ]

        for path in windowsPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // Fallback to PATH
        return "clang"
        #else
        // On Unix, we use llc, not clang for IR compilation
        throw LinkerError.compilationFailed("clang lookup not implemented for this platform")
        #endif
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
            #if os(Windows)
            // On Windows, use the full path to the library directly
            // -lARORuntime would look for ARORuntime.lib, but we have libARORuntime.a
            // Also, Windows linker doesn't support rpath
            args.append(runtimePath)
            #else
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

                // CRITICAL: When using clang to link Swift code, we need swiftrt.o
                // This object file initializes the Swift runtime (metadata registration, etc.)
                // Without it, the binary will hang during Swift runtime bootstrap
                let swiftRTPath = findSwiftRuntimeObject(swiftLibPath: swiftLibPath)
                if let rtPath = swiftRTPath {
                    FileHandle.standardError.write("[LINKER] Found swiftrt.o at: \(rtPath)\n".data(using: .utf8)!)
                    // swiftrt.o must be linked FIRST to initialize Swift runtime before any Swift code runs
                    args.insert(rtPath, at: 1)  // Insert right after compiler, before object files
                } else {
                    FileHandle.standardError.write("[LINKER] WARNING: swiftrt.o not found - binary may hang\n".data(using: .utf8)!)
                }

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

        // Export symbols to dynamic symbol table for dlsym lookup
        // Required for HTTP binaries to find compiled feature set functions at runtime
        args.append("-rdynamic")

        // Dead code stripping on Linux
        if options.deadStrip {
            args.append("-Xlinker")
            args.append("--gc-sections")
        }
        #elseif os(Windows)
        // Windows platform libraries
        // libARORuntime.a is a Swift static library. On Windows:
        // - At link time, we need import libraries (.lib) to resolve external symbols
        // - At runtime, the corresponding DLLs must be in PATH
        //
        // The Swift runtime DLLs should be in PATH from the Swift installation.
        // We add -L for the SDK's import libraries.

        if let swiftLibPath = findSwiftLibPath() {
            FileHandle.standardError.write("[LINKER-WIN] Found Swift lib path: \(swiftLibPath)\n".data(using: .utf8)!)
            args.append("-L\(swiftLibPath)")

            // CRITICAL: Link swiftrt.obj to initialize Swift runtime on Windows
            // Without this, the binary will crash with ACCESS_VIOLATION at startup
            if let swiftRTPath = findWindowsSwiftRuntimeObject(swiftLibPath: swiftLibPath) {
                FileHandle.standardError.write("[LINKER-WIN] Found swiftrt at: \(swiftRTPath)\n".data(using: .utf8)!)
                // Insert right after compiler, before object files
                args.insert(swiftRTPath, at: 1)
            } else {
                FileHandle.standardError.write("[LINKER-WIN] WARNING: swiftrt not found - binary may crash at runtime\n".data(using: .utf8)!)
            }

            // Also add the runtime lib path in case import libs are there
            // C:\Users\runneradmin\AppData\Local\Programs\Swift\Runtimes\VERSION\usr\lib
            if let runtimeLibPath = ProcessInfo.processInfo.environment["PATH"]?
                .components(separatedBy: ";")
                .first(where: { $0.contains("Swift\\Runtimes") && $0.contains("\\bin") }) {
                // Convert bin path to lib path
                let libPath = runtimeLibPath.replacingOccurrences(of: "\\bin", with: "\\lib")
                FileHandle.standardError.write("[LINKER-WIN] Also checking runtime lib: \(libPath)\n".data(using: .utf8)!)
                if FileManager.default.fileExists(atPath: libPath) {
                    args.append("-L\(libPath)")
                }
            }
        } else {
            FileHandle.standardError.write("[LINKER-WIN] WARNING: Swift library path not found!\n".data(using: .utf8)!)
        }

        // Windows CRT and system libraries
        // These resolve symbols like strdup (_strdup on Windows), _wassert, etc.
        // Note: On Windows, strdup is deprecated in favor of _strdup
        // The UCRT provides these via msvcrt.lib or ucrt.lib

        // Add UCRT library path from Windows SDK if available
        if let ucrtPath = findWindowsUCRTPath() {
            FileHandle.standardError.write("[LINKER-WIN] Found UCRT path: \(ucrtPath)\n".data(using: .utf8)!)
            args.append("-L\(ucrtPath)")
        }

        // Add VC runtime library path if available
        if let vcrtPath = findWindowsVCRuntimePath() {
            FileHandle.standardError.write("[LINKER-WIN] Found VC runtime path: \(vcrtPath)\n".data(using: .utf8)!)
            args.append("-L\(vcrtPath)")
        }

        // Add Windows UM (user mode) library path for kernel32.lib, user32.lib, etc.
        if let umPath = findWindowsUMPath() {
            FileHandle.standardError.write("[LINKER-WIN] Found Windows UM path: \(umPath)\n".data(using: .utf8)!)
            args.append("-L\(umPath)")
        }

        // Link against Windows CRT libraries to resolve __imp_strdup, __imp__wassert etc.
        // Use DLL versions (no 'lib' prefix) to match what Swift uses
        args.append("-lucrt")               // Universal CRT (basic C runtime)
        args.append("-lvcruntime")          // VC runtime (exceptions, etc.)
        args.append("-lmsvcrt")             // MS VC runtime (strdup, etc.)
        args.append("-llegacy_stdio_definitions")  // Legacy stdio (additional POSIX functions)
        args.append("-loldnames")           // POSIX name mappings (strdup -> _strdup)
        args.append("-lkernel32")           // Windows kernel functions
        args.append("-luser32")             // Windows user functions
        args.append("-lws2_32")             // Windows sockets (networking)
        args.append("-ladvapi32")           // Advanced Windows API
        args.append("-lshell32")            // Shell functions
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
            #if os(Windows)
            // On Windows, use the full path to the library directly
            args.append(runtimePath)
            #else
            let libDir = URL(fileURLWithPath: runtimePath).deletingLastPathComponent().path
            args.append("-L\(libDir)")
            args.append("-lARORuntime")
            args.append("-Wl,-rpath,\(libDir)")
            #endif
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

        // On Linux, use clang for linking Swift static libraries
        // swiftc on GitHub Actions runners is unreliable (hangs intermittently)
        // clang works consistently when we explicitly specify Swift runtime libraries

        // 1. Check for clang-14 (Ubuntu 24.04 default)
        if FileManager.default.fileExists(atPath: "/usr/bin/clang-14") {
            FileHandle.standardError.write("[LINKER] Found clang-14 at /usr/bin/clang-14\n".data(using: .utf8)!)
            return "/usr/bin/clang-14"
        }

        // 2. Check for generic clang
        if FileManager.default.fileExists(atPath: "/usr/bin/clang") {
            FileHandle.standardError.write("[LINKER] Found clang at /usr/bin/clang\n".data(using: .utf8)!)
            return "/usr/bin/clang"
        }

        // 3. Try to find clang in PATH
        FileHandle.standardError.write("[LINKER] Trying to find clang in PATH...\n".data(using: .utf8)!)
        do {
            let whichProcess = Process()
            whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            whichProcess.arguments = ["clang"]

            let whichPipe = Pipe()
            whichProcess.standardOutput = whichPipe
            whichProcess.standardError = FileHandle.nullDevice

            try whichProcess.run()
            whichProcess.waitUntilExit()

            if whichProcess.terminationStatus == 0 {
                let data = whichPipe.fileHandleForReading.readDataToEndOfFile()
                if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty {
                    FileHandle.standardError.write("[LINKER] Found clang in PATH: \(path)\n".data(using: .utf8)!)
                    return path
                }
            }
        } catch {
            FileHandle.standardError.write("[LINKER] Error searching for clang: \(error)\n".data(using: .utf8)!)
        }

        // 4. Final fallback
        FileHandle.standardError.write("[LINKER] WARNING: No compiler found, returning clang-14\n".data(using: .utf8)!)
        return "clang-14"
        #elseif os(Windows)
        // Windows: Find clang.exe in standard LLVM installation paths
        let windowsCompilers = [
            "C:\\Program Files\\LLVM\\bin\\clang.exe",
            "C:\\Program Files (x86)\\LLVM\\bin\\clang.exe"
        ]

        for compiler in windowsCompilers {
            if FileManager.default.fileExists(atPath: compiler) {
                return compiler
            }
        }

        // Try to find clang in PATH using 'where' command
        do {
            let whereProcess = Process()
            whereProcess.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\where.exe")
            whereProcess.arguments = ["clang"]

            let wherePipe = Pipe()
            whereProcess.standardOutput = wherePipe
            whereProcess.standardError = FileHandle.nullDevice

            try whereProcess.run()
            whereProcess.waitUntilExit()

            if whereProcess.terminationStatus == 0 {
                let data = wherePipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    // 'where' can return multiple lines, take the first one
                    let paths = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
                    if let firstPath = paths.first {
                        return firstPath.trimmingCharacters(in: .whitespaces)
                    }
                }
            }
        } catch {}

        return "clang.exe" // Hope it's in PATH
        #else
        // macOS fallback: Prefer clang, fall back to gcc
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
        #if os(Windows)
        // Windows: Find Swift library path for import libraries (.lib files)
        // Import libs are in: toolchain\usr\lib\swift\windows\x86_64\

        FileHandle.standardError.write("[LINKER-WIN] Searching for Swift library path...\n".data(using: .utf8)!)

        // Try to find swift.exe and derive library path from it
        do {
            let whereProcess = Process()
            whereProcess.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\where.exe")
            whereProcess.arguments = ["swift"]

            let wherePipe = Pipe()
            whereProcess.standardOutput = wherePipe
            whereProcess.standardError = FileHandle.nullDevice

            try whereProcess.run()
            whereProcess.waitUntilExit()

            FileHandle.standardError.write("[LINKER-WIN] where swift exit status: \(whereProcess.terminationStatus)\n".data(using: .utf8)!)

            if whereProcess.terminationStatus == 0 {
                let data = wherePipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    FileHandle.standardError.write("[LINKER-WIN] where swift output: \(output.trimmingCharacters(in: .whitespacesAndNewlines))\n".data(using: .utf8)!)
                    let paths = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
                    if let swiftPath = paths.first?.trimmingCharacters(in: .whitespaces) {
                        FileHandle.standardError.write("[LINKER-WIN] Swift path: \(swiftPath)\n".data(using: .utf8)!)
                        // Swift is at: C:\path\to\toolchain\usr\bin\swift.exe
                        // Import libs are at: C:\path\to\toolchain\usr\lib\swift\windows\x86_64\
                        if let binRange = swiftPath.range(of: "\\bin\\", options: .backwards) {
                            let usrPath = String(swiftPath[..<binRange.lowerBound])
                            FileHandle.standardError.write("[LINKER-WIN] usr path: \(usrPath)\n".data(using: .utf8)!)
                            // Try architecture-specific path first (contains .lib import libraries)
                            let archLibPath = usrPath + "\\lib\\swift\\windows\\x86_64"
                            FileHandle.standardError.write("[LINKER-WIN] Checking arch path: \(archLibPath)\n".data(using: .utf8)!)
                            if FileManager.default.fileExists(atPath: archLibPath) {
                                FileHandle.standardError.write("[LINKER-WIN] Found at arch path!\n".data(using: .utf8)!)
                                return archLibPath
                            }
                            // Fall back to platform path
                            let libPath = usrPath + "\\lib\\swift\\windows"
                            FileHandle.standardError.write("[LINKER-WIN] Checking platform path: \(libPath)\n".data(using: .utf8)!)
                            if FileManager.default.fileExists(atPath: libPath) {
                                FileHandle.standardError.write("[LINKER-WIN] Found at platform path!\n".data(using: .utf8)!)
                                return libPath
                            }
                        } else {
                            FileHandle.standardError.write("[LINKER-WIN] Could not find \\bin\\ in path\n".data(using: .utf8)!)
                        }
                    }
                }
            }
        } catch {
            FileHandle.standardError.write("[LINKER-WIN] Error running where: \(error)\n".data(using: .utf8)!)
        }

        // Check SDKROOT environment variable - Swift import libs are in the SDK, not the toolchain
        if let sdkRoot = ProcessInfo.processInfo.environment["SDKROOT"] {
            FileHandle.standardError.write("[LINKER-WIN] SDKROOT: \(sdkRoot)\n".data(using: .utf8)!)
            // Import libs are at: SDKROOT\usr\lib\swift\windows\x86_64
            // Handle trailing backslash in SDKROOT
            let cleanSdkRoot = sdkRoot.hasSuffix("\\") ? String(sdkRoot.dropLast()) : sdkRoot
            let sdkLibPath = cleanSdkRoot + "\\usr\\lib\\swift\\windows\\x86_64"
            let sdkLibPathAlt = cleanSdkRoot + "\\usr\\lib\\swift\\windows"  // Without arch suffix
            FileHandle.standardError.write("[LINKER-WIN] Checking SDK path: \(sdkLibPath)\n".data(using: .utf8)!)
            if FileManager.default.fileExists(atPath: sdkLibPath) {
                FileHandle.standardError.write("[LINKER-WIN] Found at SDK path!\n".data(using: .utf8)!)
                return sdkLibPath
            }
            if FileManager.default.fileExists(atPath: sdkLibPathAlt) {
                FileHandle.standardError.write("[LINKER-WIN] Found at SDK alt path!\n".data(using: .utf8)!)
                return sdkLibPathAlt
            }
        }

        // Check common installation locations (GitHub Actions Windows runner)
        FileHandle.standardError.write("[LINKER-WIN] Checking common paths...\n".data(using: .utf8)!)
        let commonPaths = [
            // SDK paths (where import libs actually live)
            "C:\\Users\\runneradmin\\AppData\\Local\\Programs\\Swift\\Platforms\\6.2.1\\Windows.platform\\Developer\\SDKs\\Windows.sdk\\usr\\lib\\swift\\windows\\x86_64",
            "C:\\Users\\runneradmin\\AppData\\Local\\Programs\\Swift\\Platforms\\6.2.1\\Windows.platform\\Developer\\SDKs\\Windows.sdk\\usr\\lib\\swift\\windows",
            // Toolchain paths (fallback)
            "C:\\Users\\runneradmin\\AppData\\Local\\Programs\\Swift\\Toolchains\\6.2.1+Asserts\\usr\\lib\\swift\\windows\\x86_64",
            "C:\\Users\\runneradmin\\AppData\\Local\\Programs\\Swift\\Toolchains\\6.2.1+Asserts\\usr\\lib\\swift\\windows",
            "C:\\Library\\Developer\\Toolchains\\unknown-Asserts-development.xctoolchain\\usr\\lib\\swift\\windows\\x86_64",
            "C:\\Swift\\Toolchains\\0.0.0+Asserts\\usr\\lib\\swift\\windows\\x86_64"
        ]

        for path in commonPaths {
            FileHandle.standardError.write("[LINKER-WIN] Checking: \(path)\n".data(using: .utf8)!)
            if FileManager.default.fileExists(atPath: path) {
                FileHandle.standardError.write("[LINKER-WIN] Found!\n".data(using: .utf8)!)
                return path
            }
        }

        FileHandle.standardError.write("[LINKER-WIN] No Swift lib path found\n".data(using: .utf8)!)
        return nil
        #else
        // First, try to get the Swift library path from the Swift toolchain itself
        let process = Process()

        #if os(macOS)
        // macOS: use xcrun to find swift
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--find", "swift"]
        #else
        // Linux: use which to find swift
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
                    #else
                    let platformLib = toolchainLib.appendingPathComponent("linux").path
                    #endif

                    if FileManager.default.fileExists(atPath: platformLib) {
                        return platformLib
                    }
                }
            }
        } catch {}
        #endif

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

    /// Find Windows Universal CRT library path
    /// The UCRT is part of the Windows SDK
    private func findWindowsUCRTPath() -> String? {
        #if os(Windows)
        // Common Windows SDK UCRT paths for x64
        // The UCRT is typically at: C:\Program Files (x86)\Windows Kits\10\Lib\<version>\ucrt\x64
        let windowsKitsBase = "C:\\Program Files (x86)\\Windows Kits\\10\\Lib"

        FileHandle.standardError.write("[LINKER-WIN] Looking for UCRT in Windows Kits...\n".data(using: .utf8)!)

        // Find the latest SDK version
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: windowsKitsBase) {
            // Sort versions in descending order to get the latest
            let sortedVersions = versions.filter { $0.hasPrefix("10.") }.sorted().reversed()
            for version in sortedVersions {
                let ucrtPath = "\(windowsKitsBase)\\\(version)\\ucrt\\x64"
                if FileManager.default.fileExists(atPath: ucrtPath) {
                    FileHandle.standardError.write("[LINKER-WIN] Found UCRT at: \(ucrtPath)\n".data(using: .utf8)!)
                    return ucrtPath
                }
            }
        }

        // Try hardcoded common versions
        let commonVersions = [
            "10.0.22621.0",  // Windows 11 SDK
            "10.0.22000.0",  // Windows 11 SDK
            "10.0.19041.0",  // Windows 10 SDK 2004
            "10.0.18362.0",  // Windows 10 SDK 1903
            "10.0.17763.0"   // Windows 10 SDK 1809
        ]

        for version in commonVersions {
            let ucrtPath = "\(windowsKitsBase)\\\(version)\\ucrt\\x64"
            if FileManager.default.fileExists(atPath: ucrtPath) {
                return ucrtPath
            }
        }

        FileHandle.standardError.write("[LINKER-WIN] UCRT not found in Windows Kits\n".data(using: .utf8)!)
        #endif
        return nil
    }

    /// Find Windows VC runtime library path
    /// The VC runtime is part of Visual Studio or Build Tools
    private func findWindowsVCRuntimePath() -> String? {
        #if os(Windows)
        // Common VC runtime paths for x64
        // Located at: C:\Program Files\Microsoft Visual Studio\<year>\<edition>\VC\Tools\MSVC\<version>\lib\x64
        // Or: C:\Program Files (x86)\Microsoft Visual Studio\<year>\<edition>\VC\Tools\MSVC\<version>\lib\x64

        FileHandle.standardError.write("[LINKER-WIN] Looking for VC runtime...\n".data(using: .utf8)!)

        let vsBasePaths = [
            "C:\\Program Files\\Microsoft Visual Studio",
            "C:\\Program Files (x86)\\Microsoft Visual Studio"
        ]

        let vsYears = ["2022", "2019", "2017"]
        let vsEditions = ["Enterprise", "Professional", "Community", "BuildTools"]

        for basePath in vsBasePaths {
            for year in vsYears {
                for edition in vsEditions {
                    let vcToolsPath = "\(basePath)\\\(year)\\\(edition)\\VC\\Tools\\MSVC"
                    if let versions = try? FileManager.default.contentsOfDirectory(atPath: vcToolsPath) {
                        // Get the latest version
                        if let latestVersion = versions.sorted().last {
                            let libPath = "\(vcToolsPath)\\\(latestVersion)\\lib\\x64"
                            if FileManager.default.fileExists(atPath: libPath) {
                                FileHandle.standardError.write("[LINKER-WIN] Found VC runtime at: \(libPath)\n".data(using: .utf8)!)
                                return libPath
                            }
                        }
                    }
                }
            }
        }

        FileHandle.standardError.write("[LINKER-WIN] VC runtime not found\n".data(using: .utf8)!)
        #endif
        return nil
    }

    /// Find Windows Swift runtime initialization object
    /// This is required to properly initialize the Swift runtime on Windows
    private func findWindowsSwiftRuntimeObject(swiftLibPath: String) -> String? {
        #if os(Windows)
        // On Windows, the Swift runtime initialization object is named swiftrt.obj
        // It's typically in the same directory as the Swift libraries

        let potentialPaths = [
            "\(swiftLibPath)\\swiftrt.obj",
            "\(swiftLibPath)\\..\\swiftrt.obj",  // One level up
        ]

        for path in potentialPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // Also check the toolchain path if swiftLibPath is the SDK
        // Toolchain: C:\...\Toolchains\6.2.1+Asserts\usr\lib\swift\windows\x86_64\swiftrt.obj
        if let sdkRoot = ProcessInfo.processInfo.environment["SDKROOT"],
           let toolchainRoot = sdkRoot.range(of: "Platforms") {
            let basePath = String(sdkRoot[..<toolchainRoot.lowerBound])
            let toolchainPaths = [
                "\(basePath)Toolchains\\6.2.1+Asserts\\usr\\lib\\swift\\windows\\x86_64\\swiftrt.obj",
                "\(basePath)Toolchains\\6.2.1-RELEASE\\usr\\lib\\swift\\windows\\x86_64\\swiftrt.obj"
            ]
            for path in toolchainPaths {
                let cleanPath = path.replacingOccurrences(of: "\\\\", with: "\\")
                if FileManager.default.fileExists(atPath: cleanPath) {
                    return cleanPath
                }
            }
        }

        // Try to find via swift.exe location
        do {
            let whereProcess = Process()
            whereProcess.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\where.exe")
            whereProcess.arguments = ["swift"]

            let wherePipe = Pipe()
            whereProcess.standardOutput = wherePipe
            whereProcess.standardError = FileHandle.nullDevice

            try whereProcess.run()
            whereProcess.waitUntilExit()

            if whereProcess.terminationStatus == 0 {
                let data = wherePipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8),
                   let swiftPath = output.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces),
                   let binRange = swiftPath.range(of: "\\bin\\", options: .backwards) {
                    let usrPath = String(swiftPath[..<binRange.lowerBound])
                    let rtPath = "\(usrPath)\\lib\\swift\\windows\\x86_64\\swiftrt.obj"
                    if FileManager.default.fileExists(atPath: rtPath) {
                        return rtPath
                    }
                }
            }
        } catch {}

        FileHandle.standardError.write("[LINKER-WIN] Could not find swiftrt.obj\n".data(using: .utf8)!)
        #endif
        return nil
    }

    /// Find Windows UM (user mode) library path for Windows API libraries
    /// Contains kernel32.lib, user32.lib, ws2_32.lib, etc.
    private func findWindowsUMPath() -> String? {
        #if os(Windows)
        let windowsKitsBase = "C:\\Program Files (x86)\\Windows Kits\\10\\Lib"

        FileHandle.standardError.write("[LINKER-WIN] Looking for Windows UM libs...\n".data(using: .utf8)!)

        if let versions = try? FileManager.default.contentsOfDirectory(atPath: windowsKitsBase) {
            let sortedVersions = versions.filter { $0.hasPrefix("10.") }.sorted().reversed()
            for version in sortedVersions {
                let umPath = "\(windowsKitsBase)\\\(version)\\um\\x64"
                if FileManager.default.fileExists(atPath: umPath) {
                    FileHandle.standardError.write("[LINKER-WIN] Found Windows UM libs at: \(umPath)\n".data(using: .utf8)!)
                    return umPath
                }
            }
        }

        // Try hardcoded common versions
        let commonVersions = [
            "10.0.22621.0",  // Windows 11 SDK
            "10.0.22000.0",  // Windows 11 SDK
            "10.0.19041.0",  // Windows 10 SDK 2004
            "10.0.18362.0",  // Windows 10 SDK 1903
            "10.0.17763.0"   // Windows 10 SDK 1809
        ]

        for version in commonVersions {
            let umPath = "\(windowsKitsBase)\\\(version)\\um\\x64"
            if FileManager.default.fileExists(atPath: umPath) {
                return umPath
            }
        }

        FileHandle.standardError.write("[LINKER-WIN] Windows UM libs not found\n".data(using: .utf8)!)
        #endif
        return nil
    }

    /// Find the Swift runtime initialization object (swiftrt.o)
    /// This object is required when linking Swift code with clang instead of swiftc
    private func findSwiftRuntimeObject(swiftLibPath: String) -> String? {
        #if os(Linux)
        // On Linux, swiftrt.o is in the architecture-specific subdirectory
        // e.g., /usr/share/swift/usr/lib/swift/linux/x86_64/swiftrt.o

        // Determine architecture
        #if arch(x86_64)
        let arch = "x86_64"
        #elseif arch(arm64)
        let arch = "aarch64"
        #else
        let arch = "x86_64"  // Default fallback
        #endif

        // Build potential paths
        let potentialPaths = [
            "\(swiftLibPath)/\(arch)/swiftrt.o",
            "\(swiftLibPath)/swiftrt.o",
            // Alternative paths based on common Swift installations
            "/usr/lib/swift/linux/\(arch)/swiftrt.o",
            "/usr/share/swift/usr/lib/swift/linux/\(arch)/swiftrt.o"
        ]

        for path in potentialPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        FileHandle.standardError.write("[LINKER] Searched for swiftrt.o in: \(potentialPaths)\n".data(using: .utf8)!)
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
