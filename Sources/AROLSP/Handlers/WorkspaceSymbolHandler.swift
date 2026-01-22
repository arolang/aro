// ============================================================
// WorkspaceSymbolHandler.swift
// AROLSP - Workspace Symbol Search Provider
// ============================================================

#if !os(Windows)
import Foundation
import AROParser
import LanguageServerProtocol

/// Handles workspace/symbol requests
public struct WorkspaceSymbolHandler: Sendable {

    public init() {}

    /// Handle a workspace symbol request
    public func handle(
        query: String,
        documentManager: DocumentManager
    ) async -> [[String: Any]]? {
        let allDocuments = await documentManager.all()

        if allDocuments.isEmpty {
            return nil
        }

        var symbols: [[String: Any]] = []
        let lowercaseQuery = query.lowercased()

        for (uri, state) in allDocuments {
            guard let result = state.compilationResult else { continue }

            for analyzed in result.analyzedProgram.featureSets {
                let fs = analyzed.featureSet

                // Check feature set name
                if fs.name.lowercased().contains(lowercaseQuery) ||
                   fs.businessActivity.lowercased().contains(lowercaseQuery) {
                    symbols.append(createSymbolInfo(
                        name: fs.name,
                        kind: 12,  // Function
                        uri: uri,
                        span: fs.span,
                        containerName: fs.businessActivity
                    ))
                }

                // Check variables in symbol table
                for (name, symbol) in analyzed.symbolTable.symbols {
                    if name.lowercased().contains(lowercaseQuery) {
                        symbols.append(createSymbolInfo(
                            name: name,
                            kind: 13,  // Variable
                            uri: uri,
                            span: symbol.definedAt,
                            containerName: fs.name
                        ))
                    }
                }

                // Check statements
                for statement in fs.statements {
                    if let aro = statement as? AROStatement {
                        // Check action verb
                        if aro.action.verb.lowercased().contains(lowercaseQuery) {
                            symbols.append(createSymbolInfo(
                                name: aro.action.verb,
                                kind: 6,  // Method
                                uri: uri,
                                span: aro.action.span,
                                containerName: fs.name
                            ))
                        }

                        // Check result name
                        if aro.result.base.lowercased().contains(lowercaseQuery) {
                            symbols.append(createSymbolInfo(
                                name: aro.result.base,
                                kind: 13,  // Variable
                                uri: uri,
                                span: aro.result.span,
                                containerName: fs.name
                            ))
                        }
                    }
                }
            }
        }

        return symbols.isEmpty ? nil : symbols
    }

    // MARK: - Helpers

    private func createSymbolInfo(
        name: String,
        kind: Int,
        uri: String,
        span: SourceSpan,
        containerName: String?
    ) -> [String: Any] {
        let lspRange = PositionConverter.toLSP(span)

        var result: [String: Any] = [
            "name": name,
            "kind": kind,
            "location": [
                "uri": uri,
                "range": [
                    "start": ["line": lspRange.start.line, "character": lspRange.start.character],
                    "end": ["line": lspRange.end.line, "character": lspRange.end.character]
                ]
            ]
        ]

        if let container = containerName {
            result["containerName"] = container
        }

        return result
    }
}

#endif
