// ============================================================
// TextFileReadTests.swift
// ARO Runtime — `.txt` is text, not properties (GitLab #468)
// ============================================================
//
// Format-aware I/O parsed `.txt` as a key=value properties file.
// A plain text file has no `=` on any line, so every line was
// skipped and the read produced an empty dictionary — the file's
// contents silently discarded, and the `Split` that followed
// failing on `[:]` rather than on anything that named the cause.
//
// `.env` is the format that means key=value, and it still does.

import Foundation
import Testing
@testable import ARORuntime

@Suite("Reading text files (#468)")
struct TextFileReadTests {

    @Test("A .txt file deserializes to its contents")
    func plainTextRoundTrips() {
        // The issue's own sample.
        let content = "line one\nline two\nline three"
        let out = FormatDeserializer.deserialize(content, format: .text)
        #expect(out as? String == content)
    }

    @Test("The same bytes read the same whether the extension is .txt or .dat")
    func extensionDoesNotChangeContent() {
        // The issue's sharpest observation: same bytes, different
        // extension, different answer — and the wrong one was `.txt`,
        // the most natural extension for a text file.
        let content = "line one\nline two\nline three"
        let asText = FormatDeserializer.deserialize(content, format: .text)
        let asBinary = FormatDeserializer.deserialize(content, format: .binary)
        #expect(asText as? String == asBinary as? String)
    }

    @Test("Text that happens to contain '=' is still text")
    func equalsSignIsNotAParseInstruction() {
        // This is the case that made the old behaviour plausible —
        // and it's exactly where it did the most damage, because
        // prose with an equals sign in it came back as a dictionary
        // built from a sentence.
        let content = "the check is x = 1\nand nothing else"
        let out = FormatDeserializer.deserialize(content, format: .text)
        #expect(out as? String == content)
    }

    @Test("An empty text file reads as an empty string, not nothing")
    func emptyFile() {
        #expect(FormatDeserializer.deserialize("", format: .text) as? String == "")
    }

    @Test("Trailing newlines survive the read")
    func preservesTrailingNewline() {
        // The reader must not normalise: counting lines is the
        // caller's business, and it needs the bytes it asked for.
        let content = "a\nb\n"
        #expect(FormatDeserializer.deserialize(content, format: .text) as? String == content)
    }

    @Test(".env still parses key=value")
    func envStillParsesPairs() throws {
        let out = FormatDeserializer.deserialize("HOST=localhost\nPORT=8080", format: .env)
        let dict = try #require(out as? [String: any Sendable])
        #expect(dict["HOST"] as? String == "localhost")
    }

    @Test(".txt maps to the text format")
    func extensionDetection() {
        #expect(FileFormat.detect(from: "/tmp/notes.txt") == .text)
        #expect(FileFormat.detect(from: "/tmp/notes.dat") == .binary)
        #expect(FileFormat.detect(from: "/tmp/.env") == .env)
    }

    @Test("Structured formats still parse")
    func structuredFormatsUnaffected() throws {
        // The fix must not turn format-aware I/O into "everything is
        // a string" — the formats that genuinely imply a schema keep
        // their parsing.
        let json = FormatDeserializer.deserialize(#"{"a": 1}"#, format: .json)
        #expect((json as? [String: any Sendable])?["a"] as? Int == 1)
        let yaml = FormatDeserializer.deserialize("a: 1", format: .yaml)
        #expect((yaml as? [String: any Sendable])?["a"] as? Int == 1)
    }

    @Test("An unparsable CSV keeps its bytes rather than returning nothing")
    func csvFallsBackToRaw() {
        // Second half of the issue: an empty or malformed parse must
        // not discard the content.
        let content = "not really csv"
        let out = FormatDeserializer.deserialize(content, format: .csv)
        #expect(out as? String == content)
    }
}
