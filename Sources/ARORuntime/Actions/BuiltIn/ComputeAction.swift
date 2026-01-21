// ============================================================
// ComputeAction.swift
// ARO Runtime - Compute and Transform Action Implementations
// ============================================================

import Foundation
import AROParser
import Crypto

// MARK: - Helper Functions

/// Resolves the operation name from a result descriptor.
///
/// This function enables two syntax patterns:
/// 1. **New syntax** `<variable: operation>`: specifier defines the operation, base is the variable name
/// 2. **Legacy syntax** `<operation>`: base is both the variable name and operation (for known operations)
///
/// - Parameters:
///   - result: The result descriptor from the statement
///   - knownOperations: Set of known operation names for backward compatibility
///   - fallback: Default value if no operation can be determined
/// - Returns: The operation name to use
private func resolveOperationName(
    from result: ResultDescriptor,
    knownOperations: Set<String>,
    fallback: String
) -> String {
    // Priority 1: Explicit specifier (new syntax: <var: operation>)
    if let specifier = result.specifiers.first {
        return specifier
    }

    // Priority 2: Base name if it's a known operation (legacy syntax: <operation>)
    if knownOperations.contains(result.base.lowercased()) {
        return result.base
    }

    // Priority 3: Fallback default
    return fallback
}

// MARK: - Compute Actions

