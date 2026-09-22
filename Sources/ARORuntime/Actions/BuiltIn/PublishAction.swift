// ============================================================
// PublishAction.swift
// ARO Runtime - Publish: making a variable visible to other feature sets
// ============================================================

import Foundation
import AROParser

/// Publishes a variable for cross-feature-set access
public struct PublishAction: SynchronousAction {
    public static let role: ActionRole = .export
    public static let verbs: Set<String> = ["publish", "export", "expose", "share"]
    public static let validPrepositions: Set<Preposition> = [.with]

    public init() {}

    public func executeSynchronously(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) throws -> any Sendable {
        // Publish is handled specially - the external name is in result, internal in object
        guard let value = context.resolveAny(object.base) else {
            throw ActionError.undefinedVariable(object.base)
        }

        // The result.base is the external name to publish as
        // This is typically handled by the execution engine's global registry
        context.emit(VariablePublishedEvent(
            externalName: result.base,
            internalName: object.base,
            featureSet: context.featureSetName
        ))

        // value is already `any Sendable` from resolveAny
        return value
    }
}

/// Event emitted when a variable is published
public struct VariablePublishedEvent: RuntimeEvent {
    public static var eventType: String { "variable.published" }
    public let timestamp: Date
    public let externalName: String
    public let internalName: String
    public let featureSet: String

    public init(externalName: String, internalName: String, featureSet: String) {
        self.timestamp = Date()
        self.externalName = externalName
        self.internalName = internalName
        self.featureSet = featureSet
    }
}
