// ============================================================
// ToolRequirement.swift
// AROAsk - a lookup this turn owes before it may answer
// ============================================================
//
// GitLab #873. The prompt tells the model to check its ARO before answering.
// A capable model does; a 6-bit local one often does not, and the recovery —
// `selfRepairIfNeeded` plus its repair loop — spends up to four more
// generations fixing code the model could have checked once.
//
// `tool_choice` names a tool the model *must* call on that request. It takes
// the third option away: answer, call something else, or call this.
//
// Two things keep that from doing damage.
//
// **Only a confirmed requirement may be forced.** The reference
// implementation separates requirements it derived from a verdict from ones
// it guessed at from words in the prompt, and records what happens when that
// distinction is missing: four forced calls on a vocabulary mis-match, each
// carrying a 600-character statement as its search term, each returning
// nothing, one rejected outright as an unknown slug. An inferred requirement
// is worth steering at and not worth compelling.
//
// **A requirement names a family, not a call.** What an answer owes is *the
// code checked*, not *`aro_check` invoked* — a run that checked through a
// differently named bridge has done the work. `preferred` is what a
// correction says; every name in `satisfiedBy` discharges it.

import Foundation

/// One place a turn has to have looked before it answers.
public struct ToolRequirement: Sendable, Equatable {

    /// How sure we are that this turn needs this lookup.
    public enum Origin: Sendable, Equatable {
        /// Derived from what the turn actually produced. May be compelled.
        case confirmed
        /// Guessed from the words of the request. Worth steering at, not
        /// worth compelling.
        case inferred
    }

    /// The call to name when none of the family has been made.
    public let preferred: String
    /// Every call that discharges this requirement.
    public let satisfiedBy: Set<String>
    public let origin: Origin
    /// Why, in one line, for the steer and the log.
    public let reason: String

    public init(preferred: String, satisfiedBy: Set<String>? = nil,
                origin: Origin, reason: String) {
        self.preferred = preferred
        self.satisfiedBy = satisfiedBy ?? [preferred]
        self.origin = origin
        self.reason = reason
    }

    /// Whether this requirement may go in a request's `tool_choice`.
    public var isCompellable: Bool { origin == .confirmed }

    /// Whether the calls made so far discharge it.
    public func isSatisfied(by calls: [String]) -> Bool {
        calls.contains { satisfiedBy.contains($0) }
    }

    // MARK: - The requirements this assistant has

    /// A turn that wrote ARO owes `aro_check`.
    ///
    /// Confirmed, because it is read off what the turn produced rather than
    /// guessed from the request: the answer contains an ```aro fence, or a
    /// writing tool was called on a `.aro` path. Neither is a guess about
    /// intent.
    public static func checkedTheCode() -> ToolRequirement {
        ToolRequirement(
            preferred: "aro_check",
            satisfiedBy: ["aro_check", "aro_test", "aro_build", "aro_mcp_aro_check"],
            origin: .confirmed,
            reason: "ARO was written and not checked")
    }

    /// What this turn owes, given what it produced and what it called.
    ///
    /// - Parameters:
    ///   - answer: the assistant's text so far, thinking stripped.
    ///   - toolCallsMade: every call dispatched in this run.
    ///   - attached: the tools this run has, so a requirement naming an
    ///     absent tool is never raised.
    public static func outstanding(
        answer: String,
        toolCallsMade: [String],
        wroteAROFile: Bool,
        attached: Set<String>
    ) -> [ToolRequirement] {
        var out: [ToolRequirement] = []
        let wroteCode = wroteAROFile || answer.contains("```aro")
        if wroteCode {
            let requirement = checkedTheCode()
            // A requirement whose family is not attached cannot be owed.
            if !requirement.satisfiedBy.isDisjoint(with: attached),
               !requirement.isSatisfied(by: toolCallsMade) {
                out.append(requirement)
            }
        }
        return out
    }

    /// Writing tools whose target says whether ARO was produced.
    public static let aroWritingTools: Set<String> = ["write_file", "edit_file"]

    /// Whether a call wrote ARO — a writing tool aimed at a `.aro` path.
    public static func wroteARO(tool: String, argumentsJSON: String) -> Bool {
        guard aroWritingTools.contains(tool) else { return false }
        return argumentsJSON.contains(".aro")
    }
}
