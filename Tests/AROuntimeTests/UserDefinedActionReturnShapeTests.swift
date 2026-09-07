// ============================================================
// UserDefinedActionReturnShapeTests.swift
// ARO Runtime - What shape a user-defined action's result has at the
// call site (ARO-0081 §5, GitLab #504)
// ============================================================
//
// `Return` flattens its payload for transport: nested records become
// dot-notation keys, collections become their JSON text. That is what an HTTP
// response needs and what a caller in the same process must never see — a
// returned list used to arrive as a 51-character string, so `length` counted
// characters and `for each` ran once over one string.
//
// These tests pin the call-site contract per shape: list, empty list, nested
// record, scalar — plus the guarantee that the transport-shaped `data` is
// still there for the renderers that depend on it.

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

@Suite("User-Defined Action Return Shapes (ARO-0081 §5, GitLab #504)", .serialized)
struct UserDefinedActionReturnShapeTests {

    /// Compile and run a snippet, returning the `Application-Start` response.
    /// The user actions are unregistered afterwards so the next test starts
    /// against a clean `ActionRegistry.shared` — same pattern as
    /// `UserDefinedActionTests`.
    private func runProgram(_ source: String) async throws -> Response {
        let result = Compiler().compile(source)
        #expect(result.diagnostics.allSatisfy { $0.severity != .error },
                "Compilation produced unexpected errors: \(result.diagnostics.map(\.message))")
        let runtime = Runtime()
        let response = try await runtime.run(result.analyzedProgram)
        let host = UserDefinedActionHost(
            analyzedProgram: result.analyzedProgram,
            globalSymbols: GlobalSymbolStorage()
        )
        await host.unregister()
        return response
    }

    /// The value a caller would bind: structured where `Return` recorded it.
    private func field(_ response: Response, _ key: String) -> (any Sendable)? {
        if let structured = response.structuredData[key] { return structured }
        return response.data[key]?.get()
    }

    private func intField(_ response: Response, _ key: String) -> Int? {
        field(response, key) as? Int
    }

    /// The exact repro from GitLab #504: `length` over a returned list counted
    /// the characters of its JSON text (54) instead of its elements.
    @Test("A returned list arrives as a list, so length counts elements")
    func returnedListKeepsItsElements() async throws {
        let source = """
        (PaidOnly: Action takes <orders>) {
            Extract the <all> from the <input: orders>.
            Filter the <paid> from the <all> where <status> == "paid".
            Return an <OK: status> with { paid: <paid> }.
        }
        (Application-Start: Demo) {
            Create the <orders> with [
                { id: 1, status: "paid" },
                { id: 2, status: "open" },
                { id: 3, status: "paid" }
            ].
            Application.PaidOnly the <res> from <orders>.
            Extract the <paid-list> from the <res: paid>.
            Compute the <n: length> from <paid-list>.
            Return an <OK: status> with { n: <n> }.
        }
        """
        let response = try await runProgram(source)
        #expect(response.status == "OK")
        #expect(intField(response, "n") == 2)
    }

    /// The other half of the bug: a JSON string is one element, so the loop
    /// body ran once no matter how long the list was.
    @Test("for each over a returned list visits every element")
    func forEachOverReturnedListVisitsEveryElement() async throws {
        let source = """
        (PaidOnly: Action takes <orders>) {
            Extract the <all> from the <input: orders>.
            Filter the <paid> from the <all> where <status> == "paid".
            Return an <OK: status> with { paid: <paid> }.
        }
        (Application-Start: Demo) {
            Create the <orders> with [
                { id: 1, status: "paid" },
                { id: 2, status: "open" },
                { id: 3, status: "paid" }
            ].
            Application.PaidOnly the <res> from <orders>.
            Extract the <paid-list> from the <res: paid>.
            for each <o> in <paid-list> {
                Store the <o> into the <visited-repository>.
            }
            Retrieve the <visited> from the <visited-repository>.
            Compute the <iterations: length> from <visited>.
            Return an <OK: status> with { iterations: <iterations> }.
        }
        """
        let response = try await runProgram(source)
        #expect(response.status == "OK")
        #expect(intField(response, "iterations") == 2)
    }

    /// An empty list used to come back as the two characters `[]`.
    @Test("A returned empty list is empty, not the two characters of its JSON")
    func returnedEmptyListIsEmpty() async throws {
        let source = """
        (NoneOf: Action takes <orders>) {
            Extract the <all> from the <input: orders>.
            Filter the <matching> from the <all> where <status> == "cancelled".
            Return an <OK: status> with { matching: <matching> }.
        }
        (Application-Start: Demo) {
            Create the <orders> with [{ id: 1, status: "paid" }].
            Application.NoneOf the <res> from <orders>.
            Extract the <unmatched> from the <res: matching>.
            Compute the <n: length> from <unmatched>.
            Return an <OK: status> with { n: <n> }.
        }
        """
        let response = try await runProgram(source)
        #expect(response.status == "OK")
        #expect(intField(response, "n") == 0)
    }

    /// A nested record was flattened to `profile.name`, so `<res: profile>`
    /// resolved to nothing and the extraction failed outright.
    @Test("A returned nested record stays a record the caller can walk into")
    func nestedRecordStaysStructured() async throws {
        let source = """
        (Describe: Action takes <name>) {
            Extract the <n> from the <input: name>.
            Return an <OK: status> with { profile: { name: <n>, age: 36 } }.
        }
        (Application-Start: Demo) {
            Application.Describe the <res> from "Ada".
            Extract the <profile> from the <res: profile>.
            Extract the <who> from the <profile: name>.
            Extract the <age> from the <profile: age>.
            Return an <OK: status> with { who: <who>, age: <age> }.
        }
        """
        let response = try await runProgram(source)
        #expect(response.status == "OK")
        #expect(field(response, "who") as? String == "Ada")
        #expect(intField(response, "age") == 36)
    }

    /// Scalars always round-tripped; the fix must leave them exactly as they
    /// were, including the documented `value` key for a bare variable payload.
    @Test("Scalars round-trip unchanged")
    func scalarsRoundTripUnchanged() async throws {
        let source = """
        (Doubler: Action takes <number>) {
            Extract the <n> from the <input: number>.
            Compute the <doubled> from <n> * 2.
            Return an <OK: status> with { doubled: <doubled> }.
        }
        (Shout: Action takes <word>) {
            Extract the <w> from the <input: word>.
            Compute the <loud: uppercase> from <w>.
            Return an <OK: status> with <loud>.
        }
        (Application-Start: Demo) {
            Application.Doubler the <d> from 21.
            Extract the <doubled> from the <d: doubled>.
            Application.Shout the <s> from "ada".
            Extract the <loud> from the <s: value>.
            Return an <OK: status> with { doubled: <doubled>, loud: <loud> }.
        }
        """
        let response = try await runProgram(source)
        #expect(response.status == "OK")
        #expect(intField(response, "doubled") == 42)
        #expect(field(response, "loud") as? String == "ADA")
    }

    /// A list returned two calls deep, through an action that forwards
    /// another action's result, must still be a list.
    @Test("A list survives a chain of user-defined actions")
    func listSurvivesChainedCalls() async throws {
        let source = """
        (Inner: Action takes <tag>) {
            Extract the <label> from the <input: tag>.
            Create the <items> with [{ id: 1 }, { id: 2 }, { id: 3 }, { id: 4 }].
            Return an <OK: status> with { items: <items>, label: <label> }.
        }
        (Outer: Action takes <tag>) {
            Extract the <label> from the <input: tag>.
            Application.Inner the <inner> from <label>.
            Extract the <items> from the <inner: items>.
            Return an <OK: status> with { items: <items> }.
        }
        (Application-Start: Demo) {
            Application.Outer the <res> from "batch".
            Extract the <items> from the <res: items>.
            Compute the <n: length> from <items>.
            Return an <OK: status> with { n: <n> }.
        }
        """
        let response = try await runProgram(source)
        #expect(response.status == "OK")
        #expect(intField(response, "n") == 4)
    }

    /// The transport shape is what HTTP and the CLI render, and it must not
    /// have changed: `data` still carries the flattened, JSON-serialized copy.
    @Test("Response.data keeps its flattened transport shape")
    func transportShapeUnchanged() async throws {
        let source = """
        (Application-Start: Demo) {
            Create the <items> with [1, 2, 3].
            Create the <who> with { name: "Ada" }.
            Return an <OK: status> with { items: <items>, who: <who> }.
        }
        """
        let response = try await runProgram(source)
        // Lists are JSON text in `data` …
        let serialized: String? = response.data["items"]?.get()
        #expect(serialized?.hasPrefix("[") == true)
        // … and nested records are dot-notation keys.
        #expect(response.data["who.name"]?.get() == "Ada")
        // The structured copy carries the values themselves.
        #expect((response.structuredData["items"] as? [any Sendable])?.count == 3)
        #expect((response.structuredData["who"] as? [String: any Sendable])?["name"] as? String == "Ada")
    }
}