/// Computes a value from inputs
///
/// The Compute action is an OWN action that performs internal computation.
/// It uses the result specifiers to determine the computation name and
/// the object as input.
///
/// ## Example
/// ```
/// <Compute> the <password: hash> for the <user: credentials>.
/// ```
public struct ComputeAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["compute", "calculate", "derive"]
    public static let validPrepositions: Set<Preposition> = [.from, .for, .with]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get input value
        guard let input = context.resolveAny(object.base) else {
            throw ActionError.undefinedVariable(object.base)
        }

        // Computation name from result specifiers or base (for backward compatibility)
        let knownComputations: Set<String> = [
            "hash", "length", "count", "uppercase", "lowercase", "identity",
            "date", "format", "distance",  // Date operations (ARO-0041)
            "intersect", "difference", "union"  // Set operations (ARO-0042)
        ]
        let computationName = resolveOperationName(from: result, knownOperations: knownComputations, fallback: "identity")

        // Check for date offset pattern (e.g., +1h, -3d)
        if DateOffset.isOffsetPattern(computationName) {
            return try computeDateOffset(input: input, offsetPattern: computationName, context: context)
        }

        // Look up computation service
        if let computeService = context.service(ComputationService.self) {
            return try await computeService.compute(named: computationName, input: input)
        }

        // Built-in computations
        switch computationName.lowercased() {
        case "hash":
            // Use SHA256 for cryptographically secure hashing
            let stringToHash: String
            if let str = input as? String {
                stringToHash = str
            } else {
                stringToHash = String(describing: input)
            }

            guard let data = stringToHash.data(using: .utf8) else {
                throw ActionError.runtimeError("Failed to encode string as UTF-8")
            }

            let hash = SHA256.hash(data: data)
            return hash.compactMap { String(format: "%02x", $0) }.joined()

        case "length", "count":
            if let str = input as? String {
                return str.count
            }
            if let arr = input as? [any Sendable] {
                return arr.count
            }
            if let dict = input as? [String: any Sendable] {
                return dict.count
            }
            // For types where count/length doesn't apply (Int, Double, etc.),
            // return input unchanged (identity behavior). This allows using
            // "count" as a variable name in sink syntax: <Compute> the <count> from 42.
            return input

        case "uppercase":
            if let str = input as? String {
                return str.uppercased()
            }
            return String(describing: input).uppercased()

        case "lowercase":
            if let str = input as? String {
                return str.lowercased()
            }
            return String(describing: input).lowercased()

        case "identity":
            return input

        // Date operations (ARO-0041)
        case "date":
            // Parse ISO 8601 string to ARODate
            if let str = input as? String {
                return try ARODate.parse(str)
            }
            if let date = input as? ARODate {
                return date
            }
            throw ActionError.typeMismatch(expected: "String (ISO 8601)", actual: String(describing: type(of: input)))

        case "format":
            // Format a date using a pattern string
            // Pattern comes from the 'with' clause (_expression_)
            guard let date = getARODate(from: input) else {
                throw ActionError.typeMismatch(expected: "ARODate or ISO 8601 String", actual: String(describing: type(of: input)))
            }
            let pattern = context.resolveAny("_expression_") as? String ?? DateFormatPattern.fullDate
            let dateService = context.service(DateService.self) ?? DefaultDateService()
            return dateService.format(date, pattern: pattern)

        case "distance":
            // Calculate distance between two dates
            // The 'to' date comes from the 'to' clause (_to_)
            guard let fromDate = getARODate(from: input) else {
                throw ActionError.typeMismatch(expected: "ARODate", actual: String(describing: type(of: input)))
            }
            guard let toValue = context.resolveAny("_to_"),
                  let toDate = getARODate(from: toValue) else {
                throw ActionError.runtimeError("Distance calculation requires a 'to' clause: <Compute> the <distance: distance> from <date1> to <date2>.")
            }
            let dateService = context.service(DateService.self) ?? DefaultDateService()
            return dateService.distance(from: fromDate, to: toDate)

        // Set operations (ARO-0042)
        case "intersect":
            // Get second operand from 'with' clause (stored in _with_ by FeatureSetExecutor)
            guard let secondOperand = context.resolveAny("_with_") else {
                throw ActionError.runtimeError("Intersect requires a 'with' clause: <Compute> the <result: intersect> from <a> with <b>.")
            }
            return try computeIntersect(input, with: secondOperand)

        case "difference":
            // Get second operand from 'with' clause (stored in _with_ by FeatureSetExecutor)
            guard let secondOperand = context.resolveAny("_with_") else {
                throw ActionError.runtimeError("Difference requires a 'with' clause: <Compute> the <result: difference> from <a> with <b>.")
            }
            return try computeDifference(input, minus: secondOperand)

        case "union":
            // Get second operand from 'with' clause (stored in _with_ by FeatureSetExecutor)
            guard let secondOperand = context.resolveAny("_with_") else {
                throw ActionError.runtimeError("Union requires a 'with' clause: <Compute> the <result: union> from <a> with <b>.")
            }
            return try computeUnion(input, with: secondOperand)

        default:
            // Return input as-is for unknown computations
            return input
        }
    }

    /// Get an ARODate from various input types
    private func getARODate(from input: any Sendable) -> ARODate? {
        if let date = input as? ARODate {
            return date
        }
        if let str = input as? String {
            return try? ARODate.parse(str)
        }
        return nil
    }

    /// Compute a date offset (e.g., +1h, -3d from a date)
    private func computeDateOffset(input: any Sendable, offsetPattern: String, context: ExecutionContext) throws -> ARODate {
        guard let date = getARODate(from: input) else {
            throw ActionError.typeMismatch(expected: "ARODate or ISO 8601 String", actual: String(describing: type(of: input)))
        }

        let offset = try DateOffset.parse(offsetPattern)
        let dateService = context.service(DateService.self) ?? DefaultDateService()
        return dateService.offset(date, by: offset)
    }

    // MARK: - Set Operations (ARO-0042)

    /// Compute intersection of two collections (multiset semantics for arrays)
    /// - Lists: Elements in both, preserving duplicates up to minimum count
    /// - Strings: Characters in both, preserving order from first string
    /// - Objects: Keys with matching values (deep recursive)
    private func computeIntersect(_ a: any Sendable, with b: any Sendable) throws -> any Sendable {
        // Arrays - multiset intersection
        if let arrA = a as? [any Sendable], let arrB = b as? [any Sendable] {
            return multisetIntersect(arrA, arrB)
        }

        // Strings - character intersection preserving order
        if let strA = a as? String, let strB = b as? String {
            var bCounts = characterCounts(strB)
            var result = ""
            for char in strA {
                if let count = bCounts[char], count > 0 {
                    result.append(char)
                    bCounts[char] = count - 1
                }
            }
            return result
        }

        // Dictionaries - deep recursive intersection
        if let dictA = a as? [String: any Sendable],
           let dictB = b as? [String: any Sendable] {
            return intersectDictionaries(dictA, dictB)
        }

        throw ActionError.typeMismatch(
            expected: "Array, String, or Object",
            actual: String(describing: type(of: a))
        )
    }

    /// Compute difference of two collections (A - B, multiset semantics for arrays)
    /// - Lists: Elements in A but not in B, with multiset subtraction
    /// - Strings: Characters in A but not in B, preserving order
    /// - Objects: Keys/values in A that are not matching in B
    private func computeDifference(_ a: any Sendable, minus b: any Sendable) throws -> any Sendable {
        // Arrays - multiset difference
        if let arrA = a as? [any Sendable], let arrB = b as? [any Sendable] {
            return multisetDifference(arrA, arrB)
        }

        // Strings - character difference preserving order
        if let strA = a as? String, let strB = b as? String {
            var bCounts = characterCounts(strB)
            var result = ""
            for char in strA {
                if let count = bCounts[char], count > 0 {
                    bCounts[char] = count - 1
                } else {
                    result.append(char)
                }
            }
            return result
        }

        // Dictionaries - deep recursive difference
        if let dictA = a as? [String: any Sendable],
           let dictB = b as? [String: any Sendable] {
            return differenceDictionaries(dictA, dictB)
        }

        throw ActionError.typeMismatch(
            expected: "Array, String, or Object",
            actual: String(describing: type(of: a))
        )
    }

    /// Compute union of two collections (deduplicated for arrays)
    /// - Lists: All unique elements from both (A wins for duplicates)
    /// - Strings: All unique characters from both, preserving order from A
    /// - Objects: Merge keys (A wins for conflicts)
    private func computeUnion(_ a: any Sendable, with b: any Sendable) throws -> any Sendable {
        // Arrays - deduplicated union
        if let arrA = a as? [any Sendable], let arrB = b as? [any Sendable] {
            var result = arrA
            var seen = Set(arrA.map { hashKey(for: $0) })
            for item in arrB {
                let key = hashKey(for: item)
                if !seen.contains(key) {
                    seen.insert(key)
                    result.append(item)
                }
            }
            return result
        }

        // Strings - character union (preserves A, adds unique chars from B)
        // Consistent with list union: start with A, add chars from B not in A's set
        if let strA = a as? String, let strB = b as? String {
            var seen = Set(strA)  // Characters already in A
            var result = strA     // Start with all of A (including duplicates)

            // Add characters from B that aren't in A's character set
            for char in strB {
                if !seen.contains(char) {
                    seen.insert(char)
                    result.append(char)
                }
            }
            return result
        }

        // Dictionaries - merge with A winning conflicts
        // Start with B's keys, then overwrite with all of A's keys (A wins)
        if let dictA = a as? [String: any Sendable],
           let dictB = b as? [String: any Sendable] {
            var result = dictB
            for (key, value) in dictA {
                result[key] = value
            }
            return result
        }

        throw ActionError.typeMismatch(
            expected: "Array, String, or Object",
            actual: String(describing: type(of: a))
        )
    }

    // MARK: - Set Operation Helpers

    /// Multiset intersection: elements in both, preserving duplicates up to min count
    private func multisetIntersect(_ a: [any Sendable], _ b: [any Sendable]) -> [any Sendable] {
        var bCounts: [String: Int] = [:]
        for item in b {
            let key = hashKey(for: item)
            bCounts[key, default: 0] += 1
        }

        var result: [any Sendable] = []
        for item in a {
            let key = hashKey(for: item)
            if let count = bCounts[key], count > 0 {
                result.append(item)
                bCounts[key] = count - 1
            }
        }
        return result
    }

    /// Multiset difference: elements in A minus occurrences in B
    private func multisetDifference(_ a: [any Sendable], _ b: [any Sendable]) -> [any Sendable] {
        var bCounts: [String: Int] = [:]
        for item in b {
            let key = hashKey(for: item)
            bCounts[key, default: 0] += 1
        }

        var result: [any Sendable] = []
        for item in a {
            let key = hashKey(for: item)
            if let count = bCounts[key], count > 0 {
                bCounts[key] = count - 1
            } else {
                result.append(item)
            }
        }
        return result
    }

    /// Deep recursive dictionary intersection
    private func intersectDictionaries(
        _ a: [String: any Sendable],
        _ b: [String: any Sendable]
    ) -> [String: any Sendable] {
        var result: [String: any Sendable] = [:]
        for (key, valueA) in a {
            guard let valueB = b[key] else { continue }

            // Recursive for nested objects
            if let nestedA = valueA as? [String: any Sendable],
               let nestedB = valueB as? [String: any Sendable] {
                let nested = intersectDictionaries(nestedA, nestedB)
                if !nested.isEmpty {
                    result[key] = nested
                }
            }
            // Arrays within objects
            else if let arrA = valueA as? [any Sendable],
                    let arrB = valueB as? [any Sendable] {
                let intersected = multisetIntersect(arrA, arrB)
                if !intersected.isEmpty {
                    result[key] = intersected
                }
            }
            // Primitive equality
            else if areStrictlyEqual(valueA, valueB) {
                result[key] = valueA
            }
        }
        return result
    }

    /// Deep recursive dictionary difference
    private func differenceDictionaries(
        _ a: [String: any Sendable],
        _ b: [String: any Sendable]
    ) -> [String: any Sendable] {
        var result: [String: any Sendable] = [:]
        for (key, valueA) in a {
            guard let valueB = b[key] else {
                // Key not in B - include it
                result[key] = valueA
                continue
            }

            // Recursive for nested objects
            if let nestedA = valueA as? [String: any Sendable],
               let nestedB = valueB as? [String: any Sendable] {
                let diff = differenceDictionaries(nestedA, nestedB)
                if !diff.isEmpty {
                    result[key] = diff
                }
            }
            // Arrays within objects
            else if let arrA = valueA as? [any Sendable],
                    let arrB = valueB as? [any Sendable] {
                let diffArr = multisetDifference(arrA, arrB)
                if !diffArr.isEmpty {
                    result[key] = diffArr
                }
            }
            // Values differ - include A's value
            else if !areStrictlyEqual(valueA, valueB) {
                result[key] = valueA
            }
        }
        return result
    }

    /// Count occurrences of each character in a string
    private func characterCounts(_ str: String) -> [Character: Int] {
        var counts: [Character: Int] = [:]
        for char in str {
            counts[char, default: 0] += 1
        }
        return counts
    }

    /// Create a hash key for any Sendable value (for multiset counting)
    private func hashKey(for value: any Sendable) -> String {
        if let dict = value as? [String: any Sendable] {
            // Sort keys for consistent hashing
            let sorted = dict.keys.sorted().map { key -> String in
                let v = dict[key]!
                return "\(key):\(hashKey(for: v))"
            }
            return "{\(sorted.joined(separator: ","))}"
        }
        if let arr = value as? [any Sendable] {
            return "[\(arr.map { hashKey(for: $0) }.joined(separator: ","))]"
        }
        return String(describing: value)
    }

    /// Strict equality check for two values
    private func areStrictlyEqual(_ a: any Sendable, _ b: any Sendable) -> Bool {
        // Same type checks
        if let aInt = a as? Int, let bInt = b as? Int {
            return aInt == bInt
        }
        if let aDouble = a as? Double, let bDouble = b as? Double {
            return aDouble == bDouble
        }
        if let aStr = a as? String, let bStr = b as? String {
            return aStr == bStr
        }
        if let aBool = a as? Bool, let bBool = b as? Bool {
            return aBool == bBool
        }
        if let aDict = a as? [String: any Sendable],
           let bDict = b as? [String: any Sendable] {
            guard aDict.count == bDict.count else { return false }
            for (key, valueA) in aDict {
                guard let valueB = bDict[key] else { return false }
                if !areStrictlyEqual(valueA, valueB) { return false }
            }
            return true
        }
        if let aArr = a as? [any Sendable], let bArr = b as? [any Sendable] {
            guard aArr.count == bArr.count else { return false }
            for (itemA, itemB) in zip(aArr, bArr) {
                if !areStrictlyEqual(itemA, itemB) { return false }
            }
            return true
        }
        // Fallback to string comparison
        return String(describing: a) == String(describing: b)
    }
}

