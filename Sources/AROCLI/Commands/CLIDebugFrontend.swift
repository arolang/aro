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
        // Resolved by the controller, which has the live context and the same
        // expression evaluator conditional breakpoints use — so a qualified
        // watch (`<user: id>`) resolves instead of printing "(unresolved)"
        // forever (GitLab #567).
        for watch in await controller.resolvedWatches(pause: pause) {
            print("   watch \(watch.expression) = \(watch.value)")
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
                    print("usage: b <line> | b <file>:<line> | b <Verb> | b [<file>:]<line> if <pred>")
                } else if let ifRange = arg.range(of: " if ") {
                    let lhs = String(arg[..<ifRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let pred = String(arg[ifRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                    switch Self.parseLocation(lhs, currentFile: pause.file) {
                    case .location(let file, let line):
                        await controller.addBreakpoint(
                            .conditionalLocation(file: file, line: line, predicate: pred))
                        print("conditional breakpoint at \(file.isEmpty ? "*" : file):\(line) if \(pred)")
                    case .malformed(let text):
                        print("not a line number: \(text) — use `b <file>:<line> if <pred>` or `b <line> if <pred>`")
                    case .notALocation:
                        print("conditional breakpoints require a line number")
                    }
                } else {
                    switch Self.parseLocation(arg, currentFile: pause.file) {
                    case .location(let file, let line):
                        await controller.addBreakpoint(.location(file: file, line: line))
                        print("breakpoint set at \(file.isEmpty ? "*" : file):\(line)")
                    case .malformed(let text):
                        // A verb never contains a colon, so this is a mistyped
                        // location rather than a verb. Saying so beats
                        // registering `.verb("main.aro:x")`, which nothing can
                        // ever match (GitLab #555).
                        print("not a line number: \(text) — use `b <file>:<line>`")
                    case .notALocation:
                        await controller.addBreakpoint(.verb(arg))
                        print("breakpoint set on verb \(arg)")
                    }
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
          b <line>      add breakpoint at that line of the current file
          b <f>:<line>  add breakpoint at that line of file f (any file if f is empty)
          b <Verb>      add breakpoint on every statement using that verb
          b <l> if X    conditional breakpoint at line l (predicate: ==, !=, &&, ||)
                        (also b <f>:<l> if X)
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

    // MARK: - Breakpoint location parsing (GitLab #555)

    /// What `b`'s argument turned out to be.
    ///
    /// `b` has to tell three things apart from one token: a line in the file
    /// we are paused in (`5`), a line in a named file (`orders.aro:12`), and a
    /// verb (`Emit`). It used to decide with `Int(arg)` alone, so every
    /// `file:line` fell through to `.verb("orders.aro:12")` — a breakpoint no
    /// statement can match, registered and listed without complaint. That was
    /// the only way to scope a breakpoint to a file other than the current one,
    /// since a launch-time `--breakpoint N` carries an empty file and matches
    /// line N everywhere.
    enum ParsedLocation: Equatable {
        /// A location. An empty `file` means "any file", as `.location` reads it.
        case location(file: String, line: Int)
        /// Contained a colon, but the part after it was not a line number.
        /// A verb never contains a colon, so this is a typo, not a verb.
        case malformed(String)
        /// No colon and not a number — the caller decides (a verb, for `b`).
        case notALocation
    }

    /// Parse `b`'s argument as `[<file>:]<line>`.
    ///
    /// Splits on the *last* colon so a path with more than one behaves, and
    /// falls back to `currentFile` for the bare-line form.
    static func parseLocation(_ arg: String, currentFile: String) -> ParsedLocation {
        if let line = Int(arg) {
            return .location(file: currentFile, line: line)
        }
        guard let colon = arg.lastIndex(of: ":") else { return .notALocation }
        let file = String(arg[arg.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
        let lineText = String(arg[arg.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard let line = Int(lineText) else { return .malformed(arg) }
        return .location(file: file, line: line)
    }
}
