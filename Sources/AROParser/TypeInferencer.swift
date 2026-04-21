// ============================================================
// TypeInferencer.swift
// ARO Parser - Type Inference for Expressions and Statements
// ============================================================

import Foundation

// MARK: - Type Inferencer

/// Infers data types from expressions and statement context
public enum TypeInferencer {

    /// Infers the result type of a statement from its type annotation or value expression
    ///
    /// This centralizes the pattern:
    ///   1. Use explicit type annotation if present
    ///   2. Infer from value expression if available
    ///   3. Fall back to .unknown
    public static func inferResultType(_ statement: AROStatement) -> DataType {
        if let annotatedType = statement.result.dataType {
            return annotatedType
        }
        if let expr = statement.valueSource.asExpression {
            return inferExpressionType(expr)
        }
        return .unknown
    }

    /// Infers the type of an expression (ARO-0006)
    public static func inferExpressionType(_ expr: any Expression) -> DataType {
        switch expr {
        case let literal as LiteralExpression:
            switch literal.value {
            case .string: return .string
            case .integer: return .integer
            case .float: return .float
            case .boolean: return .boolean
            case .null: return .unknown
            case .array: return .list(.unknown)
            case .object: return .map(key: .string, value: .unknown)
            case .regex: return .string
            }

        case is ArrayLiteralExpression:
            return .list(.unknown)

        case is MapLiteralExpression:
            return .map(key: .string, value: .unknown)

        case let binary as BinaryExpression:
            switch binary.op {
            case .add, .subtract, .multiply, .divide, .modulo:
                return .float
            case .concat:
                return .string
            case .equal, .notEqual, .lessThan, .greaterThan, .lessEqual, .greaterEqual,
                 .and, .or, .contains, .matches, .is, .isNot:
                return .boolean
            }

        case is UnaryExpression:
            return .unknown

        case is VariableRefExpression:
            return .unknown

        case is TypeCheckExpression, is ExistenceExpression:
            return .boolean

        case is InterpolatedStringExpression:
            return .string

        default:
            return .unknown
        }
    }
}
