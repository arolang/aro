// ============================================================
// YAMLScalarRoundTripTests.swift
// ARO Runtime - a YAML string reads back as itself (GitLab #582)
// ============================================================
//
// A string containing `:` or `#` was serialized as a literal block scalar:
//
//     url: |
//         http://a
//
// That is valid YAML, but the block form *implies* a trailing newline — clip
// chomping — so the value came back one `\n` longer than it went out. A
// writable `.store` file therefore grew a newline on every string on every
// restart: written as a block, reloaded with `\n`, written as a block again.
//
// Double-quoted style has no chomping semantics, and the deserializer already
// read its escapes — so the fix is to quote what needs protecting, and leave
// plain what does not, so a hand-seeded store stays readable.

import Foundation
import Testing
@testable import ARORuntime

@Suite("YAML scalar round-trip (GitLab #582)")
struct YAMLScalarRoundTripTests {

    /// Serialize then deserialize, returning what came back.
    private func roundTrip(_ value: [String: any Sendable]) -> [String: any Sendable]? {
        let yaml = FormatSerializer.serialize([value] as [any Sendable], format: .yaml, variableName: "rows")
        let back = FormatDeserializer.deserialize(yaml, format: .yaml)
        return (back as? [any Sendable])?.first as? [String: any Sendable]
    }

    // MARK: - The issue's value

    @Test("A URL survives a round-trip unchanged")
    func urlSurvives() {
        let row = roundTrip(["id": "a", "url": "http://a"])
        #expect(row?["url"] as? String == "http://a", "got \(String(describing: row?["url"]))")
    }

    @Test("A URL is not emitted as a block scalar")
    func urlIsNotABlockScalar() {
        let yaml = FormatSerializer.serialize(
            [["url": "http://a"] as [String: any Sendable]] as [any Sendable],
            format: .yaml, variableName: "rows")
        #expect(!yaml.contains(": |"), "block scalar emitted:\n\(yaml)")
        #expect(yaml.contains("\"http://a\""), "\(yaml)")
    }

    @Test("Repeated round-trips do not accumulate a newline")
    func repeatedRoundTripsAreStable() {
        // The actual symptom: one `\n` per restart, forever.
        var row: [String: any Sendable] = ["url": "http://a"]
        for pass in 1...5 {
            guard let next = roundTrip(row) else {
                return #expect(Bool(false), "round-trip \(pass) lost the row")
            }
            row = next
            #expect(row["url"] as? String == "http://a",
                    "drifted on pass \(pass): \(String(describing: row["url"]))")
        }
    }

    // MARK: - Values that still need protecting

    @Test("A string with a real newline keeps it, exactly")
    func newlineIsPreserved() {
        let row = roundTrip(["body": "line one\nline two"])
        #expect(row?["body"] as? String == "line one\nline two")
    }

    @Test("A string that looks like a number stays a string")
    func numericLookalikeStaysAString() {
        let row = roundTrip(["zip": "01234", "version": "1.0"])
        #expect(row?["zip"] as? String == "01234")
        #expect(row?["version"] as? String == "1.0")
    }

    @Test("A string that looks like a bool or null stays a string")
    func boolLookalikeStaysAString() {
        for text in ["true", "false", "null", "yes", "no", "on", "off", "~"] {
            let row = roundTrip(["flag": text])
            #expect(row?["flag"] as? String == text, "\(text) came back as \(String(describing: row?["flag"]))")
        }
    }

    @Test("Leading and trailing spaces survive")
    func surroundingSpacesSurvive() {
        let row = roundTrip(["padded": "  x  "])
        #expect(row?["padded"] as? String == "  x  ")
    }

    @Test("A comment marker is not read as a comment")
    func hashIsNotAComment() {
        let row = roundTrip(["note": "count #4"])
        #expect(row?["note"] as? String == "count #4")
    }

    @Test("Quotes and backslashes survive")
    func quotesAndBackslashesSurvive() {
        let row = roundTrip(["raw": #"he said "hi" \ ok"#])
        #expect(row?["raw"] as? String == #"he said "hi" \ ok"#)
    }

    @Test("An empty string stays an empty string, not null")
    func emptyStringSurvives() {
        let yaml = FormatSerializer.serialize(
            [["note": ""] as [String: any Sendable]] as [any Sendable],
            format: .yaml, variableName: "rows")
        #expect(yaml.contains("\"\""), "\(yaml)")
    }

    // MARK: - Plain style is kept where it is safe

    @Test("An ordinary word is left unquoted, so a seeded store stays readable")
    func ordinaryWordStaysPlain() {
        let yaml = FormatSerializer.serialize(
            [["id": "seed"] as [String: any Sendable]] as [any Sendable],
            format: .yaml, variableName: "rows")
        #expect(yaml.contains("id: seed"), "\(yaml)")
        #expect(!yaml.contains("\"seed\""), "\(yaml)")
    }

    @Test("Numbers and bools are still emitted as themselves")
    func scalarsKeepTheirType() {
        let row = roundTrip(["n": 42, "d": 1.5, "b": true])
        #expect(row?["n"] as? Int == 42)
        #expect(row?["d"] as? Double == 1.5)
        #expect(row?["b"] as? Bool == true)
    }
}
