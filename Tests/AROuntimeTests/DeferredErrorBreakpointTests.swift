// ============================================================
// DeferredErrorBreakpointTests.swift
// ARO Runtime - `berror` under ARO-0088 deferral (GitLab #561)
// ============================================================
//
// `errorCheckpoint` was fired only from `executeStatement`'s catch. Under
// ARO-0088 deferral a value-producing action that fails does not throw there —
// the `AROFuture` carries the failure, and it surfaces when the feature set
// drains. So `.errorAny` never matched, and `berror` — which the debugging
// guide bills as the breakpoint to reach for when you do not yet know *where*
// the bug is — silently did nothing for the majority of runtime failures. The
// only way to make it work was `ARO_NO_DEFER=1`.

import XCTest
import AROParser
@testable import ARORuntime

final class DeferredErrorBreakpointTests: XCTestCase {

    /// Records every pause and always continues.
    actor RecordingFrontend: DebugFrontend {
        private(set) var pauses: [PauseInfo] = []

        nonisolated func didPause(_ pause: PauseInfo, controller: DebugController) async -> StepMode {
            await record(pause)
        }
        private func record(_ pause: PauseInfo) -> StepMode {
            pauses.append(pause)
            return .continue
        }
        nonisolated func didEnd(error: Error?) async {}

        func errorPauses() -> [PauseInfo] {
            pauses.filter { if case .error = $0.reason { return true } else { return false } }
        }
    }

    /// A deferrable read that fails: `Read` produces a value, so ARO-0088
    /// defers it and the failure travels in the future rather than throwing at
    /// the statement.
    private static let failingProgram = """
    (Application-Start: Error Demo) {
        Create the <n> with 1.
        Read the <data> from "/nonexistent/definitely-not-here.json".
        Log <data> to the <console>.
        Return an <OK: status> for the <application>.
    }
    """

    private func run(
        _ source: String,
        breakpoints: [DebugBreakpoint],
        frontend: RecordingFrontend
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
        for bp in breakpoints { await controller.addBreakpoint(bp) }

        // The program is expected to fail; the pause is what is under test.
        try? await Debug.$controller.withValue(controller) {
            try await Debug.$currentSourceFile.withValue("probe.aro") {
                _ = try await app.run()
            }
        }
        await controller.didEnd(error: nil)
    }

    // MARK: - The bug

    func testErrorAnyFiresForADeferredFailure() async {
        let frontend = RecordingFrontend()
        await run(Self.failingProgram, breakpoints: [.errorAny], frontend: frontend)

        let errors = await frontend.errorPauses()
        XCTAssertEqual(errors.count, 1, "the deferred failure should have paused once")
    }

    func testThePauseNamesTheStatementThatCausedIt() async {
        let frontend = RecordingFrontend()
        await run(Self.failingProgram, breakpoints: [.errorAny], frontend: frontend)

        let pause = await frontend.errorPauses().first
        // Line 3 is the failing `Read`, not line 4 where the empty value was
        // read, nor 0. The line comes from the future's own sourceLocation.
        XCTAssertEqual(pause?.line, 3)
        XCTAssertEqual(pause?.featureSetName, "Application-Start")
        XCTAssertEqual(pause?.businessActivity, "Error Demo")
        XCTAssertEqual(pause?.file, "probe.aro")
    }

    func testTheMessageDescribesTheRealFailure() async {
        let frontend = RecordingFrontend()
        await run(Self.failingProgram, breakpoints: [.errorAny], frontend: frontend)

        guard case .error(let message)? = await frontend.errorPauses().first?.reason else {
            return XCTFail("expected an error pause")
        }
        XCTAssertTrue(message.contains("Cannot read the data"), message)
    }

    // MARK: - Matching

    func testNoErrorBreakpointMeansNoErrorPause() async {
        let frontend = RecordingFrontend()
        await run(Self.failingProgram, breakpoints: [], frontend: frontend)

        let errors = await frontend.errorPauses()
        XCTAssertTrue(errors.isEmpty)
    }

    func testAProgramThatDoesNotFailDoesNotPause() async {
        let frontend = RecordingFrontend()
        await run("""
        (Application-Start: Fine) {
            Create the <n> with 1.
            Log "ok" to the <console>.
            Return an <OK: status> for the <application>.
        }
        """, breakpoints: [.errorAny], frontend: frontend)

        let errors = await frontend.errorPauses()
        XCTAssertTrue(errors.isEmpty)
    }

    // MARK: - The non-deferred path still works

    func testErrorAnyStillFiresForAThrowingStatement() async {
        // `Sleep` is deliberately excluded from deferral (the delay *is* the
        // effect), so a failure on a non-deferrable verb still throws at the
        // statement and must keep reaching the same breakpoint.
        let frontend = RecordingFrontend()
        await run("""
        (Application-Start: Direct) {
            Retrieve the <x> from the <nope>.
            Return an <OK: status> for the <application>.
        }
        """, breakpoints: [.errorAny], frontend: frontend)

        let errors = await frontend.errorPauses()
        XCTAssertEqual(errors.count, 1, "a statement-thrown failure must still pause")
    }

    // MARK: - The recorded location

    func testTheRecordedLocationIsTheFuturesOwn() {
        let context = RuntimeContext(featureSetName: "Test")
        XCTAssertNil(context.deferredFailureLine)

        context.recordDeferredFailure(
            ActionError.runtimeError("boom"), binding: "x", sourceLocation: "7:5")
        XCTAssertEqual(context.deferredFailureLine, 7)

        // Only the first failure is kept, so the line stays the first one's.
        context.recordDeferredFailure(
            ActionError.runtimeError("later"), binding: "y", sourceLocation: "9:1")
        XCTAssertEqual(context.deferredFailureLine, 7)
    }

    func testAFailureWithNoLocationIsStillRecorded() {
        let context = RuntimeContext(featureSetName: "Test")
        context.recordDeferredFailure(ActionError.runtimeError("boom"), binding: "x")

        XCTAssertNil(context.deferredFailureLine, "no location means no line, not a crash")
        XCTAssertNotNil(context.takeDeferredFailure())
    }
}
