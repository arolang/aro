// ============================================================
// TestResults.swift
// SOLARO — pass/fail markers driven by `aro test` stdout
// ============================================================
//
// When the user clicks Run-tests, the runner prints one
// `PASS <name>` / `FAIL <name>` line per test feature set. The
// stream parser in `ConsoleProcess.appendLine` hands each output
// line to `TestResultParser.match` to maintain
// `WorkspaceController.testResults`, which the canvas's feature
// set containers + the Inspector's feature-set list then read for
// their badges.
//
// We parse stdout (instead of plumbing a structured side channel
// out of the embedded runner) because both the subprocess and the
// embedded paths already pipe through the console; mirroring that
// stream into one regex keeps the wiring trivial and works
// identically for both backends.

import Foundation

/// Outcome we surface in the canvas / inspector. Mirrors
/// `ARORuntime.TestStatus` but as a Sendable value the views can
/// hold without dragging `ARORuntime` into their import graph.
enum TestNodeResult: Sendable, Equatable {
    case passed
    /// Carries the runner's failure message so the badge tooltip
    /// can preview it without re-fetching the log line.
    case failed(message: String)
}

/// Parses the runner's PASS/FAIL/ERROR stream into
/// `TestNodeResult` updates. Lines that don't look like a result
/// — the header banner, the summary footer, plain stdout from
/// the program under test — fall through and return nil.
enum TestResultParser {

    /// Strip the ANSI colour escapes the test runner uses for its
    /// PASS/FAIL labels so the matcher can stay regex-free.
    static func sanitize(_ line: String) -> String {
        var out = ""
        var i = line.startIndex
        while i < line.endIndex {
            if line[i] == "\u{001B}" {
                // Skip until 'm' (CSI sequence terminator). Bail
                // out gracefully if the sequence is malformed so
                // we don't drop the rest of the line.
                var j = line.index(after: i)
                while j < line.endIndex, line[j] != "m" {
                    j = line.index(after: j)
                }
                i = j < line.endIndex ? line.index(after: j) : line.endIndex
            } else {
                out.append(line[i])
                i = line.index(after: i)
            }
        }
        return out
    }

    /// Returns `(testName, result)` for a recognised line. `nil`
    /// for anything else so the caller can keep streaming output
    /// untouched.
    static func match(_ raw: String) -> (name: String, result: TestNodeResult)? {
        let line = sanitize(raw)
            .trimmingCharacters(in: .whitespaces)
        // Shape: "PASS  some-test-name (1ms)"
        //        "FAIL  some-test-name (1ms)"
        //        "ERROR  some-test-name (1ms)"
        for prefix in ["PASS", "FAIL", "ERROR"] {
            guard line.hasPrefix(prefix + " ") else { continue }
            let rest = line.dropFirst(prefix.count)
                .trimmingCharacters(in: .whitespaces)
            // Drop the trailing duration suffix ` (5ms)` if present.
            let name: String
            if let openParen = rest.lastIndex(of: "("),
               rest.hasSuffix(")") {
                name = rest[..<openParen]
                    .trimmingCharacters(in: .whitespaces)
            } else {
                name = rest
            }
            guard !name.isEmpty else { return nil }
            switch prefix {
            case "PASS": return (name, .passed)
            default:     return (name, .failed(message: prefix))
            }
        }
        return nil
    }
}
