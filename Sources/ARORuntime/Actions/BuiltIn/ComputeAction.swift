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

        // Get the source value - this is what we're creating from
        // The source can be a literal, a variable, or structured data
        if let sourceValue = context.resolveAny(object.base) {
            // Check if we're creating a typed entity (e.g., <order: Order>)
            // In this case, we should generate an ID if not present
            if !result.specifiers.isEmpty {
                // Creating a typed entity - ensure it has an ID
                if var dict = sourceValue as? [String: any Sendable] {
                    if dict["id"] == nil {
                        dict["id"] = generateEntityId()
                    }
                    return dict
                }
            }
            // Return the actual value directly - this gets bound to result.base
            // by the FeatureSetExecutor
            return sourceValue
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
}

/// Updates an existing entity
public struct UpdateAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["update", "modify", "change", "set"]
    public static let validPrepositions: Set<Preposition> = [.with, .to, .for, .from]

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

            // Bind the updated entity back
            context.bind(result.base, value: updatedEntity)
            return updatedEntity
        }

        // No field specifier - merge updates into entity or replace
        if let entityDict = entity as? [String: any Sendable],
           let updateDict = updateValue as? [String: any Sendable] {
            var merged = entityDict
            for (key, value) in updateDict {
                merged[key] = value
            }
            context.bind(result.base, value: merged)
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

        // Sort order from result specifiers
        let order = result.specifiers.first ?? "ascending"
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
            // Bind merged result back to the target variable
            context.bind(result.base, value: targetDict)
            return targetDict
        }

        // Merge arrays
        if var targetArray = target as? [any Sendable],
           let sourceArray = source as? [any Sendable] {
            targetArray.append(contentsOf: sourceArray)
            // Bind merged result back to the target variable
            context.bind(result.base, value: targetArray)
            return targetArray
        }

        // Merge strings
        if let targetStr = target as? String,
           let sourceStr = source as? String {
            let merged = targetStr + sourceStr
            // Bind merged result back to the target variable
            context.bind(result.base, value: merged)
            return merged
        }

        // Return target if types don't match
        return target
    }
}

/// Deletes an entity or value
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

        // Get the source containing the item to delete
        guard let source = context.resolveAny(object.base) else {
            throw ActionError.undefinedVariable(object.base)
        }

        // Key to delete from result specifiers
        let keyToDelete = result.specifiers.first ?? result.base

        // Delete from dictionary
        if var dict = source as? [String: any Sendable] {
            dict.removeValue(forKey: keyToDelete)
            return dict
        }

        // Delete from array by index
        if var array = source as? [any Sendable], let index = Int(keyToDelete), index >= 0, index < array.count {
            array.remove(at: index)
            return array
        }

        // Emit delete event
        context.emit(DataDeletedEvent(target: result.base, source: object.base))

        return DeleteResult(target: result.base, success: true)
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
