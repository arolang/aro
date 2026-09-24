// ============================================================
// CompilationStrategy.swift
// ARO CLI - Native binary compilation pipeline
// ============================================================
//
// Extracted from BuildCommand (#354): the native-compilation pipeline used to
// live inline in `BuildCommand.run()`. Pulling it into a dedicated strategy
// keeps the command a thin coordinator and isolates the LLVM/link/sign steps.
//
// Behaviour is intentionally identical to the previous inline version: every
// verbose string, log call, warning, and error/exit path is preserved verbatim.
//
// The whole file is `#if !os(Windows)` because it depends on `AROCompiler`
// (LLVM) types that are unavailable on Windows. On Windows, `BuildCommand`
// prints the "not yet supported" message and exits before reaching here.

#if !os(Windows)

import ArgumentParser
import Foundation
import AROParser
import ARORuntime
import AROCompiler

/// Owns the native binary pipeline for `aro build`: LLVM IR generation → write
/// IR → emit object file → find runtime lib → link → post-strip → bundle Swift
/// `.so` (Linux) → codesign (macOS) → cleanup intermediates.
struct CompilationStrategy: Sendable {

    /// Everything the native pipeline needs, gathered by `BuildCommand` before
    /// the strategy runs.
    struct Request {
        /// The merged, analyzed program to compile.
        var mergedProgram: AnalyzedProgram
        /// Final executable path.
        var binaryPath: URL
        /// Intermediate LLVM IR (.ll) path.
        var llPath: URL
        /// Intermediate object (.o) path.
        var objectPath: String
        /// Application `.build` directory (for intermediate-kept messaging).
        var buildDir: URL
        /// Serialized OpenAPI spec to embed, if present.
        var openAPISpecJSON: String?
        /// Serialized templates to embed, if present.
        var templatesJSON: String?

        // Issue #231 — DWARF source-mapping provenance.
        /// Absolute app source directory, used as `DW_AT_comp_dir`.
        var sourceDirectory: String
        /// Feature-set name → origin `.aro` basename (for per-function DIFile).
        var sourceFileMap: [String: String]
        /// Basename of the file holding `Application-Start`; CU filename +
        /// fallback for feature sets missing from `sourceFileMap`.
        var entryFilename: String

        // Plugin pre-compilation results (from PluginCompiler).
        var embeddedPlugins: [(name: String, yaml: String, base64Library: String)]
        var staticPluginInfos: [StaticPluginInfo]
        var staticPluginIRInfos: [StaticPluginIRInfo]
        var pythonPluginIRInfos: [EmbeddedPythonPluginIRInfo]
        var pythonLinkerFlags: [String]

        // Resolved flags.
        var optimize: Bool
        var size: Bool
        var strip: Bool
        var release: Bool
        /// How the Swift runtime is bound to the binary. Resolved once by
        /// `BuildCommand` (GitLab #815) so the plugin pre-compile stage and
        /// this pipeline cannot disagree about which build they are in.
        var linkMode: CCompiler.LinkMode
        var verbose: Bool
        var keepIntermediate: Bool
        var emitLLVM: Bool

        #if os(macOS)
        var sign: String? = nil
        var hardenedRuntime: Bool = false
        #endif
    }

    /// Result of running the pipeline.
    enum Outcome {
        /// A native binary was produced.
        case built
        /// `--emit-llvm` was requested; only the `.ll` text was written.
        case emittedLLVMOnly
    }

    /// Resolve `--static` / `--dynamic` into the single link mode the whole
    /// build runs under.
    ///
    /// It lives here, and is called once from `BuildCommand` before anything
    /// else happens, because the choice used to be read *inside* `execute()` —
    /// long after managed plugins had already been baked for a static link. A
    /// `--dynamic` build therefore reported a static-linking failure it could
    /// never have hit (GitLab #815). One read, one value, passed to everything
    /// that acts on it.
    ///
    /// `--dynamic` wins when both are given: it was asked for explicitly, while
    /// `--static` is also the default.
    static func resolveLinkMode(staticLink: Bool, dynamicLink: Bool) throws -> CCompiler.LinkMode {
        if staticLink && dynamicLink {
            print("Error: --static and --dynamic are mutually exclusive.")
            throw ExitCode.failure
        }
        return dynamicLink ? .dynamicLink : .staticLink
    }