/// Validates input against rules
public struct ValidateAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["validate", "verify", "check"]
    public static let validPrepositions: Set<Preposition> = [.for, .against, .with]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get value to validate
        guard let value = context.resolveAny(object.base) else {
            throw ActionError.undefinedVariable(object.base)
        }

        // Validation rule from result specifiers or base (for backward compatibility)
        let knownRules: Set<String> = ["required", "exists", "nonempty", "email", "numeric"]
        let ruleName = resolveOperationName(from: result, knownOperations: knownRules, fallback: "required")

        // Look up validation service
        if let validationService = context.service(ValidationService.self) {
            return try await validationService.validate(value: value, rule: ruleName)
        }

        // Built-in validations
        let isValid: Bool
        switch ruleName.lowercased() {
        case "required", "exists":
            isValid = !isNilOrEmpty(value)

        case "nonempty":
            if let str = value as? String {
                isValid = !str.isEmpty
            } else if let arr = value as? [Any] {
                isValid = !arr.isEmpty
            } else {
                isValid = true
            }

        case "email":
            if let str = value as? String {
                isValid = str.contains("@") && str.contains(".")
            } else {
                isValid = false
            }

        case "numeric":
            if value is Int || value is Double || value is Float {
                isValid = true
            } else if let str = value as? String {
                isValid = Double(str) != nil
            } else {
                isValid = false
            }

        default:
            // Unknown rule - assume valid
            isValid = true
        }

        return ValidationResult(isValid: isValid, rule: ruleName)
    }

    private func isNilOrEmpty(_ value: Any) -> Bool {
        // Note: value is Any, so it can't be nil - check for NSNull instead
        if value is NSNull {
            return true
        }
        if let str = value as? String, str.isEmpty {
            return true
        }
        if let arr = value as? [Any], arr.isEmpty {
            return true
        }
        return false
    }
}

