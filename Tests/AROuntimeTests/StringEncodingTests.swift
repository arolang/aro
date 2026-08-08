// ============================================================
// StringEncodingTests.swift
// ARO Runtime - Encoding / escaping primitives (GitLab #482)
// ============================================================

import Foundation
import Testing
@testable import ARORuntime

@Suite("HTML Escaping")
struct HTMLEscapingTests {

    @Test("Escapes the five HTML-significant characters")
    func testEscapesAllFive() {
        #expect(StringEncoding.htmlEscape("&") == "&amp;")
        #expect(StringEncoding.htmlEscape("<") == "&lt;")
        #expect(StringEncoding.htmlEscape(">") == "&gt;")
        #expect(StringEncoding.htmlEscape("\"") == "&quot;")
        #expect(StringEncoding.htmlEscape("'") == "&#39;")
    }

    @Test("Neutralises a script tag")
    func testScriptTag() {
        #expect(
            StringEncoding.htmlEscape("<script>alert(1)</script>")
                == "&lt;script&gt;alert(1)&lt;/script&gt;"
        )
    }

    @Test("Ampersand is escaped once, not doubly")
    func testNoDoubleEscaping() {
        // If `&` were replaced after `<`, this would come out as "&amp;amp;lt;".
        #expect(StringEncoding.htmlEscape("&lt;") == "&amp;lt;")
        #expect(StringEncoding.htmlEscape("a & b < c") == "a &amp; b &lt; c")
    }

    @Test("Leaves ordinary text untouched")
    func testPassThrough() {
        #expect(StringEncoding.htmlEscape("Hello, world 123") == "Hello, world 123")
        #expect(StringEncoding.htmlEscape("") == "")
    }

    @Test("Preserves non-ASCII characters")
    func testUnicodePreserved() {
        #expect(StringEncoding.htmlEscape("café — 日本語") == "café — 日本語")
    }

    @Test("Escaping an attribute-breaking value is safe")
    func testAttributeBreakout() {
        let escaped = StringEncoding.htmlEscape(#"" onmouseover="evil()"#)

        #expect(!escaped.contains("\""))
    }
}

@Suite("URL Encoding")
struct URLEncodingTests {

    @Test("Encodes sub-delimiters that carry query structure")
    func testEncodesSubDelimiters() {
        #expect(StringEncoding.urlEncode("a&b") == "a%26b")
        #expect(StringEncoding.urlEncode("a=b") == "a%3Db")
        #expect(StringEncoding.urlEncode("a/b") == "a%2Fb")
        #expect(StringEncoding.urlEncode("a?b") == "a%3Fb")
        #expect(StringEncoding.urlEncode("a b") == "a%20b")
        #expect(StringEncoding.urlEncode("a+b") == "a%2Bb")
    }

    @Test("Leaves the RFC 3986 unreserved set alone")
    func testUnreservedUntouched() {
        let unreserved = "AZaz09-._~"

        #expect(StringEncoding.urlEncode(unreserved) == unreserved)
    }

    @Test("Round-trips through decode")
    func testRoundTrip() {
        for value in ["a&b = c/d?e", "plain", "", "100%", "café", "a+b"] {
            let encoded = StringEncoding.urlEncode(value)
            #expect(StringEncoding.urlDecode(encoded) == value, "failed for \(value)")
        }
    }

    @Test("Malformed percent-escapes pass through rather than aborting")
    func testMalformedDecodePassesThrough() {
        // Happy-case philosophy: a bad value should not kill the feature set here.
        #expect(StringEncoding.urlDecode("%zz") == "%zz")
    }
}

@Suite("Base64")
struct Base64Tests {

    @Test("Encodes and decodes round-trip")
    func testRoundTrip() {
        for value in ["user:pass", "", "a", "ab", "abc", "café — 日本語"] {
            let encoded = StringEncoding.base64Encode(value)
            #expect(StringEncoding.base64Decode(encoded) == value, "failed for \(value)")
        }
    }

    @Test("Produces the expected standard encoding")
    func testKnownVector() {
        #expect(StringEncoding.base64Encode("user:pass") == "dXNlcjpwYXNz")
    }

    @Test("Invalid Base64 returns nil rather than garbage")
    func testInvalidReturnsNil() {
        #expect(StringEncoding.base64Decode("!!!not base64!!!") == nil)
    }

    @Test("Base64 that is not valid UTF-8 returns nil")
    func testNonUTF8ReturnsNil() {
        // 0xFF is not a valid UTF-8 start byte.
        let notUTF8 = Data([0xFF, 0xFE]).base64EncodedString()

        #expect(StringEncoding.base64Decode(notUTF8) == nil)
    }

    @Test("URL-safe variant avoids +, / and padding")
    func testURLSafeAlphabet() {
        // Chosen so standard Base64 would contain both '+' and '/'.
        let encoded = StringEncoding.base64URLEncode("sure?>>ok~~")

        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        #expect(!encoded.contains("="))
    }

    @Test("URL-safe variant round-trips, including restored padding")
    func testURLSafeRoundTrip() {
        for value in ["a", "ab", "abc", "abcd", "sure?>>ok~~", "user:pass"] {
            let encoded = StringEncoding.base64URLEncode(value)
            #expect(StringEncoding.base64URLDecode(encoded) == value, "failed for \(value)")
        }
    }
}

@Suite("JSON Escaping")
struct JSONEscapingTests {

    @Test("Escapes quotes and backslashes")
    func testQuotesAndBackslashes() {
        #expect(StringEncoding.jsonEscape("say \"hi\"") == #"say \"hi\""#)
        #expect(StringEncoding.jsonEscape(#"a\b"#) == #"a\\b"#)
    }

    @Test("Escapes the named control characters")
    func testNamedControls() {
        #expect(StringEncoding.jsonEscape("\n") == #"\n"#)
        #expect(StringEncoding.jsonEscape("\r") == #"\r"#)
        #expect(StringEncoding.jsonEscape("\t") == #"\t"#)
    }

    @Test("Escapes other control characters as \\uXXXX")
    func testUnicodeEscapes() {
        #expect(StringEncoding.jsonEscape("\u{01}") == "\\u0001")
        #expect(StringEncoding.jsonEscape("\u{1F}") == "\\u001f")
    }

    @Test("Output parses as a JSON string")
    func testOutputIsValidJSON() throws {
        let original = "line1\nline2 \"quoted\" \\ and \u{01}"
        let json = "\"\(StringEncoding.jsonEscape(original))\""

        let decoded = try JSONDecoder().decode(String.self, from: Data(json.utf8))

        #expect(decoded == original)
    }

    @Test("Leaves ordinary text untouched")
    func testPassThrough() {
        #expect(StringEncoding.jsonEscape("plain text 123") == "plain text 123")
    }
}
