// ============================================================
// JSONREPLTests.swift
// AROCLI - Tests for `aro repl --json` (the Jupyter kernel backend)
// ============================================================
//
// The pieces tested here are the ones a notebook depends on and a terminal
// REPL never exercises: splitting a whole cell into units, and turning a
// runtime value into something a front-end can render.

import Testing
import Foundation
@testable import AROCLI

@Suite("REPL cell splitting")
struct REPLCellSplitterTests {

    @Test("A blank cell has no units")
    func blankCell() {
        #expect(REPLCellSplitter.split("").isEmpty)
        #expect(REPLCellSplitter.split("\n  \n\t\n").isEmpty)
    }

    @Test("Consecutive statements stay one unit")
    func statementsStayTogether() {
        // Not an aesthetic choice: statements in one feature set may overlap
        // their I/O (ARO-0088), and splitting them would serialise work the
        // language is allowed to run concurrently.
        let units = REPLCellSplitter.split("""
        Compute the <a> from 1.
        Compute the <b> from 2.
        """)
        #expect(units.count == 1)
        guard case .statements(let source, let line) = units[0] else {
            Issue.record("expected one statements unit, got \(units)")
            return
        }
        #expect(source.contains("<a>") && source.contains("<b>"))
        #expect(line == 0)
    }

    @Test("A feature set is its own unit")
    func featureSetUnit() {
        let units = REPLCellSplitter.split("""
        (Greet: Action takes <name>) {
            Extract the <n> from the <input: name>.
            Return an <OK: status> with <n>.
        }
        """)
        #expect(units.count == 1)
        guard case .featureSet(let name, let activity, _, _) = units[0] else {
            Issue.record("expected a featureSet unit, got \(units)")
            return
        }
        #expect(name == "Greet")
        #expect(activity == "Action takes <name>")
    }

    @Test("A cell mixing a definition and statements splits in source order")
    func mixedCell() {
        let units = REPLCellSplitter.split("""
        Compute the <before> from 1.
        (Greet: Action) {
            Return an <OK: status> with "hi".
        }
        Compute the <after> from 2.
        :vars
        """)

        #expect(units.count == 4)
        guard case .statements = units[0] else { Issue.record("unit 0"); return }
        guard case .featureSet(let name, _, _, let line) = units[1] else { Issue.record("unit 1"); return }
        guard case .statements = units[2] else { Issue.record("unit 2"); return }
        guard case .meta(let command, _) = units[3] else { Issue.record("unit 3"); return }

        #expect(name == "Greet")
        #expect(line == 1)
        #expect(command == ":vars")
    }

    @Test("A statement spanning lines is not split at a brace")
    func multiLineStatement() {
        // The object literal opens a brace, so line-by-line splitting would
        // cut this statement in half and produce two syntax errors.
        let units = REPLCellSplitter.split("""
        Create the <user> with {
            name: "Ada",
            role: "engineer"
        }.
        """)
        #expect(units.count == 1)
        guard case .statements(let source, _) = units[0] else {
            Issue.record("expected one statements unit, got \(units)")
            return
        }
        #expect(source.contains("engineer"))
    }

    @Test("Meta-commands are one line each")
    func metaCommands() {
        let units = REPLCellSplitter.split(":vars\n:fs")
        #expect(units.count == 2)
        guard case .meta(let first, _) = units[0], case .meta(let second, _) = units[1] else {
            Issue.record("expected two meta units, got \(units)")
            return
        }
        #expect(first == ":vars")
        #expect(second == ":fs")
    }
}

@Suite("REPL display bundles")
struct REPLDisplayTests {

    @Test("A scalar carries text and JSON")
    func scalar() {
        let bundle = REPLDisplay.bundle(for: 42)
        #expect(bundle["text/plain"] as? String == "42")
        #expect(bundle["application/json"] as? Int == 42)
        #expect(bundle["text/html"] == nil)
    }

    @Test("A list of records renders as an HTML table")
    func recordList() {
        let rows: [any Sendable] = [
            ["name": "Ada", "score": 99] as [String: any Sendable],
            ["name": "Alan", "score": 91] as [String: any Sendable]
        ]
        let bundle = REPLDisplay.bundle(for: rows)

        guard let html = bundle["text/html"] as? String else {
            Issue.record("expected an HTML table, got \(bundle.keys.sorted())")
            return
        }
        #expect(html.contains("<th>name</th>"))
        #expect(html.contains("<td>Ada</td>"))
        #expect(html.contains("<td>91</td>"))
    }

    @Test("A list of scalars gets no table")
    func scalarList() {
        // A one-column table is noise; text/plain already reads well.
        let bundle = REPLDisplay.bundle(for: ["a", "b"] as [any Sendable])
        #expect(bundle["text/html"] == nil)
        #expect(bundle["application/json"] as? [String] == ["a", "b"])
    }

    @Test("HTML-significant characters in data are escaped")
    func escaping() {
        let rows: [any Sendable] = [["tag": "<script>&"] as [String: any Sendable]]
        guard let html = REPLDisplay.bundle(for: rows)["text/html"] as? String else {
            Issue.record("expected an HTML table")
            return
        }
        #expect(html.contains("&lt;script&gt;&amp;"))
        #expect(!html.contains("<script>"))
    }
}

@Suite("REPL JSON protocol")
struct JSONREPLProtocolTests {

    @Test("A result line is one JSON object with its request id")
    func resultLine() throws {
        let line = JSONREPLEncoder.result(id: 7, status: .ok, extra: ["durationMs": 1.5])
        #expect(!line.contains("\n"))

        let decoded = try #require(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        #expect(decoded["id"] as? Int == 7)
        #expect(decoded["type"] as? String == "result")
        #expect(decoded["status"] as? String == "ok")
    }

    @Test("An ARO error keeps its whole block as the traceback")
    func errorSplit() {
        // ARO-0006: the runtime's message names the feature and statement.
        // Only the first line is the summary — dropping the rest would throw
        // away the part that says where it happened.
        let error = JSONREPLError(message: """
        Runtime Error: Cannot compute the total from the price.
          Feature: _repl_session_
          Statement: <Compute> the <total> from <price>.
        """)
        #expect(error.value == "Runtime Error: Cannot compute the total from the price.")
        #expect(error.traceback.count == 3)
        #expect(error.name == "AROError")
    }

    @Test("Stream messages carry their request id")
    func streamLine() throws {
        let line = JSONREPLEncoder.stream(id: 3, name: "stderr", text: "boom\n")
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        #expect(decoded["id"] as? Int == 3)
        #expect(decoded["name"] as? String == "stderr")
        #expect(decoded["text"] as? String == "boom\n")
    }
}
