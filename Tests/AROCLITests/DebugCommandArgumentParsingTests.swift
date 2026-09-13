// ============================================================
// DebugCommandArgumentParsingTests.swift
// AROCLITests - `aro debug` flag/path ordering (GitLab #550)
// ============================================================
//
// `--breakpoint`, `--break-condition` and `--logpoint` used to be declared
// `parsing: .upToNextOption`, which keeps consuming bare words until the next
// `-`-prefixed token. A flag written before the path therefore ate the path as
// another list element, and the command failed with "Missing path" — naming the
// argument it lost rather than the flag that took it. These tests parse the
// argument vector directly, so they pin the parse itself rather than a symptom
// visible only once the debugger runs.

import Testing
import ArgumentParser
@testable import AROCLI

@Suite("aro debug argument parsing (GitLab #550)")
struct DebugCommandArgumentParsingTests {

    // MARK: - Flag before path

    @Test("A --breakpoint before the path leaves the path intact")
    func breakpointBeforePath() throws {
        let cmd = try DebugCommand.parse(["--breakpoint", "5", "./Examples/HelloWorld"])
        #expect(cmd.path == "./Examples/HelloWorld")
        #expect(cmd.breakpoint == ["5"])
    }

    @Test("A --break-condition before the path leaves the path intact")
    func breakConditionBeforePath() throws {
        let cmd = try DebugCommand.parse(
            ["--break-condition", "5=<x> == 1", "./Examples/HelloWorld"])
        #expect(cmd.path == "./Examples/HelloWorld")
        #expect(cmd.breakCondition == ["5=<x> == 1"])
    }

    @Test("A --logpoint before the path leaves the path intact")
    func logpointBeforePath() throws {
        let cmd = try DebugCommand.parse(["--logpoint", "5=hi", "./Examples/HelloWorld"])
        #expect(cmd.path == "./Examples/HelloWorld")
        #expect(cmd.logpoint == ["5=hi"])
    }

    // MARK: - Path first still parses

    @Test("The path-first spelling still parses, for every one of the three")
    func pathFirstStillWorks() throws {
        var cmd = try DebugCommand.parse(["./Examples/HelloWorld", "--breakpoint", "5"])
        cmd.extractDebugCommandFlags()
        #expect(cmd.path == "./Examples/HelloWorld")
        #expect(cmd.breakpoint == ["5"])

        var cond = try DebugCommand.parse(
            ["./Examples/HelloWorld", "--break-condition", "5=<x> == 1"])
        cond.extractDebugCommandFlags()
        #expect(cond.path == "./Examples/HelloWorld")
        #expect(cond.breakCondition == ["5=<x> == 1"])

        var log = try DebugCommand.parse(["./Examples/HelloWorld", "--logpoint", "5=hi"])
        log.extractDebugCommandFlags()
        #expect(log.path == "./Examples/HelloWorld")
        #expect(log.logpoint == ["5=hi"])
    }

    // MARK: - Repeatable

    @Test("Each flag is repeatable, in either position")
    func repeatable() throws {
        let cmd = try DebugCommand.parse([
            "--breakpoint", "5", "--breakpoint", "Emit", "./Examples/HelloWorld",
        ])
        #expect(cmd.path == "./Examples/HelloWorld")
        #expect(cmd.breakpoint == ["5", "Emit"])
    }

    @Test("A breakpoint whose value is a verb is not mistaken for the path")
    func verbBreakpointBeforePath() throws {
        let cmd = try DebugCommand.parse(["--breakpoint", "Emit", "./MyApp"])
        #expect(cmd.path == "./MyApp")
        #expect(cmd.breakpoint == ["Emit"])
    }

    // MARK: - Passthrough still reaches the application

    @Test("Application arguments after the path still pass through")
    func passthroughSurvives() throws {
        var cmd = try DebugCommand.parse([
            "--breakpoint", "5", "./MyApp", "--url", "https://example.com",
        ])
        #expect(cmd.path == "./MyApp")
        #expect(cmd.breakpoint == ["5"])
        cmd.extractDebugCommandFlags()
        #expect(cmd.applicationArguments == ["--url", "https://example.com"])
    }

    @Test("A flag-first launch with no path at all still reports the missing path")
    func noPathIsStillAnError() throws {
        let cmd = try DebugCommand.parse(["--breakpoint", "5"])
        #expect(cmd.path.isEmpty)
        #expect(cmd.breakpoint == ["5"])
    }
}
