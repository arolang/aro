// ============================================================
// RequestViaMethodTests.swift
// AROParser — `Request … via PUT the <url>` (GitLab #464)
// ============================================================
//
// ARO-0008 §3.3 documents the `via <METHOD>` form for the HTTP
// verbs GET/POST don't cover. The parser consumed the method *as*
// the object and then died on the article that followed it:
// "Expected '.', but got article(the)".
//
// The runtime never needed a change — `RequestAction` already
// reads `case .via: object.specifiers.first`. Only the syntax was
// missing, so the method parses into exactly that slot.

import Testing
@testable import AROParser

@Suite("Request via METHOD (#464)")
struct RequestViaMethodTests {

    private func requestStatement(_ line: String) throws -> AROStatement {
        let program = try Parser.parse("""
        (Call: API) {
            \(line)
        }
        """)
        let statement = program.featureSets[0].statements[0]
        return try #require(statement as? AROStatement)
    }

    @Test("The issue's own repro parses")
    func issueReproParses() throws {
        let program = try Parser.parse("""
        (Update Thing: API) {
            Create the <url> with "https://api.example.com/x".
            Create the <data> with { name: "x" }.
            Request the <result> via PUT the <url> with <data>.
            Return an <OK: status> with <result>.
        }
        """)
        #expect(program.featureSets[0].statements.count == 4)
    }

    @Test("Each documented method parses into the object's specifier",
          arguments: ["PUT", "DELETE", "PATCH", "HEAD", "OPTIONS", "GET", "POST"])
    func methodBecomesSpecifier(method: String) throws {
        let statement = try requestStatement(
            "Request the <result> via \(method) the <url>.")
        #expect(statement.object.preposition == .via)
        #expect(statement.object.noun.base == "url")
        // This is the slot RequestAction reads.
        #expect(statement.object.noun.specifiers.first == method)
    }

    @Test("Lowercase methods are normalised")
    func lowercaseMethodNormalised() throws {
        let statement = try requestStatement(
            "Request the <result> via put the <url>.")
        #expect(statement.object.noun.specifiers.first == "PUT")
    }

    @Test("A with-clause still attaches after the method")
    func withClauseSurvives() throws {
        let statement = try requestStatement(
            "Request the <result> via PATCH the <url> with <partial>.")
        #expect(statement.object.noun.specifiers.first == "PATCH")
        #expect(statement.description.contains("PATCH"))
    }

    @Test("A qualifier the author wrote still follows the method")
    func authorQualifierPreserved() throws {
        // Method first because the runtime reads `specifiers.first`;
        // anything the author wrote has to survive behind it.
        let statement = try requestStatement(
            "Request the <result> via PUT the <url: trimmed>.")
        #expect(statement.object.noun.specifiers == ["PUT", "trimmed"])
    }

    @Test("The article is optional, as everywhere else")
    func articleOptional() throws {
        let statement = try requestStatement(
            "Request the <result> via DELETE <url>.")
        #expect(statement.object.noun.base == "url")
        #expect(statement.object.noun.specifiers.first == "DELETE")
    }

    // MARK: - Regression surface

    @Test("GET via `from` is unchanged")
    func getUnchanged() throws {
        let statement = try requestStatement(
            "Request the <result> from the <url>.")
        #expect(statement.object.preposition == .from)
        #expect(statement.object.noun.specifiers.isEmpty)
    }

    @Test("POST via `to` is unchanged")
    func postUnchanged() throws {
        let statement = try requestStatement(
            "Request the <result> to the <url> with <data>.")
        #expect(statement.object.preposition == .to)
        #expect(statement.object.noun.specifiers.isEmpty)
    }

    @Test("`via <config>` is still an ordinary object")
    func viaAngleBracketObjectUnchanged() throws {
        // The method branch needs a bare identifier; an immediate
        // `<` means the author is naming a variable, not a verb.
        let statement = try requestStatement(
            "Request the <result> via the <config>.")
        #expect(statement.object.noun.base == "config")
        #expect(statement.object.noun.specifiers.isEmpty)
    }

    @Test("A non-method word after `via` is still the object")
    func nonMethodWordUnchanged() throws {
        let statement = try requestStatement(
            "Request the <result> via the <proxy>.")
        #expect(statement.object.noun.base == "proxy")
    }

    @Test("`via` on other verbs is untouched")
    func otherVerbsUnaffected() throws {
        // Only the object slot changed, and only when the word is
        // an HTTP method followed by an object — but Call/Extract
        // also take `via`, so this pins that they still parse.
        let statement = try requestStatement(
            "Extract the <value> via the <parser>.")
        #expect(statement.object.noun.base == "parser")
        #expect(statement.object.noun.specifiers.isEmpty)
    }
}