/// Compares two values
public struct CompareAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["compare", "match"]
    public static let validPrepositions: Set<Preposition> = [.against, .with, .to]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get the value to compare (from result base)
        guard let lhs = context.resolveAny(result.base) else {
            throw ActionError.undefinedVariable(result.base)
        }

        // Get the value to compare against (from object)
        guard let rhs = context.resolveAny(object.base) else {
            throw ActionError.undefinedVariable(object.base)
        }

        // Perform comparison
        let comparisonResult = compare(lhs, rhs)

        return ComparisonResult(
            matches: comparisonResult == .equal,
            result: comparisonResult
        )
    }

    private func compare(_ lhs: Any, _ rhs: Any) -> ComparisonOutcome {
        // String comparison
        if let lhsStr = lhs as? String, let rhsStr = rhs as? String {
            if lhsStr == rhsStr { return .equal }
            if lhsStr < rhsStr { return .less }
            return .greater
        }

        // Numeric comparison
        if let lhsNum = asDouble(lhs), let rhsNum = asDouble(rhs) {
            if lhsNum == rhsNum { return .equal }
            if lhsNum < rhsNum { return .less }
            return .greater
        }

        // Bool comparison
        if let lhsBool = lhs as? Bool, let rhsBool = rhs as? Bool {
            return lhsBool == rhsBool ? .equal : .notEqual
        }

        // Fallback to string representation
        let lhsDesc = String(describing: lhs)
        let rhsDesc = String(describing: rhs)
        return lhsDesc == rhsDesc ? .equal : .notEqual
    }

    private func asDouble(_ value: Any) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let f = value as? Float { return Double(f) }
        if let s = value as? String { return Double(s) }
        return nil
    }
}

