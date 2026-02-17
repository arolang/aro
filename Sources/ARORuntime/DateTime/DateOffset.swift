// DateOffset.swift
// ARO Runtime - Date and Time Handling (ARO-0041)

import Foundation

/// A relative date offset like "+1h", "-3d", "+2w"
///
/// Supported units:
/// - s, seconds: Seconds
/// - m, min, minutes: Minutes
/// - h, hours: Hours
/// - d, days: Days
/// - w, weeks: Weeks
/// - M, months: Months
/// - y, years: Years
public struct DateOffset: Sendable, Equatable {
    /// The numeric value (positive or negative)
    public let value: Int

    /// The time unit
    public let unit: DateUnit

    /// Create a DateOffset with a value and unit
    public init(value: Int, unit: DateUnit) {
        self.value = value
        self.unit = unit
    }

    /// Parse an offset string like "+1h", "-3d", "+2w"
    public static func parse(_ string: String) throws -> DateOffset {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw DateParseError.invalidOffset(string)
        }

        // Determine sign
        var remaining = trimmed
        var multiplier = 1

        if remaining.hasPrefix("+") {
            remaining = String(remaining.dropFirst())
        } else if remaining.hasPrefix("-") {
            multiplier = -1
            remaining = String(remaining.dropFirst())
        }

        // Extract numeric part
        var numericPart = ""
        var unitPart = ""

        for char in remaining {
            if char.isNumber {
                numericPart.append(char)
            } else {
                unitPart = String(remaining.dropFirst(numericPart.count))
                break
            }
        }

        guard let value = Int(numericPart), !unitPart.isEmpty else {
            throw DateParseError.invalidOffset(string)
        }

        guard let unit = DateUnit.parse(unitPart) else {
            throw DateParseError.invalidOffset(string)
        }

        return DateOffset(value: value * multiplier, unit: unit)
    }

    /// Check if this string looks like an offset pattern
    public static func isOffsetPattern(_ string: String) -> Bool {
        let pattern = #"^[+-]?\d+(?:[smhdwMy]|seconds?|minutes?|min|hours?|days?|weeks?|months?|years?)$"#
        return string.range(of: pattern, options: .regularExpression) != nil
    }

    /// Apply this offset to a date
    public func apply(to date: ARODate) -> ARODate {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = date.timezone

        let component: Calendar.Component
        switch unit {
        case .seconds: component = .second
        case .minutes: component = .minute
        case .hours: component = .hour
        case .days: component = .day
        case .weeks: component = .weekOfYear
        case .months: component = .month
        case .years: component = .year
        }

        guard let newDate = calendar.date(byAdding: component, value: value, to: date.date) else {
            return date
        }

        return ARODate(date: newDate, timezone: date.timezone)
    }
}

// MARK: - DateUnit

/// Time units for date offsets
public enum DateUnit: String, Sendable, CaseIterable {
    case seconds
    case minutes
    case hours
    case days
    case weeks
    case months
    case years

    /// Parse a unit string
    public static func parse(_ string: String) -> DateUnit? {
        let normalized = string.lowercased().trimmingCharacters(in: .whitespaces)

        switch normalized {
        case "s", "sec", "second", "seconds":
            return .seconds
        case "m", "min", "minute", "minutes":
            return .minutes
        case "h", "hr", "hour", "hours":
            return .hours
        case "d", "day", "days":
            return .days
        case "w", "wk", "week", "weeks":
            return .weeks
        case "M", "mo", "month", "months":
            return .months
        case "y", "yr", "year", "years":
            return .years
        default:
            // Handle uppercase M for months
            if string == "M" {
                return .months
            }
            return nil
        }
    }

    /// Short form of the unit (for display)
    public var shortForm: String {
        switch self {
        case .seconds: return "s"
        case .minutes: return "m"
        case .hours: return "h"
        case .days: return "d"
        case .weeks: return "w"
        case .months: return "M"
        case .years: return "y"
        }
    }
}

// MARK: - DateDistance

/// The distance between two dates
public struct DateDistance: Sendable {
    /// The start date
    public let from: ARODate

    /// The end date
    public let to: ARODate

    /// The underlying time interval in seconds
    public var timeInterval: TimeInterval {
        to.date.timeIntervalSince(from.date)
    }

    /// Distance in seconds
    public var seconds: Int {
        Int(timeInterval)
    }

    /// Distance in minutes
    public var minutes: Int {
        Int(timeInterval / 60)
    }

    /// Distance in hours
    public var hours: Int {
        Int(timeInterval / 3600)
    }

    /// Distance in days
    public var days: Int {
        Int(timeInterval / 86400)
    }

    /// Distance in weeks
    public var weeks: Int {
        Int(timeInterval / 604800)
    }

    /// Access a property by name
    public func property(_ name: String) -> (any Sendable)? {
        switch name.lowercased() {
        case "seconds": return seconds
        case "minutes": return minutes
        case "hours": return hours
        case "days": return days
        case "weeks": return weeks
        default: return nil
        }
    }

    /// Convert to dictionary
    public func toDictionary() -> [String: any Sendable] {
        [
            "seconds": seconds,
            "minutes": minutes,
            "hours": hours,
            "days": days,
            "weeks": weeks
        ]
    }
}
