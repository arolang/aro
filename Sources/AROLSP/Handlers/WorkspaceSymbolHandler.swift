// ============================================================
// WorkspaceSymbolHandler.swift
// AROLSP - Workspace Symbol Provider
// ============================================================

#if !os(Windows)
import Foundation
import AROParser
import LanguageServerProtocol

/// Handles workspace/symbol requests
public struct WorkspaceSymbolHandler: Sendable {

    public init() {}

    /// Handle a workspace symbol request
    /// Returns SymbolInformation array for all matching symbols across the workspace
    public func handle(
        query: String,
        documents: [String: DocumentManager.DocumentState]
    ) -> [[String: Any]] {
        var symbols: [[String: Any]] = []
        let lowercaseQuery = query.lowercased()

        for (uri, state) in documents {
            guard let result = state.compilationResult else { continue }

            for analyzed in result.analyzedProgram.featureSets {
                let fs = analyzed.featureSet

                // Add feature set as a symbol
                let fsName = fs.name
                if query.isEmpty || fsName.lowercased().contains(lowercaseQuery) {
                    symbols.append(createSymbolInfo(
                        name: fsName,
                        kind: 12,  // Function
                        uri: uri,
                        span: fs.span,
                        containerName: fs.businessActivity
                    ))
                }

                // Add published symbols
                for statement in fs.statements {
                    if let publish = statement as? PublishStatement {
                        let symbolName = publish.externalName
                        if query.isEmpty || symbolName.lowercased().contains(lowercaseQuery) {
                            symbols.append(createSymbolInfo(
                                name: symbolName,
                                kind: 14,  // Constant (published/exported)
                                uri: uri,
                                span: publish.span,
                                containerName: fsName
                            ))
                        }
                    }
                }

                // Add symbols from symbol table
                for (name, symbol) in analyzed.symbolTable.symbols {
                    if query.isEmpty || name.lowercased().contains(lowercaseQuery) {
                        symbols.append(createSymbolInfo(
                            name: name,
                            kind: symbolKind(for: symbol),
                            uri: uri,
                            span: symbol.definedAt,
                            containerName: fsName
                        ))
                    }
                }
            }
        }

        return symbols
    }

    // MARK: - Helpers

    private func symbolKind(for symbol: AROParser.Symbol) -> Int {
        switch symbol.source {
        case .extracted:
            return 13  // Variable
        case .computed:
            return 13  // Variable
        case .parameter:
            return 13  // Variable
        case .alias:
            return 14  // Constant
        }
    }

    private func createSymbolInfo(
        name: String,
        kind: Int,
        uri: String,
        span: SourceSpan,
        containerName: String?
    ) -> [String: Any] {
        let lspRange = PositionConverter.toLSP(span)

        var info: [String: Any] = [
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
            info["containerName"] = container
        }

        return info
    }
}

#endif
