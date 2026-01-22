// ============================================================
// RenameHandler.swift
// AROLSP - Symbol Rename Provider
// ============================================================

#if !os(Windows)
import Foundation
import AROParser
import LanguageServerProtocol

/// Handles textDocument/rename and textDocument/prepareRename requests
public struct RenameHandler: Sendable {

    public init() {}

    /// Handle a prepare rename request
    public func prepareRename(
        uri: String,
        position: Position,
        content: String,
        compilationResult: CompilationResult?
    ) -> [String: Any]? {
        guard let result = compilationResult else { return nil }

        let aroPosition = PositionConverter.fromLSP(position)

        // Find the symbol at the position
        for analyzed in result.analyzedProgram.featureSets {
            let fs = analyzed.featureSet

            for statement in fs.statements {
                if let aro = statement as? AROStatement {
                    // Check result
                    if isPositionInSpan(aroPosition, aro.result.span) {
                        let name = aro.result.base
                        let lspRange = PositionConverter.toLSP(aro.result.span)
                        return [
                            "range": [
                                "start": ["line": lspRange.start.line, "character": lspRange.start.character],
                                "end": ["line": lspRange.end.line, "character": lspRange.end.character]
                            ],
                            "placeholder": name
                        ]
                    }

                    // Check object
                    if isPositionInSpan(aroPosition, aro.object.noun.span) {
                        let name = aro.object.noun.base
                        let lspRange = PositionConverter.toLSP(aro.object.noun.span)
                        return [
                            "range": [
                                "start": ["line": lspRange.start.line, "character": lspRange.start.character],
                                "end": ["line": lspRange.end.line, "character": lspRange.end.character]
                            ],
                            "placeholder": name
                        ]
                    }

                    // Check expression
                    if let expr = aro.valueSource.asExpression {
                        if let prepareResult = findPrepareRenameInExpression(expr, position: aroPosition) {
                            return prepareResult
                        }
                    }
                }
            }
        }

        return nil
    }

    /// Handle a rename request
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

        for analyzed in result.analyzedProgram.featureSets {
            let fs = analyzed.featureSet

            for statement in fs.statements {
                if let aro = statement as? AROStatement {
                    if isPositionInSpan(aroPosition, aro.result.span) {
                        targetName = aro.result.base
                        break
                    }

                    if isPositionInSpan(aroPosition, aro.object.noun.span) {
                        targetName = aro.object.noun.base
                        break
                    }

                    if let expr = aro.valueSource.asExpression {
                        if let name = findSymbolNameInExpression(expr, position: aroPosition) {
                            targetName = name
                            break
                        }
                    }
                }
            }

            if targetName != nil { break }
        }

        guard let symbolName = targetName else { return nil }

        // Collect all edits for this symbol
        var edits: [[String: Any]] = []

        for analyzed in result.analyzedProgram.featureSets {
            let fs = analyzed.featureSet

            for statement in fs.statements {
                if let aro = statement as? AROStatement {
                    // Check result
                    if aro.result.base == symbolName {
                        edits.append(createTextEdit(span: aro.result.span, newText: newName, content: content))
                    }

                    // Check object
                    if aro.object.noun.base == symbolName {
                        edits.append(createTextEdit(span: aro.object.noun.span, newText: newName, content: content))
                    }

                    // Check expression
                    if let expr = aro.valueSource.asExpression {
                        edits.append(contentsOf: findRenameEditsInExpression(expr, name: symbolName, newName: newName, content: content))
                    }

                    // Check where clause
                    if let whereClause = aro.queryModifiers.whereClause {
                        edits.append(contentsOf: findRenameEditsInExpression(whereClause.value, name: symbolName, newName: newName, content: content))
                    }
                }

                if let publish = statement as? PublishStatement {
                    if publish.internalVariable == symbolName {
                        edits.append(createTextEdit(span: publish.span, newText: newName, content: content))
                    }
                }
            }
        }

        if edits.isEmpty {
            return nil
        }

