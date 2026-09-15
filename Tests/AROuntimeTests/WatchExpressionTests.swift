// ============================================================
// WatchExpressionTests.swift
// ARO Runtime - watches resolve like breakpoint predicates (GitLab #567)
// ============================================================
//
// `CLIDebugFrontend.didPause` resolved a watch by exact string match against
// the pause snapshot:
//
//     let resolved = pause.symbols.first { "<\($0.name)>" == w }?.valuePreview
//                    ?? "(unresolved)"
//
// A snapshot entry's `name` is the bare binding name, so anything carrying a
// qualifier — `<user: id>`, `<users-repository: count>` — could never match and
// printed `(unresolved)` at every pause. There was no diagnostic either: `w
// <user: id>` was accepted and confirmed with `watching: <user: id>`.
//
// Conditional breakpoints already evaluate arbitrary ARO expressions against
// the live context. Watches now go through that same evaluator, so a watch
// accepts exactly what `b 5 if …` accepts.

import XCTest
import AROParser
@testable import ARORuntime

final class WatchExpressionTests: XCTestCase {

    /// Records the watch lines the frontend would print at each pause.
    actor WatchRecordingFrontend: DebugFrontend {
        private(set) var perPause: [[(expression: String, value: String)]] = []
        private var controller: DebugController?

        nonisolated func didPause(_ pause: PauseInfo, controller: DebugController) async -> StepMode {
            let resolved = await controller.resolvedWatches(pause: pause)
            await record(resolved)
            return .stepOver
        }
        private func record(_ watches: [(expression: String, value: String)]) {
            perPause.append(watches)
        }
        nonisolated func didEnd(error: Error?) async {}

        /// The last value each expression resolved to across all pauses.
        func lastValues() -> [String: String] {
            var out: [String: String] = [:]
            for pause in perPause {
                for w in pause { out[w.expression] = w.value }
            }
            return out
        }
    }

    private func run(
        _ source: String,
        watches: [String],
        frontend: WatchRecordingFrontend
    ) async {
        let result = Compiler().compile(source)
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
        for w in watches { await controller.addWatch(w) }

        try? await Debug.$controller.withValue(controller) {
            try await Debug.$currentSourceFile.withValue("probe.aro") {
                _ = try await app.run()
            }
        }
        await controller.didEnd(error: nil)
    }

    private static let program = """
    (Application-Start: Watch Demo) {
        Create the <user> with { id: 530, name: "Ada" }.
        Create the <limit> with 100.
        Log "one" to the <console>.
        Log "two" to the <console>.
        Return an <OK: status> for the <application>.
    }
    """

    // MARK: - The bug

    func testAQualifiedWatchResolves() async {
        let frontend = WatchRecordingFrontend()
        await run(Self.program, watches: ["<user: id>"], frontend: frontend)

        // Was "(unresolved)" at every pause, forever.
        let values = await frontend.lastValues()
        XCTAssertEqual(values["<user: id>"], "530")
    }

    func testAQualifiedStringFieldResolves() async {
        let frontend = WatchRecordingFrontend()
        await run(Self.program, watches: ["<user: name>"], frontend: frontend)

        let values = await frontend.lastValues()
        XCTAssertEqual(values["<user: name>"], "Ada")
    }

    // MARK: - A bare name still works

    func testABareWatchStillResolves() async {
        let frontend = WatchRecordingFrontend()
        await run(Self.program, watches: ["<limit>"], frontend: frontend)

        let values = await frontend.lastValues()
        XCTAssertEqual(values["<limit>"], "100")
    }

    // MARK: - Anything a conditional breakpoint accepts

    func testAnExpressionWatchResolves() async {
        // The issue's point: routing watches through the predicate evaluator
        // makes comparisons work as a side effect, not just qualifiers.
        let frontend = WatchRecordingFrontend()
        await run(Self.program, watches: ["<limit> > 50"], frontend: frontend)

        let values = await frontend.lastValues()
        XCTAssertEqual(values["<limit> > 50"], "true")
    }

    func testRepositoryNavigationResolves() async {
        let frontend = WatchRecordingFrontend()
        await run("""
        (Application-Start: Watch Repo) {
            Create the <a> with { id: 1 }.
            Store the <a> into the <watch567-repository>.
            Log "one" to the <console>.
            Return an <OK: status> for the <application>.
        }
        """, watches: ["<watch567-repository: count>"], frontend: frontend)

        let values = await frontend.lastValues()
        XCTAssertEqual(values["<watch567-repository: count>"], "1")
    }

    // MARK: - Failure stays quiet rather than crashing the program

    func testAnUnbindableWatchIsUnresolvedNotFatal() async {
        let frontend = WatchRecordingFrontend()
        await run(Self.program, watches: ["<nope: missing>"], frontend: frontend)

        // A debugger expression must never take the program down with it.
        let values = await frontend.lastValues()
        XCTAssertNotNil(values["<nope: missing>"])
    }

    func testNonsenseIsUnresolvedNotFatal() async {
        let frontend = WatchRecordingFrontend()
        await run(Self.program, watches: ["<<< not an expression"], frontend: frontend)

        let values = await frontend.lastValues()
        XCTAssertEqual(values["<<< not an expression"], "(unresolved)")
    }

    // MARK: - The value renderer

    func testALongValueIsTruncatedForOneConsoleLine() {
        let long = String(repeating: "x", count: 500)
        let rendered = DebugController.renderWatchValue(long)

        XCTAssertLessThan(rendered.count, 130)
        XCTAssertTrue(rendered.hasSuffix("…"))
    }

    func testAShortValueIsNotTruncated() {
        XCTAssertEqual(DebugController.renderWatchValue(530), "530")
        XCTAssertEqual(DebugController.renderWatchValue("Ada"), "Ada")
    }
}
