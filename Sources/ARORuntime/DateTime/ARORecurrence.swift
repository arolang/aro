// ARORecurrence.swift
// ARO Runtime - Date and Time Handling (ARO-0041)

import Foundation

/// A recurrence pattern for scheduling
///
/// Supports patterns like:
/// - "every day", "every week", "every month"
/// - "every 2nd day", "every 3 weeks"
/// - "every monday", "every friday"
/// - "every second monday", "every last friday"
public struct ARORecurrence: Sendable {
    /// The original pattern string
    public let pattern: String

    /// The parsed recurrence type
    public let recurrenceType: RecurrenceType

    /// The starting date for the recurrence (defaults to now)
    public let startDate: ARODate

    /// Create a recurrence from a pattern string
    public init(pattern: String, from startDate: ARODate? = nil) throws {
        self.pattern = pattern
        self.recurrenceType = try RecurrenceType.parse(pattern)
        self.startDate = startDate ?? ARODate.now()
    }

    // MARK: - Occurrence Calculations

    /// Get the next occurrence after a given date
    public func next(from date: ARODate? = nil) -> ARODate {
        let referenceDate = date ?? ARODate.now()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = referenceDate.timezone

        switch recurrenceType {
        case .interval(let count, let unit):
            return nextInterval(from: referenceDate, count: count, unit: unit, calendar: calendar)

        case .weekday(let weekday, let ordinal):
            return nextWeekday(from: referenceDate, weekday: weekday, ordinal: ordinal, calendar: calendar)
        }
    }

    /// Get the previous occurrence before a given date
    public func previous(from date: ARODate? = nil) -> ARODate {
        let referenceDate = date ?? ARODate.now()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = referenceDate.timezone

        switch recurrenceType {
        case .interval(let count, let unit):
            return previousInterval(from: referenceDate, count: count, unit: unit, calendar: calendar)

        case .weekday(let weekday, let ordinal):
            return previousWeekday(from: referenceDate, weekday: weekday, ordinal: ordinal, calendar: calendar)
        }
    }

    /// Get multiple occurrences within a date range
    public func occurrences(in range: ARODateRange, limit: Int = 100) -> [ARODate] {
        var results: [ARODate] = []
        var current = next(from: ARODate(date: range.start.date.addingTimeInterval(-1), timezone: range.start.timezone))

        while results.count < limit && current.date <= range.end.date {
            if range.contains(current) {
                results.append(current)
            }
            current = next(from: current)

            // Safety check to prevent infinite loops
            if results.count > 0 && current.date <= results.last!.date {
                break
            }
        }

        return results
    }

    /// Get the next N occurrences
    public func nextOccurrences(_ count: Int, from date: ARODate? = nil) -> [ARODate] {
        var results: [ARODate] = []
        var current = date ?? ARODate.now()

        for _ in 0..<count {
            current = next(from: current)
            results.append(current)
        }

        return results
    }

    // MARK: - Private Helpers

    private func nextInterval(from date: ARODate, count: Int, unit: DateUnit, calendar: Calendar) -> ARODate {
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

        guard let nextDate = calendar.date(byAdding: component, value: count, to: date.date) else {
            return date
        }

        return ARODate(date: nextDate, timezone: date.timezone)
    }

    private func previousInterval(from date: ARODate, count: Int, unit: DateUnit, calendar: Calendar) -> ARODate {
        return nextInterval(from: date, count: -count, unit: unit, calendar: calendar)
    }

