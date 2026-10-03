// ============================================================
// TestCommand.swift
// ARO CLI - Test Command
// ============================================================

import ArgumentParser
import Foundation
import AROParser
import ARORuntime
import AROVersion

struct TestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test",
        abstract: "Run tests in an ARO application"
    )

    @Argument(help: "Path to the application directory")
    var path: String

    @Flag(name: .shortAndLong, help: "Enable verbose output")
    var verbose: Bool = false

    @Option(name: .long, help: "Run only tests matching this pattern")
    var filter: String?

    @Flag(name: .long, help: "Disable colored output")
    var noColor: Bool = false

    @Option(name: .long, help: "JSONL file to record statement events to (SOLARO uses this for the live canvas pulse during a test run).")
    var record: String?

    @Flag(name: .long, help: "Compile the application to a native test-harness binary and run the tests through it, instead of the interpreter (ARO-0015 §3.4).")
    var compiled: Bool = false

    func run() async throws {
        let resolvedPath = URL(fileURLWithPath: path)

        // `aro test` ran the interpreter and nothing else, so a green test run
        // said nothing about the binary a user ships — which is why every
        // compiled-mode divergence in GitLab #838 went unnoticed. `--compiled`
        // builds a test-harness binary and runs the same test feature sets
        // through compiled code (GitLab #694). The interpreter stays the
        // default: it is faster, and it is what a tight edit/test loop wants.
        if compiled {
            try await runCompiled(at: resolvedPath)
            return
        }

        if verbose {
            print("ARO Test Runner v\(AROVersion.shortVersion)")
            print("Build: \(AROVersion.buildDate)")
            print("=======================")
            print("Path: \(resolvedPath.path)")
            if let filter = filter {
                print("Filter: \(filter)")
            }
            print()
        }

        // Discover application with import resolution (#361 — shared helper).
        // Use a dummy entry point since we're running tests, not the app.
        let appConfig = try await ApplicationResolver.resolve(
            at: resolvedPath,
            entryPoint: "Application-Start",
            errorPrefix: "Error discovering application"
        )

        if verbose {
            print("Discovered application:")
            print("  Root: \(appConfig.rootPath.path)")
            print("  Source files: \(appConfig.sourceFiles.count)")
            for file in appConfig.sourceFiles {
                print("    - \(file.lastPathComponent)")
            }
            print()
        }

        // Compile all source files
        let compiler = Compiler()
        var allDiagnostics: [Diagnostic] = []
        var compiledPrograms: [AnalyzedProgram] = []

        // Cross-file `Application.<Name>` resolution (#587): a test feature set
        // may call an action declared in any other file of the application.
        let declaredActions = UserActionRegistry.declared(inFiles: appConfig.sourceFiles)

        for sourceFile in appConfig.sourceFiles {
            if verbose {
                print("Compiling: \(sourceFile.lastPathComponent)")
            }

            let source: String
            do {
                source = try String(contentsOf: sourceFile, encoding: .utf8)
            } catch {
                print("Error reading \(sourceFile.lastPathComponent): \(error)")
                throw ExitCode.failure
            }

            let result = compiler.compile(source, declaredUserActions: declaredActions)
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

        // Load plugins so plugin-provided actions and qualifiers are available in tests
        do {
            try UnifiedPluginLoader.shared.loadPlugins(from: appConfig.rootPath)
        } catch {
            if verbose {
                print("Warning: Failed to load plugins: \(error)")
            }
        }

        // Collect all feature sets
        let allFeatureSets = compiledPrograms.flatMap { $0.featureSets }

        // Filter test feature sets
        let testFeatureSets = TestRunner.filterTests(allFeatureSets)

        if verbose {
            print("\nFound \(testFeatureSets.count) test(s):")
            for fs in testFeatureSets {
                print("  - \(fs.featureSet.name)")
            }
            print()
        }

        if testFeatureSets.isEmpty {
            print("No tests found.")
            print("Tests are feature sets with business activity ending in 'Test' or 'Tests'.")
            print("Example: (Add Numbers: Calculator Test) { ... }")
            throw ExitCode.failure
        }

        // If --record was set, install a DebugController +
        // JSONL recorder so each statement boundary lands in the
        // file as a `pause` event. SOLARO tails the same JSONL
        // and uses the records to flash the canvas while a test
        // is running — same wiring as `aro run --record`.
        let debugController: DebugController?
        if let recordPath = record {
            let recorder = try DebugEventLogWriter(path: recordPath)
            let frontend = HeadlessTestFrontend()
            let controller = DebugController(frontend: frontend)
            await controller.setRecorder(recorder)
            debugController = controller
        } else {
            debugController = nil
        }

        // Run tests
        let runner = TestRunner(verbose: verbose)
        let results: TestSuiteResult
        if let debugController {
            results = await Debug.$controller.withValue(debugController) {
                await runner.run(
                    tests: testFeatureSets,
                    allFeatureSets: allFeatureSets,
                    filter: filter
                )
            }
            await debugController.didEnd(error: nil)
        } else {
            results = await runner.run(
                tests: testFeatureSets,
                allFeatureSets: allFeatureSets,
                filter: filter
            )
        }

        // Report results
        let reporter = TestReporter(verbose: verbose, useColors: !noColor)
        reporter.report(results)

        // Exit with failure if any tests failed
        if results.hasFailures {
            throw ExitCode.failure
        }
    }
}

