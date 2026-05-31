// ============================================================
// DebugControllerTests.swift
// ARO Runtime - Tests for the step debugger controller (Issue #229 Phase 1)
// ============================================================

import XCTest
import AROParser
@testable import ARORuntime

final class DebugControllerTests: XCTestCase {

    // MARK: - Helpers

    /// A scriptable frontend: each pause consumes the next StepMode from a
    /// queue, and the PauseInfo is recorded for assertions.
    actor ScriptedFrontend: DebugFrontend {
        nonisolated let modes: [StepMode]
        private var index = 0
        private(set) var pauses: [PauseInfo] = []
        private(set) var ended = false
        private(set) var endError: Error?

        init(modes: [StepMode]) { self.modes = modes }

        nonisolated func didPause(_ pause: PauseInfo, controller: DebugController) async -> StepMode {
            await record(pause)
        }

        private func record(_ pause: PauseInfo) -> StepMode {
            pauses.append(pause)
            let mode = index < modes.count ? modes[index] : .continue
            index += 1
            return mode
        }

        nonisolated func didEnd(error: Error?) async {
            await finish(error)
        }
        private func finish(_ error: Error?) {
            ended = true
            endError = error
        }

        func snapshot() -> (pauses: [PauseInfo], ended: Bool) { (pauses, ended) }
    }

    /// A minimal program that compiles and runs `n` `Log` statements so the
    /// controller has well-defined statement boundaries to hit.
    private func runLogProgram(statements: Int, frontend: ScriptedFrontend) async throws {
        var body = "(Application-Start: Probe) {\n"
        for i in 0..<statements {
            body += "    Log \"line-\(i)\" to the <console>.\n"
        }
        body += "    Return an <OK: status> for the <application>.\n}\n"

        let compiler = Compiler()
        let result = compiler.compile(body)
        guard result.isSuccess else {
            XCTFail("compile failed: \(result.diagnostics)")
            return
        }

        let app = Application(
            programs: [result.analyzedProgram],
            entryPoint: "Application-Start",
            config: ApplicationConfig(verbose: false, workingDirectory: "."),
            openAPISpec: nil,
            recordPath: nil,
            replayPath: nil,
            storeFiles: []
        )

        let controller = DebugController(frontend: frontend)
        try await Debug.$controller.withValue(controller) {
            try await Debug.$currentSourceFile.withValue("probe.aro") {
                _ = try await app.run()
            }
        }
        await controller.didEnd(error: nil)
    }

    // MARK: - Tests

    func testPausesAtEveryStatementWhenStepping() async throws {
        // 3 Log + 1 Return = 4 statements; step at each.
        let frontend = ScriptedFrontend(modes: Array(repeating: .stepOver, count: 8))
        try await runLogProgram(statements: 3, frontend: frontend)

        let pauses = await frontend.pauses
        XCTAssertGreaterThanOrEqual(pauses.count, 4)
        XCTAssertEqual(pauses.first?.reason, .entry)
        for pause in pauses.dropFirst() {
            XCTAssertEqual(pause.reason, .step)
        }
    }

    func testContinueSkipsPausesUntilBreakpoint() async throws {
        // Reply `continue` to every pause; the entry pause still fires once.
        let frontend = ScriptedFrontend(modes: Array(repeating: .continue, count: 8))
        try await runLogProgram(statements: 5, frontend: frontend)

        let pauses = await frontend.pauses
        XCTAssertEqual(pauses.count, 1, "only the entry pause should fire")
        XCTAssertEqual(pauses[0].reason, .entry)
    }

    func testVerbBreakpointMatches() async throws {
        // Run with continue, but a `Log` verb breakpoint should re-pause
        // every Log statement.
        actor BreakingFrontend: DebugFrontend {
            private(set) var pauses: [PauseInfo] = []
            nonisolated func didPause(_ pause: PauseInfo, controller: DebugController) async -> StepMode {
                await record(pause)
                return .continue
            }
            private func record(_ pause: PauseInfo) { pauses.append(pause) }
            nonisolated func didEnd(error: Error?) async {}
            func get() -> [PauseInfo] { pauses }
        }
        let frontend = BreakingFrontend()
        let controller = DebugController(frontend: frontend)
        await controller.addBreakpoint(.verb("Log"))

        let body = """
        (Application-Start: Probe) {
            Log "a" to the <console>.
            Log "b" to the <console>.
            Return an <OK: status> for the <application>.
        }
        """
        let result = Compiler().compile(body)
        XCTAssertTrue(result.isSuccess)

        let app = Application(
            programs: [result.analyzedProgram],
            entryPoint: "Application-Start",
            config: ApplicationConfig(verbose: false, workingDirectory: "."),
            openAPISpec: nil,
            recordPath: nil,
            replayPath: nil,
            storeFiles: []
        )

        try await Debug.$controller.withValue(controller) {
            try await Debug.$currentSourceFile.withValue("probe.aro") {
                _ = try await app.run()
            }
        }

        let allPauses = await frontend.get()
        let logPauses = allPauses.filter { $0.verb == "Log" }
        XCTAssertGreaterThanOrEqual(logPauses.count, 2)
    }

