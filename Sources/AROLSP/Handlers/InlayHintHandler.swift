// ============================================================
// InlayHintHandler.swift
// AROLSP - Inlay Hint Provider
// ============================================================

#if !os(Windows)
import Foundation
import AROParser
import LanguageServerProtocol

/// Handles textDocument/inlayHint requests.
///
/// Inlay hints display type or qualifier information inline in the editor,
/// directly next to variable bindings, without requiring the user to hover.
///
/// For ARO, hints are shown:
/// - After the result variable of REQUEST/OWN statements: shows the data type
///   when it can be inferred from the symbol table.
/// - After a qualifier annotation: shows what the qualifier resolves to.
public struct InlayHintHandler: Sendable {

    public init() {}

    /// Handle an inlayHint request.
    ///
    /// - Parameters:
    ///   - compilationResult: The compiled AST and symbol information.
    ///   - startLine: The first line of the visible range (0-based, from LSP).
    ///   - endLine: The last line of the visible range (0-based, from LSP).
    /// - Returns: An array of inlay hint dictionaries, or nil if none.
    public func handle(
        compilationResult: CompilationResult?,
        startLine: Int,
        endLine: Int
    ) -> [[String: Any]]? {
        guard let result = compilationResult else { return nil }

        var hints: [[String: Any]] = []

        for analyzed in result.analyzedProgram.featureSets {
            let symbolTable = analyzed.symbolTable
            for statement in analyzed.featureSet.statements {
                hints.append(contentsOf: hintsForStatement(
                    statement,
                    symbolTable: symbolTable,
                    startLine: startLine,
                    endLine: endLine
                ))
            }
        }

        return hints.isEmpty ? nil : hints
    }

    // MARK: - Per-statement hint generation

    private func hintsForStatement(
        _ statement: Statement,
        symbolTable: SymbolTable,
        startLine: Int,
        endLine: Int
    ) -> [[String: Any]] {
        var hints: [[String: Any]] = []

        if let aro = statement as? AROStatement {
            hints.append(contentsOf: hintsForAROStatement(aro, symbolTable: symbolTable, startLine: startLine, endLine: endLine))
        } else if let forEachLoop = statement as? ForEachLoop {
            for nested in forEachLoop.body {
                hints.append(contentsOf: hintsForStatement(nested, symbolTable: symbolTable, startLine: startLine, endLine: endLine))
            }
        } else if let rangeLoop = statement as? RangeLoop {
            for nested in rangeLoop.body {
                hints.append(contentsOf: hintsForStatement(nested, symbolTable: symbolTable, startLine: startLine, endLine: endLine))
            }
        } else if let whileLoop = statement as? WhileLoop {
            for nested in whileLoop.body {
                hints.append(contentsOf: hintsForStatement(nested, symbolTable: symbolTable, startLine: startLine, endLine: endLine))
            }
        } else if let matchStmt = statement as? MatchStatement {
            for caseClause in matchStmt.cases {
                for nested in caseClause.body {
                    hints.append(contentsOf: hintsForStatement(nested, symbolTable: symbolTable, startLine: startLine, endLine: endLine))
                }
            }
        } else if let pipeline = statement as? PipelineStatement {
            for stage in pipeline.stages {
                hints.append(contentsOf: hintsForAROStatement(stage, symbolTable: symbolTable, startLine: startLine, endLine: endLine))
            }
        }

        return hints
    }

    private func hintsForAROStatement(
        _ aro: AROStatement,
        symbolTable: SymbolTable,
        startLine: Int,
        endLine: Int
    ) -> [[String: Any]] {
        // Only emit hints for REQUEST and OWN actions — the ones that create bindings
        guard aro.action.semanticRole == .request || aro.action.semanticRole == .own else {
            return []
        }

        let resultSpan = aro.result.span
        let resultEndLine0 = resultSpan.end.line - 1  // convert to 0-based

        // Skip if outside the requested range
        guard resultEndLine0 >= startLine && resultEndLine0 <= endLine else {
            return []
        }

        // Look up the result variable in the symbol table
        let varName = aro.result.base
        guard let symbol = symbolTable.lookup(varName),
              let dataType = symbol.dataType else {
            return []
        }

        let typeLabel = dataType.description

        // Position the hint right after the closing `>` of the result noun
        let hintLine = resultSpan.end.line - 1   // 0-based
        let hintChar = resultSpan.end.column      // already 0-based end (exclusive)

        let hint: [String: Any] = [
            "position": ["line": hintLine, "character": hintChar],
            "label": ": \(typeLabel)",
            "kind": 1,          // 1 = Type (LSP InlayHintKind)
            "paddingLeft": false,
            "paddingRight": true
        ]

        return [hint]
    }
}

#endif
