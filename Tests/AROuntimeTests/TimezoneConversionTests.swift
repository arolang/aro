// ============================================================
// TimezoneConversionTests.swift
// ARO Runtime — timezone conversion
// ARO-0041 §7, GitLab #865
// ============================================================
//
// `ARODate` carried a timezone, nothing could set it, and `<now: timezone>`
// answered `GMT` whatever was asked for. So an application that had to render
// a local time, or compare an instant against a local business day, could not
// — and the books worked around it with fixed offsets, which is wrong across a
// DST boundary.

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

@Suite("Timezone conversion (#865)")
struct TimezoneConversionTests {

    private func date(_ iso: String) throws -> ARODate {
        try ARODate.parse(iso)
    }

    /// A named zone. Force-unwrapped: these are constant IANA identifiers, and
    /// a test that cannot find `Europe/Berlin` has a broken tzdata, not a
    /// failing assertion.
    private func zone(_ identifier: String) -> TimeZone {
        TimeZone(identifier: identifier)!
    }

    private func extract(
        _ qualifier: String,
        from source: ARODate,
        with zone: String? = nil
    ) throws -> any Sendable {
        let span = SourceSpan(at: SourceLocation())
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("moment", value: source)
        if let zone { context.bind("_with_", value: zone) }
        return try ExtractAction().executeSynchronously(
            result: ResultDescriptor(base: "out", specifiers: [qualifier], span: span),
            object: ObjectDescriptor(preposition: .from, base: "moment",
                                     specifiers: [], span: span),
            context: context)
    }

    // MARK: - Parsing a zone

    @Test("every documented spelling of a zone resolves")
    func zoneSpellings() {
        #expect(ARODate.resolveTimezone("Europe/Berlin")?.identifier == "Europe/Berlin")
        #expect(ARODate.resolveTimezone("UTC") == .gmt)
        #expect(ARODate.resolveTimezone("gmt") == .gmt)
        #expect(ARODate.resolveTimezone("Z") == .gmt)
        #expect(ARODate.resolveTimezone("local") == .current)
        #expect(ARODate.resolveTimezone("CET") != nil)
    }

    @Test("a written UTC offset resolves to that offset")
    func fixedOffsets() {
        #expect(ARODate.resolveTimezone("+02:00")?.secondsFromGMT() == 7200)
        #expect(ARODate.resolveTimezone("-0800")?.secondsFromGMT() == -28800)
        #expect(ARODate.resolveTimezone("UTC+2")?.secondsFromGMT() == 7200)
        #expect(ARODate.resolveTimezone("+05:30")?.secondsFromGMT() == 19800)
    }

    @Test("a name that is not a zone is nil, not GMT")
    func unknownZoneIsNil() {
        // Falling back to GMT is exactly how the original defect hid: a
        // misspelled zone rendered a plausible-looking wrong time.
        #expect(ARODate.resolveTimezone("Europe/Berlim") == nil)
        #expect(ARODate.resolveTimezone("nowhere") == nil)
        #expect(ARODate.resolveTimezone("") == nil)
        #expect(ARODate.resolveTimezone(nil) == nil)
        #expect(ARODate.resolveTimezone("+99:00") == nil)
    }

    // MARK: - DST, the case a fixed offset gets wrong

    @Test("Europe/Berlin is +01:00 in winter and +02:00 in summer")
    func dstTransition() throws {
        // The whole reason this needs a real TimeZone: an implementation that
        // stores one offset is wrong for half the year, and nothing else in
        // the suite would catch it.
        let winter = try date("2026-01-15T12:00:00Z").converted(to: zone("Europe/Berlin"))
        let summer = try date("2026-07-15T12:00:00Z").converted(to: zone("Europe/Berlin"))

        #expect(winter.utcOffsetSeconds == 3600)
        #expect(summer.utcOffsetSeconds == 7200)
        #expect(winter.hour == 13)
        #expect(summer.hour == 14)
        #expect(winter.isDaylightSavingTime == false)
        #expect(summer.isDaylightSavingTime == true)
    }

    @Test("the hour either side of a DST transition is right")
    func acrossTheTransitionItself() throws {
        // Berlin moves to summer time at 01:00 UTC on 2026-03-29.
        let berlin = try zone("Europe/Berlin")
        let before = try date("2026-03-29T00:30:00Z").converted(to: berlin)
        let after = try date("2026-03-29T01:30:00Z").converted(to: berlin)

        #expect(before.hour == 1)     // 00:30Z is 01:30 CET
        #expect(after.hour == 3)      // 01:30Z is 03:30 CEST — 02:00 never happens
        #expect(after.utcOffsetSeconds - before.utcOffsetSeconds == 3600)
    }

    // MARK: - The instant does not move

