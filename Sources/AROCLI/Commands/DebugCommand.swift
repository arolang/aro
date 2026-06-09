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
            `aro build` do not yet emit DWARF debug info — that's tracked
            separately as issue #231. To debug, run from source.

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

        // Discover application
        let discovery = ApplicationDiscovery()
        let appConfig: DiscoveredApplication
        do {
            appConfig = try await discovery.discoverWithImports(at: resolvedPath, entryPoint: entryPoint)
        } catch {
            print("Error: \(error)")
            throw ExitCode.failure
        }

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

// MARK: - Replay

extension DebugCommand {
    /// Issue #229 Phase 4 — read a recorded JSONL session and pretend
    /// each `pause` record is a fresh checkpoint. This drives the same
    /// CLI loop without re-running the program. Doesn't support
    /// breakpoint/step semantics yet — every pause shows in source
    /// order, the user types `n` to advance.
    func runReplay(path: String) async throws {
        let reader: DebugEventLogReader
        do {
            reader = try DebugEventLogReader(path: path)
        } catch {
            print("Cannot read \(path): \(error)")
            throw ExitCode.failure
        }
        let pauses = reader.records.filter { $0.kind == .pause }
        if pauses.isEmpty {
            print("No pause records in \(path).")
            return
        }
        print("aro debug · replay (\(pauses.count) pauses)")
        var cursor = 0
        while cursor < pauses.count {
            let rec = pauses[cursor]
            print("")
            print("⏸  [\(cursor+1)/\(pauses.count)] t=\(String(format: "%.3f", rec.time))s — \(rec.body["fs"] ?? "?"):\(rec.body["line"] ?? "0")")
            print("   \(rec.body["stmt"] ?? "")")
            if let symsJson = rec.body["syms"],
               let data = symsJson.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]],
               !arr.isEmpty {
                for s in arr {
                    print("     <\(s["n"] ?? "?")> : \(s["ty"] ?? "?") = \(s["v"] ?? "?")")
                }
            }
            print("(replay) ", terminator: "")
            guard let raw = readLine() else { return }
            switch raw.trimmingCharacters(in: .whitespaces) {
            case "n", "next", "":
                cursor += 1
            case "p", "prev":
                cursor = max(0, cursor - 1)
            case "g":
                cursor = pauses.count - 1
            case "0":
                cursor = 0
            case "q", "quit":
                return
            case let s where Int(s) != nil:
                let idx = Int(s)! - 1
                cursor = max(0, min(pauses.count - 1, idx))
            default:
                print("commands: n(ext) p(rev) g(o-end) 0(start) <num> q(uit)")
            }
        }
        print("\nEnd of replay.")
    }
}

// MARK: - CLI Frontend

// `DebuggerQuit` is defined in ARORuntime (see Debug/DebugFrontend.swift)
// — the controller throws it from `checkpoint` when the frontend returns
// `.quit`. We catch it at the top of `run()` and exit zero.

