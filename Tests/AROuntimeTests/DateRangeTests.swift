// ============================================================
// DateRangeTests.swift
// ARO Runtime - Date Range Unit Tests (Issue #84)
// ============================================================

import Foundation
import Testing
@testable import ARORuntime

// MARK: - ARODate Tests

@Suite("ARODate Tests")
struct ARODateTests {

    @Test("Create ARODate from Swift Date")
    func testCreateFromDate() {
        let swiftDate = Date()
        let aroDate = ARODate(date: swiftDate, timezone: .gmt)

        #expect(aroDate.date == swiftDate)
        #expect(aroDate.timezone == .gmt)
    }

    @Test("ARODate now() creates current time")
    func testNow() {
        let before = Date()
        let aroDate = ARODate.now()
        let after = Date()

        #expect(aroDate.date >= before)
        #expect(aroDate.date <= after)
    }

    @Test("ARODate component access - year")
    func testYearComponent() throws {
        let date = try ARODate.parse("2025-06-15T12:30:45Z")
        #expect(date.year == 2025)
    }

    @Test("ARODate component access - month")
    func testMonthComponent() throws {
        let date = try ARODate.parse("2025-06-15T12:30:45Z")
        #expect(date.month == 6)
    }

    @Test("ARODate component access - day")
    func testDayComponent() throws {
        let date = try ARODate.parse("2025-06-15T12:30:45Z")
        #expect(date.day == 15)
    }

    @Test("ARODate component access - hour")
    func testHourComponent() throws {
        let date = try ARODate.parse("2025-06-15T12:30:45Z")
        #expect(date.hour == 12)
    }

    @Test("ARODate component access - minute")
    func testMinuteComponent() throws {
        let date = try ARODate.parse("2025-06-15T12:30:45Z")
        #expect(date.minute == 30)
    }

    @Test("ARODate component access - second")
    func testSecondComponent() throws {
        let date = try ARODate.parse("2025-06-15T12:30:45Z")
        #expect(date.second == 45)
    }

    @Test("ARODate ISO string representation")
    func testISOString() throws {
        let date = try ARODate.parse("2025-06-15T12:30:45Z")
        let iso = date.iso

        #expect(iso.contains("2025"))
        #expect(iso.contains("06"))
        #expect(iso.contains("15"))
    }

    @Test("ARODate timestamp")
    func testTimestamp() throws {
        let date = try ARODate.parse("2025-01-01T00:00:00Z")
        let timestamp = date.timestamp

        // 2025-01-01T00:00:00Z should be approximately 1735689600
        #expect(timestamp > 1735689000)
        #expect(timestamp < 1735690000)
    }

    @Test("ARODate equality")
    func testEquality() throws {
        let date1 = try ARODate.parse("2025-06-15T12:30:45Z")
        let date2 = try ARODate.parse("2025-06-15T12:30:45Z")
        let date3 = try ARODate.parse("2025-06-15T12:30:46Z")

        #expect(date1 == date2)
        #expect(date1 != date3)
    }

    @Test("ARODate property access")
    func testPropertyAccess() throws {
        let date = try ARODate.parse("2025-06-15T12:30:45Z")

        #expect(date.property("year") as? Int == 2025)
        #expect(date.property("month") as? Int == 6)
        #expect(date.property("day") as? Int == 15)
        #expect(date.property("hour") as? Int == 12)
        #expect(date.property("minute") as? Int == 30)
        #expect(date.property("second") as? Int == 45)
    }

    @Test("ARODate parse error for invalid string")
    func testParseError() {
        #expect(throws: DateParseError.self) {
            _ = try ARODate.parse("not-a-date")
        }
    }
}

// MARK: - DateOffset Tests

@Suite("DateOffset Tests")
struct DateOffsetTests {

    @Test("Parse positive offset - hours")
    func testParsePositiveHours() throws {
        let offset = try DateOffset.parse("+3h")

        #expect(offset.value == 3)
        #expect(offset.unit == .hours)
    }

