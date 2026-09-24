// ============================================================
// SortByFieldTests.swift
// AROCLI — field-based Sort on record lists (GitLab #491)
// ============================================================
//
// `Sort the <sorted> from the <users> by "score".` used to parse,
// run, and return the input untouched — an `aro check`-green
// program computing wrong results. These tests pin the new
// contract: record lists sort by the named field, and anything
// Sort cannot order is an error, never a pass-through.

import Testing
import Foundation
import ARORuntime
@testable import AROCLI

@Suite("Sort by field", .serialized)
struct SortByFieldTests {

    private func run(_ statements: String...) async throws -> (REPLSession, [REPLResult]) {
        let session = REPLSession()
        var results: [REPLResult] = []
        for statement in statements {
            results.append(try await session.executeStatement(statement))
        }
        return (session, results)
    }

    private func names(_ value: (any Sendable)?) -> [String] {
        ((value as? [any Sendable]) ?? [])
            .compactMap { ($0 as? [String: any Sendable])?["name"] as? String }
    }

    @Test("Numeric field sorts ascending — the issue's exact repro")
    func numericAscending() async throws {
        let (session, results) = try await run(
            #"Create the <users> with [{ name: "B", score: 2 }, { name: "A", score: 9 }, { name: "C", score: 5 }]."#,
            #"Sort the <sorted> from the <users> by "score"."#
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(names(session.getVariable("sorted")) == ["B", "C", "A"])
    }

    @Test("String field sorts lexicographically")
    func stringField() async throws {
        let (session, results) = try await run(
            #"Create the <users> with [{ name: "B", score: 2 }, { name: "A", score: 9 }, { name: "C", score: 5 }]."#,
            #"Sort the <sorted> from the <users> by "name"."#
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(names(session.getVariable("sorted")) == ["A", "B", "C"])
    }

    @Test("descending qualifier reverses the order")
    func descending() async throws {
        let (session, results) = try await run(
            #"Create the <users> with [{ name: "B", score: 2 }, { name: "A", score: 9 }, { name: "C", score: 5 }]."#,
            #"Sort the <sorted: descending> from the <users> by "score"."#
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(names(session.getVariable("sorted")) == ["A", "C", "B"])
    }

    @Test("Mixed Int and Double field values order numerically")
    func mixedNumerics() async throws {
        let (session, results) = try await run(
            #"Create the <items> with [{ name: "b", price: 2.5 }, { name: "a", price: 10 }, { name: "c", price: 2 }]."#,
            #"Sort the <sorted> from the <items> by "price"."#
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(names(session.getVariable("sorted")) == ["c", "b", "a"])
    }

    @Test("Equal keys keep input order (stable sort)")
    func stability() async throws {
        let (session, results) = try await run(
            #"Create the <users> with [{ name: "first", score: 1 }, { name: "second", score: 1 }, { name: "third", score: 0 }]."#,
            #"Sort the <sorted> from the <users> by "score"."#
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(names(session.getVariable("sorted")) == ["third", "first", "second"])
    }

    @Test("A missing field is an error, not a pass-through")
    func missingField() async throws {
        let (_, results) = try await run(
            #"Create the <users> with [{ name: "B", score: 2 }]."#,
            #"Sort the <oops> from the <users> by "missing"."#
        )
        guard case .error = results[1] else {
            Issue.record("expected an error, got \(results[1])")
            return
        }
    }

    @Test("A record list without a by clause is an error, not a pass-through")
    func recordsWithoutBy() async throws {
        let (_, results) = try await run(
            #"Create the <users> with [{ name: "B", score: 2 }, { name: "A", score: 9 }]."#,
            "Sort the <oops> from the <users>."
        )
        guard case .error = results[1] else {
            Issue.record("expected an error, got \(results[1])")
            return
        }
    }

    @Test("Mixed number/string keys are an error, not a pass-through")
    func mixedKeyTypes() async throws {
        let (_, results) = try await run(
            #"Create the <rows> with [{ v: 1 }, { v: "two" }]."#,
            #"Sort the <oops> from the <rows> by "v"."#
        )
        guard case .error = results[1] else {
            Issue.record("expected an error, got \(results[1])")
            return
        }
    }

    @Test("Scalar list sorting still works, with 'from' now accepted")
    func scalarListsUnchanged() async throws {
        let (session, results) = try await run(
            "Create the <nums> with [3, 1, 2].",
            "Sort the <sorted-nums> from the <nums>.",
            "Sort the <sorted-nums-two> for the <nums>."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("sorted-nums") as? [Int] == [1, 2, 3])
        #expect(session.getVariable("sorted-nums-two") as? [Int] == [1, 2, 3])
    }

    @Test("ARO-0002 angle form: `by <score>` means the score field")
    func byAngleField() async throws {
        let (session, results) = try await run(
            #"Create the <users> with [{ name: "B", score: 2 }, { name: "A", score: 9 }, { name: "C", score: 5 }]."#,
            "Sort the <ranked> from the <users> by <score>."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(names(session.getVariable("ranked")) == ["B", "C", "A"])
    }

    @Test("ARO-0002 trailing order: `by <score> descending`")
    func byAngleFieldDescending() async throws {
        let (session, results) = try await run(
            #"Create the <users> with [{ name: "B", score: 2 }, { name: "A", score: 9 }, { name: "C", score: 5 }]."#,
            "Sort the <ranked> from the <users> by <score> descending."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(names(session.getVariable("ranked")) == ["A", "C", "B"])
    }

    @Test("A bound string variable in `by <…>` names the field dynamically")
    func byAngleDynamic() async throws {
        let (session, results) = try await run(
            #"Create the <users> with [{ name: "B", score: 2 }, { name: "A", score: 9 }]."#,
            #"Create the <field-name> with "name"."#,
            "Sort the <ranked> from the <users> by <field-name>."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(names(session.getVariable("ranked")) == ["A", "B"])
    }

    @Test("sortRecords helper: unit-level error shapes")
    func helperErrors() throws {
        let records: [any Sendable] = [["a": 1] as [String: any Sendable]]
        let sorted = try SortAction.sortRecords(records, by: "a", ascending: true)
        #expect((sorted as? [any Sendable])?.count == 1)

        #expect(throws: (any Error).self) {
            _ = try SortAction.sortRecords("not a list", by: "a", ascending: true)
        }
        #expect(throws: (any Error).self) {
            _ = try SortAction.sortRecords([1, 2] as [any Sendable], by: "a", ascending: true)
        }
    }
}
