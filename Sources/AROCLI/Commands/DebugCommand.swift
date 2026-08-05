// ============================================================
// DebugCommand.swift
// ARO CLI - `aro debug` Step Debugger (Issue #229 Phase 1)
// ============================================================
//
// Pauses the application at each ARO statement boundary and exposes a
// small REPL of stepping commands over stdin/stdout. Subsequent phases
// add a DAP server (Phase 2), advanced breakpoints (Phase 3), and time
// travel (Phase 4) — all driven by the same `DebugController` actor.

import ArgumentParser
import Foundation
import AROParser
import ARORuntime
import AROVersion

struct DebugCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "debug",
        abstract: "Step-debug an ARO application",
        discussion: """
            Pauses execution at every ARO statement and accepts a small set of
            REPL commands over stdin. Issue #229 Phase 1.

            Note: this driver runs the program through the ARO interpreter
            (the same path as `aro run`). Compiled binaries produced by
            `aro build` now emit DWARF debug info and support source-level
            breakpoints in lldb on both macOS and Linux — build the app,
            then `lldb <binary>` and e.g. `breakpoint set --file main.aro
            --line 5` (issue #231).

            Commands at a pause prompt:
              s, step            — advance one statement
              n, next            — advance one statement (alias for step)
              c, continue        — resume until next breakpoint or program end
              b <line>           — add breakpoint at the given source line
              b <verb>           — add breakpoint at any statement using <verb>
              bl, list           — list active breakpoints
              d <n>              — delete breakpoint #n
              p, print           — show current symbol table
              bt, where          — show pause location summary
              h, help            — show this help text
              q, quit            — terminate execution and exit

            Example:
              aro debug ./Examples/HelloWorld
            """
    )

    @Argument(help: "Path to the application directory or .aro file (omit with --replay)")
    var path: String = ""

    @Argument(parsing: .captureForPassthrough, help: "Arguments to pass to the application (e.g. --url …)")
    var applicationArguments: [String] = []

    @Option(name: .shortAndLong, help: "Override the entry point feature set")
    var entryPoint: String = "Application-Start"

    @Option(name: .long, parsing: .upToNextOption, help: "Initial breakpoints (line numbers or verb names)")
    var breakpoint: [String] = []

    @Option(name: .long, parsing: .upToNextOption,
            help: "Conditional breakpoint(s) as \"LINE=EXPRESSION\" — pauses only when EXPRESSION is truthy (issue #259)")
    var breakCondition: [String] = []

    @Option(name: .long, parsing: .upToNextOption,
            help: "Logpoint(s) as \"LINE=MESSAGE\" — logs MESSAGE (with {var} interpolation) without pausing (issue #259)")
    var logpoint: [String] = []

    @Flag(name: .long, help: "Speak Debug Adapter Protocol over stdio (issue #229 Phase 2)")
    var dap: Bool = false

    @Option(name: .long, help: "Listen on TCP port for a DAP client (issue #229 Phase 5)")
    var dapPort: Int?

    @Option(name: .long, help: "DAP log file path (when --dap is set)")
    var dapLog: String?

    @Option(name: .long, help: "Record the debug session to a JSONL file (issue #229 Phase 4)")
    var record: String?

    @Option(name: .long, help: "Replay a recorded debug session — does not execute the program")
    var replay: String?

    @Option(name: .long, help: "Sample stride — pause every Nth step (issue #229 Phase 5)")
    var sample: Int = 1

    @Flag(name: .shortAndLong, help: "Enable verbose logging")
    var verbose: Bool = false

    /// Pull DebugCommand-owned flags out of the passthrough array
    /// so the remainder can flow into `ParameterStorage` as
    /// `<parameter: NAME>` values. Mirror of
    /// `RunCommand.extractRunCommandFlags()`. Needed because
    /// `.captureForPassthrough` greedily slurps everything after
    /// the path argument — without this, SOLARO's
    /// `--breakpoint`/`--record` would land in `applicationArguments`
    /// and `--url`-style user params would have nowhere to go.
    mutating func extractDebugCommandFlags() {
        var remaining: [String] = []
        var i = 0
        while i < applicationArguments.count {
            let arg = applicationArguments[i]
            switch arg {
            case "--verbose", "-v":
                verbose = true
                i += 1
            case "--dap":
                dap = true
                i += 1
            case "--entry-point", "-e":
                if i + 1 < applicationArguments.count {
                    entryPoint = applicationArguments[i + 1]
                    i += 2
                } else { remaining.append(arg); i += 1 }
            case "--record":
                if i + 1 < applicationArguments.count {
                    record = applicationArguments[i + 1]
                    i += 2
                } else { remaining.append(arg); i += 1 }
            case "--replay":
                if i + 1 < applicationArguments.count {
                    replay = applicationArguments[i + 1]
                    i += 2
                } else { remaining.append(arg); i += 1 }
            case "--dap-port":
                if i + 1 < applicationArguments.count,
                   let v = Int(applicationArguments[i + 1]) {
                    dapPort = v
                    i += 2
                } else { remaining.append(arg); i += 1 }
            case "--dap-log":
                if i + 1 < applicationArguments.count {
                    dapLog = applicationArguments[i + 1]
                    i += 2
                } else { remaining.append(arg); i += 1 }
            case "--sample":
                if i + 1 < applicationArguments.count,
                   let v = Int(applicationArguments[i + 1]) {
                    sample = v
                    i += 2
                } else { remaining.append(arg); i += 1 }
            case "--breakpoint":
                if i + 1 < applicationArguments.count {
                    breakpoint.append(applicationArguments[i + 1])
                    i += 2
                } else { remaining.append(arg); i += 1 }
            case "--break-condition":
                if i + 1 < applicationArguments.count {
                    breakCondition.append(applicationArguments[i + 1])
                    i += 2
                } else { remaining.append(arg); i += 1 }
            case "--logpoint":
                if i + 1 < applicationArguments.count {
                    logpoint.append(applicationArguments[i + 1])
                    i += 2
                } else { remaining.append(arg); i += 1 }
            default:
                remaining.append(arg)
                i += 1
            }
        }
        applicationArguments = remaining
    }

    func run() async throws {
        #if canImport(Darwin)
        setvbuf(stdout, nil, _IONBF, 0)
        #endif

        // Re-parse any flags / `<parameter: NAME>` values that landed
        // in the passthrough array. SOLARO appends them after the
        // path (e.g. `aro debug <path> --record … --breakpoint 12
        // --url https://…`); without this the runtime would either
        // ignore its own flags or refuse to start with "Unknown
        // option '--url'".
        var mutableSelf = self
        mutableSelf.extractDebugCommandFlags()
        if !mutableSelf.applicationArguments.isEmpty {
            ParameterStorage.shared.parseArguments(mutableSelf.applicationArguments)
        }
        // Shadow the @Argument/@Option properties with locals so the
        // rest of the function reads the post-extraction values
        // without having to thread `mutableSelf.` everywhere.
        let path = mutableSelf.path
        let entryPoint = mutableSelf.entryPoint
        let verbose = mutableSelf.verbose
        let breakpoint = mutableSelf.breakpoint
        let breakCondition = mutableSelf.breakCondition
        let logpoint = mutableSelf.logpoint
        let record = mutableSelf.record
        let replay = mutableSelf.replay
        let dap = mutableSelf.dap
        let dapPort = mutableSelf.dapPort
        let dapLog = mutableSelf.dapLog
        let sample = mutableSelf.sample

        // Phase 4 — replay short-circuits the runtime entirely.
        if let replay {
            try await runReplay(path: replay)
            return
        }

        if path.isEmpty {
            print("Error: Missing path. Pass a directory / .aro file, or use --replay <session.jsonl>.")
            throw ExitCode.failure
        }
        let resolvedPath = URL(fileURLWithPath: path)

        // Discover application (#361 — shared helper)
        let appConfig = try await ApplicationResolver.resolve(
            at: resolvedPath,
            entryPoint: entryPoint
        )

        // Compile
        let compiler = Compiler()
        var allDiagnostics: [Diagnostic] = []
        var compiledPrograms: [AnalyzedProgram] = []

        for sourceFile in appConfig.sourceFiles {
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

        let errors = allDiagnostics.filter { $0.severity == .error }
        if !errors.isEmpty {
            print("Compilation errors:")
            for error in errors { print("  \(error)") }
            throw ExitCode.failure
        }

        // Plugins
        do {
            try UnifiedPluginLoader.shared.loadPlugins(from: appConfig.rootPath)
        } catch {
            print("Warning: Failed to load plugins: \(error)")
        }

        // Build the frontend + controller
        let frontend: any DebugFrontend
        var dapFrontendForLoop: DAPFrontend? = nil
        if dap || dapPort != nil {
            let logFH: FileHandle?
            if let dapLog {
                FileManager.default.createFile(atPath: dapLog, contents: nil)
                logFH = FileHandle(forWritingAtPath: dapLog)
            } else {
                logFH = nil
            }
            // Phase 5: TCP socket frontend. Accept blocks; do it before
            // we start the application so the client controls timing.
            let input: FileHandle
            let output: FileHandle
            if let port = dapPort {
                FileHandle.standardError.write(Data("aro debug: DAP listening on tcp://127.0.0.1:\(port)\n".utf8))
                let ep: DAPTCPListener.Endpoint
                do {
                    ep = try DAPTCPListener.acceptOne(port: UInt16(port))
                } catch {
                    print("Error: failed to accept DAP client on port \(port): \(error)")
                    throw ExitCode.failure
                }
                input = ep.input
                output = ep.output
            } else {
                input = .standardInput
                output = .standardOutput
            }
            let dapFrontend = DAPFrontend(input: input, output: output, log: logFH)
            frontend = dapFrontend
            dapFrontendForLoop = dapFrontend
        } else {
            frontend = CLIDebugFrontend()
        }
        let controller = DebugController(frontend: frontend)
        if let dapFrontend = dapFrontendForLoop {
            await dapFrontend.attach(controller: controller)
            Task.detached { await dapFrontend.runMessageLoop() }
        }

        // Phase 4 — install JSONL recorder if --record was set.
        if let record {
            do {
                let recorder = try DebugEventLogWriter(path: record)
                await controller.setRecorder(recorder)
                if !dap { print("recording session to \(record)") }
            } catch {
                print("warning: failed to open recorder \(record): \(error)")
            }
        }

        // Phase 5 — sampling stride for production attaches.
        if sample > 1 {
            await controller.setSampleStride(sample)
            if !dap { print("sampling stride: \(sample)") }
        }

        // Seed breakpoints from --breakpoint flags
        for spec in breakpoint {
            if let line = Int(spec) {
                await controller.addBreakpoint(.location(file: "", line: line))
            } else {
                await controller.addBreakpoint(.verb(spec))
            }
        }

        // Seed conditional breakpoints (#259): "LINE=EXPRESSION". Split on
        // the FIRST `=` only — the line number never contains `=`, so any
        // `==` / `>=` inside the predicate survives intact.
        for spec in breakCondition {
            guard let eq = spec.firstIndex(of: "="),
                  let line = Int(spec[..<eq]) else {
                print("warning: ignoring malformed --break-condition '\(spec)' (expected LINE=EXPRESSION)")
                continue
            }
            let predicate = String(spec[spec.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
            await controller.addBreakpoint(
                .conditionalLocation(file: "", line: line, predicate: predicate))
        }

        // Seed logpoints (#259): "LINE=MESSAGE". Same first-`=` split.
        for spec in logpoint {
            guard let eq = spec.firstIndex(of: "="),
                  let line = Int(spec[..<eq]) else {
                print("warning: ignoring malformed --logpoint '\(spec)' (expected LINE=MESSAGE)")
                continue
            }
            let message = String(spec[spec.index(after: eq)...])
            await controller.addBreakpoint(
                .logpoint(file: "", line: line, message: message))
        }

        let application = Application(
            programs: compiledPrograms,
            entryPoint: entryPoint,
            config: ApplicationConfig(verbose: verbose, workingDirectory: appConfig.rootPath.path),
            openAPISpec: appConfig.openAPISpec,
            recordPath: nil,
            replayPath: nil,
            storeFiles: appConfig.storeFiles
        )

        // Source file for Application-Start is taken from the first source
        // file that declared it; finding the exact one would require walking
        // the AST. Phase 1 uses the rootPath basename as a stand-in so
        // breakpoints set by file name still show meaningful context.
        let sourceFileHint = appConfig.sourceFiles.first?.path ?? ""

        if !dap {
            print("aro debug · \(AROVersion.shortVersion) · \(appConfig.rootPath.lastPathComponent)")
            print("Use 'h' for help, 'q' to quit, 's' to step.")
        }

        // Open the metrics push socket so SOLARO's Metrics tab can
        // stream live data during debug sessions too — same Unix
        // socket as `aro run` (path keyed by PID), cleaned up via
        // defer below regardless of how the debug session exits.
        if MetricsSocketServer.shared.start() != nil, !dap {
            print("Metrics socket: \(MetricsSocketServer.socketPath(forPID: getpid()))")
        }
        defer { MetricsSocketServer.shared.stop() }

        do {
            try await Debug.$controller.withValue(controller) {
                try await Debug.$currentSourceFile.withValue(sourceFileHint) {
                    _ = try await application.run()
                }
            }
            await controller.didEnd(error: nil)
            if !dap { print("\nProgram ended cleanly.") }
        } catch is DebuggerQuit {
            if !dap { print("\nDebugger quit.") }
            throw ExitCode.success
        } catch {
            await controller.didEnd(error: error)
            if !dap { print("\nProgram ended with error: \(error)") }
            throw ExitCode.failure
        }
    }
}
