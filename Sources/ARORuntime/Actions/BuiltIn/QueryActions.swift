// ============================================================
// QueryActions.swift
// ARO Runtime - Data Pipeline Action Implementations (ARO-0018)
// ============================================================

import Foundation
import AROParser

// MARK: - Map Action

/// Maps a collection to a different type by extracting matching fields
///
/// The Map action transforms a collection to a target type defined in OpenAPI.
/// Fields with matching names are automatically copied from source to target.
///
/// ## Example
/// ```aro
/// <Map> the <summaries: List<UserSummary>> from the <users>.
/// ```
public struct MapAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["map"]
    public static let validPrepositions: Set<Preposition> = [.from, .to]

    public init() {}

    // Known type specifiers that should not be treated as field names
    private static let typeSpecifiers: Set<String> = [
        "List", "Array", "Set",
        "Integer", "Int", "Float", "Double", "Number",
        "String", "Boolean", "Bool",
        "Object", "Dictionary", "Map"
    ]

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get source collection
        guard let source = context.resolveAny(object.base) else {
            throw ActionError.undefinedVariable(object.base)
        }

        // Find field specifier (skip known type specifiers)
        let fieldSpecifier = result.specifiers.first { !Self.typeSpecifiers.contains($0) }

        // Handle array mapping
        if let array = source as? [any Sendable] {
            // If there's a field specifier, extract that field from each item
            if let field = fieldSpecifier {
                return array.compactMap { item -> (any Sendable)? in
                    if let dict = item as? [String: any Sendable] {
                        return dict[field]
                    }
                    return nil
                }
            }

            // Map entire objects - filter fields based on target type
            // For now, pass through the entire objects
            // OpenAPI type filtering would be done by a type-aware runtime
            return array
        }

        // Handle dictionary - extract field
        if let dict = source as? [String: any Sendable] {
            if let field = fieldSpecifier {
                if let value = dict[field] {
                    return value
                }
                throw ActionError.undefinedVariable(field)
            }
            return dict
        }

        return source
    }
}

// MARK: - Reduce Action

/// Reduces a collection to a single value using an aggregation function
///
/// The Reduce action applies aggregation functions (sum, avg, count, min, max)
/// to a collection and returns a single value.
///
/// ## Example
/// ```aro
/// <Reduce> the <total: Float> from the <orders> with sum(<amount>).
/// <Reduce> the <count: Integer> from the <users> with count().
/// ```
public struct ReduceAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["reduce", "aggregate"]
    public static let validPrepositions: Set<Preposition> = [.from, .with]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get source collection
        guard let source = context.resolveAny(object.base) else {
            throw ActionError.undefinedVariable(object.base)
        }

        // Get aggregation function from context binding (ARO-0018) or fall back to specifiers
        let aggregateFunc: String
        let field: String?

        if let aggType = context.resolveAny("_aggregation_type_") as? String {
            // New ARO-0018 syntax: with sum(<field>)
            aggregateFunc = aggType.lowercased()
            field = context.resolveAny("_aggregation_field_") as? String
        } else {
            // Legacy syntax: specifiers
            aggregateFunc = result.specifiers.first?.lowercased() ?? "count"
            field = result.specifiers.count > 1 ? result.specifiers[1] : nil
        }

        // Handle array aggregation
        guard let array = source as? [any Sendable] else {
            // Single value - return as-is for count=1, value for others
            switch aggregateFunc {
            case "count":
                return 1
            default:
                return source
            }
        }

        // Extract numeric values from array
        let values: [Double] = array.compactMap { item -> Double? in
            if let field = field, let dict = item as? [String: any Sendable] {
                return asDouble(dict[field])
            }
            // For simple arrays of numbers, convert directly
            return asDouble(item)
        }
        // Apply aggregation function
        switch aggregateFunc {
        case "count":
            return array.count

        case "sum":
            return values.reduce(0, +)

        case "avg", "average":
            guard !values.isEmpty else { return 0.0 }
            return values.reduce(0, +) / Double(values.count)

        case "min":
            return values.min() ?? 0.0

        case "max":
            return values.max() ?? 0.0

        case "first":
            return array.first ?? ([] as [any Sendable])

        case "last":
            return array.last ?? ([] as [any Sendable])

        default:
            return array.count
        }
    }

    private func asDouble(_ value: Any?) -> Double? {
        guard let value = value else { return nil }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let f = value as? Float { return Double(f) }
        if let s = value as? String { return Double(s) }
        return nil
    }
}

