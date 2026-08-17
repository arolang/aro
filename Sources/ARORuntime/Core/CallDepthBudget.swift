// ============================================================
// CallDepthBudget.swift
// ARO Runtime - Runaway-recursion diagnostic (ARO-0081)
// ============================================================

import Foundation

/// Turns "this recursion is never going to stop" into something a person can
/// read (GitLab #473).
///
/// There is no depth *limit* in ARO: a call in tail position reuses its frame
/// and runs forever in constant space, and a call that keeps its frame is
/// bounded only by memory. What this adds is an end state you can act on. The
/// alternative — the behaviour before this existed — was the operating system
/// killing the process: `SIGBUS` at ~1 300 frames with no output at all, or an
/// OOM kill after the machine had already started swapping.
public enum CallDepthBudget {
    /// Check the frame that is about to run.
    ///
    /// - Parameters:
    ///   - frame: The callee's freshly marked call-frame context.
    ///   - actionName: The action being entered, for the message.
    public static func check(frame: RuntimeContext, actionName: String) throws {
        let budget = RuntimeDefaults.maxUserActionDepth
        guard budget > 0, frame.callDepth > budget else { return }
        throw ActionError.callDepthExceeded(
            message(frame: frame, actionName: actionName, budget: budget)
        )
    }

    static func message(frame: RuntimeContext, actionName: String, budget: Int) -> String {
        let chain = frame.callChainTail
        let rendered = chain.isEmpty
            ? actionName
            : "… → " + chain.joined(separator: " → ")

        return """
            Cannot call \(UserActionVerb.prefix)\(actionName) — \
            \(frame.callDepth) frames are live, above the call-depth budget of \(budget)
              Call chain: \(rendered) (\(frame.callDepth) frames)
              hint: a recursion with no base case never returns — add a \
            `when` guard that returns without calling again
              hint: an action that ends with `Return … with <r>.` immediately \
            after the call reuses its frame, and has no depth budget at all
              hint: raise or remove the budget with ARO_MAX_CALL_DEPTH=<frames> (0 = unlimited)
            """
    }
}
