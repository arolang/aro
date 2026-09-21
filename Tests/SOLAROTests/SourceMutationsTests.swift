// ============================================================
// SourceMutationsTests.swift
// SOLARO — the splices that rewrite the user's file (GitLab #773)
// ============================================================
//
// Nine operations computed a byte-range splice into a source file and
// wrote the result back, all of them inside a SwiftUI view where no
// test could reach them. They rewrite the user's file by offset: a
// fencepost error here silently eats a line of somebody's program, with
// undo as the only thing between that and them.

import Testing
import Foundation
import AROParser
@testable import SOLARO

@Suite("Source mutations")
struct SourceMutationsTests {

    private let program = """
    (Application-Start: Demo) {
        Log "one" to the <console>.
        Log "two" to the <console>.
        Log "three" to the <console>.
    }
    """

    /// The span of the Nth `Log` line, found the way the app does.
    private func span(ofLineContaining needle: String,
                      in text: String) throws -> Range<Int> {
        let parsed = try Parser.parse(text)
        for featureSet in parsed.featureSets {
            for statement in featureSet.statements {
                let ns = text as NSString
                let range = NSRange(location: statement.span.start.offset,
                                    length: statement.span.end.offset
                                        - statement.span.start.offset)
                if ns.substring(with: range).contains(needle) {
                    return statement.span.start.offset
                        ..< statement.span.end.offset
                }
            }
        }
        Issue.record("no statement containing \(needle)")
        throw CancellationError()
    }

    // MARK: - Line ranges

