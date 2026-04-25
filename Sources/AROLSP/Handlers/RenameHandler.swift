// ============================================================
// RenameHandler.swift
// AROLSP - Rename Symbol Provider
// ============================================================

#if !os(Windows)
import Foundation
import AROParser
import LanguageServerProtocol

/// Handles textDocument/rename and textDocument/prepareRename requests
public struct RenameHandler: Sendable {

    public init() {}

    /// Handle a prepare rename request
    /// Returns the range and placeholder text for the symbol at the position
    public func prepareRename(
        uri: String,
        position: Position,
        content: String,
        compilationResult: CompilationResult?
    ) -> [String: Any]? {
        guard let result = compilationResult else { return nil }

        let aroPosition = PositionConverter.fromLSP(position)

        for analyzed in result.analyzedProgram.featureSets {
            if let prepareResult = findPrepareRenameInStatements(analyzed.featureSet.statements, position: aroPosition) {
                return prepareResult
            }
        }

        return nil
    }

    private func findPrepareRenameInStatements(
        _ statements: [Statement],
        position: SourceLocation
    ) -> [String: Any]? {
        for statement in statements {
            if let aro = statement as? AROStatement {
                if let result = findPrepareRenameInAROStatement(aro, position: position) {
                    return result
                }
            } else if let forEachLoop = statement as? ForEachLoop {
                if let result = findPrepareRenameInStatements(forEachLoop.body, position: position) { return result }
            } else if let rangeLoop = statement as? RangeLoop {
                if let result = findPrepareRenameInStatements(rangeLoop.body, position: position) { return result }
            } else if let whileLoop = statement as? WhileLoop {
                if let result = findPrepareRenameInStatements(whileLoop.body, position: position) { return result }
            } else if let matchStmt = statement as? MatchStatement {
                for caseClause in matchStmt.cases {
                    if let result = findPrepareRenameInStatements(caseClause.body, position: position) { return result }
                }
            } else if let pipeline = statement as? PipelineStatement {
                for stage in pipeline.stages {
                    if let result = findPrepareRenameInAROStatement(stage, position: position) { return result }
                }
            }
        }
        return nil
    }

    private func findPrepareRenameInAROStatement(_ aro: AROStatement, position: SourceLocation) -> [String: Any]? {
        if isPositionInSpan(position, aro.result.span) {
            let lspRange = PositionConverter.toLSP(aro.result.span)
            return [
                "range": [
                    "start": ["line": lspRange.start.line, "character": lspRange.start.character],
                    "end": ["line": lspRange.end.line, "character": lspRange.end.character]
                ],
                "placeholder": aro.result.base
            ]
        }
        if isPositionInSpan(position, aro.object.noun.span) {
            let lspRange = PositionConverter.toLSP(aro.object.noun.span)
            return [
                "range": [
                    "start": ["line": lspRange.start.line, "character": lspRange.start.character],
                    "end": ["line": lspRange.end.line, "character": lspRange.end.character]
                ],
                "placeholder": aro.object.noun.base
            ]
        }
        if let expr = aro.valueSource.asExpression {
            if let result = findPrepareRenameInExpression(expr, position: position) {
                return result
            }
        }
        return nil
    }

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

        for analyzed in result.analyzedProgram.featureSets {
            if let (name, _) = findSymbolInStatements(analyzed.featureSet.statements, position: aroPosition) {
                targetName = name
                break
            }
        }

        guard let symbolName = targetName else { return nil }

        // Find all references to this symbol and create text edits
        var textEdits: [[String: Any]] = []

        for analyzed in result.analyzedProgram.featureSets {
            textEdits.append(contentsOf: findEditsInStatements(analyzed.featureSet.statements, name: symbolName, newName: newName))
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

    private func findSymbolInStatements(_ statements: [Statement], position: SourceLocation) -> (String, SourceSpan)? {
        for statement in statements {
            if let aro = statement as? AROStatement {
                if isPositionInSpan(position, aro.result.span) { return (aro.result.base, aro.result.span) }
                if isPositionInSpan(position, aro.object.noun.span) { return (aro.object.noun.base, aro.object.noun.span) }
                if let expr = aro.valueSource.asExpression, let result = findSymbolInExpression(expr, position: position) { return result }
            } else if let forEachLoop = statement as? ForEachLoop {
                if let result = findSymbolInStatements(forEachLoop.body, position: position) { return result }
            } else if let rangeLoop = statement as? RangeLoop {
                if let result = findSymbolInStatements(rangeLoop.body, position: position) { return result }
            } else if let whileLoop = statement as? WhileLoop {
                if let result = findSymbolInStatements(whileLoop.body, position: position) { return result }
            } else if let matchStmt = statement as? MatchStatement {
                for caseClause in matchStmt.cases {
                    if let result = findSymbolInStatements(caseClause.body, position: position) { return result }
                }
            } else if let pipeline = statement as? PipelineStatement {
                for stage in pipeline.stages {
                    if isPositionInSpan(position, stage.result.span) { return (stage.result.base, stage.result.span) }
                    if isPositionInSpan(position, stage.object.noun.span) { return (stage.object.noun.base, stage.object.noun.span) }
                    if let expr = stage.valueSource.asExpression, let result = findSymbolInExpression(expr, position: position) { return result }
                }
            }
        }
        return nil
    }

    private func findEditsInStatements(_ statements: [Statement], name: String, newName: String) -> [[String: Any]] {
        var edits: [[String: Any]] = []
        for statement in statements {
            if let aro = statement as? AROStatement {
                edits.append(contentsOf: findEditsInAROStatement(aro, name: name, newName: newName))
            } else if let publish = statement as? PublishStatement {
                if publish.internalVariable == name {
                    edits.append(createTextEdit(span: publish.span, newText: newName))
                }
            } else if let forEachLoop = statement as? ForEachLoop {
                edits.append(contentsOf: findEditsInStatements(forEachLoop.body, name: name, newName: newName))
            } else if let rangeLoop = statement as? RangeLoop {
                edits.append(contentsOf: findEditsInStatements(rangeLoop.body, name: name, newName: newName))
            } else if let whileLoop = statement as? WhileLoop {
                edits.append(contentsOf: findEditsInStatements(whileLoop.body, name: name, newName: newName))
            } else if let matchStmt = statement as? MatchStatement {
                for caseClause in matchStmt.cases {
                    edits.append(contentsOf: findEditsInStatements(caseClause.body, name: name, newName: newName))
                }
            } else if let pipeline = statement as? PipelineStatement {
                for stage in pipeline.stages {
                    edits.append(contentsOf: findEditsInAROStatement(stage, name: name, newName: newName))
                }
            }
        }
        return edits
    }

    private func findEditsInAROStatement(_ aro: AROStatement, name: String, newName: String) -> [[String: Any]] {
        var edits: [[String: Any]] = []
        if aro.result.base == name { edits.append(createTextEdit(span: aro.result.span, newText: newName)) }
        if aro.object.noun.base == name { edits.append(createTextEdit(span: aro.object.noun.span, newText: newName)) }
        if let expr = aro.valueSource.asExpression { edits.append(contentsOf: findEditsInExpression(expr, name: name, newName: newName)) }
        if let whereClause = aro.queryModifiers.whereClause { edits.append(contentsOf: findEditsInExpression(whereClause.value, name: name, newName: newName)) }
        return edits
    }

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
            "newText": "<\(newText)>"
        ]
    }
}

#endif
