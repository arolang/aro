// ============================================================
// ParserBugFixTests.swift
// AROParser — operators and scope ids
// GitLab #656, #664, #667
// ============================================================

import Testing
@testable import AROParser

@Suite("Parser and analyzer bug fixes (#656, #664, #667)")
struct ParserBugFixTests {

    private func parse(_ source: String) throws -> Program {
        try Parser(tokens: try Lexer.tokenize(source)).parse()
    }

    @Test("`where <field> before <value>` parses")
    func whereBefore() throws {
        // `WhereOperator.before` has existed in the AST and been implemented in
        // `WhereConditionEvaluator` the whole time; only the parser's switch
        // never accepted the word, so a documented date comparison died on
        // "comparison operator … expected" (#656).
        let program = try parse("""
        (listOverdue: Tasks API) {
            Retrieve the <late> from the <task-repository> where <due> before <now>.
            Return an <OK: status> with <late>.
        }
        """)
        let statement = try #require(program.featureSets[0].statements[0] as? AROStatement)
        #expect(statement.whereClause?.op == .before)
    }

    @Test("`where <field> after <value>` parses")
    func whereAfter() throws {
        let program = try parse("""
        (listUpcoming: Tasks API) {
            Retrieve the <soon> from the <task-repository> where <due> after <now>.
            Return an <OK: status> with <soon>.
        }
        """)
        let statement = try #require(program.featureSets[0].statements[0] as? AROStatement)
        #expect(statement.whereClause?.op == .after)
    }

    @Test("Scope ids are stable across processes")
    func scopeIdsAreStable() throws {
        // They were `"fs-\(name.hashValue)"`, and Swift seeds `hashValue` per
        // process — so anything comparing or persisting a scope id across runs
        // saw two unrelated scopes where there was one (#667).
        let source = """
        (Handle It: Orders API) {
            Create the <x> with 1.
            Return an <OK: status> with <x>.
        }
        """
        let analyzed = try SemanticAnalyzer.analyze(source)
        let scopeId = analyzed.featureSets[0].symbolTable.scopeId
        #expect(scopeId == "fs-Handle It",
                "the id must be derived from the name, not from a per-process hash")
    }
}