/// Transforms a value
public struct TransformAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["transform", "convert", "map"]
    public static let validPrepositions: Set<Preposition> = [.from, .into, .to]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get value to transform
        guard let value = context.resolveAny(object.base) else {
            throw ActionError.undefinedVariable(object.base)
        }

        // Transformation type from result specifiers or base (for backward compatibility)
        let knownTransforms: Set<String> = ["string", "int", "integer", "double", "float", "bool", "boolean", "json", "identity"]
        let transformType = resolveOperationName(from: result, knownOperations: knownTransforms, fallback: "identity")

        switch transformType.lowercased() {
        case "string":
            return String(describing: value)

        case "int", "integer":
            if let i = value as? Int { return i }
            if let d = value as? Double { return Int(d) }
            if let s = value as? String, let i = Int(s) { return i }
            throw ActionError.typeMismatch(expected: "Int", actual: String(describing: type(of: value)))

        case "double", "float":
            if let d = value as? Double { return d }
            if let i = value as? Int { return Double(i) }
            if let s = value as? String, let d = Double(s) { return d }
            throw ActionError.typeMismatch(expected: "Double", actual: String(describing: type(of: value)))

        case "bool", "boolean":
            if let b = value as? Bool { return b }
            if let s = value as? String { return s.lowercased() == "true" || s == "1" }
            if let i = value as? Int { return i != 0 }
            return false

        case "json":
            if let dict = value as? [String: Any] {
                let data = try JSONSerialization.data(withJSONObject: dict)
                return String(data: data, encoding: .utf8) ?? "{}"
            }
            return "{}"

        case "identity":
            // value is already `any Sendable`
            return value

        default:
            // value is already `any Sendable`
            return value
        }
    }
}