    @Test("Parse negative offset - days")
    func testParseNegativeDays() throws {
        let offset = try DateOffset.parse("-5d")

        #expect(offset.value == -5)
        #expect(offset.unit == .days)
    }

    @Test("Parse offset without sign")
    func testParseNoSign() throws {
        let offset = try DateOffset.parse("2w")

        #expect(offset.value == 2)
        #expect(offset.unit == .weeks)
    }

    @Test("Parse offset with various units")
    func testParseVariousUnits() throws {
        let seconds = try DateOffset.parse("+30s")
        #expect(seconds.unit == .seconds)

        let minutes = try DateOffset.parse("+15m")
        #expect(minutes.unit == .minutes)

        let months = try DateOffset.parse("+1mo")
        #expect(months.unit == .months)

        let years = try DateOffset.parse("+2y")
        #expect(years.unit == .years)
    }

    @Test("Parse offset with long unit names")
    func testParseLongUnitNames() throws {
        let hours = try DateOffset.parse("+3hours")
        #expect(hours.unit == .hours)

        let days = try DateOffset.parse("-2days")
        #expect(days.unit == .days)

        let weeks = try DateOffset.parse("+1week")
        #expect(weeks.unit == .weeks)
    }

    @Test("Apply positive offset to date")
    func testApplyPositiveOffset() throws {
        let date = try ARODate.parse("2025-06-15T12:00:00Z")
        let offset = DateOffset(value: 3, unit: .hours)
        let result = offset.apply(to: date)

        #expect(result.hour == 15)
    }

    @Test("Apply negative offset to date")
    func testApplyNegativeOffset() throws {
        let date = try ARODate.parse("2025-06-15T12:00:00Z")
        let offset = DateOffset(value: -5, unit: .days)
        let result = offset.apply(to: date)

        #expect(result.day == 10)
    }

    @Test("Apply offset crossing month boundary")
    func testApplyOffsetCrossingMonth() throws {
        let date = try ARODate.parse("2025-01-30T12:00:00Z")
        let offset = DateOffset(value: 5, unit: .days)
        let result = offset.apply(to: date)

        #expect(result.month == 2)
        #expect(result.day == 4)
    }

    @Test("Apply offset crossing year boundary")
    func testApplyOffsetCrossingYear() throws {
        let date = try ARODate.parse("2025-12-30T12:00:00Z")
        let offset = DateOffset(value: 5, unit: .days)
        let result = offset.apply(to: date)

        #expect(result.year == 2026)
        #expect(result.month == 1)
    }

    @Test("DateOffset isOffsetPattern recognition")
    func testIsOffsetPattern() {
        #expect(DateOffset.isOffsetPattern("+1h") == true)
        #expect(DateOffset.isOffsetPattern("-3d") == true)
        #expect(DateOffset.isOffsetPattern("2w") == true)
        #expect(DateOffset.isOffsetPattern("+30minutes") == true)

        #expect(DateOffset.isOffsetPattern("hello") == false)
        #expect(DateOffset.isOffsetPattern("") == false)
        #expect(DateOffset.isOffsetPattern("++1h") == false)
    }

    @Test("DateOffset equality")
    func testEquality() {
        let offset1 = DateOffset(value: 3, unit: .hours)
        let offset2 = DateOffset(value: 3, unit: .hours)
        let offset3 = DateOffset(value: 3, unit: .days)

        #expect(offset1 == offset2)
        #expect(offset1 != offset3)
    }

    @Test("Parse invalid offset throws error")
    func testParseInvalidOffset() {
        #expect(throws: DateParseError.self) {
            _ = try DateOffset.parse("invalid")
        }

        #expect(throws: DateParseError.self) {
            _ = try DateOffset.parse("")
        }

        #expect(throws: DateParseError.self) {
            _ = try DateOffset.parse("+h") // Missing number
        }
    }
}

// MARK: - DateUnit Tests

