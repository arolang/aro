// ============================================================
// SourceLocation.swift
// ARO Parser - Source Location Tracking
// ============================================================

import Foundation

/// Represents a position in the source code
public struct SourceLocation: Sendable, Equatable, CustomStringConvertible {
    public let line: Int
    public let column: Int
    /// Unicode scalar count from the start of the source (character offset).
    public let offset: Int
    /// UTF-8 byte offset from the start of the source (ARO-0115).
    ///
    /// Used by the lexer for O(1) lexeme extraction from the UTF-8 byte buffer.
    /// Equal to `offset` for ASCII-only source; larger for source containing
    /// multi-byte Unicode characters.
    public let byteOffset: Int

    public init(line: Int = 1, column: Int = 1, offset: Int = 0, byteOffset: Int = 0) {
        self.line = line
        self.column = column
        self.offset = offset
        self.byteOffset = byteOffset
    }

    public var description: String {
        "\(line):\(column)"
    }

    /// Advances the location by one character
    public func advancing(past character: Character) -> SourceLocation {
        let charByteCount = character.utf8.count
        if character.isNewline {
            return SourceLocation(line: line + 1, column: 1, offset: offset + 1, byteOffset: byteOffset + charByteCount)
        }
        return SourceLocation(line: line, column: column + 1, offset: offset + 1, byteOffset: byteOffset + charByteCount)
    }
}

/// Represents a span in the source code (start to end)
public struct SourceSpan: Sendable, Equatable, CustomStringConvertible {
    public let start: SourceLocation
    public let end: SourceLocation
    
    public init(start: SourceLocation, end: SourceLocation) {
        self.start = start
        self.end = end
    }
    
    public init(at location: SourceLocation) {
        self.start = location
        self.end = location
    }
    
    public var description: String {
        if start.line == end.line {
            return "\(start.line):\(start.column)-\(end.column)"
        }
        return "\(start)-\(end)"
    }
    
    /// Merges two spans into one covering both
    public func merged(with other: SourceSpan) -> SourceSpan {
        let newStart = start.offset < other.start.offset ? start : other.start
        let newEnd = end.offset > other.end.offset ? end : other.end
        return SourceSpan(start: newStart, end: newEnd)
    }

    /// An unknown/placeholder span
    public static var unknown: SourceSpan {
        SourceSpan(at: SourceLocation())
    }
}

/// Protocol for AST nodes that have a source location
public protocol Locatable {
    var span: SourceSpan { get }
}
