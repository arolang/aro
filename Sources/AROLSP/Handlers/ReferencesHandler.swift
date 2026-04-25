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
            if let found = findSymbolNameInStatements(fs.statements, position: aroPosition) {
                targetName = found
                break
            }
        }

        guard let symbolName = targetName else { return nil }

        // Find all references to this symbol
        var references: [[String: Any]] = []

        for analyzed in result.analyzedProgram.featureSets {
            let fs = analyzed.featureSet
            references.append(contentsOf: findReferencesInStatements(fs.statements, name: symbolName, uri: uri))
        }

        return references.isEmpty ? nil : references
    }

    private func findReferencesInStatements(
        _ statements: [Statement],
        name symbolName: String,
        uri: String
    ) -> [[String: Any]] {
        var references: [[String: Any]] = []

        for statement in statements {
            if let aro = statement as? AROStatement {
                if aro.result.base == symbolName {
                    references.append(createLocationDict(uri: uri, span: aro.result.span))
                }
                if aro.object.noun.base == symbolName {
                    references.append(createLocationDict(uri: uri, span: aro.object.noun.span))
                }
                if let expr = aro.valueSource.asExpression {
                    references.append(contentsOf: findReferencesInExpression(expr, name: symbolName, uri: uri))
                }
                if let whereClause = aro.queryModifiers.whereClause {
                    references.append(contentsOf: findReferencesInExpression(whereClause.value, name: symbolName, uri: uri))
                }
            } else if let publish = statement as? PublishStatement {
                if publish.internalVariable == symbolName {
                    references.append(createLocationDict(uri: uri, span: publish.span))
                }
            } else if let forEachLoop = statement as? ForEachLoop {
                references.append(contentsOf: findReferencesInStatements(forEachLoop.body, name: symbolName, uri: uri))
            } else if let rangeLoop = statement as? RangeLoop {
                references.append(contentsOf: findReferencesInStatements(rangeLoop.body, name: symbolName, uri: uri))
            } else if let whileLoop = statement as? WhileLoop {
                references.append(contentsOf: findReferencesInStatements(whileLoop.body, name: symbolName, uri: uri))
            } else if let matchStmt = statement as? MatchStatement {
                for caseClause in matchStmt.cases {
                    references.append(contentsOf: findReferencesInStatements(caseClause.body, name: symbolName, uri: uri))
                }
            } else if let pipeline = statement as? PipelineStatement {
                for stage in pipeline.stages {
                    if stage.result.base == symbolName {
                        references.append(createLocationDict(uri: uri, span: stage.result.span))
                    }
                    if stage.object.noun.base == symbolName {
                        references.append(createLocationDict(uri: uri, span: stage.object.noun.span))
                    }
                    if let expr = stage.valueSource.asExpression {
                        references.append(contentsOf: findReferencesInExpression(expr, name: symbolName, uri: uri))
                    }
                }
            }
        }

        return references
    }

    // MARK: - Statement Traversal

    private func findSymbolNameInStatements(_ statements: [Statement], position: SourceLocation) -> String? {
        for statement in statements {
            if let aro = statement as? AROStatement {
                if isPositionInSpan(position, aro.result.span) { return aro.result.base }
                if isPositionInSpan(position, aro.object.noun.span) { return aro.object.noun.base }
                if let expr = aro.valueSource.asExpression,
                   let name = findSymbolNameInExpression(expr, position: position) { return name }
            } else if let forEachLoop = statement as? ForEachLoop {
                if let name = findSymbolNameInStatements(forEachLoop.body, position: position) { return name }
            } else if let rangeLoop = statement as? RangeLoop {
                if let name = findSymbolNameInStatements(rangeLoop.body, position: position) { return name }
            } else if let whileLoop = statement as? WhileLoop {
                if let name = findSymbolNameInStatements(whileLoop.body, position: position) { return name }
            } else if let matchStmt = statement as? MatchStatement {
                for caseClause in matchStmt.cases {
                    if let name = findSymbolNameInStatements(caseClause.body, position: position) { return name }
                }
            } else if let pipeline = statement as? PipelineStatement {
                for stage in pipeline.stages {
                    if isPositionInSpan(position, stage.result.span) { return stage.result.base }
                    if isPositionInSpan(position, stage.object.noun.span) { return stage.object.noun.base }
                    if let expr = stage.valueSource.asExpression,
                       let name = findSymbolNameInExpression(expr, position: position) { return name }
                }
            }
        }
        return nil
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
