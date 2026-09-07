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

        // Publish StateTransitionEvent and wait for all handlers to complete.
        // (publishAndTrack ensures awaitPendingEvents() in FeatureSetExecutor waits for handlers)
        // Typed event: StateTransitionEvent { fieldName, objectName, fromState, toState, entityId, entity }
        // DomainEvent co-publish for binary mode support (subscribed via aro_runtime_register_state_transition_handler).
        // DomainEvent eventType: "StateTransition"
        // DomainEvent payload:   { "entityId": String, "fromState": String, "toState": String,
        //                          "fieldName": String, "objectName": String }
        let transitionEvent = StateTransitionEvent(
            fieldName: fieldName,
            objectName: objectName,
            fromState: fromState,
            toState: toState,
            entityId: entityId,
            entity: updatedObject
        )
        if let eventBus = context.eventBus {
            await eventBus.publishAndTrack(transitionEvent)
        } else {
            context.emit(transitionEvent)
        }

        // Co-publish DomainEvent for binary mode compiled handlers
        var stPayload: [String: any Sendable] = [
            "fromState": fromState,
            "toState": toState,
            "fieldName": fieldName,
            "objectName": objectName
        ]
        if let eid = entityId { stPayload["entityId"] = eid }
        (context.eventBus ?? context.container.eventBus).publish(DomainEvent(eventType: "StateTransition", payload: stPayload))

        return updatedObject
    }

    /// Parse the state transition from the result descriptor.
    ///
    /// The splitting itself lives in `TransitionName` so that the static
    /// contract gate (`TransitionContractValidator`, GitLab #507) reads
    /// exactly the same two states out of the same token that the runtime
    /// does. Supported spellings:
    /// - `<transition: from_to_target>` - using `_to_` as separator
    /// - `<from_to_target: transition>` - transition in base
    private func parseTransition(_ result: ResultDescriptor) throws -> (from: String, to: String) {
        guard let transition = TransitionName.parse(
            base: result.base,
            specifiers: result.specifiers
        ) else {
            throw ActionError.invalidArgument(
                argument: "state transition",
                value: "\(result.base):\(result.specifiers.joined(separator: ","))",
                validValues: ["<transition: from_to_target>"]
            )
        }

        return (transition.from, transition.to)
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
            context.bind(objectName, value: dict, allowRebind: true)
            return dict
        }

        // Handle Any dictionary
        if var dict = targetObject as? [String: Any] {
            dict[fieldName] = toState
            let sendableDict = convertToSendableDict(dict)
            context.bind(objectName, value: sendableDict, allowRebind: true)
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
        context.bind(objectName, value: resultDict, allowRebind: true)
        return resultDict
    }

    /// Convert any value to a Sendable type
    private func convertToSendable(_ value: Any) -> any Sendable {
        SendableConverter.fromJSON(value)
    }

    /// Convert a [String: Any] dictionary to [String: any Sendable]
    private func convertToSendableDict(_ dict: [String: Any]) -> [String: any Sendable] {
        SendableConverter.fromJSONDict(dict)
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
