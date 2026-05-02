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

    /// Enable verbose logging output
    public let verbose: Bool

    // MARK: - Output Types

    public enum OutputType: String {
        case executable
        case object
        case sharedLibrary = "shared"
        case assembly
    }

    // MARK: - Initialization

    public init(runtimeLibraryPath: String? = nil, targetPlatform: String? = nil, verbose: Bool = false) {
        self.runtimeLibraryPath = runtimeLibraryPath
        self.targetPlatform = targetPlatform
        self.verbose = verbose
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
        FileHandle.standardError.write(Data("[LINKER] ===== ENTERED link() method =====\n".utf8))
        FileHandle.standardError.write(Data("[LINKER] link() called with objectFiles: \(objectFiles)\n".utf8))
        FileHandle.standardError.write(Data("[LINKER] outputPath: \(outputPath)\n".utf8))
        FileHandle.standardError.write(Data("[LINKER] Finding compiler...\n".utf8))
        #endif

        var args = [findCompiler()]

        #if os(Linux)
        FileHandle.standardError.write(Data("[LINKER] Array created with compiler: \(args[0])\n".utf8))
        FileHandle.standardError.write(Data("[LINKER] Building arguments...\n".utf8))
        #endif

        #if os(Linux)
        FileHandle.standardError.write(Data("[LINKER] 1. Handling output type...\n".utf8))
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
        FileHandle.standardError.write(Data("[LINKER] 2. Adding object files...\n".utf8))

        // On Linux, export all symbols to the dynamic symbol table
        // This is required for dlsym() to find feature set functions (aro_fs_*)
        // when handling HTTP requests in compiled binaries
        if outputType == .executable {
            args.append("-rdynamic")
        }
        #endif

        // Object files
        args.append(contentsOf: objectFiles)

        #if os(Linux)
        FileHandle.standardError.write(Data("[LINKER] 3. Adding output path...\n".utf8))
        #endif

        // Output
        args.append("-o")
        args.append(outputPath)

        #if os(Linux)
        FileHandle.standardError.write(Data("[LINKER] 4. Processing runtime library...\n".utf8))
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
        FileHandle.standardError.write(Data("[LINKER] 5. Checking platform-specific libraries...\n".utf8))
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

        // libgit2 (Homebrew). libARORuntime.a references git_* symbols from
        // the GitService implementation; without -lgit2 the link fails.
        if let libgit2Dir = findLibgit2Dir() {
            args.append("-L\(libgit2Dir)")
            args.append("-Wl,-rpath,\(libgit2Dir)")
        }
        args.append("-lgit2")

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

            FileHandle.standardError.write(Data("[LINKER] Swift lib path: \(swiftLibPath)\n".utf8))
            FileHandle.standardError.write(Data("[LINKER] Using compiler: \(usingSwiftc ? "swiftc" : "clang")\n".utf8))

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
                    FileHandle.standardError.write(Data("[LINKER] Found swiftrt.o at: \(rtPath)\n".utf8))
                    // swiftrt.o must be linked FIRST to initialize Swift runtime before any Swift code runs
                    args.insert(rtPath, at: 1)  // Insert right after compiler, before object files
                } else {
                    FileHandle.standardError.write(Data("[LINKER] WARNING: swiftrt.o not found - binary may hang\n".utf8))
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
            FileHandle.standardError.write(Data("[LINKER] WARNING: Swift library path not found\n".utf8))
        }

        args.append("-lpthread")
        args.append("-ldl")
        args.append("-lm")
        args.append("-lstdc++")  // C++ standard library for BoringSSL
        args.append("-lz")       // zlib for compression
        args.append("-lxml2")    // libxml2 for Kanna HTML/XML parsing
        args.append("-lgit2")    // libgit2 for Git actions

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
            FileHandle.standardError.write(Data("[LINKER-WIN] Found Swift lib path: \(swiftLibPath)\n".utf8))
            args.append("-L\(swiftLibPath)")

            // CRITICAL: Link swiftrt.obj to initialize Swift runtime on Windows
            // Without this, the binary will crash with ACCESS_VIOLATION at startup
            if let swiftRTPath = findWindowsSwiftRuntimeObject(swiftLibPath: swiftLibPath) {
                FileHandle.standardError.write(Data("[LINKER-WIN] Found swiftrt at: \(swiftRTPath)\n".utf8))
                // Insert right after compiler, before object files
                args.insert(swiftRTPath, at: 1)
            } else {
                FileHandle.standardError.write(Data("[LINKER-WIN] WARNING: swiftrt not found - binary may crash at runtime\n".utf8))
            }

            // Also add the runtime lib path in case import libs are there
            // C:\Users\runneradmin\AppData\Local\Programs\Swift\Runtimes\VERSION\usr\lib
            if let runtimeLibPath = ProcessInfo.processInfo.environment["PATH"]?
                .components(separatedBy: ";")
                .first(where: { $0.contains("Swift\\Runtimes") && $0.contains("\\bin") }) {
                // Convert bin path to lib path
                let libPath = runtimeLibPath.replacingOccurrences(of: "\\bin", with: "\\lib")
                FileHandle.standardError.write(Data("[LINKER-WIN] Also checking runtime lib: \(libPath)\n".utf8))
                if FileManager.default.fileExists(atPath: libPath) {
                    args.append("-L\(libPath)")
                }
            }
        } else {
            FileHandle.standardError.write(Data("[LINKER-WIN] WARNING: Swift library path not found!\n".utf8))
        }

        // Windows CRT and system libraries
        // These resolve symbols like strdup (_strdup on Windows), _wassert, etc.
        // Note: On Windows, strdup is deprecated in favor of _strdup
        // The UCRT provides these via msvcrt.lib or ucrt.lib

        // Add UCRT library path from Windows SDK if available
        if let ucrtPath = findWindowsUCRTPath() {
            FileHandle.standardError.write(Data("[LINKER-WIN] Found UCRT path: \(ucrtPath)\n".utf8))
            args.append("-L\(ucrtPath)")
        }

        // Add VC runtime library path if available
        if let vcrtPath = findWindowsVCRuntimePath() {
            FileHandle.standardError.write(Data("[LINKER-WIN] Found VC runtime path: \(vcrtPath)\n".utf8))
            args.append("-L\(vcrtPath)")
        }

        // Add Windows UM (user mode) library path for kernel32.lib, user32.lib, etc.
        if let umPath = findWindowsUMPath() {
            FileHandle.standardError.write(Data("[LINKER-WIN] Found Windows UM path: \(umPath)\n".utf8))
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
        FileHandle.standardError.write(Data("[LINKER] Arguments built, calling runProcess...\n".utf8))
        FileHandle.standardError.write(Data("[LINKER] Total args: \(args.count)\n".utf8))
        #endif

        try runProcess(args)

        #if os(Linux)
        FileHandle.standardError.write(Data("[LINKER] runProcess completed successfully\n".utf8))
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

    /// Log a debug message (only when verbose is enabled)
    private func debugLog(_ message: String) {
        guard verbose else { return }
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    private func findCompiler() -> String {
        #if os(Linux)
        FileHandle.standardError.write(Data("[LINKER] findCompiler() called on Linux\n".utf8))

        // On Linux, use clang for linking Swift static libraries
        // swiftc on GitHub Actions runners is unreliable (hangs intermittently)
        // clang works consistently when we explicitly specify Swift runtime libraries

        // 1. Check for generic clang (may be symlinked to clang-20 in CI)
        if FileManager.default.fileExists(atPath: "/usr/bin/clang") {
            FileHandle.standardError.write(Data("[LINKER] Found clang at /usr/bin/clang\n".utf8))
            return "/usr/bin/clang"
        }

        // 2. Check for clang-14 (Ubuntu fallback)
        if FileManager.default.fileExists(atPath: "/usr/bin/clang-14") {
            FileHandle.standardError.write(Data("[LINKER] Found clang-14 at /usr/bin/clang-14\n".utf8))
            return "/usr/bin/clang-14"
        }

        // 3. Try to find clang in PATH
        FileHandle.standardError.write(Data("[LINKER] Trying to find clang in PATH...\n".utf8))
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
                    FileHandle.standardError.write(Data("[LINKER] Found clang in PATH: \(path)\n".utf8))
                    return path
                }
            }
        } catch {
            FileHandle.standardError.write(Data("[LINKER] Error searching for clang: \(error)\n".utf8))
        }

        // 4. Final fallback
        FileHandle.standardError.write(Data("[LINKER] WARNING: No compiler found, returning clang-14\n".utf8))
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

    /// Locate the directory containing libgit2.dylib on macOS (Homebrew).
    /// Returns nil if libgit2 is on the default search path or cannot be found —
    /// callers still append `-lgit2` and let clang resolve it.
    private func findLibgit2Dir() -> String? {
        let candidates = [
            "/opt/homebrew/lib",       // Apple Silicon Homebrew
            "/usr/local/lib",          // Intel Homebrew / manual install
            "/opt/local/lib",          // MacPorts
        ]
        for dir in candidates {
            if FileManager.default.fileExists(atPath: "\(dir)/libgit2.dylib") {
                return dir
            }
        }
        return nil
    }

    private func findSwiftLibPath() -> String? {
        // Check environment variable first (allows CI/CD to override)
        if let envPath = ProcessInfo.processInfo.environment["SWIFT_LIB_PATH"] {
            debugLog("[LINKER] SWIFT_LIB_PATH env: \(envPath)")
            if FileManager.default.fileExists(atPath: envPath) {
                debugLog("[LINKER] Using SWIFT_LIB_PATH: \(envPath)")
                return envPath
            } else {
                debugLog("[LINKER] SWIFT_LIB_PATH does not exist!")
            }
        } else {
            debugLog("[LINKER] SWIFT_LIB_PATH not set")
        }

        #if os(Windows)
        // Windows: Find Swift library path for import libraries (.lib files)
        // Import libs are in: toolchain\usr\lib\swift\windows\x86_64\

        FileHandle.standardError.write(Data("[LINKER-WIN] Searching for Swift library path...\n".utf8))

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

            FileHandle.standardError.write(Data("[LINKER-WIN] where swift exit status: \(whereProcess.terminationStatus)\n".utf8))

            if whereProcess.terminationStatus == 0 {
                let data = wherePipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    FileHandle.standardError.write(Data("[LINKER-WIN] where swift output: \(output.trimmingCharacters(in: .whitespacesAndNewlines))\n".utf8))
                    let paths = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
                    if let swiftPath = paths.first?.trimmingCharacters(in: .whitespaces) {
                        FileHandle.standardError.write(Data("[LINKER-WIN] Swift path: \(swiftPath)\n".utf8))
                        // Swift is at: C:\path\to\toolchain\usr\bin\swift.exe
                        // Import libs are at: C:\path\to\toolchain\usr\lib\swift\windows\x86_64\
                        if let binRange = swiftPath.range(of: "\\bin\\", options: .backwards) {
                            let usrPath = String(swiftPath[..<binRange.lowerBound])
                            FileHandle.standardError.write(Data("[LINKER-WIN] usr path: \(usrPath)\n".utf8))
                            // Try architecture-specific path first (contains .lib import libraries)
                            let archLibPath = usrPath + "\\lib\\swift\\windows\\x86_64"
                            FileHandle.standardError.write(Data("[LINKER-WIN] Checking arch path: \(archLibPath)\n".utf8))
                            if FileManager.default.fileExists(atPath: archLibPath) {
                                FileHandle.standardError.write(Data("[LINKER-WIN] Found at arch path!\n".utf8))
                                return archLibPath
                            }
                            // Fall back to platform path
                            let libPath = usrPath + "\\lib\\swift\\windows"
                            FileHandle.standardError.write(Data("[LINKER-WIN] Checking platform path: \(libPath)\n".utf8))
                            if FileManager.default.fileExists(atPath: libPath) {
                                FileHandle.standardError.write(Data("[LINKER-WIN] Found at platform path!\n".utf8))
                                return libPath
                            }
                        } else {
                            FileHandle.standardError.write(Data("[LINKER-WIN] Could not find \\bin\\ in path\n".utf8))
                        }
                    }
                }
            }
        } catch {
            FileHandle.standardError.write(Data("[LINKER-WIN] Error running where: \(error)\n".utf8))
        }

        // Check SDKROOT environment variable - Swift import libs are in the SDK, not the toolchain
        if let sdkRoot = ProcessInfo.processInfo.environment["SDKROOT"] {
            FileHandle.standardError.write(Data("[LINKER-WIN] SDKROOT: \(sdkRoot)\n".utf8))
            // Import libs are at: SDKROOT\usr\lib\swift\windows\x86_64
            // Handle trailing backslash in SDKROOT
            let cleanSdkRoot = sdkRoot.hasSuffix("\\") ? String(sdkRoot.dropLast()) : sdkRoot
            let sdkLibPath = cleanSdkRoot + "\\usr\\lib\\swift\\windows\\x86_64"
            let sdkLibPathAlt = cleanSdkRoot + "\\usr\\lib\\swift\\windows"  // Without arch suffix
            FileHandle.standardError.write(Data("[LINKER-WIN] Checking SDK path: \(sdkLibPath)\n".utf8))
            if FileManager.default.fileExists(atPath: sdkLibPath) {
                FileHandle.standardError.write(Data("[LINKER-WIN] Found at SDK path!\n".utf8))
                return sdkLibPath
            }
            if FileManager.default.fileExists(atPath: sdkLibPathAlt) {
                FileHandle.standardError.write(Data("[LINKER-WIN] Found at SDK alt path!\n".utf8))
                return sdkLibPathAlt
            }
        }

        // Check common installation locations (GitHub Actions Windows runner)
        FileHandle.standardError.write(Data("[LINKER-WIN] Checking common paths...\n".utf8))
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
            FileHandle.standardError.write(Data("[LINKER-WIN] Checking: \(path)\n".utf8))
            if FileManager.default.fileExists(atPath: path) {
                FileHandle.standardError.write(Data("[LINKER-WIN] Found!\n".utf8))
                return path
            }
        }

        FileHandle.standardError.write(Data("[LINKER-WIN] No Swift lib path found\n".utf8))
        return nil
        #else
        // First, try to get the Swift library path from the Swift toolchain itself
        let process = Process()

        #if os(macOS)
        // macOS: use 'which' first to respect PATH (for swift-actions/setup-swift)
        // Fall back to 'xcrun' for Xcode installations
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["swift"]
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
                    // Swift is at: /path/to/toolchain/usr/bin/swift (standard)
                    //          or: /path/to/toolchain/bin/swift (swiftly)
                    // Libraries at: /path/to/toolchain/usr/lib/swift/macosx
                    let swiftURL = URL(fileURLWithPath: swiftPath)
                    let baseDir = swiftURL
                        .deletingLastPathComponent()  // Remove 'swift' → /path/bin
                        .deletingLastPathComponent()  // Remove 'bin' → /path

                    #if os(macOS)
                    let platformSuffix = "macosx"
                    #else
                    let platformSuffix = "linux"
                    #endif

                    // Try two possible structures:
                    // 1. Standard toolchain: /path/usr/bin/swift → /path/usr/lib/swift/platform
                    //    (baseDir is already at /path/usr, just add lib/swift)
                    // 2. Swiftly: /path/bin/swift → /path/usr/lib/swift/platform
                    //    (baseDir is at /path, need to add usr/lib/swift)
                    let pathsToTry = [
                        baseDir.appendingPathComponent("lib/swift/\(platformSuffix)").path,
                        baseDir.appendingPathComponent("usr/lib/swift/\(platformSuffix)").path
                    ]

                    #if os(macOS)
                    debugLog("[LINKER-MAC] which swift: \(swiftPath)")
                    debugLog("[LINKER-MAC] baseDir: \(baseDir.path)")
                    for path in pathsToTry {
                        debugLog("[LINKER-MAC] Trying: \(path) exists=\(FileManager.default.fileExists(atPath: path))")
                    }
                    #endif

                    for path in pathsToTry {
                        if FileManager.default.fileExists(atPath: path) {
                            return path
                        }
                    }
                }
            }
        } catch {}
        #endif

        // Fallback to standard paths
        #if os(macOS)
        debugLog("[LINKER-MAC] Primary path discovery failed, trying fallbacks...")

        // Check swift-actions/setup-swift location (GitHub Actions)
        // The action installs Swift at /Users/runner/hostedtoolcache/swift/...
        // Try to find via 'which swift' first (respects PATH)
        do {
            let whichProcess = Process()
            whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            whichProcess.arguments = ["swift"]

            let whichPipe = Pipe()
            whichProcess.standardOutput = whichPipe
            whichProcess.standardError = FileHandle.nullDevice

            try whichProcess.run()
            whichProcess.waitUntilExit()

            if whichProcess.terminationStatus == 0 {
                let data = whichPipe.fileHandleForReading.readDataToEndOfFile()
                if let swiftPath = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !swiftPath.isEmpty {
                    let swiftURL = URL(fileURLWithPath: swiftPath)
                    let baseDir = swiftURL
                        .deletingLastPathComponent()  // Remove 'swift'
                        .deletingLastPathComponent()  // Remove 'bin'

                    // Try both possible structures (standard toolchain and swiftly)
                    let pathsToTry = [
                        baseDir.appendingPathComponent("lib/swift/macosx").path,
                        baseDir.appendingPathComponent("usr/lib/swift/macosx").path
                    ]

                    debugLog("[LINKER-MAC] Fallback which swift: \(swiftPath)")
                    for path in pathsToTry {
                        debugLog("[LINKER-MAC] Fallback trying: \(path) exists=\(FileManager.default.fileExists(atPath: path))")
                        if FileManager.default.fileExists(atPath: path) {
                            return path
                        }
                    }
                }
            }
        } catch {}

        // Check swiftly toolchain location (~/.swiftly/toolchains/)
        // swiftly stores full toolchains here, unlike the temporary symlink directory
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let swiftlyToolchains = "\(homeDir)/.swiftly/toolchains"
        debugLog("[LINKER-MAC] Checking swiftly toolchains: \(swiftlyToolchains)")
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: swiftlyToolchains) {
            // Find Swift 6.x toolchain (prefer newest)
            let swift6Toolchains = contents.filter { $0.hasPrefix("swift-6.") }.sorted().reversed()
            for toolchain in swift6Toolchains {
                let libPath = "\(swiftlyToolchains)/\(toolchain)/usr/lib/swift/macosx"
                debugLog("[LINKER-MAC] Checking swiftly: \(libPath) exists=\(FileManager.default.fileExists(atPath: libPath))")
                if FileManager.default.fileExists(atPath: libPath) {
                    return libPath
                }
            }
        }

        // Check GitHub Actions hostedtoolcache (swift-actions/setup-swift)
        let toolcache = "/Users/runner/hostedtoolcache/swift"
        debugLog("[LINKER-MAC] Checking hostedtoolcache: \(toolcache)")
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: toolcache) {
            for version in versions.filter({ $0.hasPrefix("6.") }).sorted().reversed() {
                let versionPath = "\(toolcache)/\(version)"
                if let archs = try? FileManager.default.contentsOfDirectory(atPath: versionPath) {
                    for arch in archs {
                        let libPath = "\(versionPath)/\(arch)/usr/lib/swift/macosx"
                        debugLog("[LINKER-MAC] Checking toolcache: \(libPath) exists=\(FileManager.default.fileExists(atPath: libPath))")
                        if FileManager.default.fileExists(atPath: libPath) {
                            return libPath
                        }
                    }
                }
            }
        }

        // Check Xcode toolchain (WARNING: may be incompatible Swift version)
        let xcodeLib = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx"
        debugLog("[LINKER-MAC] Checking Xcode: \(xcodeLib) exists=\(FileManager.default.fileExists(atPath: xcodeLib))")
        if FileManager.default.fileExists(atPath: xcodeLib) {
            debugLog("[LINKER-MAC] WARNING: Using Xcode toolchain - may have ABI mismatch with Swift 6.2!")
            return xcodeLib
        }

        // Check usr/lib/swift
        let usrLib = "/usr/lib/swift"
        debugLog("[LINKER-MAC] Checking usrLib: \(usrLib) exists=\(FileManager.default.fileExists(atPath: usrLib))")
        if FileManager.default.fileExists(atPath: usrLib) {
            return usrLib
        }

        // Check Homebrew Swift installation
        let homebrewLib = "/opt/homebrew/opt/swift/lib/swift/macosx"
        debugLog("[LINKER-MAC] Checking Homebrew: \(homebrewLib) exists=\(FileManager.default.fileExists(atPath: homebrewLib))")
        if FileManager.default.fileExists(atPath: homebrewLib) {
            return homebrewLib
        }

        debugLog("[LINKER-MAC] WARNING: No Swift library path found!")
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

        FileHandle.standardError.write(Data("[LINKER] WARNING: Could not find Swift library path\n".utf8))
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

        FileHandle.standardError.write(Data("[LINKER-WIN] Looking for UCRT in Windows Kits...\n".utf8))

        // Find the latest SDK version
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: windowsKitsBase) {
            // Sort versions in descending order to get the latest
            let sortedVersions = versions.filter { $0.hasPrefix("10.") }.sorted().reversed()
            for version in sortedVersions {
                let ucrtPath = "\(windowsKitsBase)\\\(version)\\ucrt\\x64"
                if FileManager.default.fileExists(atPath: ucrtPath) {
                    FileHandle.standardError.write(Data("[LINKER-WIN] Found UCRT at: \(ucrtPath)\n".utf8))
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

        FileHandle.standardError.write(Data("[LINKER-WIN] UCRT not found in Windows Kits\n".utf8))
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

        FileHandle.standardError.write(Data("[LINKER-WIN] Looking for VC runtime...\n".utf8))

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
                                FileHandle.standardError.write(Data("[LINKER-WIN] Found VC runtime at: \(libPath)\n".utf8))
                                return libPath
                            }
                        }
                    }
                }
            }
        }

        FileHandle.standardError.write(Data("[LINKER-WIN] VC runtime not found\n".utf8))
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

        FileHandle.standardError.write(Data("[LINKER-WIN] Could not find swiftrt.obj\n".utf8))
        #endif
        return nil
    }

    /// Find Windows UM (user mode) library path for Windows API libraries
    /// Contains kernel32.lib, user32.lib, ws2_32.lib, etc.
    private func findWindowsUMPath() -> String? {
        #if os(Windows)
        let windowsKitsBase = "C:\\Program Files (x86)\\Windows Kits\\10\\Lib"

        FileHandle.standardError.write(Data("[LINKER-WIN] Looking for Windows UM libs...\n".utf8))

        if let versions = try? FileManager.default.contentsOfDirectory(atPath: windowsKitsBase) {
            let sortedVersions = versions.filter { $0.hasPrefix("10.") }.sorted().reversed()
            for version in sortedVersions {
                let umPath = "\(windowsKitsBase)\\\(version)\\um\\x64"
                if FileManager.default.fileExists(atPath: umPath) {
                    FileHandle.standardError.write(Data("[LINKER-WIN] Found Windows UM libs at: \(umPath)\n".utf8))
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

        FileHandle.standardError.write(Data("[LINKER-WIN] Windows UM libs not found\n".utf8))
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

        FileHandle.standardError.write(Data("[LINKER] Searched for swiftrt.o in: \(potentialPaths)\n".utf8))
        #endif

        return nil
    }

    private func runProcess(_ args: [String]) throws {
        guard !args.isEmpty else {
            throw LinkerError.compilationFailed("No command specified")
        }

        #if os(Linux)
        FileHandle.standardError.write(Data("[LINKER] runProcess() called with \(args.count) args\n".utf8))
        #endif

        // Debug: Print command being run (only in verbose mode)
        let command = args.joined(separator: " ")
        if verbose {
            print("Running: \(command)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        #if os(Linux)
        FileHandle.standardError.write(Data("[LINKER] Starting process...\n".utf8))
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
            FileHandle.standardError.write(Data("[LINKER] Process started, waiting for exit...\n".utf8))
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
            FileHandle.standardError.write(Data("[LINKER] Process exited with status: \(process.terminationStatus)\n".utf8))
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

// MARK: - Static Plugin Symbol Renaming

/// Handles symbol renaming for statically-linked plugins using llvm-objcopy.
///
/// Each plugin exports the same C ABI symbols (aro_plugin_info, aro_plugin_execute, etc.).
/// To avoid collisions when linking multiple plugins into one binary, we rename each plugin's
/// symbols with a unique prefix: `aro_static_<pluginName>__<originalSymbol>`.
public final class PluginSymbolRenamer {

    /// The 12 C ABI symbols that every ARO plugin may export
    public static let pluginSymbols = [
        "aro_plugin_info",
        "aro_plugin_execute",
        "aro_plugin_free",
        "aro_plugin_qualifier",
        "aro_plugin_init",
        "aro_plugin_shutdown",
        "aro_plugin_on_event",
        "aro_plugin_register",
        "aro_plugin_set_invoke",
        "aro_object_read",
        "aro_object_write",
        "aro_object_list",
    ]

    /// Compute the renamed symbol for a given plugin
    public static func renamedSymbol(plugin: String, original: String) -> String {
        "aro_static_\(plugin)__\(original)"
    }

    /// Enable verbose logging
    public let verbose: Bool

    public init(verbose: Bool = false) {
        self.verbose = verbose
    }

    /// Rename plugin symbols in object files so they can be statically linked without collision.
    ///
    /// - Parameters:
    ///   - objectFiles: Paths to .o files (or a single .a archive)
    ///   - pluginName: Unique plugin name used as the symbol prefix
    ///   - outputDir: Directory for renamed output files
    /// - Returns: Paths to the renamed object files
    public func renamePluginSymbols(
        objectFiles: [String],
        pluginName: String,
        outputDir: String
    ) throws -> [String] {
        let objcopyPath = try findLLVMObjcopy()

        var renamedFiles: [String] = []
        for (index, inputFile) in objectFiles.enumerated() {
            let baseName = URL(fileURLWithPath: inputFile).lastPathComponent
            let outputFile = "\(outputDir)/\(pluginName)_\(index)_\(baseName)"

            // Build --redefine-sym arguments for all 12 plugin symbols.
            // On macOS (Mach-O), symbols have a leading underscore.
            var args = [objcopyPath]
            for sym in Self.pluginSymbols {
                let renamed = Self.renamedSymbol(plugin: pluginName, original: sym)
                #if os(macOS)
                args.append("--redefine-sym")
                args.append("_\(sym)=_\(renamed)")
                #endif
                // ELF (Linux) has no leading underscore; also add the plain form
                // on macOS as a no-op safety net (llvm-objcopy ignores missing symbols)
                args.append("--redefine-sym")
                args.append("\(sym)=\(renamed)")
            }
            args.append(inputFile)
            args.append(outputFile)

            try runProcess(args)
            renamedFiles.append(outputFile)
        }

        return renamedFiles
    }

    /// Discover which of the 12 standard plugin symbols actually exist in the given object files.
    ///
    /// - Parameters:
    ///   - objectFiles: Renamed .o files (symbols already have the `aro_static_<name>__` prefix)
    ///   - pluginName: The plugin name used in the prefix
    /// - Returns: Set of original symbol names that exist (e.g., ["aro_plugin_info", "aro_plugin_execute"])
    public func discoverSymbols(in objectFiles: [String], pluginName: String) throws -> Set<String> {
        var found: Set<String> = []

        for file in objectFiles {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/nm")
            #if os(macOS)
            process.arguments = ["-gU", file]  // global, defined-only (macOS)
            #else
            process.arguments = ["-g", "--defined-only", file]  // global, defined-only (Linux)
            #endif

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { continue }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { continue }

            for sym in Self.pluginSymbols {
                let renamed = Self.renamedSymbol(plugin: pluginName, original: sym)
                // nm output format: "address T symbolName" (macOS prepends _)
                #if os(macOS)
                if output.contains("_\(renamed)") {
                    found.insert(sym)
                }
                #else
                if output.contains(renamed) {
                    found.insert(sym)
                }
                #endif
            }
        }

        return found
    }

    /// Extract .o files from a static archive (.a)
    public func extractObjectFiles(from archivePath: String, to outputDir: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ar")
        process.arguments = ["x", archivePath]
        process.currentDirectoryURL = URL(fileURLWithPath: outputDir)

        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw LinkerError.compilationFailed("ar x failed: \(msg)")
        }

        // List extracted .o files
        let contents = try FileManager.default.contentsOfDirectory(atPath: outputDir)
        return contents
            .filter { $0.hasSuffix(".o") }
            .map { "\(outputDir)/\($0)" }
    }

    // MARK: - Private

    private func findLLVMObjcopy() throws -> String {
        let paths = [
            "/opt/homebrew/opt/llvm/bin/llvm-objcopy",
            "/opt/homebrew/opt/llvm@20/bin/llvm-objcopy",  // Homebrew versioned
            "/usr/local/opt/llvm/bin/llvm-objcopy",
            "/usr/bin/llvm-objcopy",
            "/usr/local/bin/llvm-objcopy",
            "/usr/bin/llvm-objcopy-20",  // Docker CI (LLVM 20)
            "/usr/bin/llvm-objcopy-14",  // Ubuntu 24.04
        ]

        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // Try PATH
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["llvm-objcopy"]

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
        throw LinkerError.compilationFailed("llvm-objcopy not found. Please install LLVM: brew install llvm")
        #else
        throw LinkerError.compilationFailed("llvm-objcopy not found. Please install LLVM: apt-get install llvm-14")
        #endif
    }

    private func runProcess(_ args: [String]) throws {
        guard !args.isEmpty else {
            throw LinkerError.compilationFailed("No command specified")
        }

        if verbose {
            print("Running: \(args.joined(separator: " "))")
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
            throw LinkerError.compilationFailed("Failed to run llvm-objcopy: \(error)")
        }

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw LinkerError.compilationFailed("llvm-objcopy failed: \(errorMessage)")
        }
    }
}

// MARK: - Python Library Discovery

/// Finds the Python library and include paths for linking.
public final class PythonLibraryFinder {

    public let verbose: Bool

    public init(verbose: Bool = false) {
        self.verbose = verbose
    }

    /// Result of finding Python on the build machine
    public struct PythonPaths {
        /// Path to libpython (dylib or framework)
        public let libraryPath: String
        /// Linker flags (e.g., "-lpython3.12")
        public let linkerFlags: [String]
        /// Path to Python stdlib directory
        public let stdlibPath: String
        /// Python version string (e.g., "3.12")
        public let version: String
        /// Path to python3 executable
        public let executable: String
    }

    /// Find Python installation on the build machine.
    /// Uses python3-config to discover paths.
    public func findPython() -> PythonPaths? {
        // Find python3 executable
        guard let python3 = findPython3() else { return nil }

        // Get version
        guard let version = runPython(python3, code: "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')") else { return nil }

        // Get prefix
        guard let prefix = runPython(python3, code: "import sys; print(sys.prefix)") else { return nil }

        // Get linker flags via python3-config
        let ldflags = runCommand(python3 + "-config", args: ["--ldflags", "--embed"])
            ?? runCommand(python3 + "-config", args: ["--ldflags"])

        // Determine library path and linker flags
        var linkerFlags: [String] = []
        var libraryPath = ""

        #if os(macOS)
        // On macOS, use the framework
        let frameworkBinary = "\(prefix)/Python"
        if FileManager.default.fileExists(atPath: frameworkBinary) {
            libraryPath = frameworkBinary
            linkerFlags = [frameworkBinary]
        } else if let flags = ldflags {
            linkerFlags = flags.split(separator: " ").map(String.init)
            libraryPath = "\(prefix)/lib/libpython\(version).dylib"
        }
        #else
        // On Linux, use the shared library
        let libDir = "\(prefix)/lib"
        let soPath = "\(libDir)/libpython\(version).so"
        let aPath = "\(libDir)/python\(version)/config-\(version)-\(machineArch())-linux-gnu/libpython\(version).a"

        if FileManager.default.fileExists(atPath: aPath) {
            // Prefer static library on Linux
            libraryPath = aPath
            linkerFlags = [aPath, "-ldl", "-lm", "-lutil", "-lpthread"]
        } else if FileManager.default.fileExists(atPath: soPath) {
            libraryPath = soPath
            linkerFlags = ["-L\(libDir)", "-lpython\(version)"]
        } else if let flags = ldflags {
            linkerFlags = flags.split(separator: " ").map(String.init)
            libraryPath = soPath
        }
        #endif

        // Find stdlib
        let stdlibPath = "\(prefix)/lib/python\(version)"

        guard !linkerFlags.isEmpty else {
            if verbose { print("[PythonFinder] Could not determine linker flags for Python") }
            return nil
        }

        if verbose {
            print("[PythonFinder] Python \(version) at \(python3)")
            print("[PythonFinder] Library: \(libraryPath)")
            print("[PythonFinder] Stdlib: \(stdlibPath)")
        }

        return PythonPaths(
            libraryPath: libraryPath,
            linkerFlags: linkerFlags,
            stdlibPath: stdlibPath,
            version: version,
            executable: python3
        )
    }

    // MARK: - Private

    private func findPython3() -> String? {
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Try PATH
        if let path = runCommand("/usr/bin/which", args: ["python3"]) {
            return path
        }

        return nil
    }

    private func runPython(_ python: String, code: String) -> String? {
        return runCommand(python, args: ["-c", code])
    }

    private func runCommand(_ executable: String, args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private func machineArch() -> String {
        #if arch(x86_64)
        return "x86_64"
        #elseif arch(arm64)
        return "aarch64"
        #else
        return "x86_64"
        #endif
    }
}

/// Metadata about a plugin prepared for static linking
public struct StaticPluginInfo {
    /// Plugin name (matches directory name)
    public let name: String
    /// Content of plugin.yaml
    public let yaml: String
    /// Paths to renamed .o files ready for linking
    public let objectFiles: [String]
    /// Which of the 12 standard ABI symbols this plugin actually exports
    public let availableSymbols: Set<String>

    public init(name: String, yaml: String, objectFiles: [String], availableSymbols: Set<String>) {
        self.name = name
        self.yaml = yaml
        self.objectFiles = objectFiles
        self.availableSymbols = availableSymbols
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