    private func nextWeekday(from date: ARODate, weekday: Weekday, ordinal: WeekdayOrdinal, calendar: Calendar) -> ARODate {
        let targetWeekday = weekday.calendarWeekday

        switch ordinal {
        case .every:
            // Find the next occurrence of this weekday
            var current = date.date
            repeat {
                current = calendar.date(byAdding: .day, value: 1, to: current)!
            } while calendar.component(.weekday, from: current) != targetWeekday

            return ARODate(date: current, timezone: date.timezone)

        case .nth(let n):
            // Find the nth occurrence of this weekday in future months
            var searchDate = date.date
            var found = 0

            for _ in 0..<365 { // Search up to a year ahead
                searchDate = calendar.date(byAdding: .day, value: 1, to: searchDate)!

                if calendar.component(.weekday, from: searchDate) == targetWeekday {
                    // Check if this is the nth occurrence in its month
                    let dayOfMonth = calendar.component(.day, from: searchDate)
                    let weekNumber = (dayOfMonth - 1) / 7 + 1

                    if weekNumber == n {
                        found += 1
                        if searchDate > date.date {
                            return ARODate(date: searchDate, timezone: date.timezone)
                        }
                    }
                }
            }

            // Fallback: just return next week
            return nextInterval(from: date, count: 1, unit: .weeks, calendar: calendar)

        case .last:
            // Find the last occurrence of this weekday in future months
            let searchDate = calendar.date(byAdding: .month, value: 1, to: date.date)!
            let month = calendar.component(.month, from: searchDate)
            let year = calendar.component(.year, from: searchDate)

            // Get the last day of that month
            var components = DateComponents()
            components.year = year
            components.month = month + 1
            components.day = 0
            guard let lastDayOfMonth = calendar.date(from: components) else {
                return date
            }

            // Find the last occurrence of the target weekday
            var checkDate = lastDayOfMonth
            while calendar.component(.weekday, from: checkDate) != targetWeekday {
                checkDate = calendar.date(byAdding: .day, value: -1, to: checkDate)!
            }

            return ARODate(date: checkDate, timezone: date.timezone)
        }
    }

    private func previousWeekday(from date: ARODate, weekday: Weekday, ordinal: WeekdayOrdinal, calendar: Calendar) -> ARODate {
        let targetWeekday = weekday.calendarWeekday

        switch ordinal {
        case .every:
            // Find the previous occurrence of this weekday
            var current = date.date
            repeat {
                current = calendar.date(byAdding: .day, value: -1, to: current)!
            } while calendar.component(.weekday, from: current) != targetWeekday

            return ARODate(date: current, timezone: date.timezone)

        case .nth, .last:
            // For simplicity, just go back a week for these cases
            return previousInterval(from: date, count: 1, unit: .weeks, calendar: calendar)
        }
    }

    // MARK: - Property Access

    /// Access a property by name
    public func property(_ name: String) -> Any? {
        switch name.lowercased() {
        case "next": return next()
        case "previous": return previous()
        case "pattern": return pattern
        case "occurrences": return nextOccurrences(10)
        default: return nil
        }
    }
}

// MARK: - RecurrenceType

public enum RecurrenceType: Sendable, Equatable {
    /// Interval-based: "every 2 days", "every week"
    case interval(count: Int, unit: DateUnit)

    /// Weekday-based: "every monday", "every second friday"
    case weekday(day: Weekday, ordinal: WeekdayOrdinal)

    /// Parse a recurrence pattern
    public static func parse(_ pattern: String) throws -> RecurrenceType {
        let normalized = pattern.lowercased().trimmingCharacters(in: .whitespaces)

        // Must start with "every"
        guard normalized.hasPrefix("every") else {
            throw RecurrenceParseError.invalidPattern(pattern)
        }

        let remaining = String(normalized.dropFirst(5)).trimmingCharacters(in: .whitespaces)

        // Check for weekday patterns first
        if let weekdayResult = parseWeekdayPattern(remaining) {
            return weekdayResult
        }

        // Check for interval patterns
        if let intervalResult = parseIntervalPattern(remaining) {
            return intervalResult
        }

        throw RecurrenceParseError.invalidPattern(pattern)
    }

