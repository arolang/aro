// ============================================================
// NestedStatementNavigationTests.swift
// AROLSP - Navigation inside nested blocks (GitLab #723)
// ============================================================
//
// Every navigation handler used to carry its own copy of "walk the
// statements", and every copy had drifted. `grep WhenStatement
// Sources/AROLSP` found nothing, so a name that appeared only inside a
// `when { … }` block was invisible to rename, references, hover and
// go-to-definition: the request did not fail, it returned nothing, which in
// an editor reads as "this name is used exactly once" or "this symbol cannot
// be renamed". A match's `otherwise` branch was missed the same way.
//
// These tests pin the behaviour to the shared walker rather than to any one
// handler's chain: they ask for a symbol that exists *only* inside a nested
// block, so a handler that does not descend answers nil.

#if !os(Windows)
import Testing
import Foundation
@testable import AROLSP
@testable import AROParser
import LanguageServerProtocol

/// A feature set whose only mention of `nickname` is inside a `when` block.
private let whenBlockSource = """
(Test: Business) {
    Extract the <user> from the <request>.
    when <user> is not empty {
        Compute the <nickname: uppercase> from <user>.
        Log <nickname> to the <console>.
    }
    Return an <OK: status> for the <request>.
}
"""

/// A feature set whose only mention of `fallback` is inside a match's
/// `otherwise` branch — the other half of what the old chains skipped.
private let matchOtherwiseSource = """
(Test: Business) {
    Extract the <state> from the <request>.
    match <state> {
        case "ready" {
            Log "ready" to the <console>.
        }
        otherwise {
            Compute the <fallback: uppercase> from <state>.
            Log <fallback> to the <console>.
        }
    }
    Return an <OK: status> for the <request>.
}
"""

/// The LSP position of the `occurrence`-th appearance of `needle`, one
/// character in — far enough inside the identifier that it lands within the
/// span whatever the surrounding `<`/`>` do.
private func position(of needle: String, occurrence: Int = 1, in source: String) -> Position {
    var remaining = occurrence
    for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        var searchStart = line.startIndex
        while let found = line.range(of: needle, range: searchStart..<line.endIndex) {
            remaining -= 1
            if remaining == 0 {
                let character = line.utf16.distance(from: line.startIndex, to: found.lowerBound)
                return Position(line: index, character: character + 1)
            }
            searchStart = found.upperBound
        }
    }
    Issue.record("No occurrence \(occurrence) of '\(needle)' in the test source")
    return Position(line: 0, character: 0)
}

@Suite("Navigation Inside Nested Blocks (GitLab #723)")
struct NestedStatementNavigationTests {

    // MARK: - when { … }

    @Test("References finds a name used only inside a when block")
    func testReferencesInsideWhenBlock() {
        let result = ReferencesHandler().handle(
            uri: "file:///test.aro",
            position: position(of: "nickname", in: whenBlockSource),
            content: whenBlockSource,
            compilationResult: Compiler.compile(whenBlockSource)
        )

        // The binding in `Compute` and the read in `Log`.
        #expect(result?.count == 2)
    }

    @Test("Rename edits a name used only inside a when block")
    func testRenameInsideWhenBlock() {
        let result = RenameHandler().handle(
            uri: "file:///test.aro",
            position: position(of: "nickname", in: whenBlockSource),
            newName: "handle",
            content: whenBlockSource,
            compilationResult: Compiler.compile(whenBlockSource)
        )

        let changes = result?["changes"] as? [String: Any]
        let edits = changes?["file:///test.aro"] as? [[String: Any]]
        #expect(edits?.count == 2)
        #expect(edits?.allSatisfy { ($0["newText"] as? String) == "<handle>" } == true)
    }

    @Test("prepareRename offers a name inside a when block")
    func testPrepareRenameInsideWhenBlock() {
        let result = RenameHandler().prepareRename(
            uri: "file:///test.aro",
            position: position(of: "nickname", in: whenBlockSource),
            content: whenBlockSource,
            compilationResult: Compiler.compile(whenBlockSource)
        )

        #expect(result?["placeholder"] as? String == "nickname")
    }

    @Test("Hover answers for a statement inside a when block")
    func testHoverInsideWhenBlock() {
        let result = HoverHandler().handle(
            position: position(of: "nickname", in: whenBlockSource),
            content: whenBlockSource,
            compilationResult: Compiler.compile(whenBlockSource)
        )

        let contents = result?["contents"] as? [String: Any]
        #expect((contents?["value"] as? String)?.contains("nickname") == true)
    }

    @Test("Go to definition resolves a read inside a when block")
    func testDefinitionInsideWhenBlock() {
        // `<user>` is bound outside the block and read inside it, so the
        // answer is the binding's own line — which the handler can only
        // reach by descending into the block to find the read.
        let result = DefinitionHandler().handle(
            uri: "file:///test.aro",
            position: position(of: "user", occurrence: 3, in: whenBlockSource),
            content: whenBlockSource,
            compilationResult: Compiler.compile(whenBlockSource)
        )

        let range = result?["range"] as? [String: Any]
        let start = range?["start"] as? [String: Any]
        #expect(start?["line"] as? Int == 1)   // the `Extract` statement
    }

    @Test("Inlay hints reach a binding inside a when block")
    func testInlayHintsInsideWhenBlock() {
        let hints = InlayHintHandler().handle(
            compilationResult: Compiler.compile(whenBlockSource),
            startLine: 0,
            endLine: 10
        )

        // Line 3 (0-based) is the `Compute` inside the block.
        #expect(hints?.contains { ($0["position"] as? [String: Any])?["line"] as? Int == 3 } == true)
    }

    @Test("A when block is a folding range")
    func testFoldingRangeForWhenBlock() {
        let ranges = FoldingRangeHandler().handle(
            compilationResult: Compiler.compile(whenBlockSource)
        )

        // The block opens on line 2 (0-based) and closes on line 5.
        #expect(ranges?.contains {
            ($0["startLine"] as? Int) == 2 && ($0["endLine"] as? Int) == 5
        } == true)
    }

    // MARK: - match … otherwise

    @Test("References finds a name used only in a match's otherwise branch")
    func testReferencesInsideMatchOtherwise() {
        let result = ReferencesHandler().handle(
            uri: "file:///test.aro",
            position: position(of: "fallback", in: matchOtherwiseSource),
            content: matchOtherwiseSource,
            compilationResult: Compiler.compile(matchOtherwiseSource)
        )

        #expect(result?.count == 2)
    }

    @Test("Rename edits a name used only in a match's otherwise branch")
    func testRenameInsideMatchOtherwise() {
        let result = RenameHandler().handle(
            uri: "file:///test.aro",
            position: position(of: "fallback", in: matchOtherwiseSource),
            newName: "backstop",
            content: matchOtherwiseSource,
            compilationResult: Compiler.compile(matchOtherwiseSource)
        )

        let changes = result?["changes"] as? [String: Any]
        let edits = changes?["file:///test.aro"] as? [[String: Any]]
        #expect(edits?.count == 2)
    }
}

#endif
