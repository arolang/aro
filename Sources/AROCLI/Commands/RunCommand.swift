// ============================================================
// RunCommand.swift
// ARO CLI - Run Command
// ============================================================

import ArgumentParser
import Foundation
import AROParser
import ARORuntime
import AROVersion

struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run an ARO application"
    )

    @Argument(help: "Path to the application directory or .aro file")
    var path: String

    @Argument(parsing: .captureForPassthrough, help: "Arguments to pass to the application")
    var applicationArguments: [String] = []

    @Option(name: .shortAndLong, help: "Override the entry point feature set")
    var entryPoint: String = "Application-Start"

    @Flag(name: .shortAndLong, help: "Enable verbose logging")
    var verbose: Bool = false

    @Flag(name: .long, help: "Keep the application running (for servers)")
    var keepAlive: Bool = false

    @Flag(name: .long, help: "Enable developer/debug output formatting")
    var debug: Bool = false

    @Option(name: .long, help: "Record events to JSON file")
    var record: String?

    @Option(name: .long, help: "Replay events from JSON file")
    var replay: String?

    /// SOLARO and other live debuggers use this to capture a JSONL
    /// stream of per-statement pause records, without disturbing the
    /// pre-existing `--record` event-recording path (which writes a
    /// single pretty-printed `EventRecording` JSON object the
    /// `--replay` flag consumes). Kept separate so EventReplay tests
    /// keep their original wire format.
    @Option(name: .long, help: "Stream per-statement debug JSONL to file (SOLARO live view)")
    var debugRecord: String?

    /// Extract run command flags from captured application arguments
    /// This handles cases where flags are placed after the path argument
    mutating func extractRunCommandFlags() {
        var remainingArgs: [String] = []
        var i = 0

        while i < applicationArguments.count {
            let arg = applicationArguments[i]

            switch arg {
            case "--debug":
                debug = true
                i += 1
            case "--verbose", "-v":
                verbose = true
                i += 1
            case "--keep-alive":
                keepAlive = true
                i += 1
            case "--entry-point", "-e":
                // Check if there's a value following
                if i + 1 < applicationArguments.count {
                    entryPoint = applicationArguments[i + 1]
                    i += 2
                } else {
                    // Invalid usage, but pass it through to avoid silent failure
                    remainingArgs.append(arg)
                    i += 1
                }
            case "--record":
                // Check if there's a value following
                if i + 1 < applicationArguments.count {
                    record = applicationArguments[i + 1]
                    i += 2
                } else {
                    remainingArgs.append(arg)
                    i += 1
                }
            case "--replay":
                // Check if there's a value following
                if i + 1 < applicationArguments.count {
                    replay = applicationArguments[i + 1]
                    i += 2
                } else {
                    remainingArgs.append(arg)
                    i += 1
                }
            case "--debug-record":
                if i + 1 < applicationArguments.count {
                    debugRecord = applicationArguments[i + 1]
                    i += 2
                } else {
                    remainingArgs.append(arg)
                    i += 1
                }
            default:
                // Not a run command flag, keep it for the application
                remainingArgs.append(arg)
                i += 1
            }
        }

        applicationArguments = remainingArgs
    }

    func run() async throws {
        // Force unbuffered stdout so every print() reaches the pipe immediately.
        // Without this, Swift fully-buffers stdout when piped (e.g. during tests),
        // causing observer/event output to be lost until the process exits.
        // On Linux, stdout is a mutable C global (not a macro) which Swift 6's concurrency
        // checker flags as unsafe. FileHandle.standardOutput.write() bypasses C stdio
        // buffering on Linux anyway, so we only need setvbuf on Darwin.
        #if canImport(Darwin)
        setvbuf(stdout, nil, _IONBF, 0)
        #endif

        // Install SIGINT/SIGTERM handlers early so Ctrl-C always terminates the app,
        // even for apps that don't use the Keepalive action.
        KeepaliveSignalHandler.shared.setup()

        var mutableSelf = self
        mutableSelf.extractRunCommandFlags()

        let resolvedPath = URL(fileURLWithPath: mutableSelf.path)

        // ARO-0047: Parse application arguments into ParameterStorage
        if !mutableSelf.applicationArguments.isEmpty {
            ParameterStorage.shared.parseArguments(mutableSelf.applicationArguments)
        }

        let verbose = mutableSelf.verbose
        let debug = mutableSelf.debug
        let keepAlive = mutableSelf.keepAlive
        let entryPoint = mutableSelf.entryPoint
        let applicationArguments = mutableSelf.applicationArguments
        let recordPath = mutableSelf.record
        let replayPath = mutableSelf.replay
        let debugRecordPath = mutableSelf.debugRecord

        if verbose {
            AROLogger.setLevel(.debug)
        }

        if verbose {
            print("ARO Runtime v\(AROVersion.shortVersion)")
            print("Build: \(AROVersion.buildDate)")
            print("=======================")
            print("Path: \(resolvedPath.path)")
            print("Entry point: \(entryPoint)")
            if !applicationArguments.isEmpty {
                print("Application arguments: \(applicationArguments.joined(separator: " "))")
            }
            if let recordPath {
                print("Recording events to: \(recordPath)")
            }
            if let replayPath {
                print("Replaying events from: \(replayPath)")
            }
            print()
        }

        // Discover application with import resolution (#361 — shared helper)
        let appConfig = try await ApplicationResolver.resolve(
            at: resolvedPath,
            entryPoint: entryPoint,
            colorizeOnTTY: true
        )

        if verbose {
            print("Discovered application:")
            print("  Root: \(appConfig.rootPath.path)")
            print("  Source files: \(appConfig.sourceFiles.count)")
            for file in appConfig.sourceFiles {
                print("    - \(file.lastPathComponent)")
            }
            if !appConfig.storeFiles.isEmpty {
                print("  Store files: \(appConfig.storeFiles.count)")
                for store in appConfig.storeFiles {
                    let mode = store.isWritable ? "writable" : "read-only"
                    print("    - \(store.filePath.lastPathComponent) -> \(store.repositoryName) (\(mode))")
                }
            }
            print()
        }

        // Compile all source files
        let compiler = Compiler()
        var allDiagnostics: [Diagnostic] = []
        var compiledPrograms: [AnalyzedProgram] = []

        for sourceFile in appConfig.sourceFiles {
            if verbose {
                print("Compiling: \(sourceFile.lastPathComponent)")
            }

            let source: String
            do {
                source = try String(contentsOf: sourceFile, encoding: .utf8)
            } catch {
                if TTYDetector.stderrIsTTY {
                    print("\u{001B}[31mError reading \(sourceFile.lastPathComponent):\u{001B}[0m \(error)")
                } else {
                    print("Error reading \(sourceFile.lastPathComponent): \(error)")
                }
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

        if verbose {
            print("\nCompilation successful!")
            print("Feature sets found:")
            for program in compiledPrograms {
                for fs in program.featureSets {
                    print("  - \(fs.featureSet.name): \(fs.featureSet.businessActivity)")
                }
            }
            print()
        }

        // Load all plugins: managed Plugins/ (with plugin.yaml) and legacy plugins/ (bare .swift, SPM).
        // UnifiedPluginLoader handles both and passes managed names to the legacy loader so
        // plugins aren't double-loaded (which causes TLS/module-cache crashes on Linux).
        do {
            try UnifiedPluginLoader.shared.loadPlugins(from: appConfig.rootPath)
        } catch {
            print("Warning: Failed to load plugins: \(error)")
        }

        if verbose {
            let services = ExternalServiceRegistry.shared.registeredServices
            if services.count > 1 { // More than just built-in http
                print("Registered services: \(services.joined(separator: ", "))")
                print()
            }
        }

        // SOLARO's live debug stream uses `--debug-record` to get a
        // per-statement JSONL trace without touching the event-
        // recording semantics of `--record` (which writes a single
        // EventRecording JSON object that `--replay` consumes). The
        // silent frontend never blocks — it just hands back
        // `.stepOver` so `DebugController.checkpoint` keeps recording
        // rather than early-returning under `.continue`.
        let debugController: DebugController?
        if let debugRecordPath {
            let controller = DebugController(frontend: SilentRunFrontend())
            do {
                let recorder = try DebugEventLogWriter(path: debugRecordPath)
                await controller.setRecorder(recorder)
                debugController = controller
            } catch {
                if verbose {
                    print("warning: failed to open debug recorder \(debugRecordPath): \(error)")
                }
                debugController = nil
            }
        } else {
            debugController = nil
        }

        // Create and run application — `--record` still flows
        // straight to EventRecorder/EventReplayer for the existing
        // event-record/replay workflow.
        let application = Application(
            programs: compiledPrograms,
            entryPoint: entryPoint,
            config: ApplicationConfig(verbose: verbose, workingDirectory: appConfig.rootPath.path),
            openAPISpec: appConfig.openAPISpec,
            recordPath: recordPath,
            replayPath: replayPath,
            storeFiles: appConfig.storeFiles
        )

        if verbose {
            print("Starting application...")
            print()
        }

        // Open the metrics push socket — SOLARO (and any other
        // tooling) connects to $TMPDIR/aro-metrics-<pid>.sock and
        // receives NDJSON snapshots every 500ms. No flag needed:
        // local-only Unix socket, cleaned up on shutdown below.
        if let path = MetricsSocketServer.shared.start(), verbose {
            print("Metrics socket: \(path)")
            print()
        }
        defer { MetricsSocketServer.shared.stop() }

        // Pick a source-file hint so DebugController's pause records
        // include a basename for the canvas to attribute lines to.
        let sourceFileHint = appConfig.sourceFiles.first?.path ?? ""

        do {
            if let controller = debugController {
                try await Debug.$controller.withValue(controller) {
                    try await Debug.$currentSourceFile.withValue(sourceFileHint) {
                        try await self.runApplication(
                            application,
                            keepAlive: keepAlive,
                            verbose: verbose,
                            debug: debug
                        )
                    }
                }
            } else {
                try await self.runApplication(
                    application,
                    keepAlive: keepAlive,
                    verbose: verbose,
                    debug: debug
                )
            }
        } catch let error as ActionError {
            if TTYDetector.stderrIsTTY {
                print("\u{001B}[31mRuntime error:\u{001B}[0m \(error)")
            } else {
                print("Runtime error: \(error)")
            }
            throw ExitCode.failure
        } catch {
            if TTYDetector.stderrIsTTY {
                print("\u{001B}[31mError:\u{001B}[0m \(error)")
            } else {
                print("Error: \(error)")
            }
            throw ExitCode.failure
        }
    }

    private func runApplication(
        _ application: Application,
        keepAlive: Bool,
        verbose: Bool,
        debug: Bool
    ) async throws {
        if keepAlive {
            try await application.runForever()
        } else {
            let response = try await application.run()
            if verbose {
                print("\nExecution completed:")
            }
            let outputContext: OutputContext = debug ? .developer : .human
            if response.reason != "application" {
                print(response.format(for: outputContext))
            }
        }
    }
}

/// `DebugFrontend` for `aro run --record`: never prompts, never
/// blocks, just lets the controller keep recording. Returning
/// `.stepOver` keeps `DebugController.checkpoint` writing pause
/// records at every statement (vs. `.continue`, which short-
/// circuits after entry). SOLARO tails those records to drive the
/// canvas pulse / live values / repository tables (#284 step 3).
final class SilentRunFrontend: DebugFrontend {
    func didPause(_ pause: PauseInfo, controller: DebugController) async -> StepMode {
        .stepOver
    }
    func didEnd(error: Error?) async {}
}