/// Creates a new entity
public struct CreateAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["create", "build", "construct"]
    public static let validPrepositions: Set<Preposition> = [.with, .from, .for, .to]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Check for special types in result.specifiers (ARO-0041)
        if let typeSpecifier = result.specifiers.first?.lowercased() {
            switch typeSpecifier {
            case "date-range", "daterange":
                return try createDateRange(object: object, context: context)

            case "recurrence":
                return try createRecurrence(object: object, context: context)

            default:
                break  // Fall through to regular entity creation
            }
        }

        // Get the source value - check _expression_ first (binary mode), then _literal_, then object.base
        // In binary mode, variable references in expressions are resolved and bound to _expression_
        // In interpreter mode, variables may be directly resolvable via object.base
        let sourceValue: (any Sendable)?
        if let expr = context.resolveAny("_expression_") {
            sourceValue = expr
        } else if let literal = context.resolveAny("_literal_") {
            sourceValue = literal
        } else {
            sourceValue = context.resolveAny(object.base)
        }

        if let value = sourceValue {
            // Check if we're creating a typed entity (e.g., <order: Order>)
            // In this case, we should generate an ID if not present
            if !result.specifiers.isEmpty {
                // Creating a typed entity - ensure it has an ID
                if var dict = value as? [String: any Sendable] {
                    if dict["id"] == nil {
                        dict["id"] = generateEntityId()
                    }
                    return dict
                }
            }
            // Return the actual value directly - this gets bound to result.base
            // by the FeatureSetExecutor
            return value
        }

        // If no source found, return empty string as default
        return ""
    }

    /// Generate a unique entity ID
    private func generateEntityId() -> String {
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        let random = UInt32.random(in: 0..<UInt32.max)
        return String(format: "%llx%08x", timestamp, random)
    }

    /// Create a date range from start to end (ARO-0041)
    /// Syntax: <Create> the <range: date-range> from <start> to <end>.
    private func createDateRange(object: ObjectDescriptor, context: ExecutionContext) throws -> ARODateRange {
        // Get start date from object.base (the 'from' clause)
        guard let startValue = context.resolveAny(object.base),
              let startDate = getARODate(from: startValue) else {
            throw ActionError.typeMismatch(expected: "ARODate (start)", actual: object.base)
        }

        // Get end date from _to_ (the 'to' clause)
        // Debug: Log _to_ resolution for ARO-0041 diagnostics (enable with ARO_DEBUG=1)
        let endValue = context.resolveAny("_to_")
        if endValue == nil && ProcessInfo.processInfo.environment["ARO_DEBUG"] != nil {
            FileHandle.standardError.write("[CreateAction] DEBUG: _to_ is nil - date range 'to' clause not bound\n".data(using: .utf8)!)
        }
        guard let endValue, let endDate = getARODate(from: endValue) else {
            throw ActionError.runtimeError("Date range requires a 'to' clause: <Create> the <range: date-range> from <start> to <end>.")
        }

        let dateService = context.service(DateService.self) ?? DefaultDateService()
        return dateService.createRange(from: startDate, to: endDate)
    }

    /// Create a recurrence pattern (ARO-0041)
    /// Syntax: <Create> the <schedule: recurrence> with "every monday".
    private func createRecurrence(object: ObjectDescriptor, context: ExecutionContext) throws -> ARORecurrence {
        // Get pattern from _expression_ (the 'with' clause) or object.base
        let pattern: String
        if let expr = context.resolveAny("_expression_") as? String {
            pattern = expr
        } else if let literal = context.resolveAny("_literal_") as? String {
            pattern = literal
        } else if let resolved = context.resolveAny(object.base) as? String {
            pattern = resolved
        } else {
            pattern = object.base
        }

        // Get optional start date from _from_ clause
        let startDate: ARODate?
        if let fromValue = context.resolveAny("_from_") {
            startDate = getARODate(from: fromValue)
        } else {
            startDate = nil
        }

        let dateService = context.service(DateService.self) ?? DefaultDateService()
        return try dateService.createRecurrence(pattern: pattern, from: startDate)
    }

    /// Get an ARODate from various input types
    private func getARODate(from input: any Sendable) -> ARODate? {
        if let date = input as? ARODate {
            return date
        }
        if let str = input as? String {
            return try? ARODate.parse(str)
        }
        return nil
    }
}

/// Updates an existing entity
public struct UpdateAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["update", "modify", "change", "set", "configure"]
    public static let validPrepositions: Set<Preposition> = [.with, .to, .for, .from]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // For "configure" verb, allow creating new configuration if it doesn't exist
        // This enables: <Configure> the <validation: timeout> with <value>.
        let entity: any Sendable
        if let existingEntity = context.resolveAny(result.base) {
            entity = existingEntity
        } else {
            // Create empty dictionary for new configuration
            entity = [String: any Sendable]()
        }

        // Get update value - check _literal_ first (for "draft"), then resolve from object
        let updateValue: any Sendable
        if let literal = context.resolveAny("_literal_") {
            updateValue = literal
        } else if let resolved = context.resolveAny(object.base) {
            // If object has specifiers, extract the nested property
            if !object.specifiers.isEmpty {
                if let dict = resolved as? [String: any Sendable] {
                    // Extract nested property from the source object
                    var current: any Sendable = dict
                    for specifier in object.specifiers {
                        if let currentDict = current as? [String: any Sendable],
                           let nested = currentDict[specifier] {
                            current = nested
                        } else {
                            throw ActionError.propertyNotFound(property: specifier, on: object.base)
                        }
                    }
                    updateValue = current
                } else {
                    throw ActionError.propertyNotFound(property: object.specifiers.first ?? "", on: object.base)
                }
            } else {
                updateValue = resolved
            }
        } else {
            // Treat as literal value
            updateValue = object.base
        }

        // Check if we're updating a specific field (e.g., <order: status>)
        if let fieldName = result.specifiers.first {
            // Update specific field in the entity
            var updatedEntity: [String: any Sendable]

            if let dict = entity as? [String: any Sendable] {
                updatedEntity = dict
            } else if let dict = entity as? [String: Any] {
                // Convert to Sendable dictionary
                updatedEntity = [:]
                for (key, value) in dict {
                    updatedEntity[key] = convertToSendable(value)
                }
            } else {
                // Create dictionary from entity using reflection
                updatedEntity = [:]
                let mirror = Mirror(reflecting: entity)
                for child in mirror.children {
                    if let label = child.label {
                        updatedEntity[label] = convertToSendable(child.value)
                    }
                }
            }

            // Update the field
            updatedEntity[fieldName] = updateValue

            // Bind the updated entity with allowRebind: true
            // Update action is allowed to rebind for state transitions
            context.bind(result.base, value: updatedEntity, allowRebind: true)
            return updatedEntity
        }

        // No field specifier - merge updates into entity or replace
        if let entityDict = entity as? [String: any Sendable],
           let updateDict = updateValue as? [String: any Sendable] {
            var merged = entityDict
            for (key, value) in updateDict {
                merged[key] = value
            }
            context.bind(result.base, value: merged, allowRebind: true)
            return merged
        }

        // Fallback: return the update value
        return updateValue
    }

    private func convertToSendable(_ value: Any) -> any Sendable {
        if let s = value as? String { return s }
        if let i = value as? Int { return i }
        if let d = value as? Double { return d }
        if let b = value as? Bool { return b }
        if let arr = value as? [Any] { return arr.map { convertToSendable($0) } as [any Sendable] }
        if let dict = value as? [String: Any] {
            var result: [String: any Sendable] = [:]
            for (k, v) in dict { result[k] = convertToSendable(v) }
            return result
        }
        return String(describing: value)
    }
}