    private static func parseWeekdayPattern(_ input: String) -> RecurrenceType? {
        let parts = input.split(separator: " ").map(String.init)

        // "every monday" -> weekday only
        if parts.count == 1, let weekday = Weekday.parse(parts[0]) {
            return .weekday(day: weekday, ordinal: .every)
        }

        // "every second monday", "every 2nd monday", "every last friday"
        if parts.count == 2 {
            if let ordinal = WeekdayOrdinal.parse(parts[0]), let weekday = Weekday.parse(parts[1]) {
                return .weekday(day: weekday, ordinal: ordinal)
            }
        }

        return nil
    }

    private static func parseIntervalPattern(_ input: String) -> RecurrenceType? {
        let parts = input.split(separator: " ").map(String.init)

        // "every day", "every week", "every month"
        if parts.count == 1, let unit = DateUnit.parse(parts[0]) {
            return .interval(count: 1, unit: unit)
        }

        // "every 2 days", "every 3 weeks"
        if parts.count == 2 {
            // Try parsing "2nd day" or "3rd week" (ordinal + unit)
            if let (count, unit) = parseOrdinalUnit(parts[0], parts[1]) {
                return .interval(count: count, unit: unit)
            }

            // Try parsing "2 days" or "3 weeks" (number + unit)
            if let count = Int(parts[0]), let unit = DateUnit.parse(parts[1]) {
                return .interval(count: count, unit: unit)
            }
        }

        return nil
    }

    private static func parseOrdinalUnit(_ ordinalStr: String, _ unitStr: String) -> (Int, DateUnit)? {
        // Parse ordinals like "2nd", "3rd", "4th"
        let ordinalPattern = #"^(\d+)(st|nd|rd|th)$"#
        guard let regex = try? NSRegularExpression(pattern: ordinalPattern),
              let match = regex.firstMatch(in: ordinalStr, range: NSRange(ordinalStr.startIndex..., in: ordinalStr)),
              let numRange = Range(match.range(at: 1), in: ordinalStr),
              let count = Int(ordinalStr[numRange]),
              let unit = DateUnit.parse(unitStr) else {
            return nil
        }

        return (count, unit)
    }
}

// MARK: - Weekday

public enum Weekday: Int, Sendable, CaseIterable {
    case sunday = 1
    case monday = 2
    case tuesday = 3
    case wednesday = 4
    case thursday = 5
    case friday = 6
    case saturday = 7

    /// The Calendar weekday value
    public var calendarWeekday: Int { rawValue }

    /// Parse a weekday from a string
    public static func parse(_ string: String) -> Weekday? {
        switch string.lowercased() {
        case "sunday", "sun": return .sunday
        case "monday", "mon": return .monday
        case "tuesday", "tue", "tues": return .tuesday
        case "wednesday", "wed": return .wednesday
        case "thursday", "thu", "thur", "thurs": return .thursday
        case "friday", "fri": return .friday
        case "saturday", "sat": return .saturday
        default: return nil
        }
    }
}

// MARK: - WeekdayOrdinal

public enum WeekdayOrdinal: Sendable, Equatable {
    case every
    case nth(Int)
    case last

    /// Parse an ordinal from a string
    public static func parse(_ string: String) -> WeekdayOrdinal? {
        let normalized = string.lowercased()

        switch normalized {
        case "first", "1st": return .nth(1)
        case "second", "2nd": return .nth(2)
        case "third", "3rd": return .nth(3)
        case "fourth", "4th": return .nth(4)
        case "fifth", "5th": return .nth(5)
        case "last": return .last
        default:
            // Try parsing numeric ordinals like "2nd", "3rd"
            let ordinalPattern = #"^(\d+)(st|nd|rd|th)$"#
            guard let regex = try? NSRegularExpression(pattern: ordinalPattern),
                  let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
                  let numRange = Range(match.range(at: 1), in: normalized),
                  let num = Int(normalized[numRange]) else {
                return nil
            }
            return .nth(num)
        }
    }
}

// MARK: - Errors

public enum RecurrenceParseError: Error, Sendable {
    case invalidPattern(String)
}
