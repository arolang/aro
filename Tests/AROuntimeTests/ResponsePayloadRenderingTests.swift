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
// `ResponsePayload.jsonBody` now goes from the payload to those bytes
// directly. These tests pin that it lands on the *same* value the old route
// did, by rendering both ways and comparing the serialised bytes: the flat
// form is still there (`Response.data`, computed on demand), so the old route
// can be reconstructed here and asserted against.
//
// GitLab #904 then changed the graph `jsonBody` hands `JSONSerialization`
// from Swift dictionaries and arrays to Foundation containers, to stop paying
// for bridging every element on the way in. That is a *Darwin* concept —
// under swift-corelibs-foundation `NSNumber` is a different implementation,
// and a bridged `Bool` arriving as `1` instead of `true` is the kind of
// difference that ships silently. `foundationGraphMatchesSwiftGraph` below
// renders a wide corpus both ways and compares the bytes, so CI's Linux job
// is the evidence for that platform.

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
        let new = String(decoding: try ResponsePayload.jsonBody(payload), as: UTF8.self)
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

    // MARK: - The Foundation graph renders what the Swift graph did (GitLab #904)

    /// The route `jsonBody` took before GitLab #904: build the body's value
    /// graph as Swift dictionaries and arrays and let `JSONSerialization`
    /// bridge every element of it on the way in.
    ///
    /// Reproduced here verbatim so the corpus below can assert that handing
    /// the serialiser Foundation containers instead changed the cost and not
    /// the bytes — including on Linux, where the bridge is a different
    /// implementation and this test is the only thing watching.
    private func swiftNativeJSONBody(_ payload: [String: any Sendable]) throws -> Data {
        func inlineJSON(_ str: String) -> Any {
            guard str.hasPrefix("{") || str.hasPrefix("[") else { return str }
            // try? is acceptable: reproduces the old probe, which kept the raw
            // string when it did not parse.
            guard let data = str.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) else { return str }
            return parsed
        }
        func insert(_ value: any Sendable, as key: String, into json: inout [String: Any]) {
            switch value {
            case let str as String: json[key] = inlineJSON(str)
            case let int as Int: json[key] = int
            case let double as Double: json[key] = double
            case let bool as Bool: json[key] = bool
            case let dict as [String: any Sendable]:
                for (nestedKey, nested) in dict {
                    insert(nested, as: "\(key).\(nestedKey)", into: &json)
                }
            case let array as [any Sendable]:
                json[key] = array.map { SendableConverter.toJSON($0) }
            default: json[key] = inlineJSON(String(describing: value))
            }
        }
        var json: [String: Any] = [:]
        for (key, value) in payload { insert(value, as: key, into: &json) }
        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }

    /// Payloads chosen for the places the two graphs could disagree: every
    /// leaf type, numbers whose text is a formatting decision, strings that
    /// need escaping, key sets whose order `.sortedKeys` collates rather than
    /// byte-sorts, and containers with nothing in them.
    private static func parityCorpus() -> [(String, [String: any Sendable])] {
        var cases: [(String, [String: any Sendable])] = []

        // Booleans are the named risk: a bridged `Bool` reaching the body as
        // `1` instead of `true` is what this corpus exists to catch.
        cases.append(("booleans", ["t": true, "f": false]))
        cases.append(("booleans in a list", ["data": [true, false] as [any Sendable]]))

        // Doubles whose shortest representation and whose 17-significant-digit
        // representation differ, plus the extremes of the format.
        let doubles: [Double] = [
            0, -0.0, 1, -1, 0.1, 0.2, 0.3, 1.0 / 3.0, 99.95, 2.5, -2.5,
            1e-5, 1e-7, 1e15, 1e16, 1e17, 1e21, 1e22, 1e100, 1e308, 1e-306,
            5e-324, 123456789.123456789, .pi, .greatestFiniteMagnitude,
        ]
        for (index, value) in doubles.enumerated() {
            cases.append(("double[\(index)]", ["v": value]))
            cases.append(("double[\(index)] in a list", ["data": [value] as [any Sendable]]))
        }

        // Integers, including the ones no Double can hold exactly.
        for value in [0, 1, -1, Int.max, Int.min, 9_007_199_254_740_993, -9_007_199_254_740_993] {
            cases.append(("int \(value)", ["v": value]))
            cases.append(("int \(value) in a list", ["data": [value] as [any Sendable]]))
        }

        // Strings: the escapes, the control characters, the non-ASCII, and the
        // two that the JSON-text probe has to decline.
        let strings = [
            "", "a/b", "/slashes/everywhere/", "q\"q", "b\\b", "tab\there",
            "line\nbreak", "ret\rurn", "\u{0}", "\u{1}", "\u{8}\u{c}\u{b}",
            "\u{f}\u{10}\u{1f}", "\u{7f}", "\u{2028}\u{2029}", "é", "ümlaut ß",
            "日本語テキスト", "😀", "{not json", "[not json",
        ]
        for (index, value) in strings.enumerated() {
            cases.append(("string[\(index)]", ["v": value]))
            cases.append(("string[\(index)] in a list", ["data": [value] as [any Sendable]]))
        }

        // Key sets where `.sortedKeys` is not a byte sort: `item2` before
        // `item10`, `a_b` before `a-b`. The order is the serialiser's either
        // way — that is the point of not hand-writing one — so this asserts
        // the two graphs get the same answer out of it.
        let keySets: [[String]] = [
            ["item2", "item10", "item1"], ["B", "a", "C", "b"],
            ["_x", "a", ".y", "Zz"], ["é", "e", "f", "ez"],
            ["a.b", "ab", "a-b", "a_b"], ["x1", "x01", "x001"],
            ["Z", "z", "0", "9", "~", "!"], ["", " ", "  "],
        ]
        for (index, keys) in keySets.enumerated() {
            var payload: [String: any Sendable] = [:]
            for (position, key) in keys.enumerated() { payload[key] = position }
            cases.append(("keys[\(index)]", payload))
        }

        // Nothing in them.
        cases.append(("empty record", ["who": [String: any Sendable]()]))
        cases.append(("empty list", ["data": [any Sendable]()]))
        cases.append(("nested empties", [
            "a": ["b": [String: any Sendable]()] as [String: any Sendable],
            "c": ["d": [any Sendable]()] as [String: any Sendable],
        ]))
        cases.append(("list of empties", ["data": [
            [String: any Sendable]() as any Sendable, [any Sendable]() as any Sendable,
        ] as [any Sendable]]))

        // Mixed and nested, the shapes a handler actually returns.
        cases.append(("mixed list", ["data": [
            1 as any Sendable, 1.5 as any Sendable, true as any Sendable, "s" as any Sendable,
            ["k": "v"] as [String: any Sendable] as any Sendable,
            [1, 2] as [any Sendable] as any Sendable,
        ] as [any Sendable]]))
        cases.append(("records in a list", ["data": [
            ["id": 1, "name": "Ada", "score": 0.1, "active": true] as [String: any Sendable],
            ["id": 2, "name": "Grace", "score": 99.95, "active": false] as [String: any Sendable],
        ] as [any Sendable]]))
        cases.append(("dotted contract", ["user": ["data": "test"] as [String: any Sendable]]))
        cases.append(("deep nesting", [
            "who": ["address": ["city": "Vienna"] as [String: any Sendable]] as [String: any Sendable],
        ]))
        cases.append(("inlined JSON text", ["body": #"{"a":1,"b":[1,2]}"#]))
        cases.append(("list nested in a record", [
            "page": ["items": [1, 2, 3] as [any Sendable], "total": 3] as [String: any Sendable],
        ]))
        return cases
    }

    @Test("The Foundation graph serialises to the same bytes as the Swift graph")
    func foundationGraphMatchesSwiftGraph() throws {
        // Pinned so the corpus cannot shrink unnoticed: it is the only Linux
        // evidence that the bridge renders what the Swift graph rendered.
        #expect(Self.parityCorpus().count == 124)
        for (name, payload) in Self.parityCorpus() {
            let new = try ResponsePayload.jsonBody(payload)
            let old = try swiftNativeJSONBody(payload)
            #expect(
                new == old,
                """
                \(name): the Foundation container graph rendered
                  \(String(decoding: new, as: UTF8.self))
                where the Swift graph rendered
                  \(String(decoding: old, as: UTF8.self))
                """)
        }
    }

    /// The literal bytes of the cases most likely to differ by platform, so a
    /// failure says what went wrong rather than only that two routes disagree.
    @Test("Booleans, integers and escapes have the bytes the contract says")
    func leafBytesArePinned() throws {
        func body(_ payload: [String: any Sendable]) throws -> String {
            String(decoding: try ResponsePayload.jsonBody(payload), as: UTF8.self)
        }
        #expect(try body(["t": true, "f": false]) == #"{"f":false,"t":true}"#)
        #expect(try body(["data": [true, false] as [any Sendable]]) == #"{"data":[true,false]}"#)
        #expect(try body(["n": 1]) == #"{"n":1}"#)
        #expect(try body(["n": Int.max]) == #"{"n":9223372036854775807}"#)
        #expect(try body(["x": 1.5]) == #"{"x":1.5}"#)
        #expect(try body(["s": "q\"q\\\n\t"]) == #"{"s":"q\"q\\\n\t"}"#)
        #expect(try body(["s": "\u{1}"]) == "{\"s\":\"\\u0001\"}")
        #expect(try body(["s": "é😀"]) == #"{"s":"é😀"}"#)
    }

    // MARK: - A payload with nothing in it answers with its status

    @Test("An empty payload takes the whenEmpty entries, in order")
    func emptyPayloadTakesTheExtras() throws {
        let body = String(
            decoding: try ResponsePayload.jsonBody(
                [:], whenEmpty: [("status", "OK"), ("reason", "success")]),
            as: UTF8.self)
        #expect(body == #"{"reason":"success","status":"OK"}"#)
    }

    @Test("A payload with values ignores the whenEmpty entries")
    func nonEmptyPayloadIgnoresTheExtras() throws {
        let body = String(
            decoding: try ResponsePayload.jsonBody(
                ["v": 1], whenEmpty: [("status", "OK")]),
            as: UTF8.self)
        #expect(body == #"{"v":1}"#)
    }

    /// A record with no fields flattens to no keys, so the response carries no
    /// values and the status stands in — the behaviour `jsonObject` plus the
    /// caller's `isEmpty` check had, now in one place.
    @Test("A payload of only empty records is empty, and takes the extras")
    func emptyRecordCountsAsEmpty() throws {
        let body = String(
            decoding: try ResponsePayload.jsonBody(
                ["who": [String: any Sendable]()], whenEmpty: [("status", "OK")]),
            as: UTF8.self)
        #expect(body == #"{"status":"OK"}"#)
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
