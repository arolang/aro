// ============================================================
// RenameHandler.swift
// AROLSP - Rename Symbol Provider
// ============================================================

#if !os(Windows)
import Foundation
import AROParser
import LanguageServerProtocol

/// Handles textDocument/rename requests
public struct RenameHandler: Sendable {

    public init() {}

    /// Handle a rename request
    /// Returns a WorkspaceEdit with all text edits needed to rename the symbol
    public func handle(
        uri: String,
        position: Position,
        newName: String,
        content: String,
        compilationResult: CompilationResult?
    ) -> [String: Any]? {
        guard let result = compilationResult else { return nil }

        let aroPosition = PositionConverter.fromLSP(position)

        // Find the symbol name at the position
        var targetName: String?
        var targetSpan: SourceSpan?

        for analyzed in result.analyzedProgram.featureSets {
            let fs = analyzed.featureSet

            for statement in fs.statements {
                if let aro = statement as? AROStatement {
                    // Check result
                    if isPositionInSpan(aroPosition, aro.result.span) {
                        targetName = aro.result.base
                        targetSpan = aro.result.span
                        break
                    }

                    // Check object
                    if isPositionInSpan(aroPosition, aro.object.noun.span) {
                        targetName = aro.object.noun.base
                        targetSpan = aro.object.noun.span
                        break
                    }

                    // Check expression
                    if let expr = aro.valueSource.asExpression {
                        if let (name, span) = findSymbolInExpression(expr, position: aroPosition) {
                            targetName = name
                            targetSpan = span
                            break
                        }
                    }
                }
            }

            if targetName != nil { break }
        }

        guard let symbolName = targetName else { return nil }

        // Find all references to this symbol and create text edits
        var textEdits: [[String: Any]] = []

        for analyzed in result.analyzedProgram.featureSets {
            let fs = analyzed.featureSet

            for statement in fs.statements {
                if let aro = statement as? AROStatement {
                    // Check result
                    if aro.result.base == symbolName {
                        textEdits.append(createTextEdit(span: aro.result.span, newText: newName))
                    }

                    // Check object
                    if aro.object.noun.base == symbolName {
                        textEdits.append(createTextEdit(span: aro.object.noun.span, newText: newName))
                    }

                    // Check expression
                    if let expr = aro.valueSource.asExpression {
                        textEdits.append(contentsOf: findEditsInExpression(expr, name: symbolName, newName: newName))
                    }

                    // Check where clause
                    if let whereClause = aro.queryModifiers.whereClause {
                        textEdits.append(contentsOf: findEditsInExpression(whereClause.value, name: symbolName, newName: newName))
                    }
                }

                if let publish = statement as? PublishStatement {
                    if publish.internalVariable == symbolName {
                        // For publish statements, we need to handle differently
                        // since the span covers the whole statement
                        textEdits.append(createTextEdit(span: publish.span, newText: newName))
                    }
                }
            }
        }

        if textEdits.isEmpty {
            return nil
        }

        // Return WorkspaceEdit format
        return [
            "changes": [
                uri: textEdits
            ]
        ]
    }

    // MARK: - Expression Traversal

    private func findSymbolInExpression(_ expression: any AROParser.Expression, position: SourceLocation) -> (String, SourceSpan)? {
        if let varRef = expression as? VariableRefExpression {
            if isPositionInSpan(position, varRef.span) {
                return (varRef.noun.base, varRef.span)
            }
        } else if let binary = expression as? BinaryExpression {
            if let result = findSymbolInExpression(binary.left, position: position) {
                return result
            }
            if let result = findSymbolInExpression(binary.right, position: position) {
                return result
            }
        } else if let unary = expression as? UnaryExpression {
            if let result = findSymbolInExpression(unary.operand, position: position) {
                return result
            }
        } else if let member = expression as? MemberAccessExpression {
            if let result = findSymbolInExpression(member.base, position: position) {
                return result
            }
        } else if let subscript_ = expression as? SubscriptExpression {
            if let result = findSymbolInExpression(subscript_.base, position: position) {
                return result
            }
            if let result = findSymbolInExpression(subscript_.index, position: position) {
                return result
            }
        }

        return nil
    }

    private func findEditsInExpression(_ expression: any AROParser.Expression, name: String, newName: String) -> [[String: Any]] {
        var edits: [[String: Any]] = []

        if let varRef = expression as? VariableRefExpression {
            if varRef.noun.base == name {
                edits.append(createTextEdit(span: varRef.span, newText: newName))
            }
        } else if let binary = expression as? BinaryExpression {
            edits.append(contentsOf: findEditsInExpression(binary.left, name: name, newName: newName))
            edits.append(contentsOf: findEditsInExpression(binary.right, name: name, newName: newName))
        } else if let unary = expression as? UnaryExpression {
            edits.append(contentsOf: findEditsInExpression(unary.operand, name: name, newName: newName))
        } else if let member = expression as? MemberAccessExpression {
            edits.append(contentsOf: findEditsInExpression(member.base, name: name, newName: newName))
        } else if let subscript_ = expression as? SubscriptExpression {
            edits.append(contentsOf: findEditsInExpression(subscript_.base, name: name, newName: newName))
            edits.append(contentsOf: findEditsInExpression(subscript_.index, name: name, newName: newName))
        } else if let array = expression as? ArrayLiteralExpression {
            for element in array.elements {
                edits.append(contentsOf: findEditsInExpression(element, name: name, newName: newName))
            }
        } else if let map = expression as? MapLiteralExpression {
            for entry in map.entries {
                edits.append(contentsOf: findEditsInExpression(entry.value, name: name, newName: newName))
            }
        }

        return edits
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

    private func createTextEdit(span: SourceSpan, newText: String) -> [String: Any] {
        let lspRange = PositionConverter.toLSP(span)

        return [
            "range": [
                "start": ["line": lspRange.start.line, "character": lspRange.start.character],
                "end": ["line": lspRange.end.line, "character": lspRange.end.character]
            ],
            "newText": newText
        ]
    }
}

#endif
