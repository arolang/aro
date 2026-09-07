// ============================================================
// BareWhereFieldTests.swift
// AROParser — bare where-clause fields (ARO-0018 §7, GitLab #545)
// ============================================================
//
// Every proposal writes the where clause with a bare field:
//
//     Filter the <active-users> from the <users> where status = "active".
//     Retrieve the <user> from the <user-repository> where id = <id>.
//
// and the parser answered "Expected '<', but got identifier(status)" —
// so ARO-0019 §2.1's own example, ARO-0003's getUser, and ARO-0006's
// entire worked error-philosophy example did not parse. The bare form
// is now the same clause as the bracketed one; these tests pin that
// both spellings build the identical `WhereClause`, in every
// where-bearing statement and everywhere inside a condition tree.

import Testing
@testable import AROParser

@Suite("Bare where-clause fields (#545)")
struct BareWhereFieldTests {

    /// Parses one statement and returns its where condition.
    private func whereCondition(_ statement: String) throws -> WhereCondition? {
        let source = """
        (Test: Demo) {
        \(statement)
            Return an <OK: status> for the <check>.
        }
        """
        let tokens = try Lexer(source: source).tokenize()
        let program = try Parser(tokens: tokens).parse()
        let aro = try #require(program.featureSets.first?.statements.first as? AROStatement)
        return aro.queryModifiers.whereCondition
    }

    /// Errors `aro check` would report for a statement.
    private func checkErrors(_ statement: String) -> [String] {
        let source = """
        (Test: Demo) {
        \(statement)
            Return an <OK: status> for the <check>.
        }
        """
        return Compiler().compile(source).diagnostics
            .filter { $0.severity == .error }
            .map(\.message)
    }

    /// Flattens a condition tree into (field, operator) pairs, left to right.
    private func predicates(_ condition: WhereCondition) -> [(String, WhereOperator)] {
        switch condition {
        case .predicate(let clause):
            return [(clause.field, clause.op)]
        case .and(let l, let r), .or(let l, let r):
            return predicates(l) + predicates(r)
        }
    }

    // MARK: - The examples the proposals print

    @Test("ARO-0019 §2.1: Filter … where status = \"active\"")
    func aro0019FilterExample() throws {
        let condition = try #require(try whereCondition(
            #"    Filter the <active-users> from the <users> where status = "active"."#))
        guard case .predicate(let clause) = condition else {
            Issue.record("Expected a single predicate, got \(condition)")
            return
        }
        #expect(clause.field == "status")
        #expect(clause.op == .equal)
    }

