// ============================================================
// FoldingRangeHandler.swift
// AROLSP - Folding Range Provider
// ============================================================

#if !os(Windows)
import Foundation
import AROParser
import LanguageServerProtocol

/// Handles textDocument/foldingRange requests
public struct FoldingRangeHandler: Sendable {

    public init() {}

    /// Handle a folding range request
    public func handle(
        compilationResult: CompilationResult?
    ) -> [[String: Any]]? {
        guard let result = compilationResult else { return nil }

        var ranges: [[String: Any]] = []

        for analyzed in result.analyzedProgram.featureSets {
            let fs = analyzed.featureSet

            // Add folding range for feature set
            if fs.span.start.line < fs.span.end.line {
                ranges.append(createFoldingRange(
                    startLine: fs.span.start.line - 1,  // Convert to 0-based
                    endLine: fs.span.end.line - 1,
                    kind: "region"
                ))
            }

            // Every block that spans more than one line can be collapsed,
            // wherever it was written. This used to look at the feature
            // set's top-level statements only, and at four node types by
            // name — so a `when { … }` block folded nowhere, and a loop
            // inside a loop folded nowhere either. `flattenAll` yields the
            // containers, which is exactly what a folding range is about
            // (GitLab #723).
            for statement in AROStatementWalk.flattenAll(fs.statements) {
                if let matchStmt = statement as? MatchStatement {
                    append(span: matchStmt.span, to: &ranges)
                    // A case clause is not a `Statement`, so the walker does
                    // not reach it — each arm folds on its own.
                    for caseClause in matchStmt.cases {
                        append(span: caseClause.span, to: &ranges)
                    }
                } else if let whenStmt = statement as? WhenStatement {
                    append(span: whenStmt.span, to: &ranges)
                } else if let forEachLoop = statement as? ForEachLoop {
                    append(span: forEachLoop.span, to: &ranges)
                } else if let rangeLoop = statement as? RangeLoop {
                    append(span: rangeLoop.span, to: &ranges)
                } else if let whileLoop = statement as? WhileLoop {
                    append(span: whileLoop.span, to: &ranges)
                }
            }
        }

        return ranges.isEmpty ? nil : ranges
    }

    // MARK: - Helpers

    /// A block folds only when it covers more than one line: a one-line
    /// block has nothing to collapse.
    private func append(span: SourceSpan, to ranges: inout [[String: Any]]) {
        guard span.start.line < span.end.line else { return }
        ranges.append(createFoldingRange(
            startLine: span.start.line - 1,   // convert to 0-based
            endLine: span.end.line - 1,
            kind: "region"
        ))
    }

    private func createFoldingRange(
        startLine: Int,
        endLine: Int,
        kind: String
    ) -> [String: Any] {
        return [
            "startLine": startLine,
            "endLine": endLine,
            "kind": kind
        ]
    }
}

#endif
