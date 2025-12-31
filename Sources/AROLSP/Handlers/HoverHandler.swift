// ============================================================
// HoverHandler.swift
// AROLSP - Hover Information Provider
// ============================================================

#if !os(Windows)
import Foundation
import AROParser
import LanguageServerProtocol

/// Handles textDocument/hover requests
public struct HoverHandler: Sendable {

    public init() {}

    /// Handle a hover request
    public func handle(
        position: Position,
        content: String,
        compilationResult: CompilationResult?
    ) -> [String: Any]? {
        guard let result = compilationResult else { return nil }

        let aroPosition = PositionConverter.fromLSP(position)

        // Try to find what's at this position
        // 1. Check if it's inside a feature set name
        // 2. Check if it's on an action
        // 3. Check if it's on a variable reference

        for analyzed in result.analyzedProgram.featureSets {
            let fs = analyzed.featureSet

            // Check statements first (more specific)
            for statement in fs.statements {
                if let aro = statement as? AROStatement {
                    if isPositionInSpan(aroPosition, aro.span) {
                        // Check action
                        if isPositionInSpan(aroPosition, aro.action.span) {
                            let hoverContent = formatActionHover(aro.action, statement: aro, featureSet: fs, analyzed: analyzed)
                            return createHoverResponse(hoverContent, range: aro.action.span)
                        }

                        // Check result
                        if isPositionInSpan(aroPosition, aro.result.span) {
                            let symbol = analyzed.symbolTable.lookup(aro.result.base)
                            let hoverContent = formatVariableHover(
                                aro.result.base,
                                symbol: symbol,
                                isResult: true,
                                statement: aro,
                                featureSet: fs,
                                analyzed: analyzed
                            )
                            return createHoverResponse(hoverContent, range: aro.result.span)
                        }

                        // Check object
                        if isPositionInSpan(aroPosition, aro.object.noun.span) {
                            let objectName = aro.object.noun.base
                            let symbol = analyzed.symbolTable.lookup(objectName)
                            let hoverContent = formatVariableHover(
                                objectName,
                                symbol: symbol,
                                isResult: false,
                                statement: aro,
                                featureSet: fs,
                                analyzed: analyzed
                            )
                            return createHoverResponse(hoverContent, range: aro.object.noun.span)
                        }

                        // Check preposition
                        if isPositionInSpan(aroPosition, aro.object.preposition.span) {
                            let hoverContent = formatPrepositionHover(aro.object.preposition, statement: aro)
                            return createHoverResponse(hoverContent, range: aro.object.preposition.span)
                        }
                    }
                }
            }

            // Check feature set header (less specific, only if not in statements)
            // Only match on the first line (feature set declaration)
            if aroPosition.line == fs.span.start.line &&
               aroPosition.line < (fs.statements.first?.span.start.line ?? Int.max) {
                let hoverContent = formatFeatureSetHover(fs, analyzed: analyzed)
                return createHoverResponse(hoverContent, range: fs.span)
            }
        }

        return nil
    }

    // MARK: - Position Helpers

