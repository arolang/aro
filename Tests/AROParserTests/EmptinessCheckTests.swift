// ============================================================
// EmptinessCheckTests.swift
// AROParser — `is empty` / `is not empty` (GitLab #463)
// ============================================================
//
// ARO-0002 documents `expression , "is" , "empty"` and shows
// `when <username> is empty or <password> is empty` as a worked
// guard. The parser rejected all of it with "Expected type name,
// but got empty" — `empty` is its own keyword token, so the
// type-check path never had a chance.

import Testing
@testable import AROParser

@Suite("is empty (#463)")
struct EmptinessCheckTests {

    private func guardExpression(_ source: String) throws -> (any Expression)? {
        let program = try Parser.parse("""
        (Check: Test Activity) {
            \(source)
        }
        """)
        let statement = program.featureSets.first?.statements.first
        return (statement as? AROStatement)?.statementGuard.condition
    }

    // MARK: - Parsing

    @Test("The issue's own repro parses")
    func issueReproParses() throws {
        // Verbatim from #463.
        let program = try Parser.parse("""
        (Check Cart: Cart) {
            Create the <items> with [].
            Return a <BadRequest: status> with <items> when <items> is empty.
            Return an <OK: status> with <items>.
        }
        """)
        #expect(program.featureSets.count == 1)
        #expect(program.featureSets[0].statements.count == 3)
    }

    @Test("`is empty` becomes an emptiness check, not a type check")
    func parsesAsEmptinessCheck() throws {
        let condition = try guardExpression(
            "Log \"x\" to the <console> when <items> is empty.")
        let check = try #require(condition as? EmptinessCheckExpression)
        #expect(!check.negated)
    }

    @Test("`is not empty` negates")
    func parsesNegated() throws {
        let condition = try guardExpression(
            "Log \"x\" to the <console> when <items> is not empty.")
        let check = try #require(condition as? EmptinessCheckExpression)
        #expect(check.negated)
    }

    @Test("Both spellings round-trip through description")
    func description() throws {
        let plain = try #require(try guardExpression(
            "Log \"x\" to the <console> when <items> is empty.")
            as? EmptinessCheckExpression)
        let negated = try #require(try guardExpression(
            "Log \"x\" to the <console> when <items> is not empty.")
            as? EmptinessCheckExpression)
        #expect(plain.description.hasSuffix("is empty"))
        #expect(negated.description.hasSuffix("is not empty"))
    }

    @Test("The spec's worked example parses")
    func specExample() throws {
        // ARO-0002 line ~911.
        let condition = try guardExpression(
            "Log \"x\" to the <console> when <username> is empty or <password> is empty.")
        #expect(condition is BinaryExpression)
    }

    @Test("`is` still parses a type check")
    func typeCheckUnaffected() throws {
        // The emptiness branch sits in front of the type-name path,
        // so this is the regression that matters most.
        let condition = try guardExpression(
            "Log \"x\" to the <console> when <value> is a String.")
        #expect(condition is TypeCheckExpression)
    }

    @Test("`is nil` still parses as an equality comparison")
    func nilCheckUnaffected() throws {
        let condition = try guardExpression(
            "Log \"x\" to the <console> when <value> is nil.")
        #expect(condition is BinaryExpression)
    }

    @Test("`is true` still parses as an equality comparison")
    func booleanCheckUnaffected() throws {
        let condition = try guardExpression(
            "Log \"x\" to the <console> when <flag> is true.")
        #expect(condition is BinaryExpression)
    }

    @Test("Emptiness checks work outside guards too")
    func inValueExpression() throws {
        // The grammar puts it in the comparison production, not
        // just the guard one, so it has to work anywhere an
        // expression is accepted.
        let program = try Parser.parse("""
        (Check: Test Activity) {
            Compute the <blank> from <items> is empty.
            Return an <OK: status> with <blank>.
        }
        """)
        #expect(program.featureSets[0].statements.count == 2)
    }
}