    /// Run the native compilation pipeline.
    ///
    /// - Throws: `ExitCode.failure` on any hard failure (code generation, IR
    ///   write, object emission, missing runtime, or linking) — matching the
    ///   previous inline behaviour.
    func execute(_ request: Request) throws -> Outcome {
        let llvmResult: LLVMCodeGenerationResult

        do {
            let codeGenerator = LLVMCodeGenerator()
            llvmResult = try codeGenerator.generate(
                program: request.mergedProgram,
                openAPISpecJSON: request.openAPISpecJSON,
                templatesJSON: request.templatesJSON,
                embeddedPlugins: request.embeddedPlugins.isEmpty ? nil : request.embeddedPlugins,
                staticPlugins: request.staticPluginIRInfos.isEmpty ? nil : request.staticPluginIRInfos,
                pythonPlugins: request.pythonPluginIRInfos.isEmpty ? nil : request.pythonPluginIRInfos,
                linkMode: request.linkMode.recordedName,
                sourceFilename: request.entryFilename,
                sourceDirectory: request.sourceDirectory,
                sourceFileMap: request.sourceFileMap
            )
            AROLogger.debug("LLVM IR generated successfully", subsystem: "build")
        } catch {
            AROLogger.error("LLVM generation failed: \(error)", subsystem: "build")
            print("Code generation error: \(error)")
            throw ExitCode.failure
        }

        if request.verbose {
            print("  LLVM module generated")
        }

        // Write LLVM IR text if requested
        if request.emitLLVM {
            do {
                try llvmResult.irText.write(toFile: request.llPath.path, atomically: true, encoding: .utf8)
                print("LLVM IR written to: \(request.llPath.path)")
            } catch {
                print("Error writing LLVM IR: \(error)")
                throw ExitCode.failure
            }
            return .emittedLLVMOnly
        }

        // Write LLVM IR to file for llc
        do {
            try llvmResult.irText.write(toFile: request.llPath.path, atomically: true, encoding: .utf8)
            if request.verbose {
                print("  LLVM IR written: \(request.llPath.lastPathComponent)")
            }
        } catch {
            print("Error writing LLVM IR: \(error)")
            throw ExitCode.failure
        }

        // Compile LLVM IR to object file using llc
        if request.verbose {
            print("Emitting object file...")
        }

        // Release mode enables all optimizations
        let effectiveOptimize = request.optimize || request.release
        let effectiveSize = request.size || request.release
        let effectiveStrip = request.strip || request.release

        let emitter = LLVMEmitter()
        // llc only supports O0-O3, use O2 for both speed and size optimization
        // (size optimization is applied during linking stage with -Os)
        let optLevel: LLVMEmitter.OptimizationLevel = (effectiveOptimize || effectiveSize) ? .o2 : .none

        do {
            try emitter.emitObject(irPath: request.llPath.path, to: request.objectPath, optimize: optLevel)
            if request.verbose {
                print("  Object file created")
            }
        } catch {
            print("LLVM emission error: \(error)")
            print("LLVM IR at: \(request.llPath.path) for debugging")
            throw ExitCode.failure
        }

        // Find the ARORuntime library (contains C-callable bridge via @_cdecl)
        guard let runtimeLibPath = findARORuntimeLibrary() else {
            AROLogger.error("Runtime library not found", subsystem: "build")
            print("Error: ARORuntime library not found.")
            throw ExitCode.failure
        }

        AROLogger.debug("Runtime library found: \(runtimeLibPath)", subsystem: "build")

        if request.verbose {
            print("Using runtime: \(runtimeLibPath)")
        }

        // Link to final executable
        if request.verbose {
            print("Linking executable...")
            // Show Swift library path for debugging
            let linkerTest = CCompiler(runtimeLibraryPath: runtimeLibPath, verbose: request.verbose)
            if let swiftPath = linkerTest.getSwiftLibPath() {
                print("  Swift libraries: \(swiftPath)")
            } else {
                print("  Warning: Swift library path not found")
            }
        }

        AROLogger.debug("Starting linker", subsystem: "build")
        AROLogger.debug("Object file: \(request.objectPath)", subsystem: "build")
        AROLogger.debug("Output path: \(request.binaryPath.path)", subsystem: "build")

        AROLogger.debug("Creating CCompiler with runtime: \(runtimeLibPath)", subsystem: "build")

        let linker = CCompiler(runtimeLibraryPath: runtimeLibPath, verbose: request.verbose)

        AROLogger.debug("CCompiler created", subsystem: "build")

        let effectiveLinkMode = request.linkMode

        let linkOptions = CCompiler.LinkOptions(
            optimize: effectiveOptimize,
            optimizeForSize: effectiveSize,
            strip: effectiveStrip,
            deadStrip: effectiveStrip || effectiveSize,  // Enable dead stripping when stripping or optimizing for size
            linkMode: effectiveLinkMode
        )

        AROLogger.debug("LinkOptions created", subsystem: "build")
        AROLogger.debug("About to call linker.link() with objectFiles: [\(request.objectPath)], outputPath: \(request.binaryPath.path)", subsystem: "build")

        do {
            AROLogger.debug("Calling linker.link()...", subsystem: "build")

            // Collect all object files: main program + statically-linked plugins + Python lib
            var allObjectFiles = [request.objectPath]
            for pluginInfo in request.staticPluginInfos {
                allObjectFiles.append(contentsOf: pluginInfo.objectFiles)
            }
            // Add Python library if Python plugins are embedded
            allObjectFiles.append(contentsOf: request.pythonLinkerFlags)

            try linker.link(
                objectFiles: allObjectFiles,
                outputPath: request.binaryPath.path,
                outputType: .executable,
                options: linkOptions
            )

            AROLogger.debug("Linking completed", subsystem: "build")

            if request.verbose {
                print("  Executable created")
            }
        } catch {
            AROLogger.error("Linking failed: \(error)", subsystem: "build")
            print("Linking error: \(error)")
            throw ExitCode.failure
        }

        // Post-build strip for maximum size reduction
        if effectiveStrip {
            if request.verbose {
                print("Stripping symbols...")
            }
            try? runStripCommand(on: request.binaryPath.path)
        }

        // Bundle Swift runtime .so files next to the binary when --dynamic
        // (Linux only). The binary already has rpath=$ORIGIN, so the loader
        // picks them up at runtime — no system Swift install needed.
        #if os(Linux)
        if effectiveLinkMode == .dynamicLink {
            let bundleDir = request.binaryPath.deletingLastPathComponent()
            if request.verbose {
                print("Bundling Swift runtime libraries into \(bundleDir.path)...")
            }
            let copied = bundleSwiftRuntimeSOs(into: bundleDir, verbose: request.verbose)
            if request.verbose {
                print("  \(copied) Swift/Foundation .so files copied")
            }
        }
        #endif

        // Code signing (macOS only)
        #if os(macOS)
        if let signIdentity = request.sign {
            if request.verbose {
                print("Signing binary with identity: \(signIdentity)...")
            }
            do {
                try runCodesignCommand(on: request.binaryPath.path, identity: signIdentity, hardened: request.hardenedRuntime)
                if request.verbose {
                    print("  Binary signed successfully")
                }
            } catch {
                print("Warning: Code signing failed: \(error)")
            }
        }
        #endif

        // Cleanup intermediate files
        if !request.keepIntermediate {
            try? FileManager.default.removeItem(at: request.llPath)
            try? FileManager.default.removeItem(atPath: request.objectPath)
        } else if request.verbose {
            print("  Intermediate files kept at: \(request.buildDir.path)")
        }

        return .built
    }

