// ============================================================
// ComputeAction.swift
// ARO Runtime - Compute and Transform Action Implementations
// ============================================================

import Foundation
import AROParser

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

        // Computation name from result specifiers
        let computationName = result.specifiers.first ?? "identity"

        // Look up computation service
        if let computeService = context.service(ComputationService.self) {
            return try await computeService.compute(named: computationName, input: input)
        }

        // Built-in computations
        switch computationName.lowercased() {
        case "hash":
            if let str = input as? String {
                return str.hashValue
            }
            return String(describing: input).hashValue

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
            return 0

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

        default:
            // Return input as-is for unknown computations
            return input
        }
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

        // Validation rule from result specifiers
        let ruleName = result.specifiers.first ?? "required"

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
        if let optional = value as? Any?, optional == nil {
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

        // Transformation type from result specifiers
        let transformType = result.specifiers.first ?? "identity"

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
    public static let verbs: Set<String> = ["create", "make", "build", "construct"]
    public static let validPrepositions: Set<Preposition> = [.with, .from, .for]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get creation data
        var data: [String: any Sendable] = [:]
        if let source: [String: String] = context.resolve(object.base) {
            for (k, v) in source { data[k] = v }
        } else if let source = context.resolveAny(object.base) {
            data["value"] = source
        }

        // Create entity with type from result
        let entityType = result.base
        return CreatedEntity(type: entityType, data: data)
    }
}

/// Updates an existing entity
public struct UpdateAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["update", "modify", "change", "set"]
    public static let validPrepositions: Set<Preposition> = [.with, .to, .for]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get entity to update
        guard let entity = context.resolveAny(result.base) else {
            throw ActionError.undefinedVariable(result.base)
        }

        // Get update data
        guard let updates = context.resolveAny(object.base) else {
            throw ActionError.undefinedVariable(object.base)
        }

        // Perform update (simplified: just return the updates)
        // The updates value is already `any Sendable` from resolveAny
        return updates
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
