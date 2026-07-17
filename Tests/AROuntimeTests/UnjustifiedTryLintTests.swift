import XCTest

/// Enforces the CLAUDE.md "Silent fallbacks (`try?`)" policy for the audited
/// bridge files (issue #322). Every `try?` in those files must carry a
/// justifying comment — either inline or in the contiguous statement block
/// immediately above it — otherwise it either logs a stderr warning, throws
/// with context, or is documented as a genuinely optional operation.
///
/// This test drives `Scripts/lint-unjustified-try.sh`, so the shell script and
/// the test agree by construction: the script is the single source of truth
/// for the rule and for the list of audited files. `swift test` therefore
/// fails if anyone reintroduces an unjustified `try?` in an audited file.
///
/// As the audit expands to more runtime files, add them to `AUDITED_FILES` in
/// the shell script; this test picks up the wider scope automatically.
final class UnjustifiedTryLintTests: XCTestCase {

    /// Repo root, derived from this source file's location:
    /// Tests/AROuntimeTests/UnjustifiedTryLintTests.swift -> repo root is three
    /// directories up.
    private static func repoRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // AROuntimeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    func testAuditedBridgeFilesHaveNoUnjustifiedTry() throws {
        let root = Self.repoRoot()
        let script = root.appendingPathComponent("Scripts/lint-unjustified-try.sh")

        guard FileManager.default.fileExists(atPath: script.path) else {
            XCTFail("Lint script missing at \(script.path)")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        XCTAssertEqual(
            process.terminationStatus, 0,
            """
            lint-unjustified-try.sh reported unjustified `try?` in an audited file.
            Every `try?` must be justified with a comment, or rewritten to log a
            stderr warning / throw with context per CLAUDE.md.

            stdout:
            \(out)
            stderr:
            \(err)
            """
        )
    }
}
