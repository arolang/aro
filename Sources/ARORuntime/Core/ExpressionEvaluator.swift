// ============================================================
// ExpressionEvaluator.swift
// ARO Runtime - Expression Evaluation (ARO-0002)
// ============================================================

import Foundation
import AROParser

/// Evaluates expressions at runtime
public struct ExpressionEvaluator: Sendable {

    public init() {}

    /// Evaluates an expression in the given context
    /// - Parameters:
    ///   - expression: The expression to evaluate
    ///   - context: The execution context for variable resolution
    /// - Returns: The evaluated value
    public func evaluate(_ expression: any AROParser.Expression, context: ExecutionContext) async throws -> any Sendable {
        switch expression {
        // Literal expressions
        case let literal as LiteralExpression:
            return evaluateLiteral(literal.value)

        // Variable reference
        case let varRef as VariableRefExpression:
            // Special handling for repository count access: <repository-name: count>
            if InMemoryRepositoryStorage.isRepositoryName(varRef.noun.base) &&
               varRef.noun.specifiers == ["count"] {
                return await InMemoryRepositoryStorage.shared.count(
                    repository: varRef.noun.base,
                    businessActivity: context.businessActivity
                )
            }

            guard var value = context.resolveAny(varRef.noun.base) else {
                throw ExpressionError.undefinedVariable(varRef.noun.base)
            }
            // Handle specifiers as property access (e.g., <user: name> -> user.name)
            for specifier in varRef.noun.specifiers {
                value = try accessProperty(specifier, on: value)
            }
            return value

        // Array literal
        case let array as ArrayLiteralExpression:
            var elements: [any Sendable] = []
            for element in array.elements {
                let value = try await evaluate(element, context: context)
                elements.append(value)
            }
            return elements

        // Map literal
        case let map as MapLiteralExpression:
            var dict: [String: any Sendable] = [:]
            for entry in map.entries {
                let value = try await evaluate(entry.value, context: context)
                dict[entry.key] = value
            }
            return dict

        // Binary expression
        case let binary as BinaryExpression:
            return try await evaluateBinary(binary, context: context)

        // Unary expression
        case let unary as UnaryExpression:
            return try await evaluateUnary(unary, context: context)

        // Member access
        case let member as MemberAccessExpression:
            return try await evaluateMemberAccess(member, context: context)

        // Subscript
        case let subscript_ as SubscriptExpression:
            return try await evaluateSubscript(subscript_, context: context)

        // Grouped expression
        case let grouped as GroupedExpression:
            return try await evaluate(grouped.expression, context: context)

        // Existence check
        case let existence as ExistenceExpression:
            if let varRef = existence.expression as? VariableRefExpression {
                return context.exists(varRef.noun.base)
            }
            // For other expressions, try to evaluate and check for nil
            do {
                _ = try await evaluate(existence.expression, context: context)
                return true
            } catch {
                return false
            }

        // Type check
        case let typeCheck as TypeCheckExpression:
            let value = try await evaluate(typeCheck.expression, context: context)
            return checkType(value, typeName: typeCheck.typeName)

        // Interpolated string
        case let interp as InterpolatedStringExpression:
            return try await evaluateInterpolatedString(interp, context: context)

        default:
            throw ExpressionError.unsupportedExpression(String(describing: type(of: expression)))
        }
    }

    // MARK: - Literal Evaluation

    private func evaluateLiteral(_ literal: LiteralValue) -> any Sendable {
        switch literal {
        case .string(let s): return s
        case .integer(let i): return i
        case .float(let f): return f
        case .boolean(let b): return b
        case .null: return NullValue.null
        case .array(let elements):
            return elements.map { evaluateLiteral($0) }
        case .object(let fields):
            var dict: [String: any Sendable] = [:]
            for (key, value) in fields {
                dict[key] = evaluateLiteral(value)
            }
            return dict
        case .regex(let pattern, let flags):
            // Return regex as a dictionary for use with matches operator
            return ["pattern": pattern, "flags": flags]
        }
    }

    // MARK: - Binary Expression Evaluation

