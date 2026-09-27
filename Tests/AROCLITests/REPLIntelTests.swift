// ============================================================
// REPLIntelTests.swift
// AROCLI — LSP-backed REPL completion + inspection (ARO-0091)
// ============================================================

import Testing
import Foundation
@testable import AROCLI

@Suite("REPL completion & inspection")
struct REPLIntelTests {

    // MARK: - Framing

    @Test("A statement cell is framed the way execute frames it")
    func statementFraming() {
        let framed = REPLIntel.frame(
            code: "Compute the <x> from 1.",
            cursor: 7,
            definitions: ["(Helper: Action) {\n}"]
        )
        #expect(framed.content.hasPrefix("(_repl_temp_: Interactive) {\n"))
        #expect(framed.content.contains("(Helper: Action)"))
        // One wrapper line above; the cursor's column is untouched.
        #expect(framed.line == 1)
        #expect(framed.character == 7)
    }

    @Test("A cell that defines a feature set stands as its own document")
    func definitionFraming() {
        let code = "(Greet: Action) {\n    Return an <OK: status> for the <x>.\n}"
        let framed = REPLIntel.frame(code: code, cursor: 25, definitions: [])
        #expect(!framed.content.contains("_repl_temp_"))
        #expect(framed.line == 1)
    }

    @Test("Cursor maps across newlines")
    func cursorMapping() {
        let code = "Compute the <a> from 1.\nCompute the <b> from 2."
        // Cursor at start of the second line's verb.
        let framed = REPLIntel.frame(code: code, cursor: 24, definitions: [])
        #expect(framed.line == 2)   // wrapper + first line
        #expect(framed.character == 0)
    }

    // MARK: - Completion

    @Test("A partial verb at statement start completes to actions")
    func verbCompletion() {
        let session = REPLSession()
        let answer = REPLIntel.complete(
            code: "Comp", cursor: 4, session: session, definitions: [])
        #expect(answer.matches.contains("Compute"))
        #expect(answer.cursorStart == 0)
        #expect(answer.cursorEnd == 4)
    }

    @Test("A qualifier slot completes to qualifiers")
    func qualifierCompletion() {
        let session = REPLSession()
        let code = "Compute the <x: upp"
        let answer = REPLIntel.complete(
            code: code, cursor: code.count, session: session, definitions: [])
        #expect(answer.matches.contains("uppercase"))
    }

    @Test("Session variables complete inside an identifier bracket")
    func sessionVariableCompletion() async throws {
        let session = REPLSession()
        _ = try await session.executeStatement("Compute the <greeting> from \"hi\".")
        let code = "Log <greet"
        let answer = REPLIntel.complete(
            code: code, cursor: code.count, session: session, definitions: [])
        #expect(answer.matches.contains("greeting"))
        // The rich list labels it as what it is.
        let item = answer.items.first { ($0["label"] as? String) == "greeting" }
        #expect(item != nil)
    }

    @Test("Meta-commands complete on a line-opening ':'")
    func metaCommandCompletion() {
        let session = REPLSession()
        let answer = REPLIntel.complete(
            code: ":he", cursor: 3, session: session, definitions: [])
        // Replacement range covers "he" (the colon stays), so the
        // matches are bare command names.
        #expect(answer.matches.contains("help"))
        #expect(answer.cursorStart == 1)
    }

    @Test("A colon inside an identifier stays a qualifier slot")
    func colonDisambiguation() {
        let session = REPLSession()
        let code = "Compute the <x: le"
        let answer = REPLIntel.complete(
            code: code, cursor: code.count, session: session, definitions: [])
        #expect(answer.matches.contains("length"))
        #expect(!answer.matches.contains("help"))
    }

    // MARK: - Inspection

    @Test("Inspecting a session variable shows its live value")
    func inspectVariable() async throws {
        let session = REPLSession()
        _ = try await session.executeStatement("Compute the <answer> from 42.")
        let code = "Log <answer> to the <console>."
        let result = REPLIntel.inspect(
            code: code, cursor: 7, session: session, definitions: [])
        #expect(result.found)
        #expect(result.text?.contains("42") == true)
    }

    @Test("Inspecting a verb answers with its role")
    func inspectVerb() {
        let session = REPLSession()
        let code = "Compute the <x> from 1."
        let result = REPLIntel.inspect(
            code: code, cursor: 3, session: session, definitions: [])
        #expect(result.found)
        #expect(result.text?.localizedCaseInsensitiveContains("compute") == true)
    }

    @Test("Inspecting whitespace finds nothing")
    func inspectNothing() {
        let session = REPLSession()
        let result = REPLIntel.inspect(
            code: "   ", cursor: 1, session: session, definitions: [])
        #expect(!result.found)
    }
}