    private func isPositionInSpan(_ position: SourceLocation, _ span: SourceSpan) -> Bool {
        // Check if position is within span
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

    // MARK: - Hover Content Formatting

    private func formatFeatureSetHover(_ fs: FeatureSet, analyzed: AnalyzedFeatureSet) -> String {
        var content = "### Feature Set\n\n"
        content += "**Name**: `\(fs.name)`\n\n"
        content += "**Business Activity**: \(fs.businessActivity)\n\n"
        content += "**Statements**: \(fs.statements.count)\n\n"

        // Show symbols
        let symbols = analyzed.symbolTable.symbols
        if !symbols.isEmpty {
            content += "**Variables**:\n"
            for (name, symbol) in symbols.sorted(by: { $0.key < $1.key }) {
                let typeStr = symbol.dataType?.description ?? "Unknown"
                content += "- `\(name)`: \(typeStr) (\(symbol.source))\n"
            }
        }

        return content
    }

    private func formatActionHover(_ action: Action, statement: AROStatement, featureSet: FeatureSet, analyzed: AnalyzedFeatureSet) -> String {
        var content = "### Action: `\(action.verb)`\n\n"

        // Show the full statement for context
        content += "```aro\n"
        content += formatStatement(statement)
        content += "\n```\n\n"

        content += "**Semantic Role**: \(action.semanticRole.rawValue)\n\n"

        // Add description based on semantic role
        switch action.semanticRole {
        case .request:
            content += "*Extracts or retrieves data from external sources*\n\n"
        case .own:
            content += "*Processes or transforms data internally*\n\n"
        case .response:
            content += "*Returns data or produces output*\n\n"
        case .export:
            content += "*Exports data or makes it globally available*\n\n"
        }

        // Show context
        content += "**Feature Set**: `\(featureSet.name)`\n\n"
        content += "**Business Activity**: \(featureSet.businessActivity)\n"

        return content
    }

    private func formatVariableHover(_ name: String, symbol: Symbol?, isResult: Bool, statement: AROStatement, featureSet: FeatureSet, analyzed: AnalyzedFeatureSet) -> String {
        var content = isResult ? "### Result: `\(name)`\n\n" : "### Object: `\(name)`\n\n"

        // Show the full statement for context
        content += "```aro\n"
        content += formatStatement(statement)
        content += "\n```\n\n"

        if let symbol = symbol {
            let typeStr = symbol.dataType?.description ?? "Unknown"
            content += "**Type**: \(typeStr)\n\n"
            content += "**Visibility**: \(symbol.visibility.rawValue)\n\n"
            content += "**Source**: \(symbol.source)\n\n"
            content += "**Defined at**: Line \(symbol.definedAt.line)\n\n"

            // Show usage information
            if isResult {
                content += "**Role**: Result of this action\n\n"
            } else {
                content += "**Role**: Input/target object\n\n"
            }
        } else {
            content += "*Symbol not found in current scope*\n\n"
        }

        // Show context
        content += "**Feature Set**: `\(featureSet.name)`\n\n"
        content += "**Business Activity**: \(featureSet.businessActivity)\n"

        return content
    }

    private func formatPrepositionHover(_ preposition: Preposition, statement: AROStatement) -> String {
        var content = "### Preposition: `\(preposition.rawValue)`\n\n"

        // Show the full statement for context
        content += "```aro\n"
        content += formatStatement(statement)
        content += "\n```\n\n"

        // Describe the preposition's role
        switch preposition {
        case .from:
            content += "*Indicates the source or origin of data*"
        case .to:
            content += "*Indicates the destination or target*"
        case .with:
            content += "*Specifies a parameter or accompanying data*"
        case .for:
            content += "*Indicates the purpose or beneficiary*"
        case .into:
            content += "*Indicates transformation or insertion*"
        case .on:
            content += "*Indicates a subject or location*"
        case .where:
            content += "*Introduces a condition or filter*"
        }

        return content
    }

    private func formatStatement(_ statement: AROStatement) -> String {
        var result = "<\(statement.action.verb)> "

        // Add article if present
        if let article = statement.result.article {
            result += "\(article.rawValue) "
        }

        result += "<\(statement.result.base)"
        if let qualifier = statement.result.qualifier {
            result += ": \(qualifier)"
        }
        result += ">"

        result += " \(statement.object.preposition.rawValue) "

        if let article = statement.object.article {
            result += "\(article.rawValue) "
        }

        result += "<\(statement.object.noun.base)"
        if let qualifier = statement.object.noun.qualifier {
            result += ": \(qualifier)"
        }
        result += ">"

        // Add literal value if present
        if let literal = statement.object.literalValue {
            result += " with "
            if let stringLit = literal as? StringLiteral {
                result += "\"\(stringLit.value)\""
            } else if let numLit = literal as? NumericLiteral {
                result += "\(numLit.value)"
            }
        }

        result += "."

        return result
    }

    // MARK: - Response Creation

    private func createHoverResponse(_ content: String, range: SourceSpan) -> [String: Any] {
        let lspRange = PositionConverter.toLSP(range)

        return [
            "contents": [
                "kind": "markdown",
                "value": content
            ],
            "range": [
                "start": ["line": lspRange.start.line, "character": lspRange.start.character],
                "end": ["line": lspRange.end.line, "character": lspRange.end.character]
            ]
        ]
    }
}

#endif
