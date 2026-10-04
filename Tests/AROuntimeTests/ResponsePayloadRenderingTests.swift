// ============================================================
// ResponsePayloadRenderingTests.swift
// ARO Runtime - The two renderings of a response payload agree
// (GitLab #711)
// ============================================================
//
// A response used to carry its payload twice: the values the program produced
// and a flattened copy built eagerly for transport. The HTTP renderer read the
// flat copy and parsed each collection's JSON text back into a JSON value so
// it could re-serialise it into the body — encode → string → decode → encode
// on every response containing a list.
//
// `ResponsePayload.jsonObject` now goes from the payload to that JSON value
// directly. These tests pin that it lands on the *same* value the old route
// did, by rendering both ways and comparing the serialised bytes: the flat
// form is still there (`Response.data`, computed on demand), so the old route
// can be reconstructed here and asserted against.

import Foundation
import Testing
@testable import ARORuntime

@Suite("Response Payload Rendering (GitLab #711)")
struct ResponsePayloadRenderingTests {

    /// The route the HTTP renderer used to take: read the flattened
    /// dictionary, and inline any value that is JSON text.
    private func legacyJSONObject(_ response: Response) -> [String: Any] {
        var json: [String: Any] = [:]
        for (key, wrapped) in response.data {
            if let str: String = wrapped.get() {
                if str.hasPrefix("{") || str.hasPrefix("[") {
                    // try? is acceptable: this reproduces the old probe, which
                    // kept the raw string when it did not parse.
                    if let data = str.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: data) {
                        json[key] = parsed
                    } else {
                        json[key] = str
                    }
                } else {
                    json[key] = str
                }
            } else if let int: Int = wrapped.get() {
                json[key] = int
            } else if let double: Double = wrapped.get() {
                json[key] = double
            } else if let bool: Bool = wrapped.get() {
                json[key] = bool
            } else {
                json[key] = String(describing: wrapped)
            }
        }
        return json
    }

    private func bytes(_ json: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func assertSameBody(
        _ payload: [String: any Sendable],
        _ expected: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let response = Response(status: "OK", reason: "success", payload: payload)
        let new = try bytes(ResponsePayload.jsonObject(payload))
        let old = try bytes(legacyJSONObject(response))
        #expect(new == old, "payload renders differently than the flat route", sourceLocation: sourceLocation)
        #expect(new == expected, sourceLocation: sourceLocation)
    }

    @Test("A collection reaches the body as a collection, with the same bytes")
    func collectionRendersIdentically() throws {
        let rows: [any Sendable] = [
            ["id": 1, "name": "Ada"] as [String: any Sendable],
            ["id": 2, "name": "Grace"] as [String: any Sendable],
        ]
        try assertSameBody(
            ["data": rows],
            #"{"data":[{"id":1,"name":"Ada"},{"id":2,"name":"Grace"}]}"#)
    }

    @Test("An empty collection is an empty array, not the two characters of its JSON")
    func emptyCollectionRendersIdentically() throws {
        try assertSameBody(["data": [any Sendable]()], #"{"data":[]}"#)
    }

    /// The shape `Examples/SessionScopedCart` asserts: a nested record is
    /// dot-notation keys in the body, not a nested object. That reaches
    /// clients, so it is the contract rather than an artefact of the old
    /// storage.
    @Test("A nested record stays dot-notation keys in the body")
    func nestedRecordFlattensToDottedKeys() throws {
        let user: [String: any Sendable] = ["data": "test"]
        try assertSameBody(["user": user], #"{"user.data":"test"}"#)
    }

    @Test("Nesting flattens to any depth, as it did")
    func deepNestingFlattens() throws {
        let inner: [String: any Sendable] = ["city": "Vienna"]
        let address: [String: any Sendable] = ["address": inner]
        try assertSameBody(["who": address], #"{"who.address.city":"Vienna"}"#)
    }

    @Test("Scalars keep their JSON types")
    func scalarsKeepTheirTypes() throws {
        try assertSameBody(
            ["n": 7, "x": 1.5, "ok": true, "s": "hi"],
            #"{"n":7,"ok":true,"s":"hi","x":1.5}"#)
    }

    /// Pre-existing behaviour of both renderers, kept deliberately: a string
    /// that *is* JSON text is inlined as the value it spells, so a handler
    /// that built its own JSON still ships an object rather than an escaped
    /// string.
    @Test("A string that is JSON text is still inlined")
    func jsonTextStringIsInlined() throws {
        try assertSameBody([
            "body": #"{"a":1}"#,
        ], #"{"body":{"a":1}}"#)
    }

    @Test("A string that merely starts with a brace stays a string")
    func braceLeadingStringStaysAString() throws {
        try assertSameBody(["body": "{not json"], #"{"body":"{not json"}"#)
    }

    /// An empty record contributes no keys — `flatten` wrote none, so the body
    /// had none either.
    @Test("An empty record contributes no keys")
    func emptyRecordContributesNothing() throws {
        try assertSameBody(["who": [String: any Sendable]()], "{}")
    }

    // MARK: - The single-value question the content sniffers ask

    @Test("One text value is reported as text")
    func singleTextValue() {
        guard case .text(let str) = ResponsePayload.soleFlatValue(["value": "<!DOCTYPE html>"]) else {
            Issue.record("expected .text")
            return
        }
        #expect(str == "<!DOCTYPE html>")
    }

    @Test("One value reached through a record is still one value")
    func singleValueThroughRecord() {
        let nested: [String: any Sendable] = ["data": "test"]
        guard case .text(let str) = ResponsePayload.soleFlatValue(["user": nested]) else {
            Issue.record("expected .text")
            return
        }
        #expect(str == "test")
    }

    @Test("A collection is reported as a collection, not rendered")
    func singleCollectionValue() {
        guard case .collection(let array) = ResponsePayload.soleFlatValue(["data": [1, 2, 3] as [any Sendable]]) else {
            Issue.record("expected .collection")
            return
        }
        #expect(array.count == 3)
    }

    @Test("A number or a boolean is not text, so no sniffer sees it")
    func singleNonTextValue() {
        if case .nonText = ResponsePayload.soleFlatValue(["n": 7]) {} else {
            Issue.record("expected .nonText for an Int")
        }
        if case .nonText = ResponsePayload.soleFlatValue(["ok": true]) {} else {
            Issue.record("expected .nonText for a Bool")
        }
    }

    @Test("Two values, or none, is not a single value")
    func notSingle() {
        if case .notSingle = ResponsePayload.soleFlatValue(["a": "x", "b": "y"]) {} else {
            Issue.record("expected .notSingle for two keys")
        }
        if case .notSingle = ResponsePayload.soleFlatValue([:]) {} else {
            Issue.record("expected .notSingle for an empty payload")
        }
        // A record with two fields is two flattened entries.
        let two: [String: any Sendable] = ["a": "x", "b": "y"]
        if case .notSingle = ResponsePayload.soleFlatValue(["who": two]) {} else {
            Issue.record("expected .notSingle for a two-field record")
        }
    }

    // MARK: - Identity

    @Test("Two responses with the same payload are equal")
    func equalityComparesTheRendering() {
        let a = Response(status: "OK", reason: "success", payload: ["data": [1, 2] as [any Sendable]])
        let b = Response(status: "OK", reason: "success", payload: ["data": [1, 2] as [any Sendable]])
        let c = Response(status: "OK", reason: "success", payload: ["data": [1, 3] as [any Sendable]])
        #expect(a == b)
        #expect(a != c)
    }

    /// A response built from an already-flattened dictionary keeps it: there
    /// is no structure left to recover, and flattening it again is the
    /// identity.
    @Test("Building from a flat dictionary round-trips")
    func flatDictionaryRoundTrips() {
        let flat: [String: AnySendable] = ["user.data": AnySendable("test"), "n": AnySendable(7)]
        let response = Response(status: "OK", data: flat)
        #expect(response.data == flat)
        #expect(response.payload["user.data"] as? String == "test")
    }
}
