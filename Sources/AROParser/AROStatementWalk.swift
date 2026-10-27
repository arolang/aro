// ============================================================
// AROStatementWalk.swift
// AROParser — one flattening of the statement tree
// GitLab #660, GitLab #723
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
//
// GitLab #723 found seven more copies outside the validators — in the LSP,
// in the user-action and body-materialization analyses, and in the LLVM code
// generator — with the same drift and the same cause. They could not all use
// `flatten`, because several of them care about the containers too: the LLVM
// generator binds a range loop's own variable, the body-materialization pass
// asks what a `match` is matching on. `flattenAll` is the shape they share —
// every node, containers included, in the order the recursive walks visited
// them — so they lose the recursion rather than keeping a private copy of it.

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
        flattenAll(statements).compactMap(\.asAROStatement)
    }

    /// Every statement in the tree, containers included, in source order.
    ///
    /// Pre-order: a container comes before the statements it holds, which is
    /// the order the hand-written recursions produced and the order a reader
    /// of the source would name them. A consumer that only wants the actions
    /// wants `flatten`; this one is for the consumers that also have
    /// something to say about a `match`, a loop or a `Publish` — they switch
    /// on the kinds they handle and ignore the rest, exactly as their `as?`
    /// chains did, but without owning the descent.
    ///
    /// A pipeline's stages *are* `AROStatement`s — that is what a stage is —
    /// so they follow the `PipelineStatement` that holds them.
    public static func flattenAll(_ statements: [any Statement]) -> [any Statement] {
        let walker = Walker()
        for statement in statements {
            statement.accept(walker)
        }
        return walker.collected
    }

    /// Appends into one array rather than returning a fresh array per level:
    /// this runs once per feature set per analysis pass, and the passes are
    /// many.
    private final class Walker: StatementVisitor {
        typealias Result = Void

        var collected: [any Statement] = []

        func visit(_ node: AROStatement) { collected.append(node) }

        // Leaves: they contain no statements of their own.
        func visit(_ node: PublishStatement) { collected.append(node) }
        func visit(_ node: RequireStatement) { collected.append(node) }
        func visit(_ node: BreakStatement) { collected.append(node) }
        func visit(_ node: ErrorStatement) { collected.append(node) }

        func visit(_ node: MatchStatement) {
            collected.append(node)
            for caseClause in node.cases {
                for statement in caseClause.body { statement.accept(self) }
            }
            for statement in node.otherwise ?? [] { statement.accept(self) }
        }

        // The two the old copies missed entirely.
        func visit(_ node: WhenStatement) {
            collected.append(node)
            for statement in node.body { statement.accept(self) }
        }

        func visit(_ node: PipelineStatement) {
            collected.append(node)
            collected.append(contentsOf: node.stages)
        }

        func visit(_ node: ForEachLoop) {
            collected.append(node)
            for statement in node.body { statement.accept(self) }
        }
        func visit(_ node: WhileLoop) {
            collected.append(node)
            for statement in node.body { statement.accept(self) }
        }
        func visit(_ node: RangeLoop) {
            collected.append(node)
            for statement in node.body { statement.accept(self) }
        }
    }
}
