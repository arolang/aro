// ============================================================
// DiagnosticsHandler.swift
// AROLSP - Convert ARO diagnostics to LSP diagnostics
// ============================================================

#if !os(Windows)
import Foundation
import AROParser
import LanguageServerProtocol

/// Handles conversion of ARO diagnostics to LSP format
public struct DiagnosticsHandler: Sendable {

    public init() {}

    /// Convert ARO diagnostics to LSP diagnostic dictionaries
    public func convert(_ diagnostics: [AROParser.Diagnostic]) -> [[String: Any]] {
        diagnostics.compactMap { convertOne($0) }
    }

    private func convertOne(_ diagnostic: AROParser.Diagnostic) -> [String: Any]? {
        let range: [String: Any]
        if let location = diagnostic.location {
            // Create a range from the location (single character for point diagnostics)
            let startPos = PositionConverter.toLSP(location)
            range = [
                "start": ["line": startPos.line, "character": startPos.character],
                "end": ["line": startPos.line, "character": startPos.character + 1]
            ]
        } else {
            // Default to beginning of file
            range = [
                "start": ["line": 0, "character": 0],
                "end": ["line": 0, "character": 0]
            ]
        }

        var result: [String: Any] = [
            "range": range,
            "severity": mapSeverity(diagnostic.severity),
            "source": "aro",
            "message": diagnostic.message
        ]

        // Add related information from hints
        if !diagnostic.hints.isEmpty {
            result["relatedInformation"] = diagnostic.hints.map { hint in
                [
                    "location": [
                        "uri": "",
                        "range": range
                    ],
                    "message": hint
                ]
            }
        }

        return result
    }

    private func mapSeverity(_ severity: AROParser.Diagnostic.Severity) -> Int {
        switch severity {
        case .error: return 1    // DiagnosticSeverity.Error
        case .warning: return 2  // DiagnosticSeverity.Warning
        case .note: return 3     // DiagnosticSeverity.Information
        }
    }
}

#endif