// MARK: - Filter Action

/// Filters a collection using a where clause
///
/// The Filter action filters a collection based on field predicates.
///
/// ## Example
/// ```aro
/// <Filter> the <active: List<User>> from the <users> where <status> is "active".
/// <Filter> the <high-value: List<Order>> from the <orders> where <amount> > 1000.
/// ```
public struct FilterAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["filter"]
    public static let validPrepositions: Set<Preposition> = [.from]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get source collection
        guard let source = context.resolveAny(object.base) else {
            throw ActionError.undefinedVariable(object.base)
        }

        // Get where clause from context binding (ARO-0018) or fall back to specifiers
        let field: String?
        let op: String?
        let expectedValue: any Sendable

        if let whereField = context.resolveAny("_where_field_") as? String {
            // New ARO-0018 syntax: where <field> is "value"
            field = whereField
            op = context.resolveAny("_where_op_") as? String
            expectedValue = context.resolveAny("_where_value_") ?? ""
        } else if result.specifiers.count >= 3 {
            // Legacy syntax: specifiers
            field = result.specifiers[0]
            op = result.specifiers[1]
            expectedValue = result.specifiers[2]
        } else {
            // No predicate - return all
            return source
        }

        guard let field = field, let op = op else {
            return source
        }

        // Handle array filtering with predicate
        guard let array = source as? [any Sendable] else {
            return source
        }

        return array.filter { item in
            guard let dict = item as? [String: any Sendable],
                  let actualValue = dict[field] else {
                return false
            }
            return matchesPredicate(actual: actualValue, op: op, expected: expectedValue)
        }
    }

    private func matchesPredicate(actual: Any, op: String, expected: any Sendable) -> Bool {
        let actualStr = String(describing: actual)
        let expectedStr = String(describing: expected)

        switch op.lowercased() {
        case "is", "==", "equals":
            return actualStr == expectedStr

        case "is not", "is-not", "!=", "not-equals":
            return actualStr != expectedStr

        case ">", "gt":
            if let actualNum = asDouble(actual), let expectedNum = asDouble(expected) {
                return actualNum > expectedNum
            }
            return actualStr > expectedStr

        case ">=", "gte":
            if let actualNum = asDouble(actual), let expectedNum = asDouble(expected) {
                return actualNum >= expectedNum
            }
            return actualStr >= expectedStr

        case "<", "lt":
            if let actualNum = asDouble(actual), let expectedNum = asDouble(expected) {
                return actualNum < expectedNum
            }
            return actualStr < expectedStr

        case "<=", "lte":
            if let actualNum = asDouble(actual), let expectedNum = asDouble(expected) {
                return actualNum <= expectedNum
            }
            return actualStr <= expectedStr

        case "contains":
            return actualStr.contains(expectedStr)

        case "starts-with":
            return actualStr.hasPrefix(expectedStr)

        case "ends-with":
            return actualStr.hasSuffix(expectedStr)

        case "matches":
            // Regex matching
            do {
                let regex = try NSRegularExpression(pattern: expectedStr)
                let range = NSRange(actualStr.startIndex..., in: actualStr)
                return regex.firstMatch(in: actualStr, range: range) != nil
            } catch {
                return false
            }

        case "in":
            // Support array values (ARO-0042)
            if let arr = expected as? [any Sendable] {
                return arr.contains { item in
                    areValuesEqual(actual, item)
                }
            }
            // Fallback to comma-separated values
            let values = expectedStr.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            return values.contains(actualStr)

        case "not in", "not-in", "notin":
            // Support array values (ARO-0042)
            if let arr = expected as? [any Sendable] {
                return !arr.contains { item in
                    areValuesEqual(actual, item)
                }
            }
            // Fallback to comma-separated values
            let values = expectedStr.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            return !values.contains(actualStr)

        default:
            return actualStr == expectedStr
        }
    }

    private func asDouble(_ value: Any) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let f = value as? Float { return Double(f) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    /// Type-safe equality check for set membership operations (ARO-0042)
    private func areValuesEqual(_ a: Any, _ b: Any) -> Bool {
        // Integer comparison
        if let aInt = a as? Int, let bInt = b as? Int {
            return aInt == bInt
        }
        // Double comparison
        if let aDouble = a as? Double, let bDouble = b as? Double {
            return aDouble == bDouble
        }
        // String comparison
        if let aStr = a as? String, let bStr = b as? String {
            return aStr == bStr
        }
        // Bool comparison
        if let aBool = a as? Bool, let bBool = b as? Bool {
            return aBool == bBool
        }
        // Fallback to string representation for other types
        return String(describing: a) == String(describing: b)
    }
}

