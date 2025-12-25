// ============================================================
// PositionConverter.swift
// AROLSP - Position Conversion between ARO and LSP
// ============================================================

#if !os(Windows)
import Foundation
import AROParser
import LanguageServerProtocol

/// Converts between ARO source positions and LSP positions
/// LSP uses 0-based line/column, ARO uses 1-based
public struct PositionConverter {

    /// Convert ARO SourceLocation to LSP Position
    public static func toLSP(_ location: SourceLocation) -> Position {
        Position(
            line: location.line - 1,
            character: location.column - 1
        )
    }

    /// Convert ARO SourceSpan to LSP Range
    public static func toLSP(_ span: SourceSpan) -> LSPRange {
        LSPRange(
            start: toLSP(span.start),
            end: toLSP(span.end)
        )
    }

    /// Convert LSP Position to ARO SourceLocation
    public static func fromLSP(_ position: Position) -> SourceLocation {
        SourceLocation(
            line: position.line + 1,
            column: position.character + 1,
            offset: 0
        )
    }

    /// Convert LSP Range to ARO SourceSpan
    public static func fromLSP(_ range: LSPRange) -> SourceSpan {
        SourceSpan(
            start: fromLSP(range.start),
            end: fromLSP(range.end)
        )
    }

    /// Calculate offset from position in document
    public static func calculateOffset(_ position: Position, in document: String) -> Int {
        var offset = 0
        var currentLine = 0

        for char in document {
            if currentLine == position.line {
                var column = 0
                for c in document[document.index(document.startIndex, offsetBy: offset)...] {
                    if column == position.character {
                        return offset
                    }
                    if c.isNewline {
                        break
                    }
                    offset += 1
                    column += 1
                }
                return offset
            }

            if char.isNewline {
                currentLine += 1
            }
            offset += 1
        }

        return offset
    }
}

#endif
