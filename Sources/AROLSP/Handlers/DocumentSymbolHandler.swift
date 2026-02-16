// ============================================================
// DocumentSymbolHandler.swift
// AROLSP - Document Symbol Provider (Outline)
// ============================================================

#if !os(Windows)
import Foundation
import AROParser
import LanguageServerProtocol

/// Handles textDocument/documentSymbol requests
public struct DocumentSymbolHandler: Sendable {

    public init() {}

    /// Handle a document symbol request
    public func handle(compilationResult: CompilationResult?) -> [[String: Any]]? {
        guard let result = compilationResult else { return nil }

        var symbols: [[String: Any]] = []

        for analyzed in result.analyzedProgram.featureSets {
            let fs = analyzed.featureSet
            let fsRange = PositionConverter.toLSP(fs.span)

            // Create feature set symbol
            var fsSymbol: [String: Any] = [
                "name": fs.name,
                "detail": fs.businessActivity,
                "kind": 12,  // SymbolKind.Function
                "range": rangeToDict(fsRange),
                "selectionRange": rangeToDict(fsRange)
            ]

            // Add child symbols for statements
            var children: [[String: Any]] = []

            for statement in fs.statements {
                if let aro = statement as? AROStatement {
                    let stmtRange = PositionConverter.toLSP(aro.span)

                    // Determine symbol kind based on action semantic role
                    let kind: Int
                    switch aro.action.semanticRole {
                    case .request:
                        kind = 24  // Event
                    case .own:
                        kind = 6   // Method
                    case .response:
                        kind = 23  // Operator
                    case .export:
                        kind = 9   // Module
                    case .server:
                        kind = 25  // TypeParameter (server/service ops)
                    }

                    let stmtSymbol: [String: Any] = [
                        "name": "<\(aro.action.verb)> \(aro.result.base)",
                        "detail": formatStatementDetail(aro),
                        "kind": kind,
                        "range": rangeToDict(stmtRange),
                        "selectionRange": rangeToDict(PositionConverter.toLSP(aro.action.span))
                    ]

                    children.append(stmtSymbol)
                } else if let publish = statement as? PublishStatement {
                    let publishRange = PositionConverter.toLSP(publish.span)

                    let publishSymbol: [String: Any] = [
                        "name": "<Publish> \(publish.externalName)",
                        "detail": "alias of \(publish.internalVariable)",
                        "kind": 8,  // Field
                        "range": rangeToDict(publishRange),
                        "selectionRange": rangeToDict(publishRange)
                    ]

                    children.append(publishSymbol)
                } else if let matchStmt = statement as? MatchStatement {
                    let matchRange = PositionConverter.toLSP(matchStmt.span)

                    let matchSymbol: [String: Any] = [
                        "name": "match",
                        "detail": "\(matchStmt.cases.count) cases",
                        "kind": 25,  // TypeParameter
                        "range": rangeToDict(matchRange),
                        "selectionRange": rangeToDict(matchRange)
                    ]

                    children.append(matchSymbol)
                } else if let forEachStmt = statement as? ForEachLoop {
                    let forRange = PositionConverter.toLSP(forEachStmt.span)

                    let forSymbol: [String: Any] = [
                        "name": "for each \(forEachStmt.itemVariable)",
                        "detail": "in \(forEachStmt.collection.base)",
                        "kind": 26,  // Struct
                        "range": rangeToDict(forRange),
                        "selectionRange": rangeToDict(forRange)
                    ]

                    children.append(forSymbol)
                }
            }

            if !children.isEmpty {
                fsSymbol["children"] = children
            }

            symbols.append(fsSymbol)
        }

        return symbols
    }

    // MARK: - Helpers

    private func formatStatementDetail(_ statement: AROStatement) -> String {
        var parts: [String] = []

        // Add preposition and object
        parts.append("\(statement.object.preposition.rawValue) \(statement.object.noun.base)")

        // Add type annotation if present
        if let typeAnnotation = statement.result.typeAnnotation {
            parts.insert("(\(typeAnnotation))", at: 0)
        }

        return parts.joined(separator: " ")
    }

    private func rangeToDict(_ range: LSPRange) -> [String: Any] {
        return [
            "start": ["line": range.start.line, "character": range.start.character],
            "end": ["line": range.end.line, "character": range.end.character]
        ]
    }
}

#endif
