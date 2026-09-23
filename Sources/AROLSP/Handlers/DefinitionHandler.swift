// ============================================================
// DefinitionHandler.swift
// AROLSP - Go to Definition Provider
// ============================================================

#if !os(Windows)
import Foundation
import AROParser
import LanguageServerProtocol

/// Handles textDocument/definition requests
public struct DefinitionHandler: Sendable {

    public init() {}

    /// Handle a definition request
    public func handle(
        uri: String,
        position: Position,
        content: String,
        compilationResult: CompilationResult?
    ) -> [String: Any]? {
        guard let result = compilationResult else { return nil }

        let lines = LineIndex(content)
        let aroPosition = PositionConverter.fromLSP(position, using: lines)

        // Find the variable at the position
        for analyzed in result.analyzedProgram.featureSets {
            if let location = findDefinitionInStatements(analyzed.featureSet.statements, position: aroPosition, symbolTable: analyzed.symbolTable, uri: uri, lines: lines) {
                return location
            }
        }

        return nil
    }

    // MARK: - Statement Traversal

    private func findDefinitionInStatements(
        _ statements: [Statement],
        position: SourceLocation,
        symbolTable: SymbolTable,
        uri: String,
        lines: LineIndex
    ) -> [String: Any]? {
        for statement in statements {
            if let aro = statement as? AROStatement {
                if aro.result.span.contains(position) {
                    if let symbol = symbolTable.lookup(aro.result.base) {
                        return createLocationResponse(uri: uri, span: symbol.definedAt, lines: lines)
                    }
                }
                if aro.object.noun.span.contains(position) {
                    if let symbol = symbolTable.lookup(aro.object.noun.base) {
                        return createLocationResponse(uri: uri, span: symbol.definedAt, lines: lines)
                    }
                }
                if let expr = aro.valueSource.asExpression {
                    if let location = findDefinitionInExpression(expr, position: position, symbolTable: symbolTable, uri: uri, lines: lines) {
                        return location
                    }
                }
            } else if let forEachLoop = statement as? ForEachLoop {
                if let location = findDefinitionInStatements(forEachLoop.body, position: position, symbolTable: symbolTable, uri: uri, lines: lines) {
                    return location
                }
            } else if let rangeLoop = statement as? RangeLoop {
                if let location = findDefinitionInStatements(rangeLoop.body, position: position, symbolTable: symbolTable, uri: uri, lines: lines) {
                    return location
                }
            } else if let whileLoop = statement as? WhileLoop {
                if let location = findDefinitionInStatements(whileLoop.body, position: position, symbolTable: symbolTable, uri: uri, lines: lines) {
                    return location
                }
            } else if let matchStmt = statement as? MatchStatement {
                for caseClause in matchStmt.cases {
                    if let location = findDefinitionInStatements(caseClause.body, position: position, symbolTable: symbolTable, uri: uri, lines: lines) {
                        return location
                    }
                }
            } else if let pipeline = statement as? PipelineStatement {
                for stage in pipeline.stages {
                    if stage.result.span.contains(position) {
                        if let symbol = symbolTable.lookup(stage.result.base) {
                            return createLocationResponse(uri: uri, span: symbol.definedAt, lines: lines)
                        }
                    }
                    if stage.object.noun.span.contains(position) {
                        if let symbol = symbolTable.lookup(stage.object.noun.base) {
                            return createLocationResponse(uri: uri, span: symbol.definedAt, lines: lines)
                        }
                    }
                    if let expr = stage.valueSource.asExpression {
                        if let location = findDefinitionInExpression(expr, position: position, symbolTable: symbolTable, uri: uri, lines: lines) {
                            return location
                        }
                    }
                }
            }
        }
        return nil
    }

    // MARK: - Expression Traversal

    private func findDefinitionInExpression(
        _ expression: any AROParser.Expression,
        position: SourceLocation,
        symbolTable: SymbolTable,
        uri: String,
        lines: LineIndex
    ) -> [String: Any]? {
        if let varRef = expression as? VariableRefExpression {
            if varRef.span.contains(position) {
                let name = varRef.noun.base
                if let symbol = symbolTable.lookup(name) {
                    return createLocationResponse(uri: uri, span: symbol.definedAt, lines: lines)
                }
            }
        } else if let binary = expression as? BinaryExpression {
            if let result = findDefinitionInExpression(binary.left, position: position, symbolTable: symbolTable, uri: uri, lines: lines) {
                return result
            }
            if let result = findDefinitionInExpression(binary.right, position: position, symbolTable: symbolTable, uri: uri, lines: lines) {
                return result
            }
        } else if let unary = expression as? UnaryExpression {
            if let result = findDefinitionInExpression(unary.operand, position: position, symbolTable: symbolTable, uri: uri, lines: lines) {
                return result
            }
        } else if let member = expression as? MemberAccessExpression {
            if let result = findDefinitionInExpression(member.base, position: position, symbolTable: symbolTable, uri: uri, lines: lines) {
                return result
            }
        } else if let subscript_ = expression as? SubscriptExpression {
            if let result = findDefinitionInExpression(subscript_.base, position: position, symbolTable: symbolTable, uri: uri, lines: lines) {
                return result
            }
            if let result = findDefinitionInExpression(subscript_.index, position: position, symbolTable: symbolTable, uri: uri, lines: lines) {
                return result
            }
        }

        return nil
    }

    // MARK: - Helpers

    private func createLocationResponse(uri: String, span: SourceSpan, lines: LineIndex) -> [String: Any] {
        let lspRange = PositionConverter.toLSP(span, using: lines)

        return [
            "uri": uri,
            "range": [
                "start": ["line": lspRange.start.line, "character": lspRange.start.character],
                "end": ["line": lspRange.end.line, "character": lspRange.end.character]
            ]
        ]
    }
}

#endif
