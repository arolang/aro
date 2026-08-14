// ============================================================
// EmitPayloadMemoizationTests.swift
// Issue #55 follow-up — bus-side payload memoization for Emit.
// ============================================================
//
// CONTRACT CHANGED by ARO-0088 (GitLab #485). Issue #55's "Resolved Emit
// semantics" captured payload values as unforced AROFutures so the first
// handler to read a field forced it. Under ARO-0088 an effect forces its
// inputs at its own statement, and `Emit` is an effect — so the payload is
// forced at the emitting statement instead.
//
// The reason is containment, not tidiness. Once actions genuinely defer, an
// unforced handle placed in a payload escapes the runtime that created it:
// ten separate sites bind `event` into a handler context, and payloads are
// also serialised to JSON, written to sockets, and recorded for replay. Every
// one of those would have to learn to unwrap a handle.
//
// What these tests still pin is the guarantee that mattered: the producer runs
// **exactly once** no matter how many handlers read the payload, and every
// handler observes it.

import XCTest
@testable import ARORuntime
import AROParser

final class EmitPayloadMemoizationTests: XCTestCase {

    /// resolveAnyRaw returns the AROFuture itself; resolveAny would auto-force.
    /// This is the primitive EmitAction relies on.
    func testResolveAnyRawReturnsUnforcedFuture() throws {
        let ctx = RuntimeContext(featureSetName: "Test")
        let future = AROFuture(resolved: "payload-value" as String, bindingName: "payload")
        ctx.bind("payload", value: future)

        let raw = ctx.resolveAnyRaw("payload")
        XCTAssertTrue(raw is AROFuture, "resolveAnyRaw must not unwrap AROFuture")

        // Sanity: resolveAny still forces.
        XCTAssertEqual(ctx.resolveAny("payload") as? String, "payload-value")
    }

    /// EmitAction materializes the payload at the emitting statement, so a
    /// handler receives a value rather than a handle it would have to force.
    func testEmitMaterializesPayloadInDomainEventPayload() async throws {
        let bus = EventBus()
        let captured = AtomicBox<DomainEvent>()
        bus.subscribe(to: DomainEvent.self) { event in
            captured.set(event)
        }
        let ctx = RuntimeContext(
            featureSetName: "Application-Start",
            businessActivity: "App",
            eventBus: bus
        )

        let future = AROFuture(bindingName: "user") {
            return ["id": 42, "name": "alice"] as [String: any Sendable]
        }
        ctx.bind("user", value: future)
        // Mimic the FeatureSetExecutor's setup for a variable-reference Emit.
        ctx.bind("_expression_name_", value: "user")

        let span = SourceSpan(at: SourceLocation())
        let emit = EmitAction()
        let result = ResultDescriptor(base: "UserCreated", specifiers: ["event"], span: span)
        let object = ObjectDescriptor(preposition: .with, base: "user", specifiers: [], span: span)
        _ = try await emit.execute(result: result, object: object, context: ctx)

        let event = captured.value
        XCTAssertNotNil(event, "DomainEvent must reach the subscriber")
        XCTAssertFalse(
            event?.payload["user"] is AROFuture,
            "Emit must materialize the payload, not hand a handle to the bus"
        )
        let payload = event?.payload["user"] as? [String: any Sendable]
        XCTAssertEqual(payload?["id"] as? Int, 42)
        XCTAssertEqual(payload?["name"] as? String, "alice")
    }

    /// Emit + handler chain: the producer runs exactly once no matter how many
    /// handlers read the payload field. The mechanism moved (forced once at the
    /// emitting statement rather than once at first handler read); the guarantee
    /// did not.
    func testProducerRunsOnceAcrossManyHandlerForces() async throws {
        let bus = EventBus()
        let totalHandlers = 8
        let observed = AtomicCounter()
        for _ in 0..<totalHandlers {
            bus.subscribe(to: DomainEvent.self) { event in
                guard let value = event.payload["user"] as? String else {
                    XCTFail("Expected a materialized payload, got \(type(of: event.payload["user"] as Any))")
                    return
                }
                XCTAssertEqual(value, "alice")
                observed.increment()
            }
        }

        let ctx = RuntimeContext(
            featureSetName: "Application-Start",
            businessActivity: "App",
            eventBus: bus
        )

        let runCount = AtomicCounter()
        let future = AROFuture(bindingName: "user") {
            runCount.increment()
            try await Task.sleep(nanoseconds: 5_000_000) // small delay so concurrent forces overlap
            return "alice" as String
        }
        ctx.bind("user", value: future)
        ctx.bind("_expression_name_", value: "user")

        let span = SourceSpan(at: SourceLocation())
        let emit = EmitAction()
        let result = ResultDescriptor(base: "UserCreated", specifiers: ["event"], span: span)
        let object = ObjectDescriptor(preposition: .with, base: "user", specifiers: [], span: span)
        _ = try await emit.execute(result: result, object: object, context: ctx)

        // publishAndTrack waits for handlers, so all forces have happened.
        XCTAssertEqual(observed.value, totalHandlers, "Every handler should have observed the payload")
        XCTAssertEqual(runCount.value, 1, "Producer must run exactly once for the whole fan-out")
    }

    /// Object-literal Emit (`with { key: value }`) is unchanged: the dict is
    /// spread directly, no AROFuture indirection. Pin so a future refactor
    /// doesn't accidentally box dict literals.
    func testObjectLiteralEmitDoesNotWrapValuesInFuture() async throws {
        let bus = EventBus()
        let captured = AtomicBox<DomainEvent>()
        bus.subscribe(to: DomainEvent.self) { event in
            captured.set(event)
        }
        let ctx = RuntimeContext(
            featureSetName: "Application-Start",
            businessActivity: "App",
            eventBus: bus
        )
        ctx.bind(
            "_expression_",
            value: ["status": "ok", "code": 200] as [String: any Sendable]
        )
        ctx.bind("_expression_name_", value: "")

        let span = SourceSpan(at: SourceLocation())
        let emit = EmitAction()
        let result = ResultDescriptor(base: "OperationDone", specifiers: ["event"], span: span)
        let object = ObjectDescriptor(preposition: .with, base: "_expression_", specifiers: [], span: span)
        _ = try await emit.execute(result: result, object: object, context: ctx)

        let event = captured.value
        XCTAssertEqual(event?.payload["status"] as? String, "ok")
        XCTAssertEqual(event?.payload["code"] as? Int, 200)
        XCTAssertFalse(event?.payload["status"] is AROFuture, "Literal dict values must not be wrapped")
    }
}

// MARK: - Test helpers

private final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int = 0
    func increment() { lock.withLock { _value += 1 } }
    var value: Int { lock.withLock { _value } }
}

private final class AtomicBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?
    func set(_ v: T) { lock.withLock { _value = v } }
    var value: T? { lock.withLock { _value } }
}
