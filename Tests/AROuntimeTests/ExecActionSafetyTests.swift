// ============================================================
// ExecActionSafetyTests.swift
// ARO Runtime - Exec argument-passing safety (GitLab #471)
// ============================================================

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

// MARK: - Argv Construction

@Suite("Exec Argv Construction")
struct ExecArgvConstructionTests {

    @Test("Tokenize splits on whitespace")
    func testTokenizeSplitsOnWhitespace() {
        #expect(ExecuteAction.tokenize("-l -a") == ["-l", "-a"])
        #expect(ExecuteAction.tokenize("  -h   ") == ["-h"])
        #expect(ExecuteAction.tokenize("ls") == ["ls"])
        #expect(ExecuteAction.tokenize("") == [])
    }

    @Test("Tokenize does not interpret quotes or metacharacters")
    func testTokenizeKeepsMetacharactersLiteral() {
        // No quoting layer: every token is handed to the process verbatim,
        // so there is nothing for a shell to re-interpret.
        #expect(ExecuteAction.tokenize("a;b") == ["a;b"])
        #expect(ExecuteAction.tokenize("x | y") == ["x", "|", "y"])
        #expect(ExecuteAction.tokenize("'quoted arg'") == ["'quoted", "arg'"])
    }

    @Test("direct() marks the config as shell-free")
    func testDirectConfigIsShellFree() {
        let config = ExecConfig.direct(argv: ["echo", "hi"])

        #expect(config.argv == ["echo", "hi"])
    }

    @Test("Plain command string keeps the shell")
    func testPlainCommandKeepsShell() {
        let config = ExecConfig(command: "ps aux | head -20")

        #expect(config.argv == nil)
        #expect(config.command == "ps aux | head -20")
    }

    @Test("Display string quotes only non-trivial elements")
    func testDisplayStringQuoting() {
        #expect(ExecConfig.displayString(for: ["echo", "hi"]) == "echo hi")
        #expect(ExecConfig.displayString(for: ["ls", "-la", "./a_b.txt"]) == "ls -la ./a_b.txt")
        #expect(ExecConfig.displayString(for: ["echo", "a; b"]) == "echo 'a; b'")
        #expect(ExecConfig.displayString(for: ["echo", ""]) == "echo ''")
    }

    @Test("Display string escapes embedded single quotes")
    func testDisplayStringEscapesQuotes() {
        // Display only, but must not produce something that reads as valid shell
        // with different meaning than the argv it describes.
        #expect(ExecConfig.displayString(for: ["echo", "it's"]) == #"echo 'it'\''s'"#)
    }
}

// MARK: - Injection Resistance

@Suite("Exec Injection Resistance")
struct ExecInjectionResistanceTests {

    /// Runs `argv` through the same execution path the action uses.
    private func run(argv: [String]) -> ExecResult {
        ExecuteAction.runCommandSyncForTesting(ExecConfig.direct(argv: argv))
    }

    @Test("Command separator in an argument is not executed")
    func testCommandSeparatorNotExecuted() throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-471-semicolon-\(ProcessInfo.processInfo.processIdentifier)")
            .path
        defer { try? FileManager.default.removeItem(atPath: marker) }

        let result = run(argv: ["echo", "hello; touch \(marker)"])

        // echo receives one literal argument...
        #expect(result.output == "hello; touch \(marker)")
        #expect(result.exitCode == 0)
        // ...and the injected command never ran.
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test("Command substitution in an argument is not evaluated")
    func testCommandSubstitutionNotEvaluated() throws {
        let result = run(argv: ["echo", "$(id -u)", "`id -u`"])

        #expect(result.output == "$(id -u) `id -u`")
    }

    @Test("Pipe and redirection in an argument are literal")
    func testPipeAndRedirectionAreLiteral() throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-471-redirect-\(ProcessInfo.processInfo.processIdentifier)")
            .path
        defer { try? FileManager.default.removeItem(atPath: marker) }

        let result = run(argv: ["echo", "a | b > \(marker)"])

        #expect(result.output == "a | b > \(marker)")
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test("Argument with whitespace stays a single argument")
    func testWhitespaceArgumentStaysSingle() throws {
        // `-n` suppresses the trailing newline, so two args would print with a
        // space between them and one arg prints verbatim — same string either way.
        // Use `wc -w`-free check: pass to `printf %s` which takes exactly one arg.
        let result = run(argv: ["printf", "%s", "two words"])

        #expect(result.output == "two words")
    }

    @Test("Executable is resolved through PATH without a shell")
    func testExecutableResolvedThroughPath() throws {
        let result = run(argv: ["echo", "resolved"])

        #expect(result.exitCode == 0)
        #expect(result.output == "resolved")
    }

    @Test("Absolute executable path is used directly")
    func testAbsoluteExecutablePath() throws {
        let result = run(argv: ["/bin/echo", "direct"])

        #expect(result.exitCode == 0)
        #expect(result.output == "direct")
    }

    @Test("Nonexistent executable fails without invoking a shell")
    func testNonexistentExecutableFails() throws {
        let result = run(argv: ["aro-no-such-binary-471", "arg"])

        #expect(result.error)
        #expect(result.exitCode != 0)
    }
}

// MARK: - Shell Form Still Works

@Suite("Exec Shell Form")
struct ExecShellFormTests {

    @Test("Pipeline in the command qualifier is shell-interpreted")
    func testPipelineStillWorks() throws {
        let result = ExecuteAction.runCommandSyncForTesting(
            ExecConfig(command: "echo 'a\nb\nc' | wc -l")
        )

        #expect(result.exitCode == 0)
        #expect(result.output.trimmingCharacters(in: .whitespaces) == "3")
    }

    @Test("Redirection in the command qualifier still works")
    func testRedirectionStillWorks() throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-471-shellform-\(ProcessInfo.processInfo.processIdentifier)")
            .path
        defer { try? FileManager.default.removeItem(atPath: marker) }

        let result = ExecuteAction.runCommandSyncForTesting(
            ExecConfig(command: "echo written > \(marker)")
        )

        #expect(result.exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: marker))
    }
}
