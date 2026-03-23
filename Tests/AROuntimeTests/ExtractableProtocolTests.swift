// ============================================================
// ExtractableProtocolTests.swift
// ARO Runtime - Extractable protocol tests (Issue #161)
// ============================================================

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

// MARK: - Helpers

private func makeDate(year: Int, month: Int, day: Int) -> ARODate {
    // Use noon UTC to avoid DST / timezone-boundary issues when ARODate
    // extracts components in the GMT timezone.
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = .gmt
    var comps = DateComponents()
    comps.year = year; comps.month = month; comps.day = day
    comps.hour = 12; comps.minute = 0; comps.second = 0
    let date = cal.date(from: comps)!
    return ARODate(date: date, timezone: .gmt)
}

// MARK: - Extractable protocol conformance tests

@Suite("Extractable Protocol Tests")
struct ExtractableProtocolTests {

    // MARK: - Protocol conformance (static dispatch via existential)

    @Test("ARODate conforms to Extractable")
    func testARODateConformsToExtractable() {
        let date = makeDate(year: 2026, month: 3, day: 19)
        let extractable: any Extractable = date
        #expect(extractable.property("year")  as? Int == 2026)
        #expect(extractable.property("month") as? Int == 3)
        #expect(extractable.property("day")   as? Int == 19)
        #expect(extractable.property("nonexistent") == nil)
    }

    @Test("ARODateRange conforms to Extractable")
    func testARODateRangeConformsToExtractable() {
        let start = makeDate(year: 2026, month: 1, day: 1)
        let end   = makeDate(year: 2026, month: 12, day: 31)
        let range = ARODateRange(from: start, to: end)
        let extractable: any Extractable = range
        #expect(extractable.property("start") != nil)
        #expect(extractable.property("end")   != nil)
        #expect(extractable.property("nonexistent") == nil)
    }

    @Test("DateDistance conforms to Extractable")
    func testDateDistanceConformsToExtractable() {
        let t1 = makeDate(year: 2026, month: 1, day: 1)
        let t2 = makeDate(year: 2026, month: 1, day: 2) // +86400s
        let distance = DateDistance(from: t1, to: t2)
        let extractable: any Extractable = distance
        #expect(extractable.property("days")    as? Int == 1)
        #expect(extractable.property("seconds") as? Int == 86400)
        #expect(extractable.property("nonexistent") == nil)
    }

    @Test("ARORecurrence conforms to Extractable")
    func testARORecurrenceConformsToExtractable() throws {
        let start = makeDate(year: 2026, month: 1, day: 1)
        let recurrence = try ARORecurrence(pattern: "every day", from: start)
        let extractable: any Extractable = recurrence
        #expect(extractable.property("pattern") as? String == "every day")
        #expect(extractable.property("next")    != nil)
        #expect(extractable.property("nonexistent") == nil)
    }

    // MARK: - ExtractAction uses Extractable (no per-type cast chains)

    private func makeCtx(_ bindings: [String: any Sendable]) -> RuntimeContext {
        let ctx = RuntimeContext(featureSetName: "test", businessActivity: "test")
        for (k, v) in bindings { ctx.bind(k, value: v) }
        return ctx
    }

    @Test("Extract year from ARODate via result specifier (Extractable path in execute)")
    func testExtractYearFromARODateResultSpecifier() async throws {
        let date = makeDate(year: 2026, month: 3, day: 19)
        let ctx  = makeCtx(["d": date])
        let span = SourceSpan(at: SourceLocation())
        let result = ResultDescriptor(base: "yr", specifiers: ["year"], span: span)
        let object = ObjectDescriptor(preposition: .from, base: "d", specifiers: [], span: span)

        let value = try await ExtractAction().execute(result: result, object: object, context: ctx)
        #expect(value as? Int == 2026)
    }

