// ============================================================
// MultilineStringTests.swift
// AROParser — triple-quoted string semantics (GitLab #517)
// ============================================================
//
// The literal existed but was documented nowhere — three course
// authors independently concluded multi-line strings don't parse.
// These tests pin the semantics ARO-0001 documents.
//
// The form is DEPRECATED since GitLab #523 (a plain "…" string spans
// lines now) and its removal is tracked in GitLab #524. Until then it
// still lexes, and these tests keep it honest — the dedent behaviour
// in particular, because it is what makes migration a rewrite rather
// than a swap of delimiters. See MultilinePlainStringTests for the
// replacement.

import Testing
@testable import AROParser

@Suite("Multi-line string literals")
struct MultilineStringTests {

    private func literalValue(_ source: String) throws -> String? {
        let tokens = try Lexer.tokenize(source)
        for token in tokens {
            if case .stringLiteral(let value) = token.kind { return value }
        }
        return nil
    }

    @Test("Closing-delimiter indentation is stripped; final newline dropped")
    func dedentAndTrailingNewline() throws {
        let value = try literalValue("""
        Create the <x> with \"\"\"
            line one
            line two
            \"\"\".
        """)
        #expect(value == "line one\nline two")
    }

    @Test("Blank interior lines survive as empty lines")
    func blankLines() throws {
        let value = try literalValue("""
        Create the <x> with \"\"\"
            a

            b
            \"\"\".
        """)
        #expect(value == "a\n\nb")
    }

    @Test("Interpolation syntax stays literal inside the block")
    func noInterpolation() throws {
        let value = try literalValue("""
        Create the <x> with \"\"\"
        Hello ${<name>}!
        \"\"\".
        """)
        #expect(value == "Hello ${<name>}!")
    }

    @Test("Escape sequences still work")
    func escapes() throws {
        let value = try literalValue("""
        Create the <x> with \"\"\"
        tab\\there
        \"\"\".
        """)
        #expect(value == "tab\there")
    }

    @Test("Text on the opening line is rejected")
    func openingLineRejected() {
        #expect(throws: (any Error).self) {
            _ = try Lexer.tokenize("Create the <x> with \"\"\"no newline\"\"\".")
        }
    }
}
