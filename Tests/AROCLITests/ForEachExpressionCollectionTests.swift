// ============================================================
// ForEachExpressionCollectionTests.swift
// AROCLI — for-each over expression collections (GitLab #519)
// ============================================================
//
// The collection slot used to accept only `<name>`, so `for each <n>
// in [1, 2, 3]` did not parse and every quick loop needed a Create
// first. These tests pin what the loop actually iterates for each
// header shape — parsing alone would not catch a collection that is
// evaluated per iteration, or one that iterates the wrong elements.
//
// Each case accumulates into its own repository because loop bodies
// run in child contexts: a binding made inside the body is gone by
// the time the loop ends, and a repository is the ordinary ARO way
// for a loop to leave something behind.

import Testing
import Foundation
import ARORuntime
@testable import AROCLI

@Suite("For-each expression collections", .serialized)
struct ForEachExpressionCollectionRuntimeTests {

    private func run(_ statements: String...) async throws -> (REPLSession, [REPLResult]) {
        let session = REPLSession()
        var results: [REPLResult] = []
        for statement in statements {
            results.append(try await session.executeStatement(statement))
        }
        return (session, results)
    }

    private func ints(_ value: (any Sendable)?) -> [Int] {
        guard let array = value as? [any Sendable] else { return [] }
        return array.compactMap { $0 as? Int }
    }

    private func strings(_ value: (any Sendable)?) -> [String] {
        guard let array = value as? [any Sendable] else { return [] }
        return array.compactMap { $0 as? String }
    }

    @Test("A list literal iterates its elements, in order")
    func listLiteral() async throws {
        let (session, results) = try await run(
            "for each <n> in [1, 2, 3] { Store the <n> to the <lit519-repository>. }",
            "Retrieve the <seen> from the <lit519-repository>."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(ints(session.getVariable("seen")) == [1, 2, 3])
    }

    @Test("parallel for each takes a list literal and sees every element")
    func parallelListLiteral() async throws {
        let (session, results) = try await run(
            "parallel for each <n> in [1, 2, 3, 4] { Store the <n> to the <par519-repository>. }",
            "Retrieve the <seen> from the <par519-repository>."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        // Parallel iteration does not promise an order — only the set (ARO-0088).
        #expect(ints(session.getVariable("seen")).sorted() == [1, 2, 3, 4])
    }

    @Test("A bound variable collection still works unchanged")
    func boundVariable() async throws {
        let (session, results) = try await run(
            "Create the <items> with [7, 8].",
            "for each <n> in <items> { Store the <n> to the <var519-repository>. }",
            "Retrieve the <seen> from the <var519-repository>."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(ints(session.getVariable("seen")) == [7, 8])
    }

    @Test("A qualified noun still reaches the field, not the record")
    func qualifiedNoun() async throws {
        let (session, results) = try await run(
            #"Create the <team> with { members: ["ann", "bo"] }."#,
            "for each <m> in <team: members> { Store the <m> to the <spec519-repository>. }",
            "Retrieve the <seen> from the <spec519-repository>."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(strings(session.getVariable("seen")) == ["ann", "bo"])
    }

    @Test("Dotted field access iterates the field")
    func memberAccess() async throws {
        let (session, results) = try await run(
            #"Create the <squad> with { members: ["cy", "di"] }."#,
            "for each <m> in <squad>.members { Store the <m> to the <dot519-repository>. }",
            "Retrieve the <seen> from the <dot519-repository>."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(strings(session.getVariable("seen")) == ["cy", "di"])
    }

    @Test("Elements of a list literal are themselves expressions")
    func literalWithVariableElement() async throws {
        let (session, results) = try await run(
            "Create the <base> with 5.",
            "for each <n> in [<base>, 6] { Store the <n> to the <mix519-repository>. }",
            "Retrieve the <seen> from the <mix519-repository>."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(ints(session.getVariable("seen")) == [5, 6])
    }

    @Test("where and at still apply to an expression collection")
    func filterAndIndex() async throws {
        let (session, results) = try await run(
            "for each <n> at <i> in [1, 2, 3] where <n> > 1 { Store the <n> to the <filt519-repository>. }",
            "Retrieve the <seen> from the <filt519-repository>."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(ints(session.getVariable("seen")) == [2, 3])
    }

    @Test("A nested loop re-enters its expression collection each time round")
    func nestedLoops() async throws {
        let (session, results) = try await run(
            // Products are kept distinct: a repository stores each value once.
            "for each <o> in [1, 2] { for each <i> in [10, 100] { Compute the <p> from <o> * <i>. Store the <p> to the <nest519-repository>. } }",
            "Retrieve the <seen> from the <nest519-repository>."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(ints(session.getVariable("seen")) == [10, 100, 20, 200])
    }
}
