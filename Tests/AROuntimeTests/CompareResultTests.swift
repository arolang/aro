// ============================================================
// CompareResultTests.swift
// ARO Runtime — Compare binds a fresh result (GitLab #469)
// ============================================================
//
// `Compare the <a> against the <b>.` read its left operand out of
// the *result* slot, so the statement both read and wrote the same
// immutable binding. Every documented example died on "Cannot
// rebind variable 'a'" before it ever ran, and the outcome was
// unreachable anyway — nothing in the codebase could read the
// `ComparisonResult` it returned.
//
// Both operands are inputs now, and the result is a fresh binding
// readable as `<result: matches>` / `<result: result>`.

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

@Suite("Compare (#469)")
struct CompareResultTests {

    private func compare(_ lhs: any Sendable,
                         _ rhs: any Sendable) async throws -> [String: any Sendable] {
        let span = SourceSpan(at: SourceLocation())
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("lhs", value: lhs)
        context.bind("_against_", value: rhs)
        let result = ResultDescriptor(base: "verdict", specifiers: [], span: span)
        let object = ObjectDescriptor(preposition: .from, base: "lhs",
                                      specifiers: [], span: span)
        let value = try await CompareAction().execute(
            result: result, object: object, context: context)
        return try #require(value as? [String: any Sendable])
    }

    @Test("Equal values match")
    func equalMatches() async throws {
        let out = try await compare(42, 42)
        #expect(out["matches"] as? Bool == true)
        #expect(out["result"] as? String == "equal")
    }

    @Test("Ordering is reported, not just equality")
    func ordering() async throws {
        #expect(try await compare(10, 20)["result"] as? String == "less")
        #expect(try await compare(20, 10)["result"] as? String == "greater")
    }

    @Test("Strings compare")
    func strings() async throws {
        #expect(try await compare("hello", "hello")["matches"] as? Bool == true)
        #expect(try await compare("a", "b")["result"] as? String == "less")
    }

    @Test("The result binds under the fresh name, not the operand")
    func bindsFreshResult() async throws {
        // The whole bug in one assertion: the left operand keeps its
        // value, and the outcome lands somewhere else.
        let span = SourceSpan(at: SourceLocation())
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("lhs", value: 5)
        context.bind("_against_", value: 3)
        let result = ResultDescriptor(base: "verdict", specifiers: [], span: span)
        let object = ObjectDescriptor(preposition: .from, base: "lhs",
                                      specifiers: [], span: span)
        _ = try await CompareAction().execute(
            result: result, object: object, context: context)
        #expect(context.resolveAny("lhs") as? Int == 5)
        #expect(context.resolveAny("verdict") != nil)
    }

    @Test("A missing right-hand operand names the shape that works")
    func missingOperandExplains() async {
        let span = SourceSpan(at: SourceLocation())
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("lhs", value: 1)
        let result = ResultDescriptor(base: "verdict", specifiers: [], span: span)
        let object = ObjectDescriptor(preposition: .from, base: "lhs",
                                      specifiers: [], span: span)
        do {
            _ = try await CompareAction().execute(
                result: result, object: object, context: context)
            Issue.record("expected a throw")
        } catch {
            // "Cannot rebind variable 'a'" told nobody what to do.
            #expect("\(error)".contains("against"))
        }
    }

    @Test("`from` is a valid Compare preposition")
    func acceptsFrom() {
        #expect(CompareAction.validPrepositions.contains(.from))
    }
}

@Suite("Compare parsing (#469)")
struct CompareParsingTests {

    @Test("The new shape parses with the operand and the against clause")
    func parsesNewShape() throws {
        let program = try Parser.parse("""
        (Check: Test Activity) {
            Compare the <same> from the <a> against the <b>.
            Return an <OK: status> with <same>.
        }
        """)
        let statement = try #require(
            program.featureSets[0].statements[0] as? AROStatement)
        #expect(statement.result.base == "same")
        #expect(statement.object.noun.base == "a")
        #expect(statement.rangeModifiers.againstClause != nil)
    }

    @Test("`matches` parses as a qualifier")
    func matchesAsQualifier() throws {
        // It's the regex comparison keyword too, but in qualifier
        // position nothing else can appear, so it's unambiguous.
        let program = try Parser.parse("""
        (Check: Test Activity) {
            Return an <OK: status> with <same: matches>.
        }
        """)
        #expect(program.featureSets[0].statements.count == 1)
    }

    @Test("The regex `matches` operator still works")
    func regexMatchesUnaffected() throws {
        let program = try Parser.parse("""
        (Check: Test Activity) {
            Log "hit" to the <console> when <s> matches /[0-9]+/.
        }
        """)
        #expect(program.featureSets[0].statements.count == 1)
    }

    @Test("The article after `against` is optional")
    func articleOptional() throws {
        let program = try Parser.parse("""
        (Check: Test Activity) {
            Compare the <same> from the <a> against <b>.
        }
        """)
        let statement = try #require(
            program.featureSets[0].statements[0] as? AROStatement)
        #expect(statement.rangeModifiers.againstClause != nil)
    }
}
