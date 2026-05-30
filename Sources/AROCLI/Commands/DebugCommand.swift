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

    @Argument(help: "Path to the application directory or .aro file")
    var path: String

    @Option(name: .shortAndLong, help: "Override the entry point feature set")
    var entryPoint: String = "Application-Start"

    @Option(name: .long, parsing: .upToNextOption, help: "Initial breakpoints (line numbers or verb names)")
    var breakpoint: [String] = []

    @Flag(name: .long, help: "Speak Debug Adapter Protocol over stdio (issue #229 Phase 2)")
    var dap: Bool = false

    @Option(name: .long, help: "DAP log file path (when --dap is set)")
    var dapLog: String?

    @Flag(name: .shortAndLong, help: "Enable verbose logging")
    var verbose: Bool = false

    func run() async throws {
        #if canImport(Darwin)
        setvbuf(stdout, nil, _IONBF, 0)
        #endif

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
        if dap {
            let logFH: FileHandle?
            if let dapLog {
                FileManager.default.createFile(atPath: dapLog, contents: nil)
                logFH = FileHandle(forWritingAtPath: dapLog)
            } else {
                logFH = nil
            }
            let dapFrontend = DAPFrontend(log: logFH)
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

// MARK: - CLI Frontend

/// Signal thrown by the debugger when the user types `quit`. Caught by
/// the top-level handler to exit cleanly.
struct DebuggerQuit: Error {}

/// Reads stdin line-by-line at each pause and drives the controller.
/// Holds no mutable state across pauses — every command is interpreted
/// against the current `PauseInfo` and the controller's breakpoint list.
final class CLIDebugFrontend: DebugFrontend, @unchecked Sendable {
    func didPause(_ pause: PauseInfo, controller: DebugController) async -> StepMode {
        printPause(pause)
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
                    print("usage: b <line> | b <Verb>")
                } else if let line = Int(arg) {
                    await controller.addBreakpoint(.location(file: pause.file, line: line))
                    print("breakpoint set at \(pause.file.isEmpty ? "*" : pause.file):\(line)")
                } else {
                    await controller.addBreakpoint(.verb(arg))
                    print("breakpoint set on verb \(arg)")
                }
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
                // Throw a typed error from a Task so it propagates up
                // through the application.run() call.
                return .continue  // never reached; we'll throw below via DebuggerQuit
            default:
                print("unknown command: \(cmd) (use 'h' for help)")
            }

            if cmd == "q" || cmd == "quit" {
                // Returning a step mode is required by the protocol but we want
                // to terminate execution. Use a non-local throw approach: set a
                // controller flag would be nicer, but the cleanest minimum is to
                // simulate an exit by exiting the process. Phase 2 will replace
                // this with a proper teardown signal through the controller.
                Foundation.exit(0)
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
          bl, list      list breakpoints
          d <n>         delete breakpoint #n
          p, print      show bindings visible at this pause
          bt, where     show current pause location
          h, help       this help text
          q, quit       terminate the program and exit the debugger
        """)
    }
}