    @Test func alineRangeTakesTheIndentationAndTheNewline() throws {
        let range = try span(ofLineContaining: "two", in: program)
        let line = try #require(SourceMutations.lineRange(
            covering: range, in: program as NSString))
        let text = (program as NSString).substring(with: line)
        // The indentation goes with the statement, or a delete leaves a
        // line of whitespace behind.
        #expect(text == "    Log \"two\" to the <console>.\n")
    }

    @Test func aspanPastTheEndOfTheTextIsRefused() {
        // What a stale program cache looks like. Better to do nothing
        // than to splice at an offset that no longer means anything.
        #expect(SourceMutations.lineRange(covering: 0..<10_000,
                                          in: "short" as NSString) == nil)
        #expect(SourceMutations.lineRange(covering: 5..<5,
                                          in: program as NSString) == nil)
    }

    @Test func thelastLineWithoutATrailingNewlineIsNotOverRead() {
        // Consuming a newline that is not there is how you lose the
        // character after the text.
        let text = "Log \"only\"." as NSString
        let range = try? #require(SourceMutations.lineRange(
            covering: 0..<text.length, in: text))
        #expect(range?.upperBound == text.length)
    }

    // MARK: - Delete and duplicate

    @Test func deletingAStatementRemovesExactlyItsLines() throws {
        let range = try span(ofLineContaining: "two", in: program)
        let after = try #require(
            SourceMutations.deletingStatement(in: program, span: range))
        #expect(!after.contains("two"))
        #expect(after.contains("one"))
        #expect(after.contains("three"))
        // And it closes the gap rather than leaving a blank line.
        #expect(!after.contains("\n\n"))
    }

    @Test func duplicatingAStatementRepeatsItBelowItself() throws {
        let range = try span(ofLineContaining: "two", in: program)
        let after = try #require(
            SourceMutations.duplicatingStatement(in: program, span: range))
        let lines = after.components(separatedBy: "\n")
        let twos = lines.filter { $0.contains("two") }
        #expect(twos.count == 2)
        // Adjacent, in order, and with the indentation intact.
        let first = try #require(lines.firstIndex { $0.contains("two") })
        #expect(lines[first + 1].contains("two"))
        #expect(lines[first] == lines[first + 1])
    }

    // MARK: - Multiple statements

    @Test func deletingSeveralStatementsKeepsTheOffsetsValid() throws {
        // The reason this is not the single-statement version in a
        // loop: deleting the first span shifts every later one.
        let first = try span(ofLineContaining: "one", in: program)
        let third = try span(ofLineContaining: "three", in: program)
        let after = SourceMutations.deletingStatements(
            in: program, spans: [first, third])
        #expect(!after.contains("one"))
        #expect(!after.contains("three"))
        #expect(after.contains("two"))
    }

    @Test func deletingNothingChangesNothing() {
        #expect(SourceMutations.deletingStatements(in: program, spans: [])
                == program)
    }

    @Test func deletingSeveralIsOrderIndependent() throws {
        let first = try span(ofLineContaining: "one", in: program)
        let third = try span(ofLineContaining: "three", in: program)
        #expect(SourceMutations.deletingStatements(in: program,
                                                   spans: [first, third])
                == SourceMutations.deletingStatements(in: program,
                                                      spans: [third, first]))
    }

    @Test func extractingReturnsTheSourceInDocumentOrder() throws {
        let first = try span(ofLineContaining: "one", in: program)
        let third = try span(ofLineContaining: "three", in: program)
        // Given out of order, because a Set of selected node IDs has
        // no order to give.
        let chunks = SourceMutations.extracting(from: program,
                                                spans: [third, first])
        #expect(chunks.count == 2)
        #expect(chunks[0].contains("one"))
        #expect(chunks[1].contains("three"))
    }

    // MARK: - Insertion

    @Test func anInsertedSnippetTakesTheSurroundingIndentation() throws {
        let range = try span(ofLineContaining: "two", in: program)
        let line = try #require(SourceMutations.lineRange(
            covering: range, in: program as NSString))
        let after = try #require(SourceMutations.inserting(
            "Log \"new\" to the <console>.", at: line.location, in: program))
        #expect(after.contains("    Log \"new\" to the <console>.\n"))
        // And it parses, which is the only test that really matters.
        #expect(throws: Never.self) { try Parser.parse(after) }
    }

    @Test func amultiLineSnippetIndentsEveryLine() throws {
        let range = try span(ofLineContaining: "two", in: program)
        let line = try #require(SourceMutations.lineRange(
            covering: range, in: program as NSString))
        let snippet = "Create the <a> with 1.\nCreate the <b> with 2."
        let after = try #require(
            SourceMutations.inserting(snippet, at: line.location, in: program))
        #expect(after.contains("    Create the <a> with 1."))
        #expect(after.contains("    Create the <b> with 2."))
        #expect(throws: Never.self) { try Parser.parse(after) }
    }

    @Test func insertingAtAnImpossibleOffsetIsRefused() {
        #expect(SourceMutations.inserting("x", at: 10_000, in: program) == nil)
        #expect(SourceMutations.inserting("x", at: -1, in: program) == nil)
    }

    @Test func appendingLeavesABlankLineBetweenBlocks() {
        let block = "(Other: Demo) {\n    Log \"hi\".\n}\n"
        let after = SourceMutations.appending(block, to: program)
        #expect(after.contains("}\n\n(Other: Demo)"))
        #expect(after.hasSuffix("\n"))
    }

    @Test func appendingToAnEmptyFileDoesNotStartWithABlankLine() {
        let after = SourceMutations.appending("(A: B) {\n}\n", to: "")
        #expect(after.hasPrefix("(A: B)"))
    }

    // MARK: - Indentation

    @Test func indentationCopiesTheCurrentLine() {
        let text = "no indent\n\tTabbed\n    Spaced\n" as NSString
        #expect(SourceMutations.indentation(around: 3, in: text) == "    ")
        #expect(SourceMutations.indentation(
            around: text.range(of: "Tabbed").location, in: text) == "\t")
        #expect(SourceMutations.indentation(
            around: text.range(of: "Spaced").location, in: text) == "    ")
    }

    // MARK: - Locating

    @Test func aNodeIDResolvesToItsStatement() throws {
        let parsed = try Parser.parse(program)
        let target = try #require(parsed.featureSets.first?.statements[1])
        // The file part of a node ID can contain colons, so the offset
        // is read from after the last one.
        let nodeID = "/Users/someone/My: Project/main.aro:\(target.span.start.offset)"
        let found = try #require(SourceMutations.span(forNodeID: nodeID,
                                                      in: parsed))
        #expect(found.start.offset == target.span.start.offset)
    }

    @Test func anIDThatMatchesNoStatementResolvesToNothing() throws {
        let parsed = try Parser.parse(program)
        #expect(SourceMutations.span(forNodeID: "main.aro:99999",
                                     in: parsed) == nil)
        #expect(SourceMutations.span(forNodeID: "no-offset-here",
                                     in: parsed) == nil)
    }

    @Test func aLineNumberResolvesToItsStatement() throws {
        let parsed = try Parser.parse(program)
        let found = try #require(SourceMutations.span(startingOnLine: 3,
                                                      in: parsed))
        let ns = program as NSString
        let text = ns.substring(with: NSRange(
            location: found.start.offset,
            length: found.end.offset - found.start.offset))
        #expect(text.contains("two"))
    }

    @Test func aStatementInsideALoopIsFound() throws {
        // A statement inside a `for each` has a span of its own and is
        // a canvas node like any other.
        let source = """
        (Application-Start: Demo) {
            Create the <items> with [1, 2, 3].
            for each <item> in <items> {
                Log <item> to the <console>.
            }
        }
        """
        let parsed = try Parser.parse(source)
        let offset = (source as NSString)
            .range(of: "Log <item> to the <console>.").location
        let found = SourceMutations.locateStatement(
            in: parsed.featureSets[0].statements, matching: offset)
        #expect(found != nil)
    }

    // MARK: - Feature-set detection

    @Test func aBlockOpeningAFeatureSetIsRecognised() {
        #expect(SourceMutations.declaresFeatureSet(
            "(listUsers: User API) {\n    Return an <OK: status>.\n}"))
        #expect(SourceMutations.declaresFeatureSet(
            "\n\n  (Handler: UserCreated Handler) {\n}"))
    }

    @Test func aPlainStatementIsNotAFeatureSet() {
        #expect(!SourceMutations.declaresFeatureSet(
            "Log \"hi\" to the <console>."))
        // A parenthesised comment is not a header either.
        #expect(!SourceMutations.declaresFeatureSet("(* a comment *)"))
    }
}
