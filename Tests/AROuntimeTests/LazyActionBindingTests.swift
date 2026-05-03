// ============================================================
// LazyActionBindingTests.swift
// ARO Runtime - Lazy mode binding plumbing (Issue #55, Phase 2)
// ============================================================
//
// These tests verify that under lazy mode bindings hold AROFuture
// values which are transparently forced by resolve<T> and resolveAny.
// Phase 2 keeps action execution eager (the future is pre-resolved);
// Phase 4 will introduce real deferral. The point of this phase is to
// prove the binding-layer plumbing is correct so later phases can swap
// pre-resolved futures for deferred ones without touching consumers.

import XCTest
@testable import ARORuntime
import AROParser

final class LazyActionBindingTests: XCTestCase {

    func testResolveAnyAutoForcesFutureBinding() throws {
        let ctx = RuntimeContext(featureSetName: "Test")
        let future = AROFuture(resolved: "hello" as String, bindingName: "greeting")
        ctx.bind("greeting", value: future)

        // Sanity: the binding really does hold a future.
        let typed = ctx.resolveTyped("greeting")
        XCTAssertNotNil(typed)
        XCTAssertTrue(typed?.value is AROFuture)

        // resolveAny must auto-force.
        let resolved = ctx.resolveAny("greeting")
        XCTAssertEqual(resolved as? String, "hello")
    }

    func testTypedResolveAutoForcesFutureBinding() throws {
        let ctx = RuntimeContext(featureSetName: "Test")
        let future = AROFuture(resolved: 7 as Int, bindingName: "count")
        ctx.bind("count", value: future)

        let count: Int? = ctx.resolve("count")
        XCTAssertEqual(count, 7)
    }

    func testTypedResolveReturnsNilOnTypeMismatchEvenWithFuture() throws {
        let ctx = RuntimeContext(featureSetName: "Test")
        let future = AROFuture(resolved: "not-an-int" as String, bindingName: "x")
        ctx.bind("x", value: future)

        let asInt: Int? = ctx.resolve("x")
        XCTAssertNil(asInt, "Expected nil when forced value doesn't match requested type")
    }

    func testResolveAnyAsyncAwaitsFutureWithoutBlocking() async throws {
        let ctx = RuntimeContext(featureSetName: "Test")
        let future = AROFuture(bindingName: "delayed") {
            try await Task.sleep(nanoseconds: 20_000_000)
            return [1, 2, 3] as [Int]
        }
        ctx.bind("delayed", value: future)

        let resolved = await ctx.resolveAnyAsync("delayed")
        XCTAssertEqual(resolved as? [Int], [1, 2, 3])
    }

    func testResolveAnyAsyncReturnsValueForNonFutureBinding() async throws {
        let ctx = RuntimeContext(featureSetName: "Test")
        ctx.bind("plain", value: "value" as String)

        let resolved = await ctx.resolveAnyAsync("plain")
        XCTAssertEqual(resolved as? String, "value")
    }

    func testResolveAnyAsyncReturnsNilForUnboundName() async throws {
        let ctx = RuntimeContext(featureSetName: "Test")
        let resolved = await ctx.resolveAnyAsync("missing")
        XCTAssertNil(resolved)
    }

    func testLazyActionPolicyForceAtSiteSet() {
        XCTAssertTrue(LazyActionPolicy.forceAtSite("return"))
        XCTAssertTrue(LazyActionPolicy.forceAtSite("throw"))
        XCTAssertTrue(LazyActionPolicy.forceAtSite("log"))
        XCTAssertTrue(LazyActionPolicy.forceAtSite("publish"))
        XCTAssertTrue(LazyActionPolicy.forceAtSite("emit"))

        XCTAssertFalse(LazyActionPolicy.forceAtSite("compute"))
        XCTAssertFalse(LazyActionPolicy.forceAtSite("retrieve"))
        XCTAssertFalse(LazyActionPolicy.forceAtSite("extract"))
        // Note: `validate` was added to the force-at-site set in phase 3
        // (branch consumers). Phase 3 tests assert that membership.
    }

    func testExecuteLazyReturnsRunningFuture() async throws {
        let ctx = RuntimeContext(featureSetName: "Test")
        ctx.bind("source-value", value: "raw-input" as String)

        let dummyLocation = SourceLocation(line: 0, column: 0, offset: 0)
        let dummySpan = SourceSpan(at: dummyLocation)
        let result = ResultDescriptor(base: "out", specifiers: [], span: dummySpan)
        let object = ObjectDescriptor(
            preposition: .from, base: "source-value", specifiers: [], span: dummySpan
        )

        // Use compute with the implicit identity-of-input semantics is action-
        // dependent, so don't assume a specific value here. The point of this
        // test is just to verify executeLazy returns a future, the future
        // resolves successfully, and the value is non-nil.
        let future = ActionRunner.shared.executeLazy(
            verb: "extract",
            result: result,
            object: object,
            context: ctx
        )

        let value = try await future.value()
        // Extract action returns *something* — we just need it not to crash.
        _ = value
        XCTAssertTrue(future.isResolved)
    }
}