    private func evaluateBinary(_ expr: BinaryExpression, context: ExecutionContext) async throws -> any Sendable {
        let left = try await evaluate(expr.left, context: context)
        let right = try await evaluate(expr.right, context: context)

        switch expr.op {
        // Arithmetic operators
        case .add:
            return try numericOperation(left, right) { $0 + $1 }
        case .subtract:
            return try numericOperation(left, right) { $0 - $1 }
        case .multiply:
            return try numericOperation(left, right) { $0 * $1 }
        case .divide:
            return try numericOperation(left, right) { $0 / $1 }
        case .modulo:
            return try intOperation(left, right) { $0 % $1 }

        // String concatenation
        case .concat:
            return "\(left)\(right)"

        // Comparison operators
        case .equal:
            return areEqual(left, right)
        case .notEqual:
            return !areEqual(left, right)
        case .lessThan:
            return try compareValues(left, right) { $0 < $1 }
        case .greaterThan:
            return try compareValues(left, right) { $0 > $1 }
        case .lessEqual:
            return try compareValues(left, right) { $0 <= $1 }
        case .greaterEqual:
            return try compareValues(left, right) { $0 >= $1 }

        // Logical operators
        case .and:
            return asBool(left) && asBool(right)
        case .or:
            return asBool(left) || asBool(right)

        // Collection operators
        case .contains:
            return containsValue(left, right)
        case .matches:
            return matchesPattern(left, right)

        // Type operators (handled in type check expression)
        case .is, .isNot:
            return false // Should not reach here
        }
    }

    // MARK: - Unary Expression Evaluation

    private func evaluateUnary(_ expr: UnaryExpression, context: ExecutionContext) async throws -> any Sendable {
        let operand = try await evaluate(expr.operand, context: context)

        switch expr.op {
        case .negate:
            if let i = operand as? Int { return -i }
            if let d = operand as? Double { return -d }
            throw ExpressionError.typeMismatch("Cannot negate \(type(of: operand))")
        case .not:
            return !asBool(operand)
        }
    }

    // MARK: - Member Access Evaluation

    private func evaluateMemberAccess(_ expr: MemberAccessExpression, context: ExecutionContext) async throws -> any Sendable {
        let base = try await evaluate(expr.base, context: context)

        // Handle dictionary access
        if let dict = base as? [String: any Sendable] {
            if let value = dict[expr.member] {
                return value
            }
            throw ExpressionError.undefinedMember(expr.member)
        }

        // Handle key-value pairs with AnySendable
        if let dict = base as? [String: AnySendable] {
            if let value = dict[expr.member] {
                return value
            }
            throw ExpressionError.undefinedMember(expr.member)
        }

        throw ExpressionError.typeMismatch("Cannot access member '\(expr.member)' on \(type(of: base))")
    }

    // MARK: - Subscript Evaluation

    private func evaluateSubscript(_ expr: SubscriptExpression, context: ExecutionContext) async throws -> any Sendable {
        let base = try await evaluate(expr.base, context: context)
        let index = try await evaluate(expr.index, context: context)

        // Array subscript (0 = most recent element)
        if let array = base as? [any Sendable], let i = index as? Int {
            guard i >= 0 && i < array.count else {
                throw ExpressionError.indexOutOfBounds(i, count: array.count)
            }
            return array[array.count - 1 - i]
        }

        // Dictionary subscript with string key
        if let dict = base as? [String: any Sendable], let key = index as? String {
            if let value = dict[key] {
                return value
            }
            throw ExpressionError.undefinedMember(key)
        }

        throw ExpressionError.typeMismatch("Cannot subscript \(type(of: base)) with \(type(of: index))")
    }

    // MARK: - Interpolated String Evaluation

    private func evaluateInterpolatedString(_ expr: InterpolatedStringExpression, context: ExecutionContext) async throws -> any Sendable {
        var result = ""
        for part in expr.parts {
            switch part {
            case .literal(let s):
                result += s
            case .interpolation(let innerExpr):
                let value = try await evaluate(innerExpr, context: context)
                result += "\(value)"
            }
        }
        return result
    }

    // MARK: - Helper Methods