// MARK: - Aggregation Helpers

/// Helper functions for collection aggregations
public enum Aggregations {
    /// Count items in a collection
    public static func count(_ collection: Any) -> Int {
        if let array = collection as? [Any] {
            return array.count
        }
        if let dict = collection as? [String: Any] {
            return dict.count
        }
        return 1
    }

    /// Sum numeric values in a collection
    public static func sum(_ collection: Any, field: String? = nil) -> Double {
        guard let array = collection as? [Any] else { return 0 }

        return array.compactMap { item -> Double? in
            if let field = field, let dict = item as? [String: Any] {
                return asDouble(dict[field])
            }
            return asDouble(item)
        }.reduce(0, +)
    }

    /// Average numeric values in a collection
    public static func avg(_ collection: Any, field: String? = nil) -> Double {
        guard let array = collection as? [Any], !array.isEmpty else { return 0 }

        let values = array.compactMap { item -> Double? in
            if let field = field, let dict = item as? [String: Any] {
                return asDouble(dict[field])
            }
            return asDouble(item)
        }

        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Minimum value in a collection
    public static func min(_ collection: Any, field: String? = nil) -> Double? {
        guard let array = collection as? [Any] else { return nil }

        let values = array.compactMap { item -> Double? in
            if let field = field, let dict = item as? [String: Any] {
                return asDouble(dict[field])
            }
            return asDouble(item)
        }

        return values.min()
    }

    /// Maximum value in a collection
    public static func max(_ collection: Any, field: String? = nil) -> Double? {
        guard let array = collection as? [Any] else { return nil }

        let values = array.compactMap { item -> Double? in
            if let field = field, let dict = item as? [String: Any] {
                return asDouble(dict[field])
            }
            return asDouble(item)
        }

        return values.max()
    }

    private static func asDouble(_ value: Any?) -> Double? {
        guard let value = value else { return nil }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let f = value as? Float { return Double(f) }
        if let s = value as? String { return Double(s) }
        return nil
    }
}

// MARK: - Streaming Query Support (ARO-0051)

/// Extension to support streaming Filter operations
extension FilterAction {
    /// Execute filter with streaming support
    ///
    /// If the source is a lazy stream, returns a lazy filtered stream.
    /// Otherwise, falls back to eager filtering.
    public func executeStreaming(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        // Get source - check for streaming value first
        guard let source = context.resolveAny(object.base) else {
            throw ActionError.undefinedVariable(object.base)
        }

        // Check if source is already a stream
        if let streamValue = source as? AROValue<[String: any Sendable]> {
            // Get predicate info
            let (field, op, expectedValue) = getPredicateInfo(result: result, context: context)

            guard let field = field, let op = op else {
                // No predicate - return as-is
                return streamValue
            }

            // Return lazy filtered stream
            let filtered = streamValue.filter { item in
                guard let actualValue = item[field] else { return false }
                return self.matchesPredicate(actual: actualValue, op: op, expected: expectedValue)
            }
            return filtered
        }

        // Fall back to eager execution
        return try await execute(result: result, object: object, context: context)
    }

