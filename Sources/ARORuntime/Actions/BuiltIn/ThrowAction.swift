// ============================================================
// ThrowAction.swift
// ARO Runtime - Throw: failing a feature set deliberately
// ============================================================

import Foundation
import AROParser

/// Throws an error
public struct ThrowAction: SynchronousAction {
    public static let role: ActionRole = .response
    public static let verbs: Set<String> = ["throw", "raise", "fail"]
    public static let validPrepositions: Set<Preposition> = [.for]

    public init() {}

    public func executeSynchronously(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) throws -> any Sendable {
        try validatePreposition(object.preposition)

        let errorType = result.base
        let reason = object.fullName

        throw ActionError.thrown(
            type: errorType,
            reason: reason,
            context: context.featureSetName
        )
    }
}
