// ============================================================
// TailCallAnalysis.swift
// ARO Runtime - Tail-call detection for user-defined actions (ARO-0081)
// ============================================================
//
// A user-defined action that ends by handing another action's result straight
// back does not need a new frame to do it: the caller's frame has nothing left
// to do once the callee returns. Reusing it turns recursion of that shape into
// iteration, so depth stops costing anything at all — no stack, no heap, no
// spill file (GitLab #473).
//
// The shape recognised here is deliberately narrow, because "the frame has
// nothing left to do" has to be true beyond doubt:
//
//     Application.Recurse the <r> from <next>.     <- second-to-last statement
//     Return an <OK: status> with <r>.             <- last, unguarded, forwards <r>
//
// Anything that inspects the result first — `Extract the <d> from the <r: depth>`
// — is not a tail call: the frame still has work after the callee returns.

import Foundation
import AROParser

/// Static detection of a user-action call in tail position.
public enum TailCallAnalysis {
    /// Index of the statement that may be executed as a tail call, or `nil` when
    /// this feature set does not end in one.
    ///
    /// Requires, in order:
    /// 1. The last statement is an unguarded `Return` whose object is a plain
    ///    variable — no qualifier (`<r: depth>` destructures, so the frame is
    ///    still needed), no literal or expression payload, no query/range
    ///    modifiers.
    /// 2. The statement immediately before it is an `Application.<Name>` call
    ///    binding exactly that variable.
    ///
    /// A guard on the *call* is fine: if it doesn't fire, the call never
    /// dispatches and the `Return` runs normally.
    public static func tailCallStatementIndex(of featureSet: FeatureSet) -> Int? {
        let statements = featureSet.statements
        guard statements.count >= 2 else { return nil }

        let lastIndex = statements.count - 1
        guard let returnStatement = statements[lastIndex] as? AROStatement,
              let forwarded = forwardedVariable(of: returnStatement) else { return nil }

        let callIndex = lastIndex - 1
        guard let call = statements[callIndex] as? AROStatement,
              isUserActionCall(call),
              call.result.base == forwarded,
              !call.result.base.isEmpty else { return nil }

        return callIndex
    }

    /// The variable a `Return an <OK: status> with <r>.` hands straight back,
    /// or `nil` if this statement is not that.
    ///
    /// The parser routes `with <r>` to `valueSource = .expression(<r>)` and
    /// leaves the object base as `_expression_`, so the variable is read off the
    /// expression. The plain-object form is accepted too, for the shapes that
    /// reach here without an expression.
    private static func forwardedVariable(of statement: AROStatement) -> String? {
        guard statement.action.verb.lowercased() == "return" else { return nil }
        // An unguarded final `Return` always runs; a guarded one may not, and
        // then the frame still has to fall through to whatever follows.
        guard !statement.statementGuard.isPresent else { return nil }
        // Query and range modifiers mean the frame contributes work of its own.
        guard statement.queryModifiers.isEmpty, statement.rangeModifiers.isEmpty else { return nil }

        switch statement.valueSource {
        case .expression(let expression):
            guard let ref = expression as? VariableRefExpression else { return nil }
            return plainVariableName(ref.noun)
        case .none:
            return plainVariableName(statement.object.noun)
        case .literal, .sinkExpression:
            return nil
        }
    }

    /// The name of a variable referenced without a qualifier or `as` type.
    /// A qualifier (`<r: depth>`) reads a field out of the result, which is work
    /// the frame still has to do after the callee returns — not a tail call.
    private static func plainVariableName(_ noun: QualifiedNoun) -> String? {
        guard noun.typeAnnotation == nil, noun.asType == nil, !noun.base.isEmpty else { return nil }
        return noun.base
    }

    /// `Application.<Name> the <r> …`
    private static func isUserActionCall(_ statement: AROStatement) -> Bool {
        statement.action.verb.hasPrefix(UserActionVerb.prefix)
    }
}

/// The verb namespace user-defined actions are registered under (ARO-0081).
public enum UserActionVerb {
    public static let prefix = "Application."

    /// The action name behind an `Application.<Name>` verb, if it is one.
    public static func actionName(from verb: String) -> String? {
        guard verb.hasPrefix(prefix) else { return nil }
        return String(verb.dropFirst(prefix.count))
    }
}

/// A parked tail call: what to run next in the frame that is being reused.
///
/// `UserDefinedActionHost` hands one of these to each frame it runs. When the
/// executor reaches a tail-call statement it fills the slot instead of nesting a
/// call, and the host loops around to the parked target with the frame's
/// storage released — which is what makes tail recursion constant-space.
public final class TailCallSlot: @unchecked Sendable {
    public struct Parked {
        public let actionName: String
        public let input: [String: any Sendable]
    }

    private let lock = NSLock()
    private var parked: Parked?

    public init() {}

    public func park(actionName: String, input: [String: any Sendable]) {
        lock.lock()
        defer { lock.unlock() }
        parked = Parked(actionName: actionName, input: input)
    }

    /// Consume the parked call, if any.
    public func take() -> Parked? {
        lock.lock()
        defer { lock.unlock() }
        let value = parked
        parked = nil
        return value
    }

    public var isParked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return parked != nil
    }
}