    @Test("Extract month from ARODate via result specifier")
    func testExtractMonthFromARODate() async throws {
        let date = makeDate(year: 2026, month: 3, day: 19)
        let ctx  = makeCtx(["d": date])
        let span = SourceSpan(at: SourceLocation())
        let result = ResultDescriptor(base: "mo", specifiers: ["month"], span: span)
        let object = ObjectDescriptor(preposition: .from, base: "d", specifiers: [], span: span)

        let value = try await ExtractAction().execute(result: result, object: object, context: ctx)
        #expect(value as? Int == 3)
    }

    @Test("Extract day from ARODate via object specifier (extractProperty path)")
    func testExtractDayFromARODateObjectSpecifier() async throws {
        let date = makeDate(year: 2026, month: 3, day: 19)
        let ctx  = makeCtx(["d": date])
        let span = SourceSpan(at: SourceLocation())
        let result = ResultDescriptor(base: "dy", specifiers: [], span: span)
        let object = ObjectDescriptor(preposition: .from, base: "d", specifiers: ["day"], span: span)

        let value = try await ExtractAction().execute(result: result, object: object, context: ctx)
        #expect(value as? Int == 19)
    }

    @Test("Extract days from DateDistance via result specifier")
    func testExtractDaysFromDateDistance() async throws {
        let t1 = makeDate(year: 2026, month: 1, day: 1)
        let t2 = makeDate(year: 2026, month: 1, day: 8) // +7 days
        let dist = DateDistance(from: t1, to: t2)
        let ctx  = makeCtx(["dist": dist])
        let span = SourceSpan(at: SourceLocation())
        let result = ResultDescriptor(base: "days", specifiers: ["days"], span: span)
        let object = ObjectDescriptor(preposition: .from, base: "dist", specifiers: [], span: span)

        let value = try await ExtractAction().execute(result: result, object: object, context: ctx)
        #expect(value as? Int == 7)
    }

    @Test("Extract start from ARODateRange via result specifier")
    func testExtractStartFromARODateRange() async throws {
        let start = makeDate(year: 2026, month: 1, day: 1)
        let end   = makeDate(year: 2026, month: 12, day: 31)
        let range = ARODateRange(from: start, to: end)
        let ctx   = makeCtx(["r": range])
        let span  = SourceSpan(at: SourceLocation())
        let result = ResultDescriptor(base: "s", specifiers: ["start"], span: span)
        let object = ObjectDescriptor(preposition: .from, base: "r", specifiers: [], span: span)

        let value = try await ExtractAction().execute(result: result, object: object, context: ctx)
        let extracted = value as? ARODate
        #expect(extracted?.year == 2026)
        #expect(extracted?.month == 1)
        #expect(extracted?.day == 1)
    }

    // MARK: - Custom Extractable (extensibility — no ExtractAction changes needed)

    struct MockSensor: Extractable, Sendable {
        let temperature: Double
        let humidity: Int
        func property(_ name: String) -> (any Sendable)? {
            switch name {
            case "temperature": return temperature
            case "humidity":    return humidity
            default:            return nil
            }
        }
    }

    @Test("Custom Extractable type works without modifying ExtractAction")
    func testCustomExtractableViaResultSpecifier() async throws {
        let sensor = MockSensor(temperature: 22.5, humidity: 60)
        let ctx  = makeCtx(["sensor": sensor])
        let span = SourceSpan(at: SourceLocation())
        let result = ResultDescriptor(base: "temp", specifiers: ["temperature"], span: span)
        let object = ObjectDescriptor(preposition: .from, base: "sensor", specifiers: [], span: span)

        let value = try await ExtractAction().execute(result: result, object: object, context: ctx)
        #expect(value as? Double == 22.5)
    }

    @Test("Custom Extractable humidity via object specifier")
    func testCustomExtractableViaObjectSpecifier() async throws {
        let sensor = MockSensor(temperature: 22.5, humidity: 60)
        let ctx  = makeCtx(["sensor": sensor])
        let span = SourceSpan(at: SourceLocation())
        let result = ResultDescriptor(base: "hum", specifiers: [], span: span)
        let object = ObjectDescriptor(preposition: .from, base: "sensor", specifiers: ["humidity"], span: span)

        let value = try await ExtractAction().execute(result: result, object: object, context: ctx)
        #expect(value as? Int == 60)
    }
}
