// ============================================================
// AROStatementWalk.swift
// AROParser — one flattening of the statement tree
// GitLab #660
// ============================================================
//
// There were three private copies of this walk, and they disagreed:
//
//   CodeQualityValidator    match, for-each
//   CollectionOpValidator   match, for-each
//   DataFlowAnalyzer        match, for-each, range, while
//
// None of them descended into `when { … }` or a pipeline. So an unknown
// Compute qualifier or an invalid preposition inside a `while` body or a
// `when` block passed `aro check` green, and CLAUDE.md's promise that "a
// green check means the qualifier exists" held only at the top level of a
// feature set. Two of the three also missed range and while bodies, so the
// same statement was checked or not depending on which validator was asking.
//
// The reason the copies drifted is that each was an `if let … as?` chain: a
// new statement type is simply absent from it, and nothing says so. This one
// is a `StatementVisitor`, which the `Statement` protocol dispatches
// dynamically — so adding a node to the AST does not compile until it has a
// case here, and the answer to "does the checker see inside this?" is
// written down in one place.

import Foundation

/// The `AROStatement`s inside a statement tree, in source order.
///
/// Every construct that *contains* statements is descended into. The
/// containers themselves are not `AROStatement`s and do not appear — a
/// validator asking "what actions does this feature set perform?" wants the
/// actions, wherever they were written.
public enum AROStatementWalk {

    /// Flatten a statement list into the actions it contains, at any depth.
    public static func flatten(_ statements: [any Statement]) -> [AROStatement] {
        let walker = Walker()
        return statements.flatMap { $0.accept(walker) }
    }

    private struct Walker: StatementVisitor {
        typealias Result = [AROStatement]

        func visit(_ node: AROStatement) -> [AROStatement] { [node] }

        // Leaves: they contain no statements of their own.
        func visit(_ node: PublishStatement) -> [AROStatement] { [] }
        func visit(_ node: RequireStatement) -> [AROStatement] { [] }
        func visit(_ node: BreakStatement) -> [AROStatement] { [] }
        func visit(_ node: ErrorStatement) -> [AROStatement] { [] }

        func visit(_ node: MatchStatement) -> [AROStatement] {
            var out = node.cases.flatMap { AROStatementWalk.flatten($0.body) }
            out.append(contentsOf: AROStatementWalk.flatten(node.otherwise ?? []))
            return out
        }

        // The two the old copies missed entirely.
        func visit(_ node: WhenStatement) -> [AROStatement] {
            AROStatementWalk.flatten(node.body)
        }

        /// A pipeline's stages *are* `AROStatement`s — that is what a stage
        /// is — so a validator that skipped the node never saw them.
        func visit(_ node: PipelineStatement) -> [AROStatement] { node.stages }

        func visit(_ node: ForEachLoop) -> [AROStatement] {
            AROStatementWalk.flatten(node.body)
        }
        func visit(_ node: WhileLoop) -> [AROStatement] {
            AROStatementWalk.flatten(node.body)
        }
        func visit(_ node: RangeLoop) -> [AROStatement] {
            AROStatementWalk.flatten(node.body)
        }
    }
}
