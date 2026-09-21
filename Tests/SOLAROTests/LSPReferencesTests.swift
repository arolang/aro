// ============================================================
// LSPReferencesTests.swift
// SOLARO — references, document symbols, rename preview (GitLab #764)
// ============================================================
//
// The server has advertised referencesProvider, documentSymbolProvider
// and workspaceSymbolProvider all along. The IDE never asked, so "where
// is this event handled?" — the question an event-driven language is
// built around — was the one navigation it could not answer.

import Testing
import Foundation
@testable import SOLARO

@Suite("LSP references and symbols")
@MainActor
struct LSPReferencesTests {

    private func location(_ path: String, line0: Int, char: Int) -> [String: Any] {
        [
            "uri": URL(fileURLWithPath: path).absoluteString,
            "range": [
                "start": ["line": line0, "character": char],
                "end": ["line": line0, "character": char + 4],
            ],
        ]
    }

    // MARK: - references

    @Test func parsesAListOfLocations() {
        let raw: Any = [
            location("/p/users.aro", line0: 4, char: 8),
            location("/p/orders.aro", line0: 11, char: 0),
        ]
        let parsed = AROLSPClient.parseLocationsForTesting(raw)
        #expect(parsed.count == 2)
        // LSP lines are 0-based; the editor's are 1-based.
        #expect(parsed[0].line == 5)
        #expect(parsed[0].character == 8)
        #expect(parsed[1].url.lastPathComponent == "orders.aro")
    }

    @Test func aServerWithNothingToSayParsesToNoLocations() {
        #expect(AROLSPClient.parseLocationsForTesting(nil).isEmpty)
        #expect(AROLSPClient.parseLocationsForTesting([]).isEmpty)
        #expect(AROLSPClient.parseLocationsForTesting("nonsense").isEmpty)
    }

    // MARK: - documentSymbol

    @Test func readsTheHierarchicalShape() {
        // DocumentSymbol[]: nested, with selectionRange on the name.
        let url = URL(fileURLWithPath: "/p/users.aro")
        let raw: Any = [[
            "name": "listUsers",
            "kind": 12,
            "range": ["start": ["line": 0, "character": 0],
                      "end": ["line": 6, "character": 1]],
            "selectionRange": ["start": ["line": 0, "character": 1],
                               "end": ["line": 0, "character": 10]],
            "children": [[
                "name": "users",
                "kind": 13,
                "selectionRange": ["start": ["line": 2, "character": 16],
                                   "end": ["line": 2, "character": 21]],
            ]],
        ]]
        let parsed = AROLSPClient.parseDocumentSymbols(raw, url: url)
        #expect(parsed.count == 2)
        #expect(parsed[0].name == "listUsers")
        #expect(parsed[0].line == 1)
        // The child keeps its parent's name, so a row still reads as
        // belonging to its feature set.
        #expect(parsed[1].name == "users")
        #expect(parsed[1].containerName == "listUsers")
    }

    @Test func readsTheFlatShape() {
        // SymbolInformation[]: a location, and a flat containerName.
        let url = URL(fileURLWithPath: "/p/users.aro")
        let raw: Any = [[
            "name": "createUser",
            "kind": 12,
            "containerName": "User API",
            "location": location("/p/users.aro", line0: 9, char: 1),
        ]]
        let parsed = AROLSPClient.parseDocumentSymbols(raw, url: url)
        #expect(parsed.count == 1)
        #expect(parsed[0].name == "createUser")
        #expect(parsed[0].containerName == "User API")
        #expect(parsed[0].line == 10)
    }

    @Test func aSymbolWithoutANameIsSkipped() {
        let url = URL(fileURLWithPath: "/p/users.aro")
        let raw: Any = [["kind": 12]]
        #expect(AROLSPClient.parseDocumentSymbols(raw, url: url).isEmpty)
    }

    // MARK: - rename preview

    @Test func thePreviewGroupsEditsByFile() {
        let users = URL(fileURLWithPath: "/p/users.aro")
        let orders = URL(fileURLWithPath: "/p/orders.aro")
        let edits = [
            AROLSPClient.TextEdit(url: users, startLine: 1, startChar: 0,
                                  endLine: 1, endChar: 4, newText: "x"),
            AROLSPClient.TextEdit(url: users, startLine: 7, startChar: 2,
                                  endLine: 7, endChar: 6, newText: "x"),
            AROLSPClient.TextEdit(url: orders, startLine: 3, startChar: 0,
                                  endLine: 3, endChar: 4, newText: "x"),
        ]
        let preview = RenamePreview(edits: edits)
        #expect(preview.totalEdits == 3)
        #expect(preview.files.count == 2)
        #expect(preview.summary == "3 occurrences in 2 files")
        // Alphabetical, so the list does not reshuffle between previews.
        #expect(preview.files.first?.url.lastPathComponent == "orders.aro")
        #expect(preview.files.last?.edits == 2)
    }

    @Test func aRenameThatTouchesNothingSaysSo() {
        let preview = RenamePreview(edits: [])
        #expect(preview.isEmpty)
        #expect(preview.totalEdits == 0)
    }

    @Test func oneOccurrenceReadsAsSingular() {
        let preview = RenamePreview(edits: [
            AROLSPClient.TextEdit(url: URL(fileURLWithPath: "/p/a.aro"),
                                  startLine: 0, startChar: 0,
                                  endLine: 0, endChar: 1, newText: "b"),
        ])
        #expect(preview.summary == "1 occurrence in 1 file")
        #expect(preview.files.first?.label == "a.aro — 1 occurrence")
    }
}
