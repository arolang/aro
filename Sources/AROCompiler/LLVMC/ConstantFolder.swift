// ============================================================
// ConstantFolder.swift
// ARO Compiler - Compile-time Constant Expression Evaluation
// ============================================================

#if !os(Windows)
import Foundation
import AROParser

/// Constant folder for compile-time expression evaluation
/// Implements constant folding optimization (GitLab #102)
public struct ConstantFolder {

    // MARK: - Public API

    /// Check if an expression is entirely constant
    public static func isConstant(_ expr: any AROParser.Expression) -> Bool {
        switch expr {
        case is AROParser.LiteralExpression:
            return true

        case let binary as AROParser.BinaryExpression:
            return isConstant(binary.left) && isConstant(binary.right)

        case let unary as AROParser.UnaryExpression:
            return isConstant(unary.operand)

        case let grouped as AROParser.GroupedExpression:
            return isConstant(grouped.expression)

        case let array as AROParser.ArrayLiteralExpression:
            return array.elements.allSatisfy { isConstant($0) }

        case let map as AROParser.MapLiteralExpression:
            return map.entries.allSatisfy { isConstant($0.value) }

        default:
            return false
        }
    }

    /// Evaluate a constant expression at compile time
    /// Returns nil if the expression is not constant or cannot be evaluated
    public static func evaluate(_ expr: any AROParser.Expression) -> AROParser.LiteralValue? {
        switch expr {
        case let literal as AROParser.LiteralExpression:
            return literal.value

        case let binary as AROParser.BinaryExpression:
            return evaluateBinary(binary)

        case let unary as AROParser.UnaryExpression:
            return evaluateUnary(unary)

        case let grouped as AROParser.GroupedExpression:
            return evaluate(grouped.expression)

        case let array as AROParser.ArrayLiteralExpression:
            return evaluateArray(array)

        case let map as AROParser.MapLiteralExpression:
            return evaluateMap(map)

        default:
            return nil
        }
    }

    // MARK: - Binary Operations

    private static func evaluateBinary(_ binary: BinaryExpression) -> LiteralValue? {
        guard let left = evaluate(binary.left),
              let right = evaluate(binary.right) else {
            return nil
        }

        switch binary.op {
        // Arithmetic
        case .add:
            return add(left, right)
        case .subtract:
            return subtract(left, right)
        case .multiply:
            return multiply(left, right)
        case .divide:
            return divide(left, right)
        case .modulo:
            return modulo(left, right)

        // Comparison
        case .equal:
            return .boolean(isEqual(left, right))
        case .notEqual:
            return .boolean(!isEqual(left, right))
        case .lessThan:
            return lessThan(left, right)
        case .lessEqual:
            return lessEqual(left, right)
        case .greaterThan:
            return greaterThan(left, right)
        case .greaterEqual:
            return greaterEqual(left, right)

        // Logical
        case .and:
            return logicalAnd(left, right)
        case .or:
            return logicalOr(left, right)

        // Not supported in constant folding
        case .concat, .is, .isNot, .contains, .matches:
            return nil
        }
    }

    // MARK: - Unary Operations

    private static func evaluateUnary(_ unary: UnaryExpression) -> LiteralValue? {
        guard let operand = evaluate(unary.operand) else {
            return nil
        }

        switch unary.op {
        case .not:
            if case .boolean(let value) = operand {
                return .boolean(!value)
            }
            return nil

        case .negate:
            if case .integer(let value) = operand {
                return .integer(-value)
            } else if case .float(let value) = operand {
                return .float(-value)
            }
            return nil
        }
    }

    // MARK: - Collection Operations

    private static func evaluateArray(_ array: AROParser.ArrayLiteralExpression) -> AROParser.LiteralValue? {
        var values: [AROParser.LiteralValue] = []
        for elem in array.elements {
            guard let value = evaluate(elem) else {
                return nil
            }
            values.append(value)
        }
        return .array(values)
    }

    private static func evaluateMap(_ map: AROParser.MapLiteralExpression) -> AROParser.LiteralValue? {
        var entries: [(String, AROParser.LiteralValue)] = []
        for entry in map.entries {
            guard let value = evaluate(entry.value) else {
                return nil
            }
            entries.append((entry.key, value))
        }
        return .object(entries)
    }

    // MARK: - Arithmetic Helpers

    private static func add(_ left: AROParser.LiteralValue, _ right: AROParser.LiteralValue) -> AROParser.LiteralValue? {
        switch (left, right) {
        case (.integer(let a), .integer(let b)):
            return .integer(a + b)
        case (.float(let a), .float(let b)):
            return .float(a + b)
        case (.integer(let a), .float(let b)):
            return .float(Double(a) + b)
        case (.float(let a), .integer(let b)):
            return .float(a + Double(b))
        case (.string(let a), .string(let b)):
            return .string(a + b)
        default:
            return nil
        }
    }

    private static func subtract(_ left: AROParser.LiteralValue, _ right: AROParser.LiteralValue) -> AROParser.LiteralValue? {
        switch (left, right) {
        case (.integer(let a), .integer(let b)):
            return .integer(a - b)
        case (.float(let a), .float(let b)):
            return .float(a - b)
        case (.integer(let a), .float(let b)):
            return .float(Double(a) - b)
        case (.float(let a), .integer(let b)):
            return .float(a - Double(b))
        default:
            return nil
        }
    }

