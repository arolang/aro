// ============================================================
// EmitPayloadMemoizationTests.swift
// Issue #55 follow-up — bus-side payload memoization for Emit.
// ============================================================
//
// "Resolved Emit semantics" from the issue plan: payload values are
// captured as AROFutures (not forced), so the first handler that reads
// a field forces it; AROFuture.ResultStorage memoizes the result for
// every other handler. These tests pin the behaviour at the EmitAction
// + EventBus seam so a regression to eager bind would fail loudly.

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

    /// EmitAction must capture the AROFuture in DomainEvent.payload, NOT the
    /// materialized string. This is the "force at first handler read"
    /// guarantee — without it the future would be resolved at emit time.
    func testEmitCapturesUnforcedFutureInDomainEventPayload() async throws {
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
        XCTAssertTrue(
            event?.payload["user"] is AROFuture,
            "Emit must store the AROFuture, not its forced result"
        )
    }

    /// Emit + handler chain: the producer should run exactly once even when
    /// many handlers extract the same payload field. AROFuture's
    /// ResultStorage memoizes after first force.
    func testProducerRunsOnceAcrossManyHandlerForces() async throws {
        let bus = EventBus()
        let totalHandlers = 8
        let observed = AtomicCounter()
        for _ in 0..<totalHandlers {
            bus.subscribe(to: DomainEvent.self) { event in
                guard let payloadFuture = event.payload["user"] as? AROFuture else {
                    XCTFail("Expected AROFuture in payload, got \(type(of: event.payload["user"] as Any))")
                    return
                }
                _ = try? await payloadFuture.value()
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
        XCTAssertEqual(runCount.value, 1, "Producer must run exactly once thanks to memoization")
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