/// Reads stdin line-by-line at each pause and drives the controller.
/// Holds no mutable state across pauses — every command is interpreted
/// against the current `PauseInfo` and the controller's breakpoint list.
final class CLIDebugFrontend: DebugFrontend, @unchecked Sendable {
    func didPause(_ pause: PauseInfo, controller: DebugController) async -> StepMode {
        printPause(pause)
        let watches = await controller.listWatches()
        if !watches.isEmpty {
            for w in watches {
                let resolved = pause.symbols.first { "<\($0.name)>" == w }?.valuePreview ?? "(unresolved)"
                print("   watch \(w) = \(resolved)")
            }
        }
        while true {
            print("(aro-dbg) ", terminator: "")
            guard let raw = readLine() else {
                // EOF on stdin — treat as continue.
                return .continue
            }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
            let cmd = parts[0]
            let arg = parts.count > 1 ? parts[1] : ""

            switch cmd {
            case "s", "step":
                return .stepIn
            case "n", "next":
                return .stepOver
            case "c", "continue":
                return .continue
            case "f", "finish", "stepout":
                return .stepOut
            case "b", "break":
                if arg.isEmpty {
                    print("usage: b <line> | b <Verb> | b <line> if <pred>")
                } else if let ifRange = arg.range(of: " if ") {
                    let lhs = String(arg[..<ifRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let pred = String(arg[ifRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if let line = Int(lhs) {
                        await controller.addBreakpoint(.conditionalLocation(file: pause.file, line: line, predicate: pred))
                        print("conditional breakpoint at \(pause.file.isEmpty ? "*" : pause.file):\(line) if \(pred)")
                    } else {
                        print("conditional breakpoints require a line number")
                    }
                } else if let line = Int(arg) {
                    await controller.addBreakpoint(.location(file: pause.file, line: line))
                    print("breakpoint set at \(pause.file.isEmpty ? "*" : pause.file):\(line)")
                } else {
                    await controller.addBreakpoint(.verb(arg))
                    print("breakpoint set on verb \(arg)")
                }
            case "be", "breakevent":
                if arg.isEmpty { print("usage: be <EventName>"); continue }
                await controller.addBreakpoint(.event(arg))
                print("breakpoint set on event \(arg)")
            case "berror":
                await controller.addBreakpoint(.errorAny)
                print("breakpoint set on any error")
            case "w", "watch":
                if arg.isEmpty {
                    let list = await controller.listWatches()
                    if list.isEmpty { print("(no watches)") }
                    else { for (i, w) in list.enumerated() { print("  \(i): \(w)") } }
                } else {
                    await controller.addWatch(arg)
                    print("watching: \(arg)")
                }
            case "dw":
                guard let n = Int(arg) else { print("usage: dw <n>"); continue }
                let list = await controller.listWatches()
                guard n >= 0 && n < list.count else { print("no watch #\(n)"); continue }
                await controller.removeWatch(list[n])
                print("deleted watch #\(n)")
            case "bl", "list":
                let list = await controller.listBreakpoints()
                if list.isEmpty {
                    print("(no breakpoints)")
                } else {
                    for (i, bp) in list.enumerated() {
                        print("  \(i): \(bp.description)")
                    }
                }
            case "d", "delete":
                guard let n = Int(arg) else {
                    print("usage: d <n>")
                    continue
                }
                let list = await controller.listBreakpoints()
                guard n >= 0 && n < list.count else {
                    print("no breakpoint #\(n)")
                    continue
                }
                await controller.removeBreakpoint(list[n])
                print("deleted breakpoint #\(n)")
            case "p", "print":
                if pause.symbols.isEmpty {
                    print("  (no bindings)")
                } else {
                    for s in pause.symbols {
                        print("  <\(s.name)> : \(s.typeName) = \(s.valuePreview)")
                    }
                }
            case "bt", "where":
                print("  \(pause.featureSetName) · \(pause.businessActivity)")
                print("  at \(pause.file.isEmpty ? "<unknown>" : pause.file):\(pause.line)")
                print("  \(pause.statementSummary)")
            case "h", "help", "?":
                printHelp()
            case "q", "quit":
                print("quit.")
                // Issue #230 — return `.quit` so DebugController.checkpoint
                // throws DebuggerQuit, the executor unwinds normally, and
                // the run() catch handler prints the wrap-up. No more
                // Foundation.exit(0).
                return .quit
            default:
                print("unknown command: \(cmd) (use 'h' for help)")
            }
        }
    }

    func didEnd(error: Error?) async {
        // Nothing to do in Phase 1 — the run() catch handler prints the
        // wrap-up.
        _ = error
    }

    // MARK: - Output

    private func printPause(_ pause: PauseInfo) {
        let reasonText: String
        switch pause.reason {
        case .entry: reasonText = "entry"
        case .step: reasonText = "step"
        case .breakpoint(let bp): reasonText = "breakpoint (\(bp.description))"
        case .event(let n): reasonText = "event \(n)"
        case .error(let m): reasonText = "error: \(m)"
        }
        let where_ = pause.file.isEmpty ? pause.featureSetName : "\(pause.file):\(pause.line)"
        print("")
        print("⏸  paused (\(reasonText)) at \(where_) — \(pause.featureSetName)")
        print("   \(pause.statementSummary)")
    }

    private func printHelp() {
        print("""
          s, step       advance into the next statement (follows emits/calls)
          n, next       advance over the next statement
          f, finish     run until current feature set returns
          c, continue   resume until next breakpoint or program end
          b <line>      add breakpoint at source line
          b <Verb>      add breakpoint on every statement using that verb
          b <l> if X    conditional breakpoint at line l (predicate: ==, !=, &&, ||)
          be <Event>    add breakpoint on every emit of Event
                        (note: pause is best-effort vs. handler fan-out;
                         for strict pre-handler stop, use a verb bp on
                         Emit at the source statement)
          berror        add breakpoint on any runtime error
          bl, list      list breakpoints
          d <n>         delete breakpoint #n
          w <expr>      add watch expression (printed at every pause)
          dw <n>        delete watch #n
          p, print      show bindings visible at this pause
          bt, where     show current pause location
          h, help       this help text
          q, quit       terminate the program and exit the debugger
        """)
    }
}
