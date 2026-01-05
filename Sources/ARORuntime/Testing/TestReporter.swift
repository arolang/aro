// ============================================================
// TestReporter.swift
// ARO Runtime - Test Result Reporter
// ============================================================

import Foundation

// MARK: - Test Reporter

/// Formats and outputs test results to the console
public struct TestReporter: Sendable {
    // MARK: - Properties

    private let verbose: Bool
    private let useColors: Bool

    // MARK: - ANSI Colors

    private enum Color: String {
        case green = "\u{001B}[32m"
        case red = "\u{001B}[31m"
        case yellow = "\u{001B}[33m"
        case cyan = "\u{001B}[36m"
        case gray = "\u{001B}[90m"
        case reset = "\u{001B}[0m"
        case bold = "\u{001B}[1m"
    }

    // MARK: - Initialization

    public init(verbose: Bool = false, useColors: Bool = true) {
        self.verbose = verbose
        self.useColors = useColors
    }

    // MARK: - Reporting

    /// Report test results to console
    public func report(_ results: TestSuiteResult) {
        printHeader()
        printResults(results)
        printSummary(results)
    }

    // MARK: - Private Helpers

    private func printHeader() {
        print("")
        print(color(.bold) + "=== ARO Test Results ===" + color(.reset))
        print("")
    }

    private func printResults(_ results: TestSuiteResult) {
        for result in results.results {
            printResult(result)
        }
    }

    private func printResult(_ result: TestResult) {
        let duration = formatDuration(result.duration)

        switch result.status {
        case .passed:
            print("  " + color(.green) + "PASS" + color(.reset) +
                  "  " + result.name +
                  color(.gray) + " (\(duration))" + color(.reset))

        case .failed(let message):
            print("  " + color(.red) + "FAIL" + color(.reset) +
                  "  " + result.name)
            print("        " + color(.red) + message + color(.reset))

            // Print failed assertions in verbose mode
            if verbose {
                for assertion in result.assertions where !assertion.passed {
                    print("        " + color(.gray) +
                          "- \(assertion.variable): expected \(assertion.expectedDescription), " +
                          "got \(assertion.actualDescription)" + color(.reset))
                }
            }

        case .error(let message):
            print("  " + color(.red) + "ERROR" + color(.reset) +
                  " " + result.name)
            print("        " + color(.red) + message + color(.reset))

        case .skipped(let reason):
            print("  " + color(.yellow) + "SKIP" + color(.reset) +
                  "  " + result.name)
            print("        " + color(.gray) + reason + color(.reset))
        }
    }

    private func printSummary(_ results: TestSuiteResult) {
        print("")
        print("------------------------")

        let totalColor: Color = results.hasFailures ? .red : .green

        print("Total:  " + color(totalColor) + "\(results.totalCount)" + color(.reset))
        print("Passed: " + color(.green) + "\(results.passedCount)" + color(.reset))

        if results.failedCount > 0 {
            print("Failed: " + color(.red) + "\(results.failedCount)" + color(.reset))
        } else {
            print("Failed: \(results.failedCount)")
        }

        if results.errorCount > 0 {
            print("Errors: " + color(.red) + "\(results.errorCount)" + color(.reset))
        }

        if results.skippedCount > 0 {
            print("Skipped: " + color(.yellow) + "\(results.skippedCount)" + color(.reset))
        }

        print("")

        if results.hasFailures {
            print(color(.red) + "Some tests failed." + color(.reset))
        } else if results.totalCount == 0 {
            print(color(.yellow) + "No tests found." + color(.reset))
        } else {
            print(color(.green) + "All tests passed!" + color(.reset))
        }

        print("")
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 0.001 {
            return "<1ms"
        } else if duration < 1 {
            return "\(Int(duration * 1000))ms"
        } else {
            return String(format: "%.2fs", duration)
        }
    }

    private func color(_ c: Color) -> String {
        useColors ? c.rawValue : ""
    }
}

// MARK: - Convenience Extensions

extension TestReporter {
    /// Create a reporter for CI environments (no colors)
    public static var ci: TestReporter {
        TestReporter(verbose: true, useColors: false)
    }

    /// Create a verbose reporter with colors
    public static var verbose: TestReporter {
        TestReporter(verbose: true, useColors: true)
    }

    /// Create a minimal reporter
    public static var minimal: TestReporter {
        TestReporter(verbose: false, useColors: true)
    }

    /// Create a reporter with auto-detected color support based on TTY
    public static var smart: TestReporter {
        TestReporter(verbose: false, useColors: TTYDetector.stdoutIsTTY)
    }
}
