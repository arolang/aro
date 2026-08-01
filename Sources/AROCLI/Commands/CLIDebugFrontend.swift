// ============================================================
// CLIDebugFrontend.swift
// ARO CLI - stdin/stdout REPL frontend for `aro debug`
// ============================================================
//
// Extracted from DebugCommand (#354): the interactive REPL — reading a command
// line at each pause, parsing it into breakpoint / watch / step operations, and
// driving the DebugController — used to live in DebugCommand.swift alongside the
// command's discovery/compile/run coordination. Pulling it out keeps the
// command a thin coordinator and isolates the REPL plumbing the issue called out.
//
// `DebuggerQuit` is defined in ARORuntime (see Debug/DebugFrontend.swift)
// — the controller throws it from `checkpoint` when the frontend returns
// `.quit`. DebugCommand catches it at the top of `run()` and exits zero.

import Foundation
import ARORuntime

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