@Suite("DateUnit Tests")
struct DateUnitTests {

    @Test("Parse short unit forms")
    func testParseShortForms() {
        #expect(DateUnit.parse("s") == .seconds)
        #expect(DateUnit.parse("m") == .minutes)
        #expect(DateUnit.parse("h") == .hours)
        #expect(DateUnit.parse("d") == .days)
        #expect(DateUnit.parse("w") == .weeks)
        #expect(DateUnit.parse("mo") == .months)  // "M" lowercased becomes "m" (minutes)
        #expect(DateUnit.parse("y") == .years)
    }

    @Test("Parse long unit forms")
    func testParseLongForms() {
        #expect(DateUnit.parse("seconds") == .seconds)
        #expect(DateUnit.parse("minutes") == .minutes)
        #expect(DateUnit.parse("hours") == .hours)
        #expect(DateUnit.parse("days") == .days)
        #expect(DateUnit.parse("weeks") == .weeks)
        #expect(DateUnit.parse("months") == .months)
        #expect(DateUnit.parse("years") == .years)
    }

    @Test("Parse case insensitive")
    func testParseCaseInsensitive() {
        #expect(DateUnit.parse("HOURS") == .hours)
        #expect(DateUnit.parse("Days") == .days)
        #expect(DateUnit.parse("WEEKS") == .weeks)
    }

    @Test("Short form property")
    func testShortForm() {
        #expect(DateUnit.seconds.shortForm == "s")
        #expect(DateUnit.minutes.shortForm == "m")
        #expect(DateUnit.hours.shortForm == "h")
        #expect(DateUnit.days.shortForm == "d")
        #expect(DateUnit.weeks.shortForm == "w")
        #expect(DateUnit.months.shortForm == "M")
        #expect(DateUnit.years.shortForm == "y")
    }

    @Test("Parse invalid unit returns nil")
    func testParseInvalid() {
        #expect(DateUnit.parse("invalid") == nil)
        #expect(DateUnit.parse("") == nil)
        #expect(DateUnit.parse("x") == nil)
    }
}

// MARK: - ARODateRange Tests

@Suite("ARODateRange Tests")
struct ARODateRangeTests {

    @Test("Create date range")
    func testCreateRange() throws {
        let start = try ARODate.parse("2025-01-01T00:00:00Z")
        let end = try ARODate.parse("2025-01-15T00:00:00Z")
        let range = ARODateRange(from: start, to: end)

        #expect(range.start == start)
        #expect(range.end == end)
    }

    @Test("Date range span in days")
    func testSpanInDays() throws {
        let start = try ARODate.parse("2025-01-01T00:00:00Z")
        let end = try ARODate.parse("2025-01-15T00:00:00Z")
        let range = ARODateRange(from: start, to: end)

        #expect(range.days == 14)
    }

    @Test("Date range span in hours")
    func testSpanInHours() throws {
        let start = try ARODate.parse("2025-01-01T00:00:00Z")
        let end = try ARODate.parse("2025-01-01T12:00:00Z")
        let range = ARODateRange(from: start, to: end)

        #expect(range.hours == 12)
    }

    @Test("Date range span in minutes")
    func testSpanInMinutes() throws {
        let start = try ARODate.parse("2025-01-01T00:00:00Z")
        let end = try ARODate.parse("2025-01-01T01:30:00Z")
        let range = ARODateRange(from: start, to: end)

        #expect(range.minutes == 90)
    }

    @Test("Date range span in weeks")
    func testSpanInWeeks() throws {
        let start = try ARODate.parse("2025-01-01T00:00:00Z")
        let end = try ARODate.parse("2025-01-22T00:00:00Z")
        let range = ARODateRange(from: start, to: end)

        #expect(range.weeks == 3)
    }