    /// Extract predicate information from result and context
    private func getPredicateInfo(result: ResultDescriptor, context: ExecutionContext) -> (field: String?, op: String?, value: any Sendable) {
        if let whereField = context.resolveAny("_where_field_") as? String {
            return (
                whereField,
                context.resolveAny("_where_op_") as? String,
                context.resolveAny("_where_value_") ?? ""
            )
        } else if result.specifiers.count >= 3 {
            return (result.specifiers[0], result.specifiers[1], result.specifiers[2])
        }
        return (nil, nil, "")
    }
}

/// Extension to support streaming Map operations
extension MapAction {
    /// Execute map with streaming support
    ///
    /// If the source is a lazy stream, returns a lazy mapped stream.
    /// Otherwise, falls back to eager mapping.
    public func executeStreaming(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        guard let source = context.resolveAny(object.base) else {
            throw ActionError.undefinedVariable(object.base)
        }

        // Check if source is a streaming value
        if let streamValue = source as? AROValue<[String: any Sendable]> {
            let fieldSpecifier = result.specifiers.first { !Self.typeSpecifiers.contains($0) }

            if let field = fieldSpecifier {
                // Map to extract a single field
                let mapped: AROValue<any Sendable> = streamValue.map { item in
                    return item[field] ?? "" as any Sendable
                }
                return mapped
            }

            // Pass through entire objects
            return streamValue
        }

        // Fall back to eager execution
        return try await execute(result: result, object: object, context: context)
    }
}

/// Extension to support streaming Reduce operations
extension ReduceAction {
    /// Execute reduce with streaming support
    ///
    /// Reduce operations naturally stream - they consume elements one at a time
    /// and maintain an accumulator with O(1) memory.
    public func executeStreaming(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        guard let source = context.resolveAny(object.base) else {
            throw ActionError.undefinedVariable(object.base)
        }

        // Get aggregation function
        let aggregateFunc: String
        let field: String?

        if let aggType = context.resolveAny("_aggregation_type_") as? String {
            aggregateFunc = aggType.lowercased()
            field = context.resolveAny("_aggregation_field_") as? String
        } else {
            aggregateFunc = result.specifiers.first?.lowercased() ?? "count"
            field = result.specifiers.count > 1 ? result.specifiers[1] : nil
        }

        // Check if source is a streaming value
        if let streamValue = source as? AROValue<[String: any Sendable]> {
            let stream = streamValue.asStream()

            // Perform streaming reduction using reduce (no mutable captures)
            switch aggregateFunc {
            case "count":
                return try await stream.reduce(0) { count, _ in count + 1 }

            case "sum":
                let fieldName = field
                return try await stream.reduce(0.0) { sum, item in
                    if let fieldName = fieldName, let value = item[fieldName] {
                        return sum + (asDouble(value) ?? 0)
                    }
                    return sum
                }

            case "avg", "average":
                let fieldName = field
                let (sum, count) = try await stream.reduce((0.0, 0)) { acc, item in
                    if let fieldName = fieldName, let value = item[fieldName], let num = asDouble(value) {
                        return (acc.0 + num, acc.1 + 1)
                    }
                    return acc
                }
                return count > 0 ? sum / Double(count) : 0.0

            case "min":
                let fieldName = field
                let result = try await stream.reduce(Double?.none) { minValue, item in
                    if let fieldName = fieldName, let value = item[fieldName], let num = asDouble(value) {
                        return minValue.map { Swift.min($0, num) } ?? num
                    }
                    return minValue
                }
                return result ?? 0.0

            case "max":
                let fieldName = field
                let result = try await stream.reduce(Double?.none) { maxValue, item in
                    if let fieldName = fieldName, let value = item[fieldName], let num = asDouble(value) {
                        return maxValue.map { Swift.max($0, num) } ?? num
                    }
                    return maxValue
                }
                return result ?? 0.0

            case "first":
                // Collect just the first element
                let result = try await stream.reduce([String: any Sendable]?.none) { first, item in
                    return first ?? item
                }
                return result ?? ([:] as [String: any Sendable])

            case "last":
                // Keep overwriting with latest
                let result = try await stream.reduce([String: any Sendable]?.none) { _, item in
                    return item
                }
                return result ?? ([:] as [String: any Sendable])

            default:
                // Default to count
                return try await stream.reduce(0) { count, _ in count + 1 }
            }
        }

        // Fall back to eager execution
        return try await execute(result: result, object: object, context: context)
    }
}

/// Streaming aggregation helpers
extension Aggregations {
    /// Stream-based count
    public static func streamCount<T: Sendable>(_ stream: AROStream<T>) async throws -> Int {
        try await stream.reduce(0) { count, _ in count + 1 }
    }