    @Test("ARO-0003/ARO-0006: Retrieve … where id = <id>")
    func aro0003RetrieveExample() throws {
        let condition = try #require(try whereCondition(
            "    Retrieve the <user> from the <user-repository> where id = <id>."))
        guard case .predicate(let clause) = condition else {
            Issue.record("Expected a single predicate, got \(condition)")
            return
        }
        #expect(clause.field == "id")
        #expect(clause.op == .equal)
    }

    // MARK: - Both spellings are the same clause

    @Test("Bare and bracketed fields build the identical predicate")
    func spellingsAgree() throws {
        let bare = try #require(try whereCondition(
            #"    Filter the <hits> from the <orders> where status is "paid"."#))
        let bracketed = try #require(try whereCondition(
            #"    Filter the <hits> from the <orders> where <status> is "paid"."#))
        #expect(predicates(bare).map(\.0) == predicates(bracketed).map(\.0))
        #expect(predicates(bare).map(\.1) == predicates(bracketed).map(\.1))
    }

    @Test("Hyphenated names work bare: where customer-id = <id>")
    func hyphenatedBareField() throws {
        let condition = try #require(try whereCondition(
            "    Filter the <mine> from the <orders> where customer-id = <id>."))
        #expect(predicates(condition).map(\.0) == ["customer-id"])
    }

    // MARK: - Every operator keeps working bare

    @Test("Operators parse after a bare field", arguments: [
        (#"where status is "paid""#, WhereOperator.equal),
        (#"where status is not "paid""#, WhereOperator.notEqual),
        (#"where status == "paid""#, WhereOperator.equal),
        (#"where status != "paid""#, WhereOperator.notEqual),
        ("where qty > 2", WhereOperator.greaterThan),
        ("where qty >= 2", WhereOperator.greaterEqual),
        ("where qty < 2", WhereOperator.lessThan),
        ("where qty <= 2", WhereOperator.lessEqual),
        (#"where name contains "test""#, WhereOperator.contains),
        (#"where status in ["paid", "open"]"#, WhereOperator.in),
        (#"where status not in ["paid"]"#, WhereOperator.notIn),
    ])
    func bareFieldOperators(clause: String, expected: WhereOperator) throws {
        let condition = try #require(try whereCondition(
            "    Filter the <hits> from the <orders> \(clause)."))
        #expect(predicates(condition).map(\.1) == [expected])
        #expect(predicates(condition).map(\.0).allSatisfy { $0 == "status" || $0 == "qty" || $0 == "name" })
    }

    // MARK: - Inside the condition tree (MR !486 / #498 shapes)

    @Test("Bare fields chain with and")
    func bareAndChain() throws {
        let condition = try #require(try whereCondition(
            #"    Filter the <big-paid> from the <orders> where status == "paid" and qty > 2."#))
        guard case .and = condition else {
            Issue.record("Expected .and, got \(condition)")
            return
        }
        #expect(predicates(condition).map(\.0) == ["status", "qty"])
    }

    @Test("Bare and bracketed fields mix inside one condition")
    func mixedSpellingsChain() throws {
        let condition = try #require(try whereCondition(
            #"    Filter the <big-paid> from the <orders> where status == "paid" and <qty> > 2."#))
        #expect(predicates(condition).map(\.0) == ["status", "qty"])
    }

    @Test("Bare fields work inside parenthesized groups")
    func bareInParenthesizedGroup() throws {
        let condition = try #require(try whereCondition(
            #"    Filter the <mixed> from the <orders> where (status == "paid" or status == "open") and qty > 2."#))
        guard case .and(let left, .predicate(let right)) = condition else {
            Issue.record("Expected (a or b) and c, got \(condition)")
            return
        }
        guard case .or = left else {
            Issue.record("Expected the group to stay an .or, got \(left)")
            return
        }
        #expect(right.field == "qty")
    }

    @Test("between desugars from a bare field too")
    func bareBetween() throws {
        let condition = try #require(try whereCondition(
            "    Filter the <ranged> from the <orders> where qty between 1 and 3."))
        #expect(predicates(condition).map(\.0) == ["qty", "qty"])
        #expect(predicates(condition).map(\.1) == [.greaterEqual, .lessEqual])
    }

    @Test("and still binds tighter than or with bare fields")
    func barePrecedence() throws {
        let condition = try #require(try whereCondition(
            #"    Filter the <prec> from the <orders> where qty > 4 or status == "paid" and qty > 2."#))
        guard case .or(.predicate, .and) = condition else {
            Issue.record("Expected a or (b and c), got \(condition)")
            return
        }
    }

    // MARK: - Every where-bearing statement

    @Test("Statements that carry a where clause accept the bare field", arguments: [
        #"Filter the <hits> from the <orders> where status is "paid"."#,
        #"Fetch the <hits> from the <order-repository> where status is "paid"."#,
        #"Retrieve the <hit> from the <order-repository> where status is "paid"."#,
        #"Delete the <gone> from the <order-repository> where status is "cancelled"."#,
        // Reduce carries a where clause too, but only after its `with`
        // aggregate — `where … with sum(…)`, the order ARO-0018 §1.5's
        // grammar prints, does not parse in either spelling. That is a
        // clause-ordering bug of its own, not this one.
        #"Reduce the <total> from the <orders> with sum(<qty>) where status is "paid"."#,
    ])
    func whereBearingStatements(statement: String) throws {
        let condition = try #require(try whereCondition("    \(statement)"))
        #expect(predicates(condition).map(\.0) == ["status"])
        #expect(checkErrors("    \(statement)").isEmpty)
    }

    // MARK: - Diagnostics

    @Test("A bare field with no operator still names the comparison operator")
    func bareFieldMissingOperator() {
        let messages = checkErrors(#"    Filter the <x> from the <orders> where status "paid"."#)
        #expect(messages.contains { $0.contains("comparison operator") && $0.contains("status") })
    }

    @Test("Something that is neither a field nor '<' names both spellings")
    func nonFieldAfterWhere() {
        let messages = checkErrors(#"    Filter the <x> from the <orders> where "paid" is "paid"."#)
        #expect(messages.contains { $0.contains("field name") && $0.contains("where clause") })
    }
}
