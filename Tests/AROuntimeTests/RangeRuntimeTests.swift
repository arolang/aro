// ============================================================
// RangeRuntimeTests.swift
// ARORuntime — ranges, executed (ARO-0089, GitLab #546)
// ============================================================
//
// `RangeTests` in AROParserTests proves the spelling parses. These prove it
// counts: both ends included, nothing at all for a descending span, and the
// `for each` collection slot driving a loop straight off the two endpoints
// instead of a materialised list.
//
// `AROIntRange` is asserted directly as well as through programs, because it
// is the one piece of range arithmetic both execution modes share — the
// interpreter calls it from `ExpressionEvaluator`, the compiled binary calls
// it from the C-ABI bridge. If the two modes are ever to disagree about what
// `1->10` contains, it has to start here.

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

@Suite("Ranges, executed (ARO-0089, #546)", .serialized)
struct RangeRuntimeTests {

    private func run(_ source: String) async throws -> Response {
        let result = Compiler().compile(source)
        #expect(result.diagnostics.allSatisfy { $0.severity != .error },
                "unexpected errors: \(result.diagnostics.map(\.message))")
        let engine = ExecutionEngine()
        return try await engine.execute(result.analyzedProgram)
    }

    /// The Int a program returned under `<value>`. `AnySendable.get()` is
    /// generic, so asking for a String back would answer nil for the very
    /// values a range produces.
    private func value(_ response: Response) -> Int? {
        if let i: Int = response.data["value"]?.get() { return i }
        if let s: String = response.data["value"]?.get() { return Int(s) }
        return nil
    }

    // MARK: - The span itself

    @Test("Both ends are included")
    func countsMatchTheSpelling() {
        #expect(AROIntRange(lower: 1, upper: 10).count == 10)
        #expect(AROIntRange(lower: 1, upper: 1).count == 1)
        #expect(AROIntRange(lower: 0, upper: 23).count == 24)
    }

    @Test("A descending range is empty, not reversed and not an error (§3.2)")
    func descendingIsEmpty() {
        let descending = AROIntRange(lower: 10, upper: 1)
        #expect(descending.count == 0)
        #expect(descending.isEmpty)
        #expect(descending.elements.isEmpty)
        #expect(descending.element(at: 0) == nil)
    }

    @Test("Elements are the span, in order")
    func elementsAreTheSpan() {
        #expect(AROIntRange(lower: 3, upper: 6).elements == [3, 4, 5, 6])
        #expect(AROIntRange(lower: -2, upper: 1).elements == [-2, -1, 0, 1])
    }

    @Test("`count` is arithmetic, so an unwalkable span still answers")
    func countDoesNotTraverse() {
        // No iteration happens here: this is `hi - lo + 1`, which is the
        // property that makes the for-each driver O(1) (§3.3).
        #expect(AROIntRange(lower: 1, upper: 1_000_000_000).count == 1_000_000_000)
        // And it clamps rather than trapping on a span wider than Int.
        #expect(AROIntRange(lower: Int.min, upper: Int.max).count == Int.max)
    }

    @Test("`element(at:)` is the index walk both for-each drivers use")
    func elementAtIndex() {
        let range = AROIntRange(lower: 5, upper: 9)
        #expect(range.element(at: 0) == 5)
        #expect(range.element(at: 4) == 9)
        #expect(range.element(at: 5) == nil)
        #expect(range.element(at: -1) == nil)
    }

    @Test("A range prints the way it was written")
    func descriptionIsTheSourceSpelling() {
        #expect(AROIntRange(lower: 1, upper: 10).description == "1->10")
        #expect(AROIntRange(lower: 0, upper: 23).description == "0->23")
    }

    // MARK: - In a program

    @Test("`Compute … length` answers the span's size")
    func lengthOfARange() async throws {
        let response = try await run("""
        (Application-Start: Demo) {
            Compute the <value: length> from 1->10.
            Return an <OK: status> with <value>.
        }
        """)
        #expect(value(response) == 10)
    }

    @Test("A zero-based span counts its upper endpoint too")
    func lengthOfAZeroBasedRange() async throws {
        let response = try await run("""
        (Application-Start: Demo) {
            Compute the <value: length> from 0->23.
            Return an <OK: status> with <value>.
        }
        """)
        #expect(value(response) == 24)
    }

    @Test("A range is a collection to the qualifiers that take one")
    func rangeFeedsACollectionQualifier() async throws {
        let response = try await run("""
        (Application-Start: Demo) {
            Compute the <value: sum> from 1->10.
            Return an <OK: status> with <value>.
        }
        """)
        #expect(value(response) == 55)
    }

    /// How many times a loop body ran, observed from outside the loop —
    /// an immutable binding cannot count for us, so each iteration stores a
    /// row and the rows are counted afterwards.
    ///
    /// `id` names a repository of this test's own: repository storage outlives
    /// one `ExecutionEngine`, so a shared name would have each test counting
    /// the rows of the tests before it. The seed row is what makes a loop that
    /// runs zero times distinguishable from a repository that was never
    /// written, which is a `Retrieve` error rather than an empty list.
    private func iterations(_ id: String, over header: String, body: String = "") async throws -> Int? {
        let response = try await run("""
        (Application-Start: Demo) {
            Create the <seed> with { n: 0 }.
            Store the <seed> into the <\(id)-repository>.
            \(header) {
                Create the <row> with { n: <n> }.
                Store the <row> into the <\(id)-repository>.
                \(body)
            }
            Retrieve the <rows> from the <\(id)-repository>.
            Compute the <stored: length> from <rows>.
            Compute the <value> from <stored> - 1.
            Return an <OK: status> with <value>.
        }
        """)
        return value(response)
    }

    @Test("`for each` over a range runs once per element")
    func forEachCountsIterations() async throws {
        #expect(try await iterations("inclusive-span", over: "for each <n> in 1->7") == 7)
    }

    @Test("A one-element range runs once")
    func forEachSingleElementRange() async throws {
        #expect(try await iterations("single-span", over: "for each <n> in 7->7") == 1)
    }

    @Test("A `where` filter applies to a range loop")
    func forEachWithFilter() async throws {
        // 3, 6 and 9 of 1->10.
        #expect(try await iterations(
            "filtered-span", over: "for each <n> in 1->10 where <n> % 3 == 0") == 3)
    }

    @Test("`Break` leaves a range loop (GitLab #664)")
    func breakLeavesARangeLoop() async throws {
        #expect(try await iterations(
            "broken-span", over: "for each <n> in 1->100", body: "Break.") == 1)
    }

    @Test("A descending range loop runs zero times")
    func descendingRangeLoopDoesNothing() async throws {
        #expect(try await iterations("descending-span", over: "for each <n> in 10->1") == 0)
    }

    @Test("`Return` inside a range loop ends the feature set (GitLab #665)")
    func returnInsideARangeLoop() async throws {
        let response = try await run("""
        (Application-Start: Demo) {
            for each <value> in 1->100 {
                Return an <OK: status> with <value>.
            }
            Return an <OK: status> with "never".
        }
        """)
        #expect(value(response) == 1)
    }

    @Test("Endpoints are expressions, evaluated once")
    func computedEndpoints() async throws {
        let response = try await run("""
        (Application-Start: Demo) {
            Create the <lo> with 3.
            Create the <hi> with 6.
            Compute the <value: length> from <lo>-><hi>.
            Return an <OK: status> with <value>.
        }
        """)
        #expect(value(response) == 4)
    }

    @Test("A non-Int endpoint fails the statement rather than counting something else")
    func stringEndpointFailsAtRuntime() async throws {
        // `aro check` catches the literal case; a variable holding a String
        // can only be caught here, and it must not be guessed at.
        let result = Compiler().compile("""
        (Application-Start: Demo) {
            Create the <hi> with "ten".
            Compute the <value: length> from 1-><hi>.
            Return an <OK: status> with <value>.
        }
        """)
        let engine = ExecutionEngine()
        await #expect(throws: (any Error).self) {
            _ = try await engine.execute(result.analyzedProgram)
        }
    }
}
