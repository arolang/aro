// ============================================================
// WhereConditionTests.swift
// AROParser — where-clause and/or chaining (ARO-0018 §2.2, GitLab #498)
// ============================================================
//
// The mis-parse this guards against: `where <status> == "paid" and
// <qty> > 2` used to hand the whole tail to the value expression
// parser, producing value = ("paid" and (<qty> > 2)) — which parsed,
// passed `aro check`, and then died at run time with the misleading
// "Undefined variable: qty". The where grammar now owns `and`/`or`
// itself, at the precedence ARO-0018 §7 documents (and binds tighter
// than or, parentheses group), and a malformed clause is a parse
// error with the where-clause named.

import Testing
@testable import AROParser

@Suite("Where-condition parsing (#498)")
struct WhereConditionTests {

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

    /// The parser error-recovers per statement, so a malformed where
    /// clause surfaces as a check-time diagnostic — the same channel
    /// `aro check` reports through — rather than a thrown error.
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

    // MARK: - The mis-parse from the issue

    @Test("`and` chains two predicates instead of feeding the value parser")
    func andChainsCleanly() throws {
        let condition = try #require(try whereCondition(
            #"    Filter the <big-paid> from the <orders> where <status> == "paid" and <qty> > 2."#))

        guard case .and(let left, let right) = condition else {
            Issue.record("Expected .and, got \(condition)")
            return
        }
        guard case .predicate(let l) = left, case .predicate(let r) = right else {
            Issue.record("Expected two leaf predicates")
            return
        }
        #expect(l.field == "status")
        #expect(l.op == .equal)
        // The first value must be just the literal — not a logical
        // expression that swallowed the second predicate.
        #expect(l.value is LiteralExpression)
        #expect(r.field == "qty")
        #expect(r.op == .greaterThan)
    }

    @Test("Single predicate still round-trips through whereClause")
    func singlePredicateUnchanged() throws {
        let condition = try #require(try whereCondition(
            #"    Filter the <paid> from the <orders> where <status> is "paid"."#))
        let single = try #require(condition.singlePredicate)
        #expect(single.field == "status")
        #expect(single.op == .equal)
        #expect(condition.predicates.count == 1)
    }

    // MARK: - Precedence and grouping

    @Test("`a or b and c` parses as a or (b and c)")
    func andBindsTighterThanOr() throws {
        let condition = try #require(try whereCondition(
            #"    Filter the <x> from the <orders> where <qty> > 4 or <status> is "paid" and <qty> > 2."#))
        guard case .or(let left, let right) = condition else {
            Issue.record("Expected top-level .or, got \(condition)")
            return
        }
        guard case .predicate = left, case .and = right else {
            Issue.record("Expected or(predicate, and(...)), got \(condition)")
            return
        }
        #expect(condition.predicates.map(\.field) == ["qty", "status", "qty"])
    }

    @Test("Parentheses regroup: (a or b) and c")
    func parenthesesGroup() throws {
        let condition = try #require(try whereCondition(
            #"    Filter the <x> from the <orders> where (<status> is "paid" or <status> is "open") and <qty> > 2."#))
        guard case .and(let left, let right) = condition else {
            Issue.record("Expected top-level .and, got \(condition)")
            return
        }
        guard case .or = left, case .predicate = right else {
            Issue.record("Expected and(or(...), predicate), got \(condition)")
            return
        }
    }

    @Test("treeSkeleton indexes predicates left to right")
    func treeSkeleton() throws {
        let chained = try #require(try whereCondition(
            #"    Filter the <x> from the <orders> where <a> is 1 or <b> is 2 and <c> is 3."#))
        #expect(chained.treeSkeleton == "or(0,and(1,2))")

        let single = try #require(try whereCondition(
            #"    Filter the <x> from the <orders> where <a> is 1."#))
        #expect(single.treeSkeleton == "0")
    }

    // MARK: - between (ARO-0018 §2.1)

    @Test("`between lo and hi` desugars to field >= lo and field <= hi")
    func betweenDesugars() throws {
        let condition = try #require(try whereCondition(
            "    Filter the <x> from the <orders> where <qty> between 2 and 4."))
        guard case .and(.predicate(let low), .predicate(let high)) = condition else {
            Issue.record("Expected and(predicate, predicate), got \(condition)")
            return
        }
        #expect(low.field == "qty")
        #expect(low.op == .greaterEqual)
        #expect(high.field == "qty")
        #expect(high.op == .lessEqual)
    }

    @Test("`between` chains with further and/or")
    func betweenChains() throws {
        let condition = try #require(try whereCondition(
            #"    Filter the <x> from the <orders> where <qty> between 2 and 4 and <status> is "paid"."#))
        #expect(condition.predicates.map(\.field) == ["qty", "qty", "status"])
        #expect(condition.treeSkeleton == "and(and(0,1),2)")
    }

    // MARK: - Malformed clauses fail the parse (not the runtime)

    @Test("Unknown operator names the where clause in the error")
    func unknownOperatorIsParseError() {
        let messages = checkErrors(
            "    Filter the <x> from the <orders> where <qty> banana 3.")
        #expect(messages.contains { $0.contains("comparison operator") && $0.contains("qty") })
        #expect(!messages.contains { $0.contains("Undefined variable") })
    }

    @Test("A dangling `and` without a second predicate is a parse error")
    func danglingAndIsParseError() {
        let messages = checkErrors(
            #"    Filter the <x> from the <orders> where <status> is "paid" and."#)
        #expect(!messages.isEmpty)
    }

    @Test("`between` without `and` is a parse error")
    func betweenWithoutAndIsParseError() {
        let messages = checkErrors(
            "    Filter the <x> from the <orders> where <qty> between 2.")
        #expect(messages.contains { $0.contains("between") })
    }

    @Test("Unclosed parenthesis is a parse error")
    func unclosedParenIsParseError() {
        let messages = checkErrors(
            #"    Filter the <x> from the <orders> where (<status> is "paid" and <qty> > 2."#)
        #expect(!messages.isEmpty)
    }

    // MARK: - Delete stays single-predicate (check-time gate)

    @Test("Delete with a compound where fails aro check, not the repository")
    func deleteCompoundWhereRejected() {
        let source = """
        (Test: Demo) {
            Delete the <gone> from the <order-repository> where <status> is "paid" and <qty> > 2.
            Return an <OK: status> for the <check>.
        }
        """
        let result = Compiler().compile(source)
        let messages = result.diagnostics.filter { $0.severity == .error }.map(\.message)
        #expect(messages.contains { $0.contains("single where predicate") })
    }

    @Test("Delete with a single where predicate stays accepted")
    func deleteSingleWhereAccepted() {
        let source = """
        (Test: Demo) {
            Delete the <gone> from the <order-repository> where <status> is "paid".
            Return an <OK: status> for the <check>.
        }
        """
        let result = Compiler().compile(source)
        let messages = result.diagnostics.filter { $0.severity == .error }.map(\.message)
        #expect(!messages.contains { $0.contains("single where predicate") })
    }
}
