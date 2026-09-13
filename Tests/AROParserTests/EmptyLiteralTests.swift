// ============================================================
// EmptyLiteralTests.swift
// ARO Parser — empty collection literals and the keyword diagnostic (GitLab #548)
// ============================================================
//
// `Create the <items> with [].` is how an accumulator or a fixture
// starts, so it is pinned here: `[]` and `{}` parse everywhere a
// populated literal does, including nested inside one another.
//
// The report also called the diagnostic confusing — "Expected
// identifier, but got empty". That message came from the *keyword*
// `empty` (of `<list> is empty`) being used as a name, and it read as
// if the parser had rejected an ordinary identifier. Two changes:
// `empty` is now a usable name outside the `is empty` guard, and a
// reserved word that turns up where a name belongs is named as one.

import Testing
@testable import AROParser

@Suite("Empty literals and keyword diagnostics (#548)")
struct EmptyLiteralTests {

    // MARK: - `[]`

    @Test("`[]` binds an empty list")
    func emptyListLiteral() throws {
        let source = "(Test: Demo) { Create the <items> with []. }"
        let program = try Parser.parse(source)
        let statement = try #require(program.featureSets[0].statements[0] as? AROStatement)

        let array = try #require(statement.expression as? ArrayLiteralExpression)
        #expect(array.elements.isEmpty)
    }

    @Test("`{}` binds an empty record")
    func emptyMapLiteral() throws {
        let source = "(Test: Demo) { Create the <record> with {}. }"
        let program = try Parser.parse(source)
        let statement = try #require(program.featureSets[0].statements[0] as? AROStatement)

        let map = try #require(statement.expression as? MapLiteralExpression)
        #expect(map.entries.isEmpty)
    }

    @Test("Empty literals nest: `{ items: [] }` and `[{}]`")
    func emptyLiteralsNest() throws {
        let program = try Parser.parse("""
        (Test: Demo) {
            Create the <a> with { items: [] }.
            Create the <b> with [{}].
        }
        """)
        let statements = program.featureSets[0].statements

        let first = try #require(statements[0] as? AROStatement)
        let map = try #require(first.expression as? MapLiteralExpression)
        let nestedArray = try #require(map.entries.first?.value as? ArrayLiteralExpression)
        #expect(nestedArray.elements.isEmpty)

        let second = try #require(statements[1] as? AROStatement)
        let array = try #require(second.expression as? ArrayLiteralExpression)
        let nestedMap = try #require(array.elements.first as? MapLiteralExpression)
        #expect(nestedMap.entries.isEmpty)
    }

    @Test("An empty list reads the same after `from`, `to` and `for`")
    func emptyListInEveryExpressionPosition() throws {
        let program = try Parser.parse("""
        (Test: Demo) {
            Sort the <sorted> for [].
            Filter the <kept> from [] where <id> is 1.
            Return an <OK: status> with [].
        }
        """)
        for statement in program.featureSets[0].statements {
            let aro = try #require(statement as? AROStatement)
            let array = try #require(aro.expression as? ArrayLiteralExpression)
            #expect(array.elements.isEmpty)
        }
    }

    // MARK: - `empty` as a name

    @Test("`empty` is a usable name: `<empty>`")
    func emptyIsAUsableVariableName() throws {
        let source = "(Test: Demo) { Create the <empty> with []. }"
        let program = try Parser.parse(source)
        let statement = try #require(program.featureSets[0].statements[0] as? AROStatement)
        #expect(statement.result.base == "empty")
    }

    @Test("`empty` is a usable record key: `{ empty: true }`")
    func emptyIsAUsableRecordKey() throws {
        let source = "(Test: Demo) { Create the <flags> with { empty: true }. }"
        let program = try Parser.parse(source)
        let statement = try #require(program.featureSets[0].statements[0] as? AROStatement)

        let map = try #require(statement.expression as? MapLiteralExpression)
        #expect(map.entries.map(\.key) == ["empty"])
    }

    @Test("`is empty` is still the emptiness guard, not a name")
    func isEmptyStillGuards() throws {
        let source = "(Test: Demo) { Return an <OK: status> for the <check> when <items> is empty. }"
        let program = try Parser.parse(source)
        let statement = try #require(program.featureSets[0].statements[0] as? AROStatement)

        let condition = try #require(statement.statementGuard.condition as? EmptinessCheckExpression)
        #expect(condition.negated == false)
    }

    // MARK: - Diagnostics

    @Test("A reserved word where a name belongs is named as a keyword")
    func keywordDiagnosticNamesTheKeyword() {
        let error = ParserError.unexpectedToken(
            expected: "identifier",
            got: Token(kind: .while, span: SourceSpan.unknown, lexeme: "while")
        )
        #expect(error.message == "Expected identifier, but got the keyword 'while'")
    }

    @Test("A malformed literal still reports what is missing")
    func malformedLiteralStillReadsWell() {
        #expect(throws: (any Error).self) {
            _ = try Parser.parse("(Test: Demo) { Create the <x> with [1, 2. }")
        }
        do {
            _ = try Parser.parse("(Test: Demo) { Create the <x> with [1, 2. }")
            Issue.record("Expected the unterminated list literal to fail")
        } catch let error as ParserError {
            #expect(error.message.contains("']'"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