    /// Stream-based sum
    public static func streamSum(_ stream: AROStream<[String: any Sendable]>, field: String) async throws -> Double {
        try await stream.reduce(0.0) { sum, item in
            if let value = item[field], let num = asDouble(value) {
                return sum + num
            }
            return sum
        }
    }

    /// Stream-based average
    public static func streamAvg(_ stream: AROStream<[String: any Sendable]>, field: String) async throws -> Double {
        let (sum, count) = try await stream.reduce((0.0, 0)) { acc, item in
            if let value = item[field], let num = asDouble(value) {
                return (acc.0 + num, acc.1 + 1)
            }
            return acc
        }
        return count > 0 ? sum / Double(count) : 0.0
    }

    /// Stream-based min
    public static func streamMin(_ stream: AROStream<[String: any Sendable]>, field: String) async throws -> Double? {
        try await stream.reduce(Double?.none) { minValue, item in
            if let value = item[field], let num = asDouble(value) {
                return minValue.map { Swift.min($0, num) } ?? num
            }
            return minValue
        }
    }

    /// Stream-based max
    public static func streamMax(_ stream: AROStream<[String: any Sendable]>, field: String) async throws -> Double? {
        try await stream.reduce(Double?.none) { maxValue, item in
            if let value = item[field], let num = asDouble(value) {
                return maxValue.map { Swift.max($0, num) } ?? num
            }
            return maxValue
        }
    }
}

// MARK: - Collection Extensions

extension Array where Element == any Sendable {
    /// Filter collection with a field predicate
    public func whereField(_ field: String, equals value: String) -> [any Sendable] {
        filter { item in
            guard let dict = item as? [String: any Sendable],
                  let fieldValue = dict[field] else {
                return false
            }
            return String(describing: fieldValue) == value
        }
    }

    /// Filter collection with a numeric comparison
    public func whereField(_ field: String, greaterThan value: Double) -> [any Sendable] {
        filter { item in
            guard let dict = item as? [String: any Sendable],
                  let fieldValue = dict[field],
                  let numValue = fieldValue as? Double ?? (fieldValue as? Int).map(Double.init) else {
                return false
            }
            return numValue > value
        }
    }

    /// Extract a single field from all items
    public func pluck(_ field: String) -> [any Sendable] {
        compactMap { item -> (any Sendable)? in
            guard let dict = item as? [String: any Sendable] else { return nil }
            return dict[field]
        }
    }

    /// Sort by a field
    public func sortedBy(_ field: String, ascending: Bool = true) -> [any Sendable] {
        sorted { lhs, rhs in
            guard let lhsDict = lhs as? [String: any Sendable],
                  let rhsDict = rhs as? [String: any Sendable],
                  let lhsValue = lhsDict[field],
                  let rhsValue = rhsDict[field] else {
                return false
            }

            // Numeric comparison
            if let lhsNum = lhsValue as? Double ?? (lhsValue as? Int).map(Double.init),
               let rhsNum = rhsValue as? Double ?? (rhsValue as? Int).map(Double.init) {
                return ascending ? lhsNum < rhsNum : lhsNum > rhsNum
            }

            // String comparison
            let lhsStr = String(describing: lhsValue)
            let rhsStr = String(describing: rhsValue)
            return ascending ? lhsStr < rhsStr : lhsStr > rhsStr
        }
    }
}