// MARK: - Supporting Types

/// Computation service protocol
public protocol ComputationService: Sendable {
    func compute(named: String, input: Any) async throws -> any Sendable
}

/// Validation service protocol
public protocol ValidationService: Sendable {
    func validate(value: Any, rule: String) async throws -> ValidationResult
}

/// Result of a validation operation
public struct ValidationResult: Sendable, Equatable {
    public let isValid: Bool
    public let rule: String
    public let message: String?

    public init(isValid: Bool, rule: String, message: String? = nil) {
        self.isValid = isValid
        self.rule = rule
        self.message = message
    }
}

/// Result of a comparison operation
public struct ComparisonResult: Sendable, Equatable {
    public let matches: Bool
    public let result: ComparisonOutcome

    public init(matches: Bool, result: ComparisonOutcome) {
        self.matches = matches
        self.result = result
    }
}

/// Outcome of a comparison
public enum ComparisonOutcome: String, Sendable {
    case equal
    case notEqual
    case less
    case greater
}

/// Entity created by CreateAction
public struct CreatedEntity: Sendable {
    public let type: String
    public let data: [String: any Sendable]

    public init(type: String, data: [String: any Sendable]) {
        self.type = type
        self.data = data
    }
}

extension CreatedEntity: Equatable {
    public static func == (lhs: CreatedEntity, rhs: CreatedEntity) -> Bool {
        lhs.type == rhs.type
    }
}

// MARK: - Additional OWN Actions (ARO-0001)

// Note: FilterAction with ARO-0018 where clause support is now in QueryActions.swift

/// Sorts a collection
public struct SortAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["sort", "order", "arrange"]
    public static let validPrepositions: Set<Preposition> = [.for, .with]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get collection to sort
        guard let collection = context.resolveAny(object.base) else {
            throw ActionError.undefinedVariable(object.base)
        }

        // Sort order from result specifiers or base (for backward compatibility)
        let knownOrders: Set<String> = ["ascending", "descending"]
        let order = resolveOperationName(from: result, knownOperations: knownOrders, fallback: "ascending")
        let ascending = order.lowercased() != "descending"

        // Handle string array sorting
        if let array = collection as? [String] {
            return ascending ? array.sorted() : array.sorted().reversed()
        }

        // Handle int array sorting
        if let array = collection as? [Int] {
            return ascending ? array.sorted() : array.sorted().reversed()
        }

        // Handle double array sorting
        if let array = collection as? [Double] {
            return ascending ? array.sorted() : array.sorted().reversed()
        }

        // Return original if not sortable
        return collection
    }
}