    // MARK: - Runtime library lookup

    private func findARORuntimeLibrary() -> String? {
        let fm = FileManager.default

        // Environment variable override: ARO_LIB_PATH points directly to the library file
        if let envPath = ProcessInfo.processInfo.environment["ARO_LIB_PATH"],
           !envPath.isEmpty,
           fm.fileExists(atPath: envPath) {
            return envPath
        }

        // Get the path to the aro executable itself
        let executablePath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let executableDir = executablePath.deletingLastPathComponent()

        // Build search paths array programmatically
        var searchPaths: [String] = []

        // Platform-specific library names to search for
        // Swift uses .a for static libs on all platforms, but we also check .lib for Windows
        let runtimeLibNames = ["libARORuntime.a"]

        // 0. Check ARO_BIN environment variable directory (used in CI)
        if let aroBinPath = ProcessInfo.processInfo.environment["ARO_BIN"] {
            let aroBinDir = URL(fileURLWithPath: aroBinPath).deletingLastPathComponent()
            for libName in runtimeLibNames {
                searchPaths.append(aroBinDir.appendingPathComponent(libName).path)
            }
        }

        // 1. Same directory as executable (for distributed binaries/artifacts)
        // This is the primary location for CI/CD artifacts
        for libName in runtimeLibNames {
            searchPaths.append(executableDir.appendingPathComponent(libName).path)
        }

        // 2. Sibling lib/ directory relative to executable (standard Unix layout)
        // e.g., /usr/local/bin/aro → /usr/local/lib/libARORuntime.a
        let siblingLibDir = executableDir.deletingLastPathComponent().appendingPathComponent("lib")
        for libName in runtimeLibNames {
            searchPaths.append(siblingLibDir.appendingPathComponent(libName).path)
        }

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
        #endif


        for path in searchPaths {
            var fullPath: String
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

    // MARK: - Post-link tooling

    #if os(macOS)
    private func runCodesignCommand(on binaryPath: String, identity: String, hardened: Bool) throws {
        guard let codesignPath = ToolResolver.findTool("codesign", fallbackPaths: ["/usr/bin/codesign"]) else {
            throw CodesignError.failed(status: -1)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: codesignPath)
        var args = ["--sign", identity, "--force"]
        if hardened {
            args += ["--options", "runtime"]
        }
        args.append(binaryPath)
        process.arguments = args
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw CodesignError.failed(status: process.terminationStatus)
        }
    }

    private enum CodesignError: Error, CustomStringConvertible {
        case failed(status: Int32)
        var description: String { "codesign exited with status \(status)" }
        var status: Int32 {
            switch self { case .failed(let s): return s }
        }
    }
    #endif

    #if os(Linux)
    /// Copy the Swift / Foundation `.so` files required by the linked binary
    /// into `destination`. Returns the number of files actually copied.
    ///
    /// Used by `--dynamic` mode so the produced binary plus the `.so`s next to
    /// it form a self-contained deployment unit — no system Swift install
    /// needed on the target.
    private func bundleSwiftRuntimeSOs(into destination: URL, verbose: Bool) -> Int {
        // The same list the linker pulled in. Suffix .so.5 / .so.6 etc. is
        // resolved by also copying the unversioned symlink target.
        let names = [
            "libswiftCore",
            "libswift_Concurrency",
            "libswiftGlibc",
            "libswiftDispatch",
            "libBlocksRuntime",
            "libswift_StringProcessing",
            "libswift_RegexParser",
            "libswiftSwiftOnoneSupport",
            "libFoundation",
            "libFoundationEssentials",
            "libFoundationNetworking",
            "libdispatch",
            "libicudataswift",
            "libicui18nswift",
            "libicuucswift",
        ]
        guard let swiftLibPath = findSwiftLibPath() else {
            FileHandle.standardError.write(Data("[bundle] swift lib path not found; skipping\n".utf8))
            return 0
        }
        let fm = FileManager.default
        var copied = 0
        let dirContents = (try? fm.contentsOfDirectory(atPath: swiftLibPath)) ?? []
        for name in names {
            // Match libfoo.so, libfoo.so.X, libfoo.so.X.Y to handle versioned
            // SONAMEs the runtime loader expects.
            let candidates = dirContents.filter { $0.hasPrefix("\(name).so") }
            for entry in candidates {
                let src = URL(fileURLWithPath: swiftLibPath).appendingPathComponent(entry)
                let dst = destination.appendingPathComponent(entry)
                try? fm.removeItem(at: dst)
                do {
                    // Resolve symlinks so the destination has the actual file,
                    // not a dangling link into /usr/share/swift.
                    let resolved = src.resolvingSymlinksInPath()
                    try fm.copyItem(at: resolved, to: dst)
                    copied += 1
                    if verbose {
                        print("    \(entry)")
                    }
                } catch {
                    if verbose {
                        print("    (skip) \(entry): \(error.localizedDescription)")
                    }
                }
            }
        }
        return copied
    }

    /// Locate the Swift dynamic library directory the same way the linker does.
    private func findSwiftLibPath() -> String? {
        if let envPath = ProcessInfo.processInfo.environment["SWIFT_LIB_PATH"],
           FileManager.default.fileExists(atPath: envPath) {
            return envPath
        }
        let candidates = [
            "/usr/share/swift/usr/lib/swift/linux",
            "/usr/lib/swift/linux",
            "/usr/local/lib/swift/linux",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }
    #endif

    private func runStripCommand(on binaryPath: String) throws {
        guard let stripPath = ToolResolver.findTool("strip", fallbackPaths: ["/usr/bin/strip"]) else {
            return  // strip is optional — skip silently if not found
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: stripPath)
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

#endif  // !os(Windows)