    func testNoControllerNoOverhead() async throws {
        // Sanity: without a TaskLocal controller bound, the hook is a no-op
        // and the program runs to completion without surprises.
        let body = "(Application-Start: Probe) { Return an <OK: status> for the <application>. }\n"
        let result = Compiler().compile(body)
        XCTAssertTrue(result.isSuccess)
        let app = Application(
            programs: [result.analyzedProgram],
            entryPoint: "Application-Start",
            config: ApplicationConfig(verbose: false, workingDirectory: "."),
            openAPISpec: nil,
            recordPath: nil,
            replayPath: nil,
            storeFiles: []
        )
        let response = try await app.run()
        XCTAssertEqual(response.status, "OK")
    }

    func testSymbolSnapshotIncludesUserBindings() async throws {
        actor CapturingFrontend: DebugFrontend {
            private(set) var allSymbols: [String] = []
            nonisolated func didPause(_ pause: PauseInfo, controller: DebugController) async -> StepMode {
                await append(pause.symbols.map(\.name))
                return .stepOver
            }
            private func append(_ names: [String]) { allSymbols.append(contentsOf: names) }
            nonisolated func didEnd(error: Error?) async {}
            func get() -> [String] { allSymbols }
        }
        let frontend = CapturingFrontend()
        let controller = DebugController(frontend: frontend)

        let body = """
        (Application-Start: Probe) {
            Create the <greeting: String> with "hi".
            Log <greeting> to the <console>.
            Return an <OK: status> for the <application>.
        }
        """
        let result = Compiler().compile(body)
        let app = Application(
            programs: [result.analyzedProgram],
            entryPoint: "Application-Start",
            config: ApplicationConfig(verbose: false, workingDirectory: "."),
            openAPISpec: nil,
            recordPath: nil,
            replayPath: nil,
            storeFiles: []
        )
        try await Debug.$controller.withValue(controller) {
            _ = try await app.run()
        }
        let observed = await frontend.get()
        XCTAssertTrue(observed.contains("greeting"))
    }

    // MARK: - Issue #230 follow-up coverage

    /// `.quit` from the frontend must surface as a thrown `DebuggerQuit`
    /// from the next checkpoint — not as `Foundation.exit(0)`.
    func testQuitThrowsDebuggerQuit() async throws {
        // Quit on the very first pause (entry).
        let frontend = ScriptedFrontend(modes: [.quit])
        let body = """
        (Application-Start: Probe) {
            Log "a" to the <console>.
            Log "b" to the <console>.
            Return an <OK: status> for the <application>.
        }
        """
        let result = Compiler().compile(body)
        XCTAssertTrue(result.isSuccess)
        let app = Application(
            programs: [result.analyzedProgram],
            entryPoint: "Application-Start",
            config: ApplicationConfig(verbose: false, workingDirectory: "."),
            openAPISpec: nil,
            recordPath: nil,
            replayPath: nil,
            storeFiles: []
        )
        let controller = DebugController(frontend: frontend)

        do {
            try await Debug.$controller.withValue(controller) {
                _ = try await app.run()
            }
            XCTFail("expected DebuggerQuit to throw")
        } catch is DebuggerQuit {
            // expected
        }
    }

    /// Conditional predicates evaluate against the live ExecutionContext,
    /// not against the snapshot strings.
    func testConditionalPredicateAgainstLiveContext() async throws {
        actor CapturingFrontend: DebugFrontend {
            private(set) var pauses: [PauseInfo] = []
            nonisolated func didPause(_ pause: PauseInfo, controller: DebugController) async -> StepMode {
                await record(pause)
                return .continue
            }
            private func record(_ p: PauseInfo) { pauses.append(p) }
            nonisolated func didEnd(error: Error?) async {}
            func get() -> [PauseInfo] { pauses }
        }
        let frontend = CapturingFrontend()
        let controller = DebugController(frontend: frontend)
        // After line 2 binds <count> = 41, the checkpoint on line 3 runs
        // with <count> already in scope. Predicate is true only when the
        // live ExecutionContext resolves <count> as an Integer equal to
        // 41 — the snapshot-string fallback can't satisfy this because
        // the snapshot stringifies the value without parsing it as Int.
        await controller.addBreakpoint(.conditionalLocation(file: "", line: 3, predicate: "<count> == 41"))

        let body = """
        (Application-Start: Probe) {
            Create the <count: Integer> with 41.
            Log <count> to the <console>.
            Return an <OK: status> for the <application>.
        }
        """
        let result = Compiler().compile(body)
        XCTAssertTrue(result.isSuccess)
        let app = Application(
            programs: [result.analyzedProgram],
            entryPoint: "Application-Start",
            config: ApplicationConfig(verbose: false, workingDirectory: "."),
            openAPISpec: nil,
            recordPath: nil,
            replayPath: nil,
            storeFiles: []
        )
        try await Debug.$controller.withValue(controller) {
            try await Debug.$currentSourceFile.withValue("probe.aro") {
                _ = try await app.run()
            }
        }
        // Predicate is true exactly once — at line 3 after Create binds 41.
        let allPauses = await frontend.get()
        let breakpointPauses = allPauses.filter {
            if case .breakpoint = $0.reason { return true } else { return false }
        }
        XCTAssertEqual(breakpointPauses.count, 1, "expected exactly one conditional bp hit on line 3")
    }
}