    private static func multiply(_ left: AROParser.LiteralValue, _ right: AROParser.LiteralValue) -> AROParser.LiteralValue? {
        switch (left, right) {
        case (.integer(let a), .integer(let b)):
            return .integer(a * b)
        case (.float(let a), .float(let b)):
            return .float(a * b)
        case (.integer(let a), .float(let b)):
            return .float(Double(a) * b)
        case (.float(let a), .integer(let b)):
            return .float(a * Double(b))
        default:
            return nil
        }
    }

    private static func divide(_ left: AROParser.LiteralValue, _ right: AROParser.LiteralValue) -> AROParser.LiteralValue? {
        switch (left, right) {
        case (.integer(let a), .integer(let b)):
            guard b != 0 else { return nil }
            return .integer(a / b)
        case (.float(let a), .float(let b)):
            guard b != 0 else { return nil }
            return .float(a / b)
        case (.integer(let a), .float(let b)):
            guard b != 0 else { return nil }
            return .float(Double(a) / b)
        case (.float(let a), .integer(let b)):
            guard b != 0 else { return nil }
            return .float(a / Double(b))
        default:
            return nil
        }
    }

    private static func modulo(_ left: AROParser.LiteralValue, _ right: AROParser.LiteralValue) -> AROParser.LiteralValue? {
        switch (left, right) {
        case (.integer(let a), .integer(let b)):
            guard b != 0 else { return nil }
            return .integer(a % b)
        default:
            return nil
        }
    }

    // MARK: - Comparison Helpers

    private static func isEqual(_ left: AROParser.LiteralValue, _ right: AROParser.LiteralValue) -> Bool {
        switch (left, right) {
        case (.integer(let a), .integer(let b)):
            return a == b
        case (.float(let a), .float(let b)):
            return a == b
        case (.string(let a), .string(let b)):
            return a == b
        case (.boolean(let a), .boolean(let b)):
            return a == b
        case (.null, .null):
            return true
        default:
            return false
        }
    }

    private static func lessThan(_ left: AROParser.LiteralValue, _ right: AROParser.LiteralValue) -> AROParser.LiteralValue? {
        switch (left, right) {
        case (.integer(let a), .integer(let b)):
            return .boolean(a < b)
        case (.float(let a), .float(let b)):
            return .boolean(a < b)
        case (.integer(let a), .float(let b)):
            return .boolean(Double(a) < b)
        case (.float(let a), .integer(let b)):
            return .boolean(a < Double(b))
        case (.string(let a), .string(let b)):
            return .boolean(a < b)
        default:
            return nil
        }
    }

    private static func lessEqual(_ left: AROParser.LiteralValue, _ right: AROParser.LiteralValue) -> AROParser.LiteralValue? {
        switch (left, right) {
        case (.integer(let a), .integer(let b)):
            return .boolean(a <= b)
        case (.float(let a), .float(let b)):
            return .boolean(a <= b)
        case (.integer(let a), .float(let b)):
            return .boolean(Double(a) <= b)
        case (.float(let a), .integer(let b)):
            return .boolean(a <= Double(b))
        case (.string(let a), .string(let b)):
            return .boolean(a <= b)
        default:
            return nil
        }
    }

    private static func greaterThan(_ left: AROParser.LiteralValue, _ right: AROParser.LiteralValue) -> AROParser.LiteralValue? {
        switch (left, right) {
        case (.integer(let a), .integer(let b)):
            return .boolean(a > b)
        case (.float(let a), .float(let b)):
            return .boolean(a > b)
        case (.integer(let a), .float(let b)):
            return .boolean(Double(a) > b)
        case (.float(let a), .integer(let b)):
            return .boolean(a > Double(b))
        case (.string(let a), .string(let b)):
            return .boolean(a > b)
        default:
            return nil
        }
    }

    private static func greaterEqual(_ left: AROParser.LiteralValue, _ right: AROParser.LiteralValue) -> AROParser.LiteralValue? {
        switch (left, right) {
        case (.integer(let a), .integer(let b)):
            return .boolean(a >= b)
        case (.float(let a), .float(let b)):
            return .boolean(a >= b)
        case (.integer(let a), .float(let b)):
            return .boolean(Double(a) >= b)
        case (.float(let a), .integer(let b)):
            return .boolean(a >= Double(b))
        case (.string(let a), .string(let b)):
            return .boolean(a >= b)
        default:
            return nil
        }
    }

    // MARK: - Logical Helpers

    private static func logicalAnd(_ left: AROParser.LiteralValue, _ right: AROParser.LiteralValue) -> AROParser.LiteralValue? {
        guard case .boolean(let a) = left, case .boolean(let b) = right else {
            return nil
        }
        return .boolean(a && b)
    }

    private static func logicalOr(_ left: AROParser.LiteralValue, _ right: AROParser.LiteralValue) -> AROParser.LiteralValue? {
        guard case .boolean(let a) = left, case .boolean(let b) = right else {
            return nil
        }
        return .boolean(a || b)
    }
}

#endif
