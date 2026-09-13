// ============================================================
// DebugBreakpointLocationParseTests.swift
// AROCLITests - `b <file>:<line>` at the debugger prompt (GitLab #555)
// ============================================================
//
// `b` decided between a location and a verb with `Int(arg)` alone, so every
// `file:line` fell through to `.verb("main.aro:5")` — a breakpoint no statement
// can match, registered and listed without complaint. That was the only way to
// scope a breakpoint to a file other than the one you are paused in, since a
// launch-time `--breakpoint N` carries an empty file and matches line N in
// every file.

import Testing
@testable import AROCLI

@Suite("Debugger breakpoint location parsing (GitLab #555)")
struct DebugBreakpointLocationParseTests {

    typealias Parsed = CLIDebugFrontend.ParsedLocation

    // MARK: - The bug

    @Test("file:line is a location, not a verb")
    func fileLineIsALocation() {
        #expect(CLIDebugFrontend.parseLocation("main.aro:5", currentFile: "other.aro")
                == .location(file: "main.aro", line: 5))
    }

    @Test("The named file wins over the file we are paused in")
    func namedFileOverridesCurrent() {
        #expect(CLIDebugFrontend.parseLocation("orders.aro:12", currentFile: "main.aro")
                == .location(file: "orders.aro", line: 12))
    }

    // MARK: - The forms that already worked

    @Test("A bare line number picks up the current file")
    func bareLineUsesCurrentFile() {
        #expect(CLIDebugFrontend.parseLocation("5", currentFile: "main.aro")
                == .location(file: "main.aro", line: 5))
    }

    @Test("A verb is still a verb")
    func verbIsStillAVerb() {
        #expect(CLIDebugFrontend.parseLocation("Emit", currentFile: "main.aro") == .notALocation)
        #expect(CLIDebugFrontend.parseLocation("Retrieve", currentFile: "") == .notALocation)
    }

    // MARK: - Edges

    @Test("An empty file half means any file, as .location reads it")
    func emptyFileMeansAnyFile() {
        #expect(CLIDebugFrontend.parseLocation(":5", currentFile: "main.aro")
                == .location(file: "", line: 5))
    }

    @Test("A colon with a non-numeric tail is a typo, not a verb")
    func malformedIsReported() {
        // Registering `.verb("main.aro:x")` is what made the original failure
        // silent — the debugger confirmed a breakpoint nothing could match.
        #expect(CLIDebugFrontend.parseLocation("main.aro:x", currentFile: "main.aro")
                == .malformed("main.aro:x"))
    }

    @Test("The split is on the last colon, so a path may contain several")
    func splitsOnLastColon() {
        #expect(CLIDebugFrontend.parseLocation("sources/orders/orders.aro:7", currentFile: "")
                == .location(file: "sources/orders/orders.aro", line: 7))
    }

    @Test("Whitespace around either half is tolerated")
    func whitespaceTolerated() {
        #expect(CLIDebugFrontend.parseLocation("orders.aro : 12", currentFile: "")
                == .location(file: "orders.aro", line: 12))
    }

    @Test("A negative line still parses as a line, not as a verb")
    func negativeLineParses() {
        // `-3` is `Int`-parseable, so it is a location. Nothing will match it,
        // but it must not become a verb named "-3".
        #expect(CLIDebugFrontend.parseLocation("-3", currentFile: "main.aro")
                == .location(file: "main.aro", line: -3))
    }
}