    /// Access a property on a value (dictionary, AnySendable, etc.)
    private func accessProperty(_ property: String, on value: any Sendable) throws -> any Sendable {
        // Handle Contract property access (magic system object)
        if let contract = value as? Contract {
            if let propValue = contract.property(property) {
                return propValue
            }
            throw ExpressionError.undefinedMember(property)
        }

        // Handle HTTPServerConfig property access (contract.http-server)
        if let serverConfig = value as? HTTPServerConfig {
            if let propValue = serverConfig.property(property) {
                return propValue
            }
            throw ExpressionError.undefinedMember(property)
        }

        // Handle ARODate property access (ARO-0041)
        if let date = value as? ARODate {
            if let propValue = date.property(property) {
                return propValue
            }
            throw ExpressionError.undefinedMember(property)
        }

        // Handle ARODateRange property access (ARO-0041)
        if let range = value as? ARODateRange {
            if let propValue = range.property(property) {
                return propValue
            }
            throw ExpressionError.undefinedMember(property)
        }

        // Handle ARORecurrence property access (ARO-0041)
        if let recurrence = value as? ARORecurrence {
            if let propValue = recurrence.property(property) {
                return propValue
            }
            throw ExpressionError.undefinedMember(property)
        }

        // Handle DateDistance property access (ARO-0041)
        if let distance = value as? DateDistance {
            if let propValue = distance.property(property) {
                return propValue
            }
            throw ExpressionError.undefinedMember(property)
        }

        // Handle [String: any Sendable] dictionary
        if let dict = value as? [String: any Sendable] {
            guard let propValue = dict[property] else {
                throw ExpressionError.undefinedMember(property)
            }
            return propValue
        }

        // Handle [String: AnySendable] dictionary
        if let dict = value as? [String: AnySendable] {
            guard let propValue = dict[property] else {
                throw ExpressionError.undefinedMember(property)
            }
            return propValue
        }

        throw ExpressionError.typeMismatch("Cannot access property '\(property)' on \(type(of: value))")
    }

    private func numericOperation(_ left: any Sendable, _ right: any Sendable, _ op: (Double, Double) -> Double) throws -> any Sendable {
        let l = try asDouble(left)
        let r = try asDouble(right)
        let result = op(l, r)

        // Return Int if both inputs were Int and result is whole
        if left is Int && right is Int && result.truncatingRemainder(dividingBy: 1) == 0 {
            return Int(result)
        }
        return result
    }

    private func intOperation(_ left: any Sendable, _ right: any Sendable, _ op: (Int, Int) -> Int) throws -> any Sendable {
        guard let l = left as? Int, let r = right as? Int else {
            throw ExpressionError.typeMismatch("Expected integers for modulo operation")
        }
        return op(l, r)
    }

    private func compareValues(_ left: any Sendable, _ right: any Sendable, _ compare: (Double, Double) -> Bool) throws -> Bool {
        // Date comparison (ARO-0041)
        if let leftDate = getARODate(from: left), let rightDate = getARODate(from: right) {
            let leftTime = leftDate.date.timeIntervalSince1970
            let rightTime = rightDate.date.timeIntervalSince1970
            return compare(leftTime, rightTime)
        }

        let l = try asDouble(left)
        let r = try asDouble(right)
        return compare(l, r)
    }

    /// Get an ARODate from various input types (ARO-0041)
    private func getARODate(from value: any Sendable) -> ARODate? {
        if let date = value as? ARODate {
            return date
        }
        if let str = value as? String {
            return try? ARODate.parse(str)
        }
        return nil
    }

    private func asDouble(_ value: any Sendable) throws -> Double {
        if let i = value as? Int { return Double(i) }
        if let d = value as? Double { return d }
        if let s = value as? String, let d = Double(s) { return d }
        throw ExpressionError.typeMismatch("Cannot convert \(type(of: value)) to number")
    }

    private func asBool(_ value: any Sendable) -> Bool {
        if let b = value as? Bool { return b }
        if let i = value as? Int { return i != 0 }
        if let s = value as? String { return !s.isEmpty }
        if let array = value as? [any Sendable] { return !array.isEmpty }
        return true // Non-nil values are truthy
    }

