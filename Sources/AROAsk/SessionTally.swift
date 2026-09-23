// ============================================================
// SessionTally.swift
// AROAsk - what the harness had to fix
// ============================================================
//
// GitLab #878. `aro ask` repairs a good deal silently:
// `normalizeAROWhitespace` fixes a missing-space bug the base model bakes
// in, three corrective retries re-ask the model, the repair loop runs
// `aro check` and regenerates up to four times, bail-out nudges fire, a tool
// that fails three times is withdrawn.
//
// Every one of those is a place where the prompt, the model or a tool did
// not do its job — and none of them was counted. So the question "is the
// fine-tune getting better?" could not be answered from the tool that would
// know.
//
// The reference implementation states the principle its repair pipeline
// works to:
//
//   > each takes the answer as the model wrote it, fixes a defect the prompt
//   > was supposed to prevent, and reports what it did so the prompt failure
//   > stays visible in the metrics rather than being quietly papered over.
//
// No metrics endpoint here and none needed. A per-run tally, printed on
// request, and — the real consumer — available to the training pipeline,
// which already gates promotion on a benchmark syntax pass rate. "How often
// did the harness have to correct the model" is a second measurement of the
// same thing taken from real use, and it is the one that would notice a
// fine-tune that passes the benchmark and still needs three repairs a
// session.

import Foundation

/// What one run cost, and what had to be corrected in it.
public actor SessionTally {

    public struct Snapshot: Sendable, Equatable, Codable {
        public var turns = 0
        public var toolCalls = 0
        public var toolFailures = 0
        public var toolsWithdrawn = 0
        /// Retries by the name of the thing that triggered them.
        public var retries: [String: Int] = [:]
        /// Deterministic repairs applied to a finished answer.
        public var repairs: [String: Int] = [:]
        /// Calls compelled with `tool_choice` (#873) — a recorded admission
        /// that asking nicely did not work.
        public var forcedCalls = 0
        /// Tool results elided to stay inside the window (#868).
        public var resultsCompacted = 0
        /// Retrieval repeats withheld (#874).
        public var duplicatesWithheld = 0

        /// Whether the harness had to correct anything at all.
        public var hadToCorrect: Bool {
            !retries.isEmpty || !repairs.isEmpty || forcedCalls > 0
        }

        public init() {}
    }

    private var snapshot = Snapshot()

    public init() {}

    public func record(turn: Bool = false, toolCall: Bool = false,
                       toolFailure: Bool = false, toolWithdrawn: Bool = false,
                       forcedCall: Bool = false, compacted: Int = 0,
                       duplicatesWithheld: Int = 0) {
        if turn { snapshot.turns += 1 }
        if toolCall { snapshot.toolCalls += 1 }
        if toolFailure { snapshot.toolFailures += 1 }
        if toolWithdrawn { snapshot.toolsWithdrawn += 1 }
        if forcedCall { snapshot.forcedCalls += 1 }
        snapshot.resultsCompacted += compacted
        snapshot.duplicatesWithheld += duplicatesWithheld
    }

    public func recordRetry(_ reason: String) {
        snapshot.retries[reason, default: 0] += 1
    }

    public func recordRepair(_ kind: String) {
        snapshot.repairs[kind, default: 0] += 1
    }

    public func current() -> Snapshot { snapshot }

    /// One line for the terminal.
    ///
    /// Reads as a bill, because that is what it is: what the run cost, and
    /// what of that was the harness making up for something.
    public func summary() -> String {
        Self.summary(of: snapshot)
    }

    static func summary(of s: Snapshot) -> String {
        var parts = ["turns \(s.turns)", "tool calls \(s.toolCalls)"]
        if s.toolFailures > 0 { parts.append("tool failures \(s.toolFailures)") }
        if s.forcedCalls > 0 { parts.append("forced calls \(s.forcedCalls)") }
        if s.resultsCompacted > 0 { parts.append("results elided \(s.resultsCompacted)") }
        if s.duplicatesWithheld > 0 { parts.append("repeats withheld \(s.duplicatesWithheld)") }
        if !s.retries.isEmpty {
            let detail = s.retries.sorted { $0.key < $1.key }
                .map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            parts.append("retries \(s.retries.values.reduce(0, +)) (\(detail))")
        }
        if !s.repairs.isEmpty {
            let detail = s.repairs.sorted { $0.key < $1.key }
                .map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            parts.append("repairs \(s.repairs.values.reduce(0, +)) (\(detail))")
        }
        return parts.joined(separator: " · ")
    }
}