    @Test("conversion changes the rendering, not the instant")
    func timestampIsPreserved() throws {
        let utc = try date("2026-07-15T12:00:00Z")
        let tokyo = utc.converted(to: zone("Asia/Tokyo"))
        #expect(tokyo.timestamp == utc.timestamp)
        #expect(tokyo.hour == 21)
        #expect(tokyo.iso.hasSuffix("+09:00"))
    }

    @Test("converting there and back is the identity")
    func roundTrip() throws {
        let utc = try date("2026-02-01T08:15:00Z")
        let back = utc
            .converted(to: zone("America/Los_Angeles"))
            .converted(to: .gmt)
        #expect(back.iso == utc.iso)
        #expect(back.timestamp == utc.timestamp)
    }

    @Test("two renderings of one instant compare equal")
    func comparisonIgnoresRendering() throws {
        // If rendering affected ordering, sorting timestamps would depend on
        // where each was formatted.
        let instant = try date("2026-05-01T00:00:00Z")
        let berlin = instant.converted(to: zone("Europe/Berlin"))
        let tokyo = instant.converted(to: zone("Asia/Tokyo"))

        #expect(!berlin.isBefore(tokyo))
        #expect(!berlin.isAfter(tokyo))
        #expect(!(berlin < tokyo))
        #expect(!(tokyo < berlin))
    }

    @Test("a zone does change which local day an instant falls in")
    func localDayDiffers() throws {
        // Which is the reason to convert at all: "orders placed on Tuesday" is
        // a question about a zone.
        let instant = try date("2026-05-01T23:30:00Z")
        let berlin = instant.converted(to: zone("Europe/Berlin"))
        #expect(instant.day == 1)
        #expect(berlin.day == 2)
    }

    // MARK: - The Extract surface

    @Test("`<r: timezone>` with a zone in the with clause converts")
    func extractWithClause() throws {
        let value = try extract("timezone", from: date("2026-07-15T12:00:00Z"),
                                with: "Europe/Berlin")
        let converted = try #require(value as? ARODate)
        #expect(converted.timezoneIdentifier == "Europe/Berlin")
        #expect(converted.hour == 14)
    }

    @Test("the zone may be the qualifier itself")
    func extractZoneAsQualifier() throws {
        let value = try extract("Asia/Tokyo", from: date("2026-07-15T12:00:00Z"))
        #expect((value as? ARODate)?.timezoneIdentifier == "Asia/Tokyo")
    }

    @Test("`UTC` as a qualifier is a conversion, not a schema name")
    func utcIsNotASchema() throws {
        // `UTC` is uppercase and not a property, so schema detection claimed
        // it and the statement failed in schema validation.
        let berlin = try date("2026-07-15T12:00:00Z")
            .converted(to: zone("Europe/Berlin"))
        let span = SourceSpan(at: SourceLocation())
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("moment", value: berlin)
        let value = try ExtractAction().executeSynchronously(
            result: ResultDescriptor(base: "out", specifiers: ["UTC"], span: span),
            object: ObjectDescriptor(preposition: .from, base: "moment",
                                     specifiers: [], span: span),
            context: context)
        #expect((value as? ARODate)?.timezoneIdentifier == "GMT")
    }

    @Test("`<r: timezone>` with no zone still reads the date's own zone")
    func bareTimezoneStillReadsTheProperty() throws {
        let value = try extract("timezone", from: date("2026-07-15T12:00:00Z"))
        #expect(value as? String == "GMT")
    }

    @Test("an ordinary property name is not mistaken for a zone")
    func propertiesWin() throws {
        let value = try extract("hour", from: date("2026-07-15T12:00:00Z"))
        #expect(value as? Int == 12)
    }

    @Test("a zone that does not exist fails the statement")
    func unknownZoneThrows() {
        #expect(throws: (any Error).self) {
            _ = try extract("timezone", from: try ARODate.parse("2026-07-15T12:00:00Z"),
                            with: "Europe/Berlim")
        }
    }

    // MARK: - Properties

    @Test("offset and dst are readable on a date")
    func zoneProperties() throws {
        let summer = try date("2026-07-15T12:00:00Z")
            .converted(to: zone("Europe/Berlin"))
        #expect(summer.property("offset") as? Int == 7200)
        #expect(summer.property("dst") as? Bool == true)
        #expect(summer.toDictionary()["offset"] as? Int == 7200)
    }

    // MARK: - The check-time redirect

    @Test("Compute names the Extract spelling rather than failing blankly")
    func computeRedirects() {
        // Every other date operation is a Compute qualifier, so this is the
        // first thing people try.
        let hint = ComputeQualifierCatalog.redirect(
            for: "timezone", result: "local", object: "now")
        #expect(hint?.contains("Extract the <local: timezone>") == true)
    }
}
