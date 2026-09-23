// ARODate.swift
// ARO Runtime - Date and Time Handling (ARO-0041)

import Foundation

/// A date/time value in ARO with timezone support and property access.
///
/// ARODate wraps Swift's Date and provides:
/// - ISO 8601 string representation
/// - Component access (year, month, day, hour, minute, second)
/// - Timezone support (UTC, local, IANA timezones)
/// - Comparison operators
public struct ARODate: Sendable, Equatable, CustomStringConvertible {
    /// The underlying Swift Date (always stored in UTC)
    public let date: Date

    /// The timezone for display purposes
    public let timezone: TimeZone

    /// Create an ARODate from a Swift Date
    public init(date: Date = Date(), timezone: TimeZone = .gmt) {
        self.date = date
        self.timezone = timezone
    }

    /// Create an ARODate for the current time
    public static func now(timezone: TimeZone = .gmt) -> ARODate {
        ARODate(date: Date(), timezone: timezone)
    }

    // MARK: - Calendar Components

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timezone
        return cal
    }

    /// The year component (e.g., 2025)
    public var year: Int {
        calendar.component(.year, from: date)
    }

    /// The month component (1-12)
    public var month: Int {
        calendar.component(.month, from: date)
    }

    /// The day of month component (1-31)
    public var day: Int {
        calendar.component(.day, from: date)
    }

    /// The hour component (0-23)
    public var hour: Int {
        calendar.component(.hour, from: date)
    }

    /// The minute component (0-59)
    public var minute: Int {
        calendar.component(.minute, from: date)
    }

    /// The second component (0-59)
    public var second: Int {
        calendar.component(.second, from: date)
    }

    /// The day of the week as a string (e.g., "Monday")
    public var dayOfWeek: String {
        let formatter = DateFormatter()
        formatter.timeZone = timezone
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }

    /// The day of the year (1-366)
    public var dayOfYear: Int {
        calendar.ordinality(of: .day, in: .year, for: date) ?? 1
    }

    /// The week of the year (1-53)
    public var weekOfYear: Int {
        calendar.component(.weekOfYear, from: date)
    }

    /// Unix timestamp in seconds
    public var timestamp: Int {
        Int(date.timeIntervalSince1970)
    }

    /// ISO 8601 formatted string
    public var iso: String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timezone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// The timezone identifier (e.g., "UTC", "Europe/Berlin")
    public var timezoneIdentifier: String {
        timezone.identifier
    }

    /// The same instant, rendered in another zone (ARO-0041 §7, GitLab #865).
    ///
    /// The instant does not move. `date` is absolute and is copied unchanged;
    /// only `timezone` differs, so every component, the ISO string and the
    /// day-of-week are recomputed for the new zone while `timestamp` stays
    /// identical. That is what makes a comparison between two dates in
    /// different zones mean what it looks like it means — they are the same
    /// two moments, rendered differently.
    public func converted(to zone: TimeZone) -> ARODate {
        ARODate(date: date, timezone: zone)
    }

    /// The UTC offset of this instant in its own zone, in seconds.
    ///
    /// Read from the zone *at this instant*, not from a stored constant, which
    /// is the whole reason a fixed offset is the wrong way to do this: for
    /// `Europe/Berlin` it is 3600 in January and 7200 in July, and an
    /// implementation that picks one is wrong for half the year.
    public var utcOffsetSeconds: Int {
        timezone.secondsFromGMT(for: date)
    }

    /// Whether daylight saving time is in effect at this instant in this zone.
    public var isDaylightSavingTime: Bool {
        timezone.isDaylightSavingTime(for: date)
    }

    // MARK: - Comparison

    /// Check if this date is before another date
    public func isBefore(_ other: ARODate) -> Bool {
        date < other.date
    }

    /// Check if this date is after another date
    public func isAfter(_ other: ARODate) -> Bool {
        date > other.date
    }

    // MARK: - Property Access

    /// Access a property by name (for qualifier-based access)
    public func property(_ name: String) -> (any Sendable)? {
        switch name.lowercased() {
        case "year": return year
        case "month": return month
        case "day": return day
        case "hour": return hour
        case "minute": return minute
        case "second": return second
        case "dayofweek": return dayOfWeek
        case "dayofyear": return dayOfYear
        case "weekofyear": return weekOfYear
        case "timestamp": return timestamp
        case "iso": return iso
        case "timezone": return timezoneIdentifier
        case "offset", "utcoffset": return utcOffsetSeconds
        case "dst", "isdst": return isDaylightSavingTime
        default: return nil
        }
    }

    /// Convert to a dictionary for serialization
    public func toDictionary() -> [String: any Sendable] {
        [
            "iso": iso,
            "year": year,
            "month": month,
            "day": day,
            "hour": hour,
            "minute": minute,
            "second": second,
            "dayOfWeek": dayOfWeek,
            "dayOfYear": dayOfYear,
            "weekOfYear": weekOfYear,
            "timestamp": timestamp,
            "timezone": timezoneIdentifier,
            "offset": utcOffsetSeconds,
            "dst": isDaylightSavingTime
        ]
    }

    // MARK: - CustomStringConvertible

    public var description: String {
        iso
    }
}

