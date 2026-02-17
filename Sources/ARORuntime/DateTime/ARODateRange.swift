// ARODateRange.swift
// ARO Runtime - Date and Time Handling (ARO-0041)

import Foundation

/// A date range with start and end dates
///
/// Provides:
/// - Range membership checking
/// - Span calculations in various units
/// - Start and end access
public struct ARODateRange: Sendable, Equatable {
    /// The start date of the range
    public let start: ARODate

    /// The end date of the range
    public let end: ARODate

    /// Create a date range from start to end
    public init(from start: ARODate, to end: ARODate) {
        self.start = start
        self.end = end
    }

    // MARK: - Span Calculations

    /// The time interval of the range in seconds
    public var timeInterval: TimeInterval {
        end.date.timeIntervalSince(start.date)
    }

    /// The span in seconds
    public var seconds: Int {
        Int(abs(timeInterval))
    }

    /// The span in minutes
    public var minutes: Int {
        Int(abs(timeInterval) / 60)
    }

    /// The span in hours
    public var hours: Int {
        Int(abs(timeInterval) / 3600)
    }

    /// The span in days
    public var days: Int {
        Int(abs(timeInterval) / 86400)
    }

    /// The span in weeks
    public var weeks: Int {
        Int(abs(timeInterval) / 604800)
    }

    /// Get the span in a specific unit
    public func span(_ unit: DateUnit) -> Int {
        switch unit {
        case .seconds: return seconds
        case .minutes: return minutes
        case .hours: return hours
        case .days: return days
        case .weeks: return weeks
        case .months:
            let calendar = Calendar(identifier: .gregorian)
            let components = calendar.dateComponents([.month], from: start.date, to: end.date)
            return abs(components.month ?? 0)
        case .years:
            let calendar = Calendar(identifier: .gregorian)
            let components = calendar.dateComponents([.year], from: start.date, to: end.date)
            return abs(components.year ?? 0)
        }
    }

    // MARK: - Membership

    /// Check if a date falls within this range (inclusive)
    public func contains(_ date: ARODate) -> Bool {
        let minDate = min(start.date, end.date)
        let maxDate = max(start.date, end.date)
        return date.date >= minDate && date.date <= maxDate
    }

    /// Check if a date falls strictly within this range (exclusive)
    public func containsExclusive(_ date: ARODate) -> Bool {
        let minDate = min(start.date, end.date)
        let maxDate = max(start.date, end.date)
        return date.date > minDate && date.date < maxDate
    }

    // MARK: - Property Access

    /// Access a property by name
    public func property(_ name: String) -> (any Sendable)? {
        switch name.lowercased() {
        case "start": return start
        case "end": return end
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
            "start": start.iso,
            "end": end.iso,
            "seconds": seconds,
            "minutes": minutes,
            "hours": hours,
            "days": days,
            "weeks": weeks
        ]
    }
}

// MARK: - CustomStringConvertible

extension ARODateRange: CustomStringConvertible {
    public var description: String {
        "\(start.iso) to \(end.iso)"
    }
}
