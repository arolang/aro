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

            // Check feature set header
            if isPositionInSpan(aroPosition, fs.span) {
                // Check if on the name portion
                let hoverContent = formatFeatureSetHover(fs, analyzed: analyzed)
                return createHoverResponse(hoverContent, range: fs.span)
            }

            // Check statements
            for statement in fs.statements {
                if let aro = statement as? AROStatement {
                    if isPositionInSpan(aroPosition, aro.span) {
                        // Check action
                        if isPositionInSpan(aroPosition, aro.action.span) {
                            let hoverContent = formatActionHover(aro.action)
                            return createHoverResponse(hoverContent, range: aro.action.span)
                        }

                        // Check result
                        if isPositionInSpan(aroPosition, aro.result.span) {
                            let symbol = analyzed.symbolTable.lookup(aro.result.base)
                            let hoverContent = formatVariableHover(aro.result.base, symbol: symbol, isResult: true)
                            return createHoverResponse(hoverContent, range: aro.result.span)
                        }

                        // Check object
                        if isPositionInSpan(aroPosition, aro.object.noun.span) {
                            let objectName = aro.object.noun.base
                            let symbol = analyzed.symbolTable.lookup(objectName)
                            let hoverContent = formatVariableHover(objectName, symbol: symbol, isResult: false)
                            return createHoverResponse(hoverContent, range: aro.object.noun.span)
                        }
                    }
                }
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

    private func formatActionHover(_ action: Action) -> String {
        var content = "### Action\n\n"
        content += "**Verb**: `\(action.verb)`\n\n"
        content += "**Semantic Role**: \(action.semanticRole.rawValue)\n\n"

        // Add description based on semantic role
        switch action.semanticRole {
        case .request:
            content += "Extracts or retrieves data from external sources."
        case .own:
            content += "Processes or transforms data internally."
        case .response:
            content += "Returns data or produces output."
        case .export:
            content += "Exports data to external systems or makes it globally available."
        }

        return content
    }

    private func formatVariableHover(_ name: String, symbol: Symbol?, isResult: Bool) -> String {
        var content = isResult ? "### Result\n\n" : "### Object\n\n"
        content += "**Name**: `\(name)`\n\n"

        if let symbol = symbol {
            let typeStr = symbol.dataType?.description ?? "Unknown"
            content += "**Type**: \(typeStr)\n\n"
            content += "**Visibility**: \(symbol.visibility.rawValue)\n\n"
            content += "**Source**: \(symbol.source)\n\n"
            content += "**Defined at**: \(symbol.definedAt)\n"
        } else {
            content += "*Symbol not found in current scope*"
        }

        return content
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
