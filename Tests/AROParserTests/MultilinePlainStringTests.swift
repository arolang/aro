// ============================================================
// MultilinePlainStringTests.swift
// AROParser — plain "…" strings span lines (GitLab #523)
// ============================================================
//
// One delimiter for every string: a newline inside "…" is content,
// exactly like any other character. Triple-quoted strings still lex
// but carry a deprecation warning; their removal is a separate,
// announced step.

import Testing
@testable import AROParser

@Suite("Multiline plain strings")
struct MultilinePlainStringTests {

    private func lexOnly(_ source: String) throws -> [Token] {
        try Lexer(source: source).tokenize()
    }

    private func firstString(_ source: String) throws -> String? {
        for token in try lexOnly(source) {
            if case .stringLiteral(let value) = token.kind { return value }
        }
        return nil
    }

    @Test("A newline inside a plain string is content")
    func newlinesAreContent() throws {
        let value = try firstString("Create the <t> with \"one\ntwo\nthree\".")
        #expect(value == "one\ntwo\nthree")
    }

    @Test("Escapes keep working across lines")
    func escapesAcrossLines() throws {
        let value = try firstString("Create the <t> with \"a\\tb\nc\\\"d\".")
        #expect(value == "a\tb\nc\"d")
    }

    @Test("Interpolation works inside a multiline string")
    func interpolationSpansLines() throws {
        // The ${…} expression itself stays on one line; the string
        // around it may break wherever it likes.
        let tokens = try lexOnly("Create the <t> with \"Dear ${<name>},\nwelcome\".")
        #expect(tokens.contains { if case .interpolationStart = $0.kind { return true } else { return false } })
        #expect(tokens.contains { if case .stringSegment(let s) = $0.kind { return s.contains("\nwelcome") } else { return false } })
    }

    @Test("An unterminated string is reported at its opening quote")
    func unterminatedReportsOpeningLine() {
        // The string now swallows following lines, so pointing at the
        // opening quote is what keeps the typo findable.
        do {
            _ = try lexOnly("Create the <t> with \"never closed.\nLog <t> to the <console>.")
            Issue.record("expected unterminatedString")
        } catch let error as LexerError {
            guard case .unterminatedString(let at) = error else {
                Issue.record("expected unterminatedString, got \(error)")
                return
            }
            #expect(at.line == 1)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("Triple-quoted strings are an error naming the replacement")
    func tripleQuotedRemoved() {
        let source = """
        (Removal Probe: Test) {
            Create the <t> with \"\"\"
                content
                \"\"\".
            Log <t> to the <console>.
            Return an <OK: status> for the <run>.
        }
        """
        let result = Compiler().compile(source)
        #expect(!result.isSuccess)
        let errors = result.diagnostics.filter { $0.severity == .error }
        // One mistake, one diagnostic: the literal is replaced by a
        // placeholder token so the statement keeps its shape and the
        // parser does not add a second, misleading complaint.
        #expect(errors.count == 1, "\(result.diagnostics.map(\.message))")
        #expect(errors.first?.message.contains("Triple-quoted strings were removed") == true)
        #expect(errors.first?.hints.contains { $0.contains("plain") } == true)
    }

    @Test("An empty string is not mistaken for a removed delimiter")
    func emptyStringUnaffected() {
        // `""` is two quotes, not three — the detection must not widen.
        // (The feature set is named "Blank", not "Empty": a keyword
        // cannot open a feature-set name — GitLab #497, unrelated.)
        let result = Compiler().compile("""
        (Blank Probe: Test) {
            Create the <t> with "".
            Log <t> to the <console>.
            Return an <OK: status> for the <run>.
        }
        """)
        #expect(result.isSuccess, "\(result.diagnostics.map(\.message))")
    }

    @Test("Raw '…' strings keep their single-line rule")
    func rawStringsUnchanged() {
        // Scope pin: #523 changed \"…\" only.
        #expect(throws: (any Error).self) {
            _ = try lexOnly("Create the <t> with 'one\ntwo'.")
        }
    }

    @Test("A multiline string parses inside a full feature set")
    func compilesEndToEnd() {
        let result = Compiler().compile("""
        (Multiline Probe: Test) {
            Create the <letter> with "Dear reader,
        this spans lines.".
            Log <letter> to the <console>.
            Return an <OK: status> for the <run>.
        }
        """)
        #expect(result.isSuccess, "\(result.diagnostics.map(\.message))")
    }
}
