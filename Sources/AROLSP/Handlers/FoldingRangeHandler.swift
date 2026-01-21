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

            // Add folding ranges for match statements
            for statement in fs.statements {
                if let matchStmt = statement as? MatchStatement {
                    if matchStmt.span.start.line < matchStmt.span.end.line {
                        ranges.append(createFoldingRange(
                            startLine: matchStmt.span.start.line - 1,
                            endLine: matchStmt.span.end.line - 1,
                            kind: "region"
                        ))
                    }

                    // Add folding for each case clause
                    for caseClause in matchStmt.cases {
                        if caseClause.span.start.line < caseClause.span.end.line {
                            ranges.append(createFoldingRange(
                                startLine: caseClause.span.start.line - 1,
                                endLine: caseClause.span.end.line - 1,
                                kind: "region"
                            ))
                        }
                    }
                }

                // Add folding ranges for for-each loops
                if let forEachLoop = statement as? ForEachLoop {
                    if forEachLoop.span.start.line < forEachLoop.span.end.line {
                        ranges.append(createFoldingRange(
                            startLine: forEachLoop.span.start.line - 1,
                            endLine: forEachLoop.span.end.line - 1,
                            kind: "region"
                        ))
                    }
                }
            }
        }

        return ranges.isEmpty ? nil : ranges
    }

    // MARK: - Helpers

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
