// ============================================================
// NumberFormattingTests.swift
// ARO Runtime - Human-facing numeric rendering (GitLab #474)
// ============================================================

import Foundation
import Testing
@testable import ARORuntime

@Suite("Number Formatting")
struct NumberFormattingTests {

    // MARK: - Precision is preserved

    @Test("Full precision is preserved, not rounded to two decimals")
    func testFullPrecision() {
        // Previously "3.14".
        #expect(AroNumberFormatting.string(for: 3.14159265) == "3.14159265")
    }

    @Test("Repeating fractions keep 15 significant digits")
    func testRepeatingFraction() {
        // Previously "0.33", which read as a computed result.
        #expect(AroNumberFormatting.string(for: 1.0 / 3.0) == "0.333333333333333")
    }

    @Test("A halved value renders without a padding zero")
    func testSingleDecimal() {
        // Previously "3.50".
        #expect(AroNumberFormatting.string(for: 3.5) == "3.5")
    }

    @Test("Values a user could have typed round-trip exactly")
    func testUserTypedValuesRoundTrip() {
        // 15 significant digits is DBL_DIG: any decimal with 15 or fewer
        // significant digits survives decimal -> Double -> decimal unchanged.
        // These are all values someone would plausibly write in source.
        let values: [Double] = [
            0.1, 0.2, 3.5, 19.99, 9.95, 100.55, 2.5e10, -0.125, 1e-9, 0.000001234
        ]
        for value in values {
            let text = AroNumberFormatting.string(for: value)
            #expect(Double(text) == value, "\(text) did not round-trip to \(value)")
        }
    }

    @Test("Values needing more than 15 digits display rounded, by design")
    func testHighPrecisionValuesAreRounded() {
        // Double -> decimal -> Double needs up to 17 digits, so this is the
        // deliberate half of the trade-off: display absorbs the last digits.
        // The stored value is untouched and the JSON path serialises in full.
        #expect(AroNumberFormatting.string(for: Double.pi) == "3.14159265358979")
        #expect(Double(AroNumberFormatting.string(for: Double.pi)) != Double.pi)
    }

    // MARK: - Floating-point artifacts

    @Test("0.1 + 0.2 prints as 0.3")
    func testClassicArtifact() {
        // The reason this formatter is not shortest-round-trip. ARO expresses
        // business features; the reader's question is "what is the total", not
        // "how does IEEE 754 represent it".
        #expect(AroNumberFormatting.string(for: 0.1 + 0.2) == "0.3")
    }

    @Test("Other common arithmetic artifacts are absorbed")
    func testOtherArtifacts() {
        #expect(AroNumberFormatting.string(for: 0.7 * 3) == "2.1")
        #expect(AroNumberFormatting.string(for: 1.1 + 2.2) == "3.3")
        #expect(AroNumberFormatting.string(for: 19.99 * 3) == "59.97")
        #expect(AroNumberFormatting.string(for: 0.3 - 0.1) == "0.2")
    }

    @Test("9.95 is not mangled")
    func testNineNinetyFive() {
        // 16 significant digits was rejected precisely because it renders this
        // as 9.949999999999999 while still fixing 0.1 + 0.2.
        #expect(AroNumberFormatting.string(for: 9.95) == "9.95")
    }

    // MARK: - Whole values

    @Test("Whole values render without a fractional part")
    func testWholeValues() {
        #expect(AroNumberFormatting.string(for: 3.0) == "3")
        #expect(AroNumberFormatting.string(for: 0.0) == "0")
        #expect(AroNumberFormatting.string(for: -7.0) == "-7")
        // Previously "123456789000.00".
        #expect(AroNumberFormatting.string(for: 123456789000.0) == "123456789000")
    }

    @Test("Whole values beyond Int range do not trap")
    func testHugeWholeValueDoesNotTrap() {
        // The bridge's previous `String(Int(d))` fast path traps here, because
        // 1e21 is outside Int's range. Must fall through to the Double form.
        let text = AroNumberFormatting.string(for: 1e21)

        #expect(Double(text) == 1e21)
        #expect(!text.isEmpty)
    }

    @Test("Int.max as a Double does not trap")
    func testIntMaxAsDouble() {
        // Double(Int.max) is 2^63, one past Int.max, so `Int(exactly:)` declines
        // and it falls through to the 15-digit path. The point of this test is
        // that nothing traps — the value needs 16 significant digits, so it is
        // displayed rounded like any other high-precision value.
        let text = AroNumberFormatting.string(for: Double(Int.max))

        #expect(!text.isEmpty)
        let parsed = try? #require(Double(text))
        #expect(parsed != nil)
        // Within one part in 10^15 of the true value.
        if let parsed {
            #expect(abs(parsed - Double(Int.max)) / Double(Int.max) < 1e-15)
        }
    }

    // MARK: - Non-finite values

    @Test("Non-finite values get readable names")
    func testNonFinite() {
        #expect(AroNumberFormatting.string(for: .nan) == "NaN")
        #expect(AroNumberFormatting.string(for: .infinity) == "Infinity")
        #expect(AroNumberFormatting.string(for: -.infinity) == "-Infinity")
    }

    // MARK: - Through the formatter

    @Test("ResponseFormatter renders a Double at full precision")
    func testResponseFormatterPrecision() {
        let formatted = ResponseFormatter.formatValue(3.14159265, for: .developer)

        #expect(formatted.contains("3.14159265"))
        #expect(!formatted.contains("3.14\n"))
    }

    @Test("ResponseFormatter renders nested Doubles at full precision")
    func testNestedPrecision() {
        let value: [String: any Sendable] = ["ratio": 1.0 / 3.0]
        let formatted = ResponseFormatter.formatValue(value, for: .developer)

        #expect(formatted.contains("0.3333333333333333"))
    }
}
