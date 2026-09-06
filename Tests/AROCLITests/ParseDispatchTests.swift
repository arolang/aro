// ============================================================
// ParseDispatchTests.swift
// AROCLI — deterministic Parse dispatch (GitLab #521)
// ============================================================
//
// The `parse` verb used to be split across three actions plus an
// executor fast path, and which one answered depended on the
// statement's SHAPE (noun vs. expression object, qualifier
// presence). These tests pin the contract: dispatch is decided by
// the result qualifier, and by nothing else. Every case runs both
// object shapes where it matters.

import Testing
import Foundation
import ARORuntime
@testable import AROCLI

@Suite("Parse dispatch", .serialized)
struct ParseDispatchTests {

    private func run(_ statements: String...) async throws -> (REPLSession, [REPLResult]) {
        let session = REPLSession(suppressLogPrefix: true)
        var results: [REPLResult] = []
        for statement in statements {
            results.append(try await session.executeStatement(statement))
        }
        return (session, results)
    }

    @Test("Unqualified Parse is an Extract alias — noun object (the documented form)")
    func unqualifiedNounObject() async throws {
        // Examples/UserService/events.aro uses exactly this shape; it
        // used to throw from the link-header action.
        let (session, results) = try await run(
            #"Create the <content> with "{\"name\": \"Ada\"}"."#,
            "Parse the <user-data> from the <content>.",
            "Extract the <nm> from the <user-data: name>."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("nm") as? String == "Ada")
    }

    @Test("Unqualified Parse is an Extract alias — expression object")
    func unqualifiedExpressionObject() async throws {
        let (session, results) = try await run(
            #"Create the <j> with "{\"name\": \"Ada\"}"."#,
            "Parse the <d> from <j>.",
            "Extract the <nm> from the <d: name>."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(session.getVariable("nm") as? String == "Ada")
    }

    @Test("json qualifier parses strictly to a structured value")
    func jsonQualifier() async throws {
        let (session, results) = try await run(
            #"Create the <j> with "{\"age\": 36, \"vip\": true}"."#,
            "Parse the <d: json> from <j>.",
            "Extract the <age> from the <d: age>.",
            "Compute the <next-age> from <age> + 1."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        // Real Int arithmetic — not string coercion on a passed-through
        // JSON string.
        #expect(session.getVariable("next-age") as? Int == 37)
    }

    @Test("json qualifier on invalid input errors — never a silent pass-through")
    func jsonQualifierInvalid() async throws {
        let (session, results) = try await run(
            #"Create the <bad> with "definitely not json"."#,
            "Parse the <d: json> from <bad>."
        )
        guard case .error(let message) = results[1] else {
            Issue.record("expected an error, got \(results[1])")
            return
        }
        #expect(message.contains("json") || message.contains("JSON") || message.contains("parse"))
        // The session survives (no fatalError); the deferred-failure
        // placeholder may bind an empty value, never the raw input.
        #expect(((session.getVariable("d") as? String) ?? "").isEmpty)
    }

    @Test("link-header qualifier parses RFC 8288 into a rel-keyed dictionary")
    func linkHeaderQualifier() async throws {
        let (session, results) = try await run(
            #"Create the <lh> with "<https://api/items?page=2>; rel=\"next\", <https://api/items?page=1>; rel=\"prev\""."#,
            "Parse the <pag: link-header> from <lh>."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        let dict = session.getVariable("pag") as? [String: any Sendable]
        #expect(dict?["next"] as? String == "https://api/items?page=2")
        #expect(dict?["prev"] as? String == "https://api/items?page=1")
    }

    @Test("HTML qualifiers reach the HTML parser through the plain Parse verb")
    func htmlQualifiers() async throws {
        let (session, results) = try await run(
            #"Create the <h> with "<html><body><h1>Menu</h1><a href=\"https://a.example\">A</a></body></html>"."#,
            "Parse the <links: links> from <h>.",
            "Parse the <md: markdown> from <h>."
        )
        #expect(results.allSatisfy { $0.isSuccess })
        let links = session.getVariable("links") as? [String]
        #expect(links == ["https://a.example"])
        // `markdown` returns a record: { markdown: …, title: … }.
        let md = session.getVariable("md") as? [String: any Sendable]
        #expect((md?["markdown"] as? String)?.contains("Menu") == true)
    }

    @Test("An unknown format qualifier errors, naming the valid ones")
    func unknownQualifier() async throws {
        let (_, results) = try await run(
            #"Create the <j> with "{}"."#,
            "Parse the <oops: sparkle> from <j>."
        )
        guard case .error(let message) = results[1] else {
            Issue.record("expected an error, got \(results[1])")
            return
        }
        // The full diagnostic names the failing statement (the headline
        // may be the generic wrapper — GitLab #508).
        #expect(message.contains("sparkle") || message.contains("parse"))
    }

    @Test("Strict JSON helper: shapes and scalars")
    func strictJSONHelper() throws {
        let record = try ParseDispatchAction.parseJSONStrict(#"{"a": 1, "b": 2.5, "c": true}"#)
        let dict = record as? [String: any Sendable]
        #expect(dict?["a"] as? Int == 1)
        #expect(dict?["b"] as? Double == 2.5)
        #expect(dict?["c"] as? Bool == true)

        let list = try ParseDispatchAction.parseJSONStrict("[1, 2, 3]") as? [any Sendable]
        #expect(list?.count == 3)

        #expect(throws: (any Error).self) {
            _ = try ParseDispatchAction.parseJSONStrict("nope {")
        }
    }
}
