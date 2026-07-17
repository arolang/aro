// ============================================================
// StatementReorderTests.swift
// SOLARO — drag-reorder text transform (#376, Swift Testing)
// ============================================================

import Testing
import Foundation
@testable import SOLARO

@Suite("StatementReorder.movingStatement")
struct StatementReorderTests {

    /// Statement offsets in these fixtures are located by string
    /// search so the tests don't hard-code byte positions.
    private func range(of needle: String, in text: String) -> Range<Int> {
        let r = (text as NSString).range(of: needle)
        #expect(r.location != NSNotFound, "fixture must contain \(needle)")
        return r.location ..< (r.location + r.length)
    }

    private let fixture = """
    (Application-Start: Probe) {
        Extract the <id> from the <request: id>.
        Compute the <total> from <price> * <qty>.
        Log <total> to the <console>.
        Return an <OK: status> with <total>.
    }
    """

    @Test func movesStatementBeforeTarget() throws {
        let src = range(of: "Log <total> to the <console>.", in: fixture)
        let dst = range(of: "Extract the <id> from the <request: id>.",
                        in: fixture)
        let out = try #require(StatementReorder.movingStatement(
            in: fixture, source: src, target: dst, insertBefore: true
        ))
        let lines = out.components(separatedBy: "\n")
        #expect(lines[1] == "    Log <total> to the <console>.")
        #expect(lines[2] == "    Extract the <id> from the <request: id>.")
        #expect(lines[3] == "    Compute the <total> from <price> * <qty>.")
        #expect(lines[4] == "    Return an <OK: status> with <total>.")
    }

    @Test func movesStatementAfterTarget() throws {
        let src = range(of: "Extract the <id> from the <request: id>.",
                        in: fixture)
        let dst = range(of: "Log <total> to the <console>.", in: fixture)
        let out = try #require(StatementReorder.movingStatement(
            in: fixture, source: src, target: dst, insertBefore: false
        ))
        let lines = out.components(separatedBy: "\n")
        #expect(lines[1] == "    Compute the <total> from <price> * <qty>.")
        #expect(lines[2] == "    Log <total> to the <console>.")
        #expect(lines[3] == "    Extract the <id> from the <request: id>.")
    }

    @Test func adjacentBeforeIsPositionalNoOp() throws {
        // A already precedes B — "move A before B" changes nothing.
        let src = range(of: "Extract the <id> from the <request: id>.",
                        in: fixture)
        let dst = range(of: "Compute the <total> from <price> * <qty>.",
                        in: fixture)
        let out = try #require(StatementReorder.movingStatement(
            in: fixture, source: src, target: dst, insertBefore: true
        ))
        #expect(out == fixture)
    }

    @Test func adjacentAfterIsPositionalNoOp() throws {
        // B already follows A — "move B after A" changes nothing.
        let src = range(of: "Compute the <total> from <price> * <qty>.",
                        in: fixture)
        let dst = range(of: "Extract the <id> from the <request: id>.",
                        in: fixture)
        let out = try #require(StatementReorder.movingStatement(
            in: fixture, source: src, target: dst, insertBefore: false
        ))
        #expect(out == fixture)
    }

    @Test func droppingOnItselfReturnsNil() {
        let src = range(of: "Log <total> to the <console>.", in: fixture)
        let out = StatementReorder.movingStatement(
            in: fixture, source: src, target: src, insertBefore: true
        )
        #expect(out == nil)
    }

    @Test func outOfBoundsRangeReturnsNil() {
        let src = range(of: "Log <total> to the <console>.", in: fixture)
        let out = StatementReorder.movingStatement(
            in: fixture, source: src,
            target: fixture.utf16.count ..< fixture.utf16.count + 10,
            insertBefore: true
        )
        #expect(out == nil)
    }

    @Test func multiLineStatementMovesAsOneBlock() throws {
        let text = """
        (Setup: App) {
            Clone the <repo> from the <git> with { url: "https://x.test",
                path: "./cloned" }.
            Log "done" to the <console>.
        }
        """
        // Span covers both physical lines of the Clone statement.
        let start = range(of: "Clone the <repo>", in: text).lowerBound
        let end = range(of: "path: \"./cloned\" }.", in: text).upperBound
        let dst = range(of: "Log \"done\" to the <console>.", in: text)
        let out = try #require(StatementReorder.movingStatement(
            in: text, source: start ..< end, target: dst,
            insertBefore: false
        ))
        let lines = out.components(separatedBy: "\n")
        #expect(lines[1] == "    Log \"done\" to the <console>.")
        #expect(lines[2].contains("Clone the <repo>"))
        #expect(lines[3].contains("path: \"./cloned\" }."))
        #expect(lines[4] == "}")
    }

    @Test func statementAtEOFWithoutNewlineGainsOne() throws {
        let text = "First line.\nSecond line."
        let src = range(of: "Second line.", in: text)
        let dst = range(of: "First line.", in: text)
        let out = try #require(StatementReorder.movingStatement(
            in: text, source: src, target: dst, insertBefore: true
        ))
        #expect(out == "Second line.\nFirst line.\n")
    }

    @Test func indentationTravelsWithTheStatement() throws {
        let text = "(FS: A) {\n        Deep <a>.\n    Shallow <b>.\n}\n"
        let src = range(of: "Deep <a>.", in: text)
        let dst = range(of: "Shallow <b>.", in: text)
        let out = try #require(StatementReorder.movingStatement(
            in: text, source: src, target: dst, insertBefore: false
        ))
        #expect(out == "(FS: A) {\n    Shallow <b>.\n        Deep <a>.\n}\n")
    }
}
