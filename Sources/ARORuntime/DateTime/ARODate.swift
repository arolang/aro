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
            "timezone": timezoneIdentifier
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
        guard let qualifier = qualifier else { return .gmt }

        let normalized = qualifier.lowercased().trimmingCharacters(in: .whitespaces)

        switch normalized {
        case "utc", "gmt":
            return .gmt
        case "local":
            return .current
        default:
            // Try IANA timezone identifier
            if let tz = TimeZone(identifier: qualifier) {
                return tz
            }
            // Try common abbreviations
            if let tz = TimeZone(abbreviation: qualifier.uppercased()) {
                return tz
            }
            return .gmt
        }
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
