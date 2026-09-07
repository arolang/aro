// ============================================================
// JSONDoubleRenderingTests.swift
// ARO Runtime — doubles in JSON read the way they were written
// ============================================================
//
// `JSONSerialization` on Darwin prints doubles at 17 significant
// digits, so a pipeline that wrote `99.95` produced
// `99.950000000000003` in .json/.jsonl while the CSV writer — which
// uses String(double) — wrote `99.95`. The same value was honest in
// one format and noisy in the other, and these files ARE the output
// people read. Found while implementing GitLab #522; related to the
// money-artifact complaint in #517.

import Testing
import Foundation
@testable import ARORuntime

@Suite("JSON double rendering")
struct JSONDoubleRenderingTests {

    private func json(_ value: any Sendable) -> String {
        FormatSerializer.serialize(value, format: .json, variableName: "rows")
    }

    private func jsonl(_ value: any Sendable) -> String {
        FormatSerializer.serialize(value, format: .jsonl, variableName: "rows")
    }

    @Test("A double keeps its shortest round-trip spelling")
    func shortestRoundTrip() {
        let row: [String: any Sendable] = ["price": 99.95]
        #expect(json(row).contains("99.95"))
        #expect(!json(row).contains("99.950000000000003"))
    }

    @Test("Every writer agrees on the same value")
    func writersAgree() {
        let rows: [any Sendable] = [["price": 99.95] as [String: any Sendable]]
        let asJSON = json(rows)
        let asJSONL = jsonl(rows)
        let asCSV = FormatSerializer.serialize(rows, format: .csv, variableName: "rows")
        #expect(asJSON.contains("99.95") && !asJSON.contains("99.9500000"))
        #expect(asJSONL.contains("99.95") && !asJSONL.contains("99.9500000"))
        #expect(asCSV.contains("99.95") && !asCSV.contains("99.9500000"))
    }

    @Test("Values round-trip back to the same double")
    func roundTrips() throws {
        let values: [Double] = [99.95, 7.2, 0.1, -0.125, 1234567.89, 5.0, 1e-7, 1e21]
        for value in values {
            let text = jsonl(["v": value] as [String: any Sendable])
            let data = Data(text.utf8)
            let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let back = (parsed?["v"] as? NSNumber)?.doubleValue
            #expect(back == value, "\(value) came back as \(String(describing: back)) via \(text)")
        }
    }

    @Test("A whole double stays a double, not an int")
    func wholeValuesKeepTheirPoint() {
        // 5.0 rendering as `5` would silently change the type a
        // consumer infers from the file.
        #expect(jsonl(["v": 5.0] as [String: any Sendable]).contains("5.0"))
    }

    @Test("Ints are not turned into doubles")
    func intsStayInts() {
        let text = jsonl(["v": 3] as [String: any Sendable])
        #expect(text.contains("\"v\":3"))
    }

    @Test("Booleans stay booleans, not 0/1")
    func boolsSurvive() {
        // NSNumber erases Bool, so this is the classic way to get
        // `true` written as `1`.
        let text = jsonl(["ok": true, "no": false] as [String: any Sendable])
        #expect(text.contains("\"ok\":true"))
        #expect(text.contains("\"no\":false"))
    }

    @Test("Strings keep their escaping")
    func stringsEscaped() {
        let text = jsonl(["s": "he said \"hi\"\nsecond"] as [String: any Sendable])
        #expect(text.contains("\\\""))
        #expect(text.contains("\\n"))
        #expect(!text.contains("\nsecond"))
    }

    @Test("Nested structures and empties keep their shape")
    func nesting() {
        let value: [String: any Sendable] = [
            "a": [1.5, 2.25] as [any Sendable],
            "empty-list": [] as [any Sendable],
            "empty-map": [:] as [String: any Sendable],
            "deep": ["x": ["y": 0.5] as [String: any Sendable]] as [String: any Sendable]
        ]
        let text = jsonl(value)
        #expect(text.contains("[1.5,2.25]"))
        #expect(text.contains("\"empty-list\":[]"))
        #expect(text.contains("\"empty-map\":{}"))
        #expect(text.contains("\"deep\":{\"x\":{\"y\":0.5}}"))
    }

    @Test("A JSON round trip keeps each value's kind")
    func readThenWriteKeepsKinds() throws {
        // The shape that matters in practice: values READ from a JSON
        // file arrive as NSNumber, which erases Bool/Int/Double. Telling
        // them apart must not rely on CoreFoundation — this runtime
        // builds on Linux too.
        let source = Data(#"{"flag":true,"off":false,"count":3,"price":99.95}"#.utf8)
        let parsed = try JSONSerialization.jsonObject(with: source)
        let text = jsonl(parsed as! [String: any Sendable])
        #expect(text == #"{"count":3,"flag":true,"off":false,"price":99.95}"#)
    }

    @Test("Keys stay sorted, as the JSONSerialization path had them")
    func keysSorted() {
        let text = jsonl(["b": 1, "a": 2, "c": 3] as [String: any Sendable])
        #expect(text == "{\"a\":2,\"b\":1,\"c\":3}")
    }

    @Test("NaN and infinity become null rather than invalid JSON")
    func nonFiniteValues() {
        // JSON has no NaN/Infinity; JSONSerialization used to throw and
        // drop the whole document into a fallback rendering.
        #expect(FormatSerializer.renderDouble(Double.nan) == "null")
        #expect(FormatSerializer.renderDouble(Double.infinity) == "null")
        #expect(jsonl(["v": Double.nan] as [String: any Sendable]) == "{\"v\":null}")
    }
}
