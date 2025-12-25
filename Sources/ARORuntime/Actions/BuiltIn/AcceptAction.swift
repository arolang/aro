// ============================================================
// AcceptAction.swift
// ARO Runtime - State Transition Action Implementation
// ============================================================

import Foundation
import AROParser

/// Accepts a state transition on a field
///
/// The Accept action validates and applies state transitions.
/// It checks that the current state matches the expected "from" state
/// and then updates the field to the "to" state.
///
/// ## Syntax
/// ```aro
/// <Accept> the <transition: from_to_target> on <object: field>.
/// ```
///
/// The transition format uses `_to_` as the separator between states.
///
/// ## Examples
/// ```aro
/// <Accept> the <transition: draft_to_placed> on <order: status>.
/// <Accept> the <transition: placed_to_paid> on <order: status>.
/// <Accept> the <transition: pending_to_approved> on <request: state>.
/// ```
///
/// ## Error Message
/// If the current state doesn't match:
/// ```
/// Cannot accept state draft->placed on order: status. Current state is "paid".
/// ```
public struct AcceptAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["accept"]
    public static let validPrepositions: Set<Preposition> = [.on]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Parse state transition from result
        // Expected format: <transition: from_to_target>
        // result.base = "transition"
        // result.specifiers = ["from_to_target"] or ["from", "to", "target"]

        let (fromState, toState) = try parseTransition(result)

        // Get the target object and field
        let objectName = object.base
        let fieldName = object.specifiers.first ?? "status"

        // Get the object from context
        guard let targetObject = context.resolveAny(objectName) else {
            throw ActionError.undefinedVariable(objectName)
        }

        // Get the current state from the object
        let currentState = try extractCurrentState(
            from: targetObject,
            fieldName: fieldName,
            objectName: objectName
        )

        // Validate current state matches expected "from" state
        if currentState != fromState {
            throw AcceptStateError(
                expectedFrom: fromState,
                expectedTo: toState,
                actualState: currentState,
                objectName: objectName,
                fieldName: fieldName
            )
        }

        // Update the state
        let updatedObject = try updateState(
            targetObject: targetObject,
            fieldName: fieldName,
            toState: toState,
            objectName: objectName,
            context: context
        )

        // Extract entity ID for the event
        let entityId = extractEntityId(from: updatedObject)

        // Emit StateTransitionEvent for observers
        context.emit(StateTransitionEvent(
            fieldName: fieldName,
            objectName: objectName,
            fromState: fromState,
            toState: toState,
            entityId: entityId,
            entity: updatedObject
        ))

        return updatedObject
    }

    /// Parse the state transition from the result descriptor
    /// Supports formats:
    /// - `<transition: from_to_target>` - using `_to_` as separator
    /// - `<from_to_target: transition>` - transition in base
    private func parseTransition(_ result: ResultDescriptor) throws -> (from: String, to: String) {
        // Try to find the transition string
        var transitionString: String?

        // Check if specifiers contain the transition (e.g., "draft_to_placed")
        if let spec = result.specifiers.first, spec.contains("_to_") {
            transitionString = spec
        }
        // Check if base contains the transition
        else if result.base.contains("_to_") {
            transitionString = result.base
        }
        // Check if specifiers can be joined to form "from_to_target"
        else if result.specifiers.count >= 3 {
            let joined = result.specifiers.joined(separator: "-")
            if joined.contains("_to_") {
                transitionString = joined
            }
        }
        // Handle case where specifiers are ["from", "to", "target"]
        else if result.specifiers.count == 3 && result.specifiers[1].lowercased() == "to" {
            let from = result.specifiers[0]
            let to = result.specifiers[2]
            return (from, to)
        }

        guard let transition = transitionString else {
            throw ActionError.runtimeError(
                "Accept action requires state transition in format <transition: from_to_target>, got: \(result.base) with specifiers: \(result.specifiers)"
            )
        }

        // Parse "from_to_target" format
        let parts = transition.components(separatedBy: "_to_")
        guard parts.count == 2 else {
            throw ActionError.runtimeError(
                "Invalid state transition format. Expected 'from_to_target', got: \(transition)"
            )
        }

        let fromState = parts[0]
        let toState = parts[1]

        guard !fromState.isEmpty && !toState.isEmpty else {
            throw ActionError.runtimeError(
                "Invalid state transition: from and to states cannot be empty"
            )
        }

        return (fromState, toState)
    }

    /// Extract the current state value from the target object
    private func extractCurrentState(
        from targetObject: any Sendable,
        fieldName: String,
        objectName: String
    ) throws -> String {
        // Try dictionary access first
        if let dict = targetObject as? [String: any Sendable],
           let state = dict[fieldName] as? String {
            return state
        }

        if let dict = targetObject as? [String: Any],
           let state = dict[fieldName] as? String {
            return state
        }

        // Try reflection for custom types
        let mirror = Mirror(reflecting: targetObject)
        if let child = mirror.children.first(where: { $0.label == fieldName }),
           let state = child.value as? String {
            return state
        }

        throw ActionError.propertyNotFound(
            property: fieldName,
            on: objectName
        )
    }

    /// Extract entity ID from the object if it has an "id" field
    private func extractEntityId(from object: any Sendable) -> String? {
        if let dict = object as? [String: any Sendable],
           let id = dict["id"] {
            return String(describing: id)
        }
        if let dict = object as? [String: Any],
           let id = dict["id"] {
            return String(describing: id)
        }
        // Try reflection for custom types
        let mirror = Mirror(reflecting: object)
        if let child = mirror.children.first(where: { $0.label == "id" }) {
            return String(describing: child.value)
        }
        return nil
    }

    /// Update the state field on the target object
    private func updateState(
        targetObject: any Sendable,
        fieldName: String,
        toState: String,
        objectName: String,
        context: ExecutionContext
    ) throws -> any Sendable {
        // Handle Sendable dictionary
        if var dict = targetObject as? [String: any Sendable] {
            dict[fieldName] = toState
            context.bind(objectName, value: dict)
            return dict
        }

        // Handle Any dictionary
        if var dict = targetObject as? [String: Any] {
            dict[fieldName] = toState
            let sendableDict = convertToSendableDict(dict)
            context.bind(objectName, value: sendableDict)
            return sendableDict
        }

        // For other types, create a new dictionary with the updated state
        var resultDict: [String: any Sendable] = [:]
        let mirror = Mirror(reflecting: targetObject)
        for child in mirror.children {
            if let label = child.label {
                if label == fieldName {
                    resultDict[label] = toState
                } else {
                    resultDict[label] = convertToSendable(child.value)
                }
            }
        }
        context.bind(objectName, value: resultDict)
        return resultDict
    }

    /// Convert any value to a Sendable type
    /// Since Sendable is a marker protocol and cannot be checked at runtime,
    /// we explicitly handle known types
    private func convertToSendable(_ value: Any) -> any Sendable {
        if let str = value as? String { return str }
        if let int = value as? Int { return int }
        if let double = value as? Double { return double }
        if let bool = value as? Bool { return bool }
        if let date = value as? Date { return date }
        if let data = value as? Data { return data }
        if let uuid = value as? UUID { return uuid }
        if let url = value as? URL { return url }
        if let array = value as? [String] { return array }
        if let array = value as? [Int] { return array }
        if let array = value as? [Double] { return array }
        if let dict = value as? [String: String] { return dict }
        if let dict = value as? [String: Int] { return dict }
        if let dict = value as? [String: Any] { return convertToSendableDict(dict) }
        return String(describing: value)
    }

    /// Convert a [String: Any] dictionary to [String: any Sendable]
    private func convertToSendableDict(_ dict: [String: Any]) -> [String: any Sendable] {
        var result: [String: any Sendable] = [:]
        for (key, value) in dict {
            result[key] = convertToSendable(value)
        }
        return result
    }
}

/// Error thrown when state transition is not valid
public struct AcceptStateError: Error, LocalizedError, Sendable {
    public let expectedFrom: String
    public let expectedTo: String
    public let actualState: String
    public let objectName: String
    public let fieldName: String

    public var errorDescription: String? {
        "Cannot accept state \(expectedFrom)->\(expectedTo) on \(objectName): \(fieldName). Current state is \"\(actualState)\"."
    }
}
