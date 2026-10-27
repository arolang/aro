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

        let lines = LineIndex(content)
        let aroPosition = PositionConverter.fromLSP(position, using: lines)

        for analyzed in result.analyzedProgram.featureSets {
            if let prepareResult = findPrepareRenameInStatements(analyzed.featureSet.statements, position: aroPosition, lines: lines) {
                return prepareResult
            }
        }

        return nil
    }

    private func findPrepareRenameInStatements(
        _ statements: [Statement],
        position: SourceLocation,
        lines: LineIndex
    ) -> [String: Any]? {
        // GitLab #723: what counts as "inside a feature set" is the shared
        // walker's answer, not a private `as?` chain's. The chain that stood
        // here knew about loops, match cases and pipeline stages but not
        // about `when { … }` or a match's `otherwise`, so a name that
        // appeared only there could not be renamed at all — the request
        // returned nothing and the editor said the symbol could not be
        // renamed.
        for aro in AROStatementWalk.flatten(statements) {
            if let result = findPrepareRenameInAROStatement(aro, position: position, lines: lines) {
                return result
            }
        }
        return nil
    }

    private func findPrepareRenameInAROStatement(_ aro: AROStatement, position: SourceLocation, lines: LineIndex) -> [String: Any]? {
        if aro.result.span.contains(position) {
            let lspRange = PositionConverter.toLSP(aro.result.span, using: lines)
            return [
                "range": [
                    "start": ["line": lspRange.start.line, "character": lspRange.start.character],
                    "end": ["line": lspRange.end.line, "character": lspRange.end.character]
                ],
                "placeholder": aro.result.base
            ]
        }
        if aro.object.noun.span.contains(position) {
            let lspRange = PositionConverter.toLSP(aro.object.noun.span, using: lines)
            return [
                "range": [
                    "start": ["line": lspRange.start.line, "character": lspRange.start.character],
                    "end": ["line": lspRange.end.line, "character": lspRange.end.character]
                ],
                "placeholder": aro.object.noun.base
            ]
        }
        if let expr = aro.valueSource.asExpression {
            if let result = findPrepareRenameInExpression(expr, position: position, lines: lines) {
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

        let lines = LineIndex(content)
        let aroPosition = PositionConverter.fromLSP(position, using: lines)

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
            textEdits.append(contentsOf: findEditsInStatements(analyzed.featureSet.statements, name: symbolName, newName: newName, lines: lines))
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
        position: SourceLocation,
        lines: LineIndex
    ) -> [String: Any]? {
        if let varRef = expression as? VariableRefExpression {
            if varRef.span.contains(position) {
                let lspRange = PositionConverter.toLSP(varRef.span, using: lines)
                return [
                    "range": [
                        "start": ["line": lspRange.start.line, "character": lspRange.start.character],
                        "end": ["line": lspRange.end.line, "character": lspRange.end.character]
                    ],
                    "placeholder": varRef.noun.base
                ]
            }
        } else if let binary = expression as? BinaryExpression {
            if let result = findPrepareRenameInExpression(binary.left, position: position, lines: lines) {
                return result
            }
            if let result = findPrepareRenameInExpression(binary.right, position: position, lines: lines) {
                return result
            }
        } else if let unary = expression as? UnaryExpression {
            if let result = findPrepareRenameInExpression(unary.operand, position: position, lines: lines) {
                return result
            }
        } else if let member = expression as? MemberAccessExpression {
            if let result = findPrepareRenameInExpression(member.base, position: position, lines: lines) {
                return result
            }
        } else if let subscript_ = expression as? SubscriptExpression {
            if let result = findPrepareRenameInExpression(subscript_.base, position: position, lines: lines) {
                return result
            }
            if let result = findPrepareRenameInExpression(subscript_.index, position: position, lines: lines) {
                return result
            }
        }

        return nil
    }

    private func findSymbolInStatements(_ statements: [Statement], position: SourceLocation) -> (String, SourceSpan)? {
        // A pipeline stage *is* an `AROStatement`, which is why the old
        // chain's stage branch was a copy of its own first branch. The walker
        // yields stages as the statements they are, so there is one branch
        // again (GitLab #723).
        for aro in AROStatementWalk.flatten(statements) {
            if aro.result.span.contains(position) { return (aro.result.base, aro.result.span) }
            if aro.object.noun.span.contains(position) { return (aro.object.noun.base, aro.object.noun.span) }
            if let expr = aro.valueSource.asExpression, let result = findSymbolInExpression(expr, position: position) { return result }
        }
        return nil
    }

    private func findEditsInStatements(_ statements: [Statement], name: String, newName: String, lines: LineIndex) -> [[String: Any]] {
        // `flattenAll` rather than `flatten`, because a rename has to touch
        // `Publish as <alias> <variable>` too, and that is not an action
        // (GitLab #723). Container nodes come through as well and are
        // ignored here; the statements they hold arrive on their own.
        var edits: [[String: Any]] = []
        for statement in AROStatementWalk.flattenAll(statements) {
            if let aro = statement as? AROStatement {
                edits.append(contentsOf: findEditsInAROStatement(aro, name: name, newName: newName, lines: lines))
            } else if let publish = statement as? PublishStatement {
                if publish.internalVariable == name {
                    edits.append(createTextEdit(span: publish.span, newText: newName, lines: lines))
                }
            }
        }
        return edits
    }

    private func findEditsInAROStatement(_ aro: AROStatement, name: String, newName: String, lines: LineIndex) -> [[String: Any]] {
        var edits: [[String: Any]] = []
        if aro.result.base == name { edits.append(createTextEdit(span: aro.result.span, newText: newName, lines: lines)) }
        if aro.object.noun.base == name { edits.append(createTextEdit(span: aro.object.noun.span, newText: newName, lines: lines)) }
        if let expr = aro.valueSource.asExpression { edits.append(contentsOf: findEditsInExpression(expr, name: name, newName: newName, lines: lines)) }
        for predicate in aro.queryModifiers.whereCondition?.predicates ?? [] { edits.append(contentsOf: findEditsInExpression(predicate.value, name: name, newName: newName, lines: lines)) }
        return edits
    }

    private func findSymbolInExpression(_ expression: any AROParser.Expression, position: SourceLocation) -> (String, SourceSpan)? {
        if let varRef = expression as? VariableRefExpression {
            if varRef.span.contains(position) {
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

    private func findEditsInExpression(_ expression: any AROParser.Expression, name: String, newName: String, lines: LineIndex) -> [[String: Any]] {
        var edits: [[String: Any]] = []

        if let varRef = expression as? VariableRefExpression {
            if varRef.noun.base == name {
                edits.append(createTextEdit(span: varRef.span, newText: newName, lines: lines))
            }
        } else if let binary = expression as? BinaryExpression {
            edits.append(contentsOf: findEditsInExpression(binary.left, name: name, newName: newName, lines: lines))
            edits.append(contentsOf: findEditsInExpression(binary.right, name: name, newName: newName, lines: lines))
        } else if let unary = expression as? UnaryExpression {
            edits.append(contentsOf: findEditsInExpression(unary.operand, name: name, newName: newName, lines: lines))
        } else if let member = expression as? MemberAccessExpression {
            edits.append(contentsOf: findEditsInExpression(member.base, name: name, newName: newName, lines: lines))
        } else if let subscript_ = expression as? SubscriptExpression {
            edits.append(contentsOf: findEditsInExpression(subscript_.base, name: name, newName: newName, lines: lines))
            edits.append(contentsOf: findEditsInExpression(subscript_.index, name: name, newName: newName, lines: lines))
        } else if let array = expression as? ArrayLiteralExpression {
            for element in array.elements {
                edits.append(contentsOf: findEditsInExpression(element, name: name, newName: newName, lines: lines))
            }
        } else if let map = expression as? MapLiteralExpression {
            for entry in map.entries {
                edits.append(contentsOf: findEditsInExpression(entry.value, name: name, newName: newName, lines: lines))
            }
        }

        return edits
    }

    // MARK: - Helpers

    private func createTextEdit(span: SourceSpan, newText: String, lines: LineIndex) -> [String: Any] {
        let lspRange = PositionConverter.toLSP(span, using: lines)

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