    private func areEqual(_ left: any Sendable, _ right: any Sendable) -> Bool {
        // Handle nil comparison
        if isNil(left) && isNil(right) { return true }
        if isNil(left) || isNil(right) { return false }

        // Date comparison (ARO-0041)
        if let leftDate = getARODate(from: left), let rightDate = getARODate(from: right) {
            return leftDate == rightDate
        }

        // String comparison
        if let l = left as? String, let r = right as? String { return l == r }

        // Numeric comparison
        if let l = left as? Int, let r = right as? Int { return l == r }
        if let l = left as? Double, let r = right as? Double { return l == r }
        if let l = left as? Int, let r = right as? Double { return Double(l) == r }
        if let l = left as? Double, let r = right as? Int { return l == Double(r) }

        // Boolean comparison
        if let l = left as? Bool, let r = right as? Bool { return l == r }

        // String representation comparison as fallback
        return "\(left)" == "\(right)"
    }

    private func isNil(_ value: any Sendable) -> Bool {
        if value is NullValue { return true }
        if case Optional<Any>.none = value { return true }
        return false
    }

    private func containsValue(_ container: any Sendable, _ element: any Sendable) -> Bool {
        // Date range membership check (ARO-0041)
        // For "when <date> in <range>" the container is the range and element is the date
        if let range = container as? ARODateRange, let date = getARODate(from: element) {
            return range.contains(date)
        }
        // Reverse check: "when <date> in <range>" might have swapped order
        if let range = element as? ARODateRange, let date = getARODate(from: container) {
            return range.contains(date)
        }

        if let array = container as? [any Sendable] {
            return array.contains { areEqual($0, element) }
        }
        if let str = container as? String, let substr = element as? String {
            return str.contains(substr)
        }
        if let dict = container as? [String: any Sendable], let key = element as? String {
            return dict[key] != nil
        }
        return false
    }

    private func matchesPattern(_ value: any Sendable, _ pattern: any Sendable) -> Bool {
        guard let str = value as? String else {
            return false
        }

        var patternStr: String
        var flags: String = ""

        // Check if pattern is a regex literal (dictionary with pattern and flags)
        if let regexDict = pattern as? [String: any Sendable],
           let p = regexDict["pattern"] as? String {
            patternStr = p
            flags = (regexDict["flags"] as? String) ?? ""
        } else if let p = pattern as? String {
            patternStr = p
        } else {
            return false
        }

        var options: NSRegularExpression.Options = []
        if flags.contains("i") { options.insert(.caseInsensitive) }
        if flags.contains("s") { options.insert(.dotMatchesLineSeparators) }
        if flags.contains("m") { options.insert(.anchorsMatchLines) }

        do {
            let regex = try NSRegularExpression(pattern: patternStr, options: options)
            let range = NSRange(str.startIndex..., in: str)
            return regex.firstMatch(in: str, range: range) != nil
        } catch {
            return false
        }
    }

    private func checkType(_ value: any Sendable, typeName: String) -> Bool {
        switch typeName.lowercased() {
        case "string": return value is String
        case "number", "integer", "int": return value is Int || value is Double
        case "float", "double": return value is Double
        case "boolean", "bool": return value is Bool
        case "list", "array": return value is [any Sendable]
        case "map", "dictionary", "object": return value is [String: any Sendable]
        case "null", "nil": return value is NullValue || isNil(value)
        default: return false
        }
    }
}

// MARK: - Null Value

/// Represents a null value in ARO expressions
public struct NullValue: Sendable, Equatable, CustomStringConvertible {
    public static let null = NullValue()
    private init() {}

    public var description: String { "null" }
}

// MARK: - Expression Errors

/// Errors that can occur during expression evaluation
public enum ExpressionError: Error, CustomStringConvertible {
    case undefinedVariable(String)
    case undefinedMember(String)
    case typeMismatch(String)
    case indexOutOfBounds(Int, count: Int)
    case unsupportedExpression(String)

    public var description: String {
        switch self {
        case .undefinedVariable(let name):
            return "Undefined variable: \(name)"
        case .undefinedMember(let name):
            return "Undefined member: \(name)"
        case .typeMismatch(let msg):
            return "Type mismatch: \(msg)"
        case .indexOutOfBounds(let index, let count):
            return "Index \(index) out of bounds (count: \(count))"
        case .unsupportedExpression(let type):
            return "Unsupported expression type: \(type)"
        }
    }
}
