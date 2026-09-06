// ============================================================
// IsEqualityTests.swift
// AROParser — `is` compares; only type names type-check (GitLab #500)
// ============================================================

import Testing
@testable import AROParser

@Suite("is-operator parsing")
struct IsEqualityTests {

    private func parseGuardExpression(_ condition: String) throws -> (any Expression)? {
        let source = """
        (Probe: Interactive) {
            for each <o> in <orders> where \(condition) {
                Log <o> to the <console>.
            }
            Return an <OK: status> for the <probe>.
        }
        """
        let program = try Parser(tokens: Lexer.tokenize(source)).parse()
        let loop = program.featureSets[0].statements.compactMap { $0 as? ForEachLoop }.first
        return loop?.filter
    }

    @Test("is <string literal> parses as equality")
    func stringEquality() throws {
        let filter = try parseGuardExpression(#"<o: status> is "paid""#)
        let binary = try #require(filter as? BinaryExpression)
        #expect(binary.op == .equal)
    }

    @Test("is <int literal> parses as equality")
    func intEquality() throws {
        let filter = try parseGuardExpression("<o: id> is 2")
        let binary = try #require(filter as? BinaryExpression)
        #expect(binary.op == .equal)
    }

    @Test("is <variable> parses as equality")
    func variableEquality() throws {
        let filter = try parseGuardExpression("<o: status> is <target>")
        let binary = try #require(filter as? BinaryExpression)
        #expect(binary.op == .equal)
    }

    @Test("is not <literal> parses as inequality")
    func negatedEquality() throws {
        let filter = try parseGuardExpression("<o: id> is not 2")
        let binary = try #require(filter as? BinaryExpression)
        #expect(binary.op == .notEqual)
    }

    @Test("is TypeName stays a type check, with or without an article")
    func typeCheckPreserved() throws {
        let bare = try parseGuardExpression("<o: id> is Integer")
        #expect(bare is TypeCheckExpression)
        let article = try parseGuardExpression("<o: status> is a String")
        #expect(article is TypeCheckExpression)
    }

    @Test("is true / is empty keep their existing meanings")
    func existingFormsUntouched() throws {
        let boolean = try #require(try parseGuardExpression("<o: active> is true") as? BinaryExpression)
        #expect(boolean.op == .equal)
        #expect(try parseGuardExpression("<o: items> is empty") is EmptinessCheckExpression)
        #expect(try parseGuardExpression("<o: items> is not empty") is EmptinessCheckExpression)
    }
}
