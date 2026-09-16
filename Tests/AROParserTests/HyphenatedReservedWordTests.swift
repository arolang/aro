// ============================================================
// HyphenatedReservedWordTests.swift
// ARO Parser Tests - reserved words inside hyphenated names
// (GitLab #579, #583)
// ============================================================
//
// Each segment of a hyphenated identifier had to be a plain identifier, so a
// segment that lexed as a keyword or preposition was a parse error wherever
// the name appeared:
//
//     Create the <content-type> with "x".            Expected identifier after '-'
//     Compute the <with-tax> from 2 * 3.             Expected identifier
//     Create the <o> with { created-at: "x" }.       Expected identifier after hyphen
//     Extract the <ct> from the <request: headers.Content-Type>.
//
// `taxed-price` and `user-email-address` were fine, so the rule was not
// discoverable by trying a few names. And the qualifier-path case has no
// workaround by renaming: `Content-Type` is the header's real name, chosen by
// whoever produced the data.
//
// After a hyphen no clause can begin, so any word there is part of the name.
// For the *first* segment a reserved word is accepted only when a hyphen
// follows — one token of lookahead, which is what keeps `with` alone a
// preposition.

import Testing
@testable import AROParser

@Suite("Reserved words in hyphenated names (GitLab #579, #583)")
struct HyphenatedReservedWordTests {

    private func errors(_ body: String) -> [Diagnostic] {
        Compiler().compile("""
        (Probe: Naming) {
            \(body)
            Return an <OK: status> for the <probe>.
        }
        """).diagnostics.filter { $0.severity == .error }
    }

    // MARK: - #583's list

    @Test("Every name the issue lists parses")
    func issueNamesParse() {
        let bodies = [
            #"Create the <content-type> with "x"."#,
            "Compute the <with-tax> from 2 * 3.",
            "Compute the <tax-with> from 2 * 3.",
            "Create the <from-date> with 1.",
            "Create the <by-age> with 1.",
        ]
        for body in bodies {
            #expect(errors(body).isEmpty, "\(body) → \(errors(body))")
        }
    }

    @Test("A reserved word is accepted at the start, the middle and the end")
    func reservedWordAnywhereInTheName() {
        for body in ["Create the <at-home> with 1.",
                     "Create the <home-at-last> with 1.",
                     "Create the <home-at> with 1."] {
            #expect(errors(body).isEmpty, "\(body) → \(errors(body))")
        }
    }

    // MARK: - #579's list

    @Test("Timestamp-shaped field names work as object-literal keys")
    func objectLiteralKeys() {
        #expect(errors(#"Create the <o> with { created-at: "x", updated-at: "y" }."#).isEmpty)
        #expect(errors(#"Create the <o> with { valid-from: "a", valid-to: "b" }."#).isEmpty)
    }

    @Test("And can be read back off the record")
    func keysAreReadable() {
        #expect(errors("""
        Create the <o> with { created-at: "x" }.
            Extract the <c> from the <o: created-at>.
        """).isEmpty)
    }

    // MARK: - The case with no rename workaround

    @Test("A qualifier path segment may be a real header name")
    func qualifierPathSegment() {
        // `Content-Type` is chosen by whoever produced the data, so renaming
        // is not available — this is the case #583 calls out as having no
        // workaround.
        #expect(errors("""
        Create the <h> with { headers: { Content-Type: "application/json" } }.
            Extract the <ct> from the <h: headers.Content-Type>.
        """).isEmpty)
    }

    // MARK: - What must not change

    @Test("A preposition alone is still a preposition")
    func prepositionAloneIsUnchanged() {
        // The lookahead only accepts a reserved first segment when a hyphen
        // follows, so every ordinary clause parses as it did.
        for body in ["Create the <a> with 5.",
                     "Compute the <b> from <a> * 2.",
                     #"Log "x" to the <console>."#,
                     "Compute the <s: sum> from <items> with { separator: \"-\" }."] {
            let diagnostics = errors("Create the <items> with [1, 2].\n    " + body)
            #expect(!diagnostics.contains { $0.message.contains("Expected") },
                    "\(body) → \(diagnostics)")
        }
    }

    @Test("A hyphen followed by something that is not a word is still an error")
    func hyphenThenNonWord() {
        // `isWordShaped` excludes literals and punctuation: a hyphen followed
        // by `42` is not a longer name.
        #expect(!errors("Create the <a-42> with 1.").isEmpty)
    }

    @Test("Names that already worked still work")
    func previouslyWorkingNames() {
        for body in ["Create the <taxed-price> with 1.",
                     "Create the <youngest-first> with 1.",
                     "Create the <user-email-address> with 1."] {
            #expect(errors(body).isEmpty, "\(body) → \(errors(body))")
        }
    }

    // MARK: - The predicate itself

    @Test("isWordShaped accepts words and rejects literals and punctuation")
    func wordShapedPredicate() {
        func tokens(_ source: String) -> [Token] {
            (try? Lexer(source: source).tokenize()) ?? []
        }
        // A preposition and a keyword are words.
        #expect(tokens("at").first?.isWordShaped == true)
        #expect(tokens("with").first?.isWordShaped == true)
        #expect(tokens("type").first?.isWordShaped == true)
        #expect(tokens("name").first?.isWordShaped == true)
        // Literals and punctuation are not.
        #expect(tokens("42").first?.isWordShaped == false)
        #expect(tokens("\"x\"").first?.isWordShaped == false)
        #expect(tokens("(").first?.isWordShaped == false)
    }
}