    @Test("Date range contains date - inclusive")
    func testContainsInclusive() throws {
        let start = try ARODate.parse("2025-01-01T00:00:00Z")
        let end = try ARODate.parse("2025-01-31T23:59:59Z")
        let range = ARODateRange(from: start, to: end)

        let middle = try ARODate.parse("2025-01-15T12:00:00Z")
        let before = try ARODate.parse("2024-12-31T23:59:59Z")
        let after = try ARODate.parse("2025-02-01T00:00:00Z")

        #expect(range.contains(middle) == true)
        #expect(range.contains(start) == true) // Inclusive
        #expect(range.contains(end) == true)   // Inclusive
        #expect(range.contains(before) == false)
        #expect(range.contains(after) == false)
    }

    @Test("Date range contains date - exclusive")
    func testContainsExclusive() throws {
        let start = try ARODate.parse("2025-01-01T00:00:00Z")
        let end = try ARODate.parse("2025-01-31T23:59:59Z")
        let range = ARODateRange(from: start, to: end)

        let middle = try ARODate.parse("2025-01-15T12:00:00Z")

        #expect(range.containsExclusive(middle) == true)
        #expect(range.containsExclusive(start) == false) // Exclusive
        #expect(range.containsExclusive(end) == false)   // Exclusive
    }

    @Test("Date range property access")
    func testPropertyAccess() throws {
        let start = try ARODate.parse("2025-01-01T00:00:00Z")
        let end = try ARODate.parse("2025-01-08T00:00:00Z")
        let range = ARODateRange(from: start, to: end)

        #expect(range.property("days") as? Int == 7)
        #expect(range.property("hours") as? Int == 168)
        #expect(range.property("weeks") as? Int == 1)
        #expect((range.property("start") as? ARODate) == start)
        #expect((range.property("end") as? ARODate) == end)
    }

    @Test("Date range to dictionary")
    func testToDictionary() throws {
        let start = try ARODate.parse("2025-01-01T00:00:00Z")
        let end = try ARODate.parse("2025-01-08T00:00:00Z")
        let range = ARODateRange(from: start, to: end)

        let dict = range.toDictionary()

        #expect(dict["days"] as? Int == 7)
        #expect(dict["hours"] as? Int == 168)
        #expect(dict["start"] != nil)
        #expect(dict["end"] != nil)
    }

    @Test("Date range equality")
    func testEquality() throws {
        let start = try ARODate.parse("2025-01-01T00:00:00Z")
        let end = try ARODate.parse("2025-01-08T00:00:00Z")
        let range1 = ARODateRange(from: start, to: end)
        let range2 = ARODateRange(from: start, to: end)
        let range3 = ARODateRange(from: start, to: start)

        #expect(range1 == range2)
        #expect(range1 != range3)
    }

    @Test("Date range description")
    func testDescription() throws {
        let start = try ARODate.parse("2025-01-01T00:00:00Z")
        let end = try ARODate.parse("2025-01-08T00:00:00Z")
        let range = ARODateRange(from: start, to: end)

        let description = range.description
        #expect(description.contains("to"))
    }

    @Test("Date range with reversed dates")
    func testReversedDates() throws {
        let start = try ARODate.parse("2025-01-08T00:00:00Z")
        let end = try ARODate.parse("2025-01-01T00:00:00Z")
        let range = ARODateRange(from: start, to: end)

        // Should still work - contains uses min/max
        let middle = try ARODate.parse("2025-01-04T00:00:00Z")
        #expect(range.contains(middle) == true)

        // Span should still be positive (uses abs)
        #expect(range.days == 7)
    }
}

// MARK: - DateDistance Tests

@Suite("DateDistance Tests")
struct DateDistanceTests {

    @Test("Calculate distance in seconds")
    func testDistanceInSeconds() throws {
        let from = try ARODate.parse("2025-01-01T00:00:00Z")
        let to = try ARODate.parse("2025-01-01T00:01:30Z")
        let distance = DateDistance(from: from, to: to)

        #expect(distance.seconds == 90)
    }