/// Merges two or more values
public struct MergeAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["merge", "combine", "join", "concat"]
    public static let validPrepositions: Set<Preposition> = [.with, .into, .from]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get the base value to merge into
        guard let target = context.resolveAny(result.base) else {
            throw ActionError.undefinedVariable(result.base)
        }

        // Get the value to merge from
        guard let source = context.resolveAny(object.base) else {
            throw ActionError.undefinedVariable(object.base)
        }

        // Merge dictionaries
        if var targetDict = target as? [String: any Sendable],
           let sourceDict = source as? [String: any Sendable] {
            for (key, value) in sourceDict {
                targetDict[key] = value
            }
            // Bind merged result back to the target variable (allow rebind)
            context.bind(result.base, value: targetDict, allowRebind: true)
            return targetDict
        }

        // Merge arrays
        if var targetArray = target as? [any Sendable],
           let sourceArray = source as? [any Sendable] {
            targetArray.append(contentsOf: sourceArray)
            // Bind merged result back to the target variable (allow rebind)
            context.bind(result.base, value: targetArray, allowRebind: true)
            return targetArray
        }

        // Merge strings
        if let targetStr = target as? String,
           let sourceStr = source as? String {
            let merged = targetStr + sourceStr
            // Bind merged result back to the target variable (allow rebind)
            context.bind(result.base, value: merged, allowRebind: true)
            return merged
        }

        // Return target if types don't match
        return target
    }
}

/// Deletes an entity or value
///
/// Supports deleting from:
/// - Dictionaries: removes the key
/// - Arrays: removes by index
/// - Repositories: removes items matching the where clause
///
/// ## Examples
/// ```
/// <Delete> the <key> from the <dictionary>.
/// <Delete> the <0> from the <array>.
/// <Delete> the <user> from the <user-repository> where id = <userId>.
/// ```
public struct DeleteAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["delete", "remove", "destroy", "clear"]
    public static let validPrepositions: Set<Preposition> = [.from, .for]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        let targetName = object.base

        // Check if this is a repository (ends with -repository)
        if InMemoryRepositoryStorage.isRepositoryName(targetName) {
            return try await deleteFromRepository(
                result: result,
                repositoryName: targetName,
                context: context
            )
        }

        // Get the source containing the item to delete
        guard let source = context.resolveAny(targetName) else {
            throw ActionError.undefinedVariable(targetName)
        }

        // Key to delete from result specifiers
        let keyToDelete = result.specifiers.first ?? result.base

        // Delete from dictionary
        if var dict = source as? [String: any Sendable] {
            dict.removeValue(forKey: keyToDelete)
            return dict
        }

        // Delete from array by index (0 = most recent element)
        if var array = source as? [any Sendable], let index = Int(keyToDelete), index >= 0, index < array.count {
            array.remove(at: array.count - 1 - index)
            return array
        }

        // Emit delete event
        context.emit(DataDeletedEvent(target: result.base, source: targetName))

        return DeleteResult(target: result.base, success: true)
    }

    private func deleteFromRepository(
        result: ResultDescriptor,
        repositoryName: String,
        context: ExecutionContext
    ) async throws -> any Sendable {
        // Check for where clause (bound by FeatureSetExecutor)
        let whereField: String? = context.resolve("_where_field_")
        let whereValue = context.resolveAny("_where_value_")

        guard let field = whereField, let matchValue = whereValue else {
            throw ActionError.runtimeError(
                "Delete from repository requires a where clause: <Delete> the <item> from the <\(repositoryName)> where field = <value>."
            )
        }

        // Delete from repository storage service
        let deleteResult: RepositoryDeleteResult
        if let storage = context.service(RepositoryStorageService.self) {
            deleteResult = await storage.delete(
                from: repositoryName,
                businessActivity: context.businessActivity,
                where: field,
                equals: matchValue
            )
        } else {
            // Fallback to shared instance
            deleteResult = await InMemoryRepositoryStorage.shared.delete(
                from: repositoryName,
                businessActivity: context.businessActivity,
                where: field,
                equals: matchValue
            )
        }

        // Emit repository change events for each deleted item
        for deletedItem in deleteResult.deletedItems {
            let entityId: String?
            if let dict = deletedItem as? [String: any Sendable] {
                entityId = dict["id"] as? String
            } else {
                entityId = nil
            }

            context.emit(RepositoryChangedEvent(
                repositoryName: repositoryName,
                changeType: .deleted,
                entityId: entityId,
                newValue: nil,
                oldValue: deletedItem
            ))
        }

        // Emit legacy delete event
        context.emit(DataDeletedEvent(target: result.base, source: repositoryName))

        // Bind the deleted items to the result variable
        if deleteResult.deletedItems.count == 1 {
            context.bind(result.base, value: deleteResult.deletedItems[0])
        } else {
            context.bind(result.base, value: deleteResult.deletedItems)
        }

        return DeleteResult(target: result.base, success: deleteResult.count > 0)
    }
}

/// Result of a delete operation
public struct DeleteResult: Sendable, Equatable {
    public let target: String
    public let success: Bool
}

/// Event emitted when data is deleted
public struct DataDeletedEvent: RuntimeEvent {
    public static var eventType: String { "data.deleted" }
    public let timestamp: Date
    public let target: String
    public let source: String

    public init(target: String, source: String) {
        self.timestamp = Date()
        self.target = target
        self.source = source
    }
}