// MARK: - Comparable

extension ARODate: Comparable {
    public static func < (lhs: ARODate, rhs: ARODate) -> Bool {
        lhs.date < rhs.date
    }
}

// MARK: - Timezone Parsing

extension ARODate {
    /// Parse a timezone from a string qualifier
    /// - "utc" -> UTC
    /// - "local" -> System local timezone
    /// - "Europe/Berlin" -> IANA timezone
    public static func parseTimezone(_ qualifier: String?) -> TimeZone {
        resolveTimezone(qualifier) ?? .gmt
    }

    /// Parse a timezone, or `nil` when the name is not one.
    ///
    /// The nil-returning form is what a *conversion* needs: silently falling
    /// back to GMT is how `<now: timezone>` came to answer GMT whatever was
    /// asked for (GitLab #865), and a misspelled zone should say so rather
    /// than quietly render the wrong time.
    public static func resolveTimezone(_ qualifier: String?) -> TimeZone? {
        guard let qualifier else { return nil }

        let trimmed = qualifier.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        switch trimmed.lowercased() {
        case "utc", "gmt", "z":
            return .gmt
        case "local", "system":
            return .current
        default:
            break
        }

        // IANA identifier ("Europe/Berlin"), case as written — identifiers are
        // case-sensitive and `TimeZone` will not normalise them.
        if let tz = TimeZone(identifier: trimmed) { return tz }
        // A common abbreviation ("CET", "PST"). These are ambiguous worldwide
        // and are accepted only because a program that writes one means the
        // one Foundation picks.
        if let tz = TimeZone(abbreviation: trimmed.uppercased()) { return tz }
        // A fixed offset ("+02:00", "-0800", "UTC+2"): not a zone, so it does
        // not observe DST — but it is what an offset in a data feed means.
        if let tz = fixedOffsetZone(trimmed) { return tz }
        return nil
    }

    /// A `TimeZone` for a written UTC offset, or nil.
    private static func fixedOffsetZone(_ raw: String) -> TimeZone? {
        var text = raw.uppercased()
        for prefix in ["UTC", "GMT"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        guard let sign = text.first, sign == "+" || sign == "-" else { return nil }
        let digits = String(text.dropFirst()).replacingOccurrences(of: ":", with: "")
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }

        let hours: Int
        let minutes: Int
        switch digits.count {
        case 1, 2:
            hours = Int(digits) ?? 0
            minutes = 0
        case 3, 4:
            let padded = String(repeating: "0", count: 4 - digits.count) + digits
            hours = Int(padded.prefix(2)) ?? 0
            minutes = Int(padded.suffix(2)) ?? 0
        default:
            return nil
        }
        guard hours <= 18, minutes < 60 else { return nil }
        let seconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds)
    }
}

// MARK: - ISO 8601 Parsing

extension ARODate {
    /// Parse an ISO 8601 date string
    public static func parse(_ string: String) throws -> ARODate {
        let trimmed = string.trimmingCharacters(in: .whitespaces)

        // Try full ISO 8601 with timezone
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: trimmed) {
            return ARODate(date: date, timezone: .gmt)
        }

        // Try without fractional seconds
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: trimmed) {
            return ARODate(date: date, timezone: .gmt)
        }

        // Try date only (YYYY-MM-DD)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = .gmt
        if let date = dateFormatter.date(from: trimmed) {
            return ARODate(date: date, timezone: .gmt)
        }

        // Try date and time without timezone (assumes UTC)
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        if let date = dateFormatter.date(from: trimmed) {
            return ARODate(date: date, timezone: .gmt)
        }

        throw DateParseError.invalidFormat(string)
    }
}

// MARK: - Errors

public enum DateParseError: Error, Sendable {
    case invalidFormat(String)
    case invalidTimezone(String)
    case invalidOffset(String)
}
