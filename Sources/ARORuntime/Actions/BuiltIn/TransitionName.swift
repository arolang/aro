// ============================================================
// TransitionName.swift
// ARO Runtime — the two states hiding inside a transition name
// ============================================================
//
// `Accept the <transition: draft_to_placed> on <order: status>.`
// names two states in one token. Both the runtime (AcceptAction) and
// the static contract gate (TransitionContractValidator, GitLab #507)
// have to split that token the same way — if they disagree, the gate
// either lets an illegal move through or rejects a legal one. So the
// splitting lives here once, and both call it.

import Foundation

/// A transition name split into its `from` and `to` halves.
public struct TransitionName: Sendable, Equatable {
    /// The state the entity must currently be in.
    public let from: String
    /// The state the entity moves to.
    public let to: String
    /// The token the two halves were read out of, e.g. `draft_to_placed`.
    public let raw: String

    public init(from: String, to: String, raw: String) {
        self.from = from
        self.to = to
        self.raw = raw
    }

    /// The separator between the two states.
    public static let separator = "_to_"

    /// Splits a result descriptor — written either as
    /// `<transition: from_to_target>` or `<from_to_target: transition>` —
    /// into its two states.
    ///
    /// Returns `nil` when the descriptor carries no transition; callers
    /// decide whether that is an error (the runtime) or simply nothing to
    /// check (the static gate).
    public static func parse(base: String, specifiers: [String]) -> TransitionName? {
        var transitionString: String?

        // `<transition: draft_to_placed>` — the common spelling.
        if let spec = specifiers.first, spec.contains(separator) {
            transitionString = spec
        }
        // `<draft_to_placed: transition>` — transition in the base.
        else if base.contains(separator) {
            transitionString = base
        }
        // A dotted qualifier the parser split into pieces.
        else if specifiers.count >= 3 {
            let joined = specifiers.joined(separator: "-")
            if joined.contains(separator) {
                transitionString = joined
            } else if specifiers.count == 3 && specifiers[1].lowercased() == "to" {
                return TransitionName(
                    from: specifiers[0],
                    to: specifiers[2],
                    raw: specifiers.joined(separator: ".")
                )
            }
        }

        guard let transition = transitionString else { return nil }

        let parts = transition.components(separatedBy: separator)
        guard parts.count == 2,
              !parts[0].isEmpty,
              !parts[1].isEmpty
        else { return nil }

        return TransitionName(from: parts[0], to: parts[1], raw: transition)
    }
}
