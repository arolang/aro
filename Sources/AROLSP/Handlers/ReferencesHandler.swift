// ============================================================
// ReferencesHandler.swift
// AROLSP - Find References Provider
// ============================================================

#if !os(Windows)
import Foundation
import AROParser
import LanguageServerProtocol

/// Handles textDocument/references requests
public struct ReferencesHandler: Sendable {

    public init() {}

    /// Handle a references request
    public func handle(
        uri: String,
        position: Position,
        content: String,
        compilationResult: CompilationResult?
    ) -> [[String: Any]]? {
        guard let result = compilationResult else { return nil }

        let aroPosition = PositionConverter.fromLSP(position)

        // Find the symbol name at the position
        var targetName: String?

        for analyzed in result.analyzedProgram.featureSets {
            let fs = analyzed.featureSet

            for statement in fs.statements {
                if let aro = statement as? AROStatement {
                    // Check result
                    if isPositionInSpan(aroPosition, aro.result.span) {
                        targetName = aro.result.base
                        break
                    }

                    // Check object
                    if isPositionInSpan(aroPosition, aro.object.noun.span) {
                        targetName = aro.object.noun.base
                        break
                    }

                    // Check expression
                    if let expr = aro.expression {
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

        // Find all references to this symbol
        var references: [[String: Any]] = []

        for analyzed in result.analyzedProgram.featureSets {
            let fs = analyzed.featureSet

            for statement in fs.statements {
                if let aro = statement as? AROStatement {
                    // Check result
                    if aro.result.base == symbolName {
                        references.append(createLocationDict(uri: uri, span: aro.result.span))
                    }

                    // Check object
                    if aro.object.noun.base == symbolName {
                        references.append(createLocationDict(uri: uri, span: aro.object.noun.span))
                    }

                    // Check expression
                    if let expr = aro.expression {
                        references.append(contentsOf: findReferencesInExpression(expr, name: symbolName, uri: uri))
                    }

                    // Check where clause
                    if let whereClause = aro.whereClause {
                        references.append(contentsOf: findReferencesInExpression(whereClause.value, name: symbolName, uri: uri))
                    }
                }

                if let publish = statement as? PublishStatement {
                    if publish.internalVariable == symbolName {
                        references.append(createLocationDict(uri: uri, span: publish.span))
                    }
                }
            }
        }

        return references.isEmpty ? nil : references
    }

    // MARK: - Expression Traversal

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

    private func findReferencesInExpression(_ expression: any AROParser.Expression, name: String, uri: String) -> [[String: Any]] {
        var references: [[String: Any]] = []

        if let varRef = expression as? VariableRefExpression {
            if varRef.noun.base == name {
                references.append(createLocationDict(uri: uri, span: varRef.span))
            }
        } else if let binary = expression as? BinaryExpression {
            references.append(contentsOf: findReferencesInExpression(binary.left, name: name, uri: uri))
            references.append(contentsOf: findReferencesInExpression(binary.right, name: name, uri: uri))
        } else if let unary = expression as? UnaryExpression {
            references.append(contentsOf: findReferencesInExpression(unary.operand, name: name, uri: uri))
        } else if let member = expression as? MemberAccessExpression {
            references.append(contentsOf: findReferencesInExpression(member.base, name: name, uri: uri))
        } else if let subscript_ = expression as? SubscriptExpression {
            references.append(contentsOf: findReferencesInExpression(subscript_.base, name: name, uri: uri))
            references.append(contentsOf: findReferencesInExpression(subscript_.index, name: name, uri: uri))
        } else if let array = expression as? ArrayLiteralExpression {
            for element in array.elements {
                references.append(contentsOf: findReferencesInExpression(element, name: name, uri: uri))
            }
        } else if let map = expression as? MapLiteralExpression {
            for entry in map.entries {
                references.append(contentsOf: findReferencesInExpression(entry.value, name: name, uri: uri))
            }
        }

        return references
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

    private func createLocationDict(uri: String, span: SourceSpan) -> [String: Any] {
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
