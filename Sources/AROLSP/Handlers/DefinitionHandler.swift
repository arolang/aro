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

        let aroPosition = PositionConverter.fromLSP(position)

        // Find the variable at the position
        for analyzed in result.analyzedProgram.featureSets {
            let fs = analyzed.featureSet

            // Check statements for variable references
            for statement in fs.statements {
                if let aro = statement as? AROStatement {
                    // Check if on result
                    if isPositionInSpan(aroPosition, aro.result.span) {
                        let name = aro.result.base
                        if let symbol = analyzed.symbolTable.lookup(name) {
                            return createLocationResponse(uri: uri, span: symbol.definedAt)
                        }
                    }

                    // Check if on object
                    if isPositionInSpan(aroPosition, aro.object.noun.span) {
                        let name = aro.object.noun.base
                        if let symbol = analyzed.symbolTable.lookup(name) {
                            return createLocationResponse(uri: uri, span: symbol.definedAt)
                        }
                    }

                    // Check expression for variable references
                    if let expr = aro.valueSource.asExpression {
                        if let location = findDefinitionInExpression(expr, position: aroPosition, symbolTable: analyzed.symbolTable, uri: uri) {
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
        uri: String
    ) -> [String: Any]? {
        if let varRef = expression as? VariableRefExpression {
            if isPositionInSpan(position, varRef.span) {
                let name = varRef.noun.base
                if let symbol = symbolTable.lookup(name) {
                    return createLocationResponse(uri: uri, span: symbol.definedAt)
                }
            }
        } else if let binary = expression as? BinaryExpression {
            if let result = findDefinitionInExpression(binary.left, position: position, symbolTable: symbolTable, uri: uri) {
                return result
            }
            if let result = findDefinitionInExpression(binary.right, position: position, symbolTable: symbolTable, uri: uri) {
                return result
            }
        } else if let unary = expression as? UnaryExpression {
            if let result = findDefinitionInExpression(unary.operand, position: position, symbolTable: symbolTable, uri: uri) {
                return result
            }
        } else if let member = expression as? MemberAccessExpression {
            if let result = findDefinitionInExpression(member.base, position: position, symbolTable: symbolTable, uri: uri) {
                return result
            }
        } else if let subscript_ = expression as? SubscriptExpression {
            if let result = findDefinitionInExpression(subscript_.base, position: position, symbolTable: symbolTable, uri: uri) {
                return result
            }
            if let result = findDefinitionInExpression(subscript_.index, position: position, symbolTable: symbolTable, uri: uri) {
                return result
            }
        }

        return nil
    }

    // MARK: - Helpers

    private func isPositionInSpan(_ position: SourceLocation, _ span: SourceSpan) -> Bool {
        if position.line < span.start.line || position.line > span.end.line {
            return false
        }

        if position.line == span.start.line && position.column < span.start.column {
            return false
        }

        if position.line == span.end.line && position.column > span.end.column {
            return false
        }

        return true
    }

    private func createLocationResponse(uri: String, span: SourceSpan) -> [String: Any] {
        let lspRange = PositionConverter.toLSP(span)

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