        return [
            "changes": [
                uri: edits
            ]
        ]
    }

    // MARK: - Expression Traversal

    private func findPrepareRenameInExpression(
        _ expression: any AROParser.Expression,
        position: SourceLocation
    ) -> [String: Any]? {
        if let varRef = expression as? VariableRefExpression {
            if isPositionInSpan(position, varRef.span) {
                let lspRange = PositionConverter.toLSP(varRef.span)
                return [
                    "range": [
                        "start": ["line": lspRange.start.line, "character": lspRange.start.character],
                        "end": ["line": lspRange.end.line, "character": lspRange.end.character]
                    ],
                    "placeholder": varRef.noun.base
                ]
            }
        } else if let binary = expression as? BinaryExpression {
            if let result = findPrepareRenameInExpression(binary.left, position: position) {
                return result
            }
            if let result = findPrepareRenameInExpression(binary.right, position: position) {
                return result
            }
        } else if let unary = expression as? UnaryExpression {
            if let result = findPrepareRenameInExpression(unary.operand, position: position) {
                return result
            }
        } else if let member = expression as? MemberAccessExpression {
            if let result = findPrepareRenameInExpression(member.base, position: position) {
                return result
            }
        } else if let subscript_ = expression as? SubscriptExpression {
            if let result = findPrepareRenameInExpression(subscript_.base, position: position) {
                return result
            }
            if let result = findPrepareRenameInExpression(subscript_.index, position: position) {
                return result
            }
        }

        return nil
    }

    private func findSymbolNameInExpression(_ expression: any AROParser.Expression, position: SourceLocation) -> String? {
        if let varRef = expression as? VariableRefExpression {
            if isPositionInSpan(position, varRef.span) {
                return varRef.noun.base
            }
        } else if let binary = expression as? BinaryExpression {
            if let name = findSymbolNameInExpression(binary.left, position: position) {
                return name
            }
            if let name = findSymbolNameInExpression(binary.right, position: position) {
                return name
            }
        } else if let unary = expression as? UnaryExpression {
            if let name = findSymbolNameInExpression(unary.operand, position: position) {
                return name
            }
        } else if let member = expression as? MemberAccessExpression {
            if let name = findSymbolNameInExpression(member.base, position: position) {
                return name
            }
        } else if let subscript_ = expression as? SubscriptExpression {
            if let name = findSymbolNameInExpression(subscript_.base, position: position) {
                return name
            }
            if let name = findSymbolNameInExpression(subscript_.index, position: position) {
                return name
            }
        }

        return nil
    }

    private func findRenameEditsInExpression(
        _ expression: any AROParser.Expression,
        name: String,
        newName: String,
        content: String
    ) -> [[String: Any]] {
        var edits: [[String: Any]] = []

        if let varRef = expression as? VariableRefExpression {
            if varRef.noun.base == name {
                edits.append(createTextEdit(span: varRef.span, newText: newName, content: content))
            }
        } else if let binary = expression as? BinaryExpression {
            edits.append(contentsOf: findRenameEditsInExpression(binary.left, name: name, newName: newName, content: content))
            edits.append(contentsOf: findRenameEditsInExpression(binary.right, name: name, newName: newName, content: content))
        } else if let unary = expression as? UnaryExpression {
            edits.append(contentsOf: findRenameEditsInExpression(unary.operand, name: name, newName: newName, content: content))
        } else if let member = expression as? MemberAccessExpression {
            edits.append(contentsOf: findRenameEditsInExpression(member.base, name: name, newName: newName, content: content))
        } else if let subscript_ = expression as? SubscriptExpression {
            edits.append(contentsOf: findRenameEditsInExpression(subscript_.base, name: name, newName: newName, content: content))
            edits.append(contentsOf: findRenameEditsInExpression(subscript_.index, name: name, newName: newName, content: content))
        } else if let array = expression as? ArrayLiteralExpression {
            for element in array.elements {
                edits.append(contentsOf: findRenameEditsInExpression(element, name: name, newName: newName, content: content))
            }
        } else if let map = expression as? MapLiteralExpression {
            for entry in map.entries {
                edits.append(contentsOf: findRenameEditsInExpression(entry.value, name: name, newName: newName, content: content))
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

    private func createTextEdit(span: SourceSpan, newText: String, content: String) -> [String: Any] {
        let lspRange = PositionConverter.toLSP(span)

        return [
            "range": [
                "start": ["line": lspRange.start.line, "character": lspRange.start.character],
                "end": ["line": lspRange.end.line, "character": lspRange.end.character]
            ],
            "newText": "<\(newText)>"
        ]
    }
}

#endif