    @Test("Calculate distance in minutes")
    func testDistanceInMinutes() throws {
        let from = try ARODate.parse("2025-01-01T00:00:00Z")
        let to = try ARODate.parse("2025-01-01T02:30:00Z")
        let distance = DateDistance(from: from, to: to)

        #expect(distance.minutes == 150)
    }

    @Test("Calculate distance in hours")
    func testDistanceInHours() throws {
        let from = try ARODate.parse("2025-01-01T00:00:00Z")
        let to = try ARODate.parse("2025-01-01T12:00:00Z")
        let distance = DateDistance(from: from, to: to)

        #expect(distance.hours == 12)
    }

    @Test("Calculate distance in days")
    func testDistanceInDays() throws {
        let from = try ARODate.parse("2025-01-01T00:00:00Z")
        let to = try ARODate.parse("2025-01-15T00:00:00Z")
        let distance = DateDistance(from: from, to: to)

        #expect(distance.days == 14)
    }

    @Test("Calculate distance in weeks")
    func testDistanceInWeeks() throws {
        let from = try ARODate.parse("2025-01-01T00:00:00Z")
        let to = try ARODate.parse("2025-01-22T00:00:00Z")
        let distance = DateDistance(from: from, to: to)

        #expect(distance.weeks == 3)
    }

    @Test("Distance property access")
    func testPropertyAccess() throws {
        let from = try ARODate.parse("2025-01-01T00:00:00Z")
        let to = try ARODate.parse("2025-01-08T00:00:00Z")
        let distance = DateDistance(from: from, to: to)

        #expect(distance.property("days") as? Int == 7)
        #expect(distance.property("hours") as? Int == 168)
        #expect(distance.property("weeks") as? Int == 1)
    }

    @Test("Distance to dictionary")
    func testToDictionary() throws {
        let from = try ARODate.parse("2025-01-01T00:00:00Z")
        let to = try ARODate.parse("2025-01-08T00:00:00Z")
        let distance = DateDistance(from: from, to: to)

        let dict = distance.toDictionary()

        #expect(dict["days"] as? Int == 7)
        #expect(dict["hours"] as? Int == 168)
        #expect(dict["weeks"] as? Int == 1)
    }
}

// MARK: - DateService Tests

@Suite("DateService Tests")
struct DateServiceTests {
    let service = DefaultDateService()

    @Test("DateService now returns current time")
    func testNow() {
        let before = Date()
        let aroDate = service.now(timezone: nil)
        let after = Date()

        #expect(aroDate.date >= before)
        #expect(aroDate.date <= after)
    }

    @Test("DateService parse ISO 8601")
    func testParse() throws {
        let date = try service.parse("2025-06-15T12:30:45Z")

        #expect(date.year == 2025)
        #expect(date.month == 6)
        #expect(date.day == 15)
    }

    @Test("DateService apply offset")
    func testOffset() throws {
        let date = try service.parse("2025-06-15T12:00:00Z")
        let offset = DateOffset(value: 3, unit: .hours)
        let result = service.offset(date, by: offset)

        #expect(result.hour == 15)
    }

    @Test("DateService calculate distance")
    func testDistance() throws {
        let from = try service.parse("2025-01-01T00:00:00Z")
        let to = try service.parse("2025-01-08T00:00:00Z")
        let distance = service.distance(from: from, to: to)

        #expect(distance.days == 7)
    }

    @Test("DateService format date")
    func testFormat() throws {
        let date = try service.parse("2025-06-15T12:30:45Z")
        let formatted = service.format(date, pattern: "yyyy-MM-dd")

        #expect(formatted == "2025-06-15")
    }

    @Test("DateService create range")
    func testCreateRange() throws {
        let start = try service.parse("2025-01-01T00:00:00Z")
        let end = try service.parse("2025-01-08T00:00:00Z")
        let range = service.createRange(from: start, to: end)

        #expect(range.start == start)
        #expect(range.end == end)
        #expect(range.days == 7)
    }
}
