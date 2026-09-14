// ============================================================
// EventBreakpointTests.swift
// ARO Runtime - `be <Event>` event breakpoints (GitLab #557)
// ============================================================
//
// Three things stopped an event breakpoint from ever firing on the only kind of
// event an ARO program emits:
//
//   1. `eventCheckpoint` was called from `EventBus.publish(_:)` alone, and an
//      `Emit` goes through `publishAndTrack`. `publishAndWait` and
//      `publishInternalBackpressured` had no hook either.
//   2. The hook matched `type(of: event).eventType`. Every `Emit` produces a
//      `DomainEvent`, whose static `eventType` is the routing prefix "domain",
//      so every user event was compared against one constant — while handler
//      routing compared the instance's `domainEventType`.
//   3. The pause carried `featureSetName: ""` / `businessActivity: ""`, so a
//      matching pause named the event but never where the `Emit` was.
//
// These run a real program, so they cover the wiring rather than the hook in
// isolation: a pass means the pause actually happened on the `Emit` path.

import XCTest
import AROParser
@testable import ARORuntime

final class EventBreakpointTests: XCTestCase {

    // MARK: - Helpers

    /// Records every pause, always continues, and notes whether a handler ran
    /// before the pause was delivered.
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
        func eventPauses() -> [PauseInfo] {
            pauses.filter { if case .event = $0.reason { return true } else { return false } }
        }
    }

    /// A program that emits `NumberTriggered` and handles it.
    private static let emitProgram = """
    (Application-Start: Event Probe) {
        Create the <n> with 42.
        Emit a <NumberTriggered: event> with <n>.
        Return an <OK: status> for the <application>.
    }

    (Note It: NumberTriggered Handler) {
        Log "handled" to the <console>.
        Return an <OK: status> for the <note>.
    }
    """

    private func run(
        _ source: String,
        breakpoints: [DebugBreakpoint],
        frontend: RecordingFrontend
    ) async throws {
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

        try await Debug.$controller.withValue(controller) {
            try await Debug.$currentSourceFile.withValue("probe.aro") {
                _ = try await app.run()
            }
        }
        await controller.didEnd(error: nil)
    }

    // MARK: - The bug

    func testEventBreakpointFiresOnAnEmit() async throws {
        let frontend = RecordingFrontend()
        try await run(Self.emitProgram,
                      breakpoints: [.event("NumberTriggered")],
                      frontend: frontend)

        let events = await frontend.eventPauses()
        XCTAssertEqual(events.count, 1, "the Emit should have paused exactly once")
        XCTAssertEqual(events.first?.reason, .event("NumberTriggered"))
    }

    func testEventBreakpointIsAttributedToTheEmittingStatement() async throws {
        let frontend = RecordingFrontend()
        try await run(Self.emitProgram,
                      breakpoints: [.event("NumberTriggered")],
                      frontend: frontend)

        let pause = await frontend.eventPauses().first
        // Was "" / "" before, so the banner had no context at all.
        XCTAssertEqual(pause?.featureSetName, "Application-Start")
        XCTAssertEqual(pause?.businessActivity, "Event Probe")
        XCTAssertEqual(pause?.file, "probe.aro")
        XCTAssertEqual(pause?.line, 3, "the Emit is on line 3")
        XCTAssertEqual(pause?.verb, "Emit")
    }

    // MARK: - Matching

    func testANonMatchingEventNameDoesNotPause() async throws {
        let frontend = RecordingFrontend()
        try await run(Self.emitProgram,
                      breakpoints: [.event("SomeOtherEvent")],
                      frontend: frontend)

        let events = await frontend.eventPauses()
        XCTAssertTrue(events.isEmpty)
    }

    func testTheStaticEventTypeIsNotWhatMatches() {
        // The shape of the bug: two different user events share one static
        // type, so matching on it made every Emit look identical.
        let a = DomainEvent(eventType: "NumberTriggered", payload: [:])
        let b = DomainEvent(eventType: "SomethingElse", payload: [:])

        XCTAssertEqual(type(of: a).eventType, type(of: b).eventType)
        XCTAssertEqual(type(of: a).eventType, "domain")
        XCTAssertNotEqual(a.eventName, b.eventName)
        XCTAssertEqual(a.eventName, "NumberTriggered")
    }

    func testEventNameAgreesWithWhatRoutingMatches() {
        // Routing compares `event.domainEventType == eventType` in
        // FeatureSetExecutor and ExecutionEngine. A breakpoint must match the
        // same string, or it can only ever disagree with the handlers.
        let event = DomainEvent(eventType: "OrderPlaced", payload: [:])
        XCTAssertEqual(event.eventName, event.domainEventType)
    }

    func testOtherEventsKeepTheStaticTypeAsTheirName() {
        // The protocol default: an event with no instance-level name is
        // matched exactly as it always was.
        struct Plain: RuntimeEvent {
            static var eventType: String { "PlainThing" }
            let timestamp = Date()
        }
        XCTAssertEqual(Plain().eventName, "PlainThing")
        XCTAssertEqual(Plain().eventName, Plain.eventType)
    }

    // MARK: - No breakpoint, no pause

    func testNoEventBreakpointMeansNoEventPause() async throws {
        let frontend = RecordingFrontend()
        try await run(Self.emitProgram, breakpoints: [], frontend: frontend)

        let events = await frontend.eventPauses()
        XCTAssertTrue(events.isEmpty)
    }
}