// MARK: - Compiled mode (GitLab #694)

extension TestCommand {
    /// Build a test-harness binary for this application and run it.
    ///
    /// The build is delegated to `aro build --tests` rather than reimplemented:
    /// discovery, diagnostics, plugin baking, link-mode resolution and the LLVM
    /// pipeline must be the *same* ones that produce a shipped binary, or the
    /// tests would be asserting against a build nobody runs.
    fileprivate func runCompiled(at resolvedPath: URL) async throws {
        #if os(Windows)
        print("Error: `aro test --compiled` needs `aro build`, which is not yet supported on Windows.")
        print("Run `aro test \(path)` to test through the interpreter instead.")
        throw ExitCode.failure
        #else
        if record != nil {
            // Say so rather than accepting it silently. The JSONL trace comes
            // from the interpreter's per-statement checkpoints; a compiled
            // binary has none (ARO-0015 §5.5).
            print("Note: --record is interpreter-only and is ignored with --compiled.")
        }

        // `aro test` accepts a directory or a single `.aro` file, as `aro run`
        // does; the harness goes beside the application's other build
        // intermediates either way. The name is distinct from the application
        // binary's so `aro build` and `aro test --compiled` in one directory do
        // not overwrite each other.
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: resolvedPath.path, isDirectory: &isDirectory)
        let appRoot = (exists && isDirectory.boolValue)
            ? resolvedPath.standardizedFileURL
            : resolvedPath.standardizedFileURL.deletingLastPathComponent()

        let binary = appRoot
            .appendingPathComponent(".build/aro-test")
            .appendingPathComponent(appRoot.lastPathComponent + "-test")
            .standardizedFileURL

        var buildArguments = [resolvedPath.path, "--tests", "--output", binary.path]
        if verbose { buildArguments.append("--verbose") }

        let build = try BuildCommand.parse(buildArguments)
        try await build.run()

        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            print("Error: the test harness was not built at \(binary.path)")
            throw ExitCode.failure
        }

        // The harness binary is built once and can be run many times, so the
        // run-time choices travel in the environment rather than being baked in.
        var environment = ProcessInfo.processInfo.environment
        if let filter { environment["ARO_TEST_FILTER"] = filter }
        if noColor { environment["ARO_TEST_NO_COLOR"] = "1" }
        if verbose { environment["ARO_TEST_VERBOSE"] = "1" }

        // The build's own output is buffered in this process while the child
        // writes straight to the terminal, so without this the build log lands
        // after the test report.
        fflush(stdout)

        let process = Process()
        process.executableURL = binary
        process.environment = environment
        // Run from the application directory so a test reading a relative path
        // sees what it sees interpreted.
        process.currentDirectoryURL = appRoot
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw ExitCode(process.terminationStatus)
        }
        #endif
    }
}

/// Minimal `DebugFrontend` used when `--record` is set: keeps
/// stepping past every checkpoint so the recorder sees every
/// statement, but never blocks the test run waiting for user
/// input. The records themselves are what SOLARO consumes —
/// nothing observes `didPause` here.
private final class HeadlessTestFrontend: DebugFrontend, @unchecked Sendable {
    func didPause(_ pause: PauseInfo, controller: DebugController) async -> StepMode {
        .stepOver
    }
    func didEnd(error: Error?) async {}
}
