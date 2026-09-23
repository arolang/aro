// ============================================================
// ToolScope.swift
// AROAsk - which tools this request is given
// ============================================================
//
// GitLab #875. Every registered tool was attached to every request. With MCP
// servers bridged in that list can be long, and each entry costs schema
// tokens in every one of up to 25 rounds.
//
// The reference implementation puts the general argument well:
//
//   > A rule the model cannot follow is better enforced than repeated.
//
// It had measured the cost: a 2B model told in prose that a person question
// is answered from the content tools opened with the wrong catalogue anyway,
// got an empty result, and wrote that nothing was found — a true statement
// about the wrong index. The correction then regenerated the whole answer in
// front of the reader.
//
// The equivalent here is narrower and safer, because `aro ask` already knows
// something the prompt cannot: whether this session may write at all. A
// read-only session was still *offered* `write_file` and `run_shell`, so the
// model planned a write, asked for approval, and was denied — a round spent
// on a plan that could never run.
//
// Narrow is the point. When in doubt, attach. This withholds only tools that
// provably cannot contribute.

import Foundation

/// Decides which of the registered tools a request is given.
public enum ToolScope {

    /// What this session is allowed to do, as far as scoping cares.
    public struct Situation: Sendable {
        /// The session may not modify anything — every `.modify` and
        /// `.execute` approval would be refused.
        public var readOnly: Bool

        public init(readOnly: Bool = false) {
            self.readOnly = readOnly
        }
    }

    /// The tools to attach, and the names withheld.
    ///
    /// Returns the full set unchanged whenever nothing applies, so the
    /// default path is exactly what it was.
    public static func apply(
        to tools: [AskToolDescriptor],
        situation: Situation
    ) -> (attached: [AskToolDescriptor], withheld: [String]) {
        guard situation.readOnly else { return (tools, []) }

        // A tool the approver will refuse is not a capability, it is a
        // round the model will spend discovering that. The risk tier the
        // approval policy already reads is the honest test — no second list
        // of names to keep in step with the first.
        let attached = tools.filter { $0.riskLevel == .readonly }
        let withheld = tools.filter { $0.riskLevel != .readonly }.map(\.name).sorted()
        return (attached, withheld)
    }

    /// The line the prompt gains when tools were withheld.
    ///
    /// Said rather than silent: a model that finds no way to write should
    /// know it is a policy, so it answers with what to change instead of
    /// looking for a tool that is not there.
    public static func withheldNotice(_ withheld: [String]) -> String? {
        guard !withheld.isEmpty else { return nil }
        return "This session is read-only: \(withheld.joined(separator: ", ")) "
             + "are not available. Describe the change you would make and where, "
             + "rather than looking for a way to make it."
    }
}
