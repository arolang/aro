// ============================================================
// Token.swift
// ARO Parser - Token Definitions
// ============================================================

import Foundation

/// All possible token types in the ARO language
public enum TokenKind: Sendable, Equatable, CustomStringConvertible {
    // Delimiters
    case leftParen          // (
    case rightParen         // )
    case leftBrace          // {
    case rightBrace         // }
    case leftAngle          // <
    case rightAngle         // >
    case leftBracket        // [
    case rightBracket       // ]
    case colon              // :
    case doubleColon        // ::
    case dot                // .
    case hyphen             // -
    case comma              // ,
    case semicolon          // ;
    case atSign             // @
    case question           // ?
    case arrow              // ->
    case fatArrow           // =>
    case equals             // =

    // Operators
    case plus               // +
    case minus              // - (unary/binary)
    case star               // *
    case slash              // /
    case percent            // %
    case plusPlus           // ++
    case equalEqual         // ==
    case bangEqual          // !=
    case lessThan           // < (when not angle bracket)
    case greaterThan        // > (when not angle bracket)
    case lessEqual          // <=
    case greaterEqual       // >=

    // Keywords - Core
    case publish            // Publish
    case require            // Require (ARO-0003)
    case `import`           // import (ARO-0007)
    case `as`               // as

    // Keywords - Control Flow (ARO-0004)
    case `if`               // if
    case then               // then
    case `else`             // else
    case when               // when
    case match              // match
    case `case`             // case
    case otherwise          // otherwise
    case `where`            // where

    // Keywords - Iteration (ARO-0005)
    case `for`              // for
    case each               // each
    case `in`               // in
    case atKeyword          // at (for indexed iteration)
    case parallel           // parallel (for parallel for-each)
    case concurrency        // concurrency (for concurrency limit)

    // Keywords - Types (ARO-0006)
    case type               // type
    case `enum`             // enum
    case `protocol`         // protocol

    // Keywords - Error Handling (ARO-0008)
    // Note: ARO has NO try-catch blocks. Errors are auto-generated from statements.
    case error              // error (for <Throw> a <BadRequest: error>)
    case `guard`            // guard (for validation patterns)
    case `defer`            // defer (for cleanup)
    case assert             // assert (for debug assertions)
    case precondition       // precondition (for preconditions)

    // Keywords - Logical Operators
    case and                // and
    case or                 // or
    case not                // not
    case `is`               // is
    case exists             // exists
    case defined            // defined
    case null               // null
    case empty              // empty
    case contains           // contains
    case matches            // matches

    // Literals
    case identifier(String)
    case stringLiteral(String)
    case intLiteral(Int)
    case floatLiteral(Double)
    case regexLiteral(pattern: String, flags: String)  // /pattern/flags
    case `true`             // true
    case `false`            // false
    case `nil`              // nil/null/none

    // String Interpolation (ARO-0002)
    case stringSegment(String)    // A segment of an interpolated string
    case interpolationStart       // ${
    case interpolationEnd         // } (closing interpolation)

    // Articles and Prepositions
    case article(Article)
    case preposition(Preposition)

    // Special
    case eof

    public var description: String {
        switch self {
        case .leftParen: return "("
        case .rightParen: return ")"
        case .leftBrace: return "{"
        case .rightBrace: return "}"
        case .leftAngle: return "<"
        case .rightAngle: return ">"
        case .leftBracket: return "["
        case .rightBracket: return "]"
        case .colon: return ":"
        case .doubleColon: return "::"
        case .dot: return "."
        case .hyphen: return "-"
        case .comma: return ","
        case .semicolon: return ";"
        case .atSign: return "@"
        case .question: return "?"
        case .arrow: return "->"
        case .fatArrow: return "=>"
        case .equals: return "="
        case .plus: return "+"
        case .minus: return "-"
        case .star: return "*"
        case .slash: return "/"
        case .percent: return "%"
        case .plusPlus: return "++"
        case .equalEqual: return "=="
        case .bangEqual: return "!="
        case .lessThan: return "<"
        case .greaterThan: return ">"
        case .lessEqual: return "<="
        case .greaterEqual: return ">="
        case .publish: return "Publish"
        case .require: return "Require"
        case .import: return "import"
        case .as: return "as"
        case .if: return "if"
        case .then: return "then"
        case .else: return "else"
        case .when: return "when"
        case .match: return "match"
        case .case: return "case"
        case .otherwise: return "otherwise"
        case .where: return "where"
        case .for: return "for"
        case .each: return "each"
        case .in: return "in"
        case .atKeyword: return "at"
        case .parallel: return "parallel"
        case .concurrency: return "concurrency"
        case .type: return "type"
        case .enum: return "enum"
        case .protocol: return "protocol"
        case .error: return "error"
        case .guard: return "guard"
        case .defer: return "defer"
        case .assert: return "assert"
        case .precondition: return "precondition"
        case .and: return "and"
        case .or: return "or"
        case .not: return "not"
        case .is: return "is"
        case .exists: return "exists"
        case .defined: return "defined"
        case .null: return "null"
        case .empty: return "empty"
        case .contains: return "contains"
        case .matches: return "matches"
        case .identifier(let value): return "identifier(\(value))"
        case .stringLiteral(let value): return "string(\"\(value)\")"
        case .intLiteral(let value): return "int(\(value))"
        case .floatLiteral(let value): return "float(\(value))"
        case .regexLiteral(let pattern, let flags): return "regex(/\(pattern)/\(flags))"
        case .true: return "true"
        case .false: return "false"
        case .nil: return "nil"
        case .stringSegment(let value): return "stringSegment(\"\(value)\")"
        case .interpolationStart: return "${"
        case .interpolationEnd: return "}"
        case .article(let art): return "article(\(art))"
        case .preposition(let prep): return "preposition(\(prep))"
        case .eof: return "EOF"
        }
    }
}

/// English articles
public enum Article: String, Sendable, CaseIterable {
    case a = "a"
    case an = "an"
    case the = "the"
}

/// Supported prepositions with semantic meaning
public enum Preposition: String, Sendable, CaseIterable {
    case from = "from"          // External source
    case `for` = "for"          // Purpose/target
    case against = "against"    // Comparison
    case to = "to"              // Destination
    case into = "into"          // Transformation
    case via = "via"            // Through
    case with = "with"          // Accompaniment
    case on = "on"              // Location/attachment (e.g., "on port 8080")

    /// Indicates if this preposition typically references an external source
    public var indicatesExternalSource: Bool {
        switch self {
        case .from, .via: return true
        default: return false
        }
    }
}

/// A token with its kind and source location
public struct Token: Sendable, Equatable, Locatable, CustomStringConvertible {
    public let kind: TokenKind
    public let span: SourceSpan
    public let lexeme: String
    
    public init(kind: TokenKind, span: SourceSpan, lexeme: String) {
        self.kind = kind
        self.span = span
        self.lexeme = lexeme
    }
    
    public var description: String {
        "\(kind) at \(span)"
    }
}

// MARK: - Token Matching Extensions

extension TokenKind {
    /// Checks if this is an identifier (regardless of value)
    public var isIdentifier: Bool {
        if case .identifier = self { return true }
        return false
    }

    /// Checks if this token can be used as an identifier in contexts like business activity names.
    /// Includes actual identifiers plus keywords that are valid words (e.g., "Error").
    public var isIdentifierLike: Bool {
        switch self {
        case .identifier:
            return true
        // Keywords that can appear in business activity names
        case .error, .match, .case, .otherwise, .`if`, .`else`:
            return true
        default:
            return false
        }
    }

    /// Extracts the identifier value if this is an identifier
    public var identifierValue: String? {
        if case .identifier(let value) = self { return value }
        return nil
    }

    /// Checks if this is an article
    public var isArticle: Bool {
        if case .article = self { return true }
        return false
    }

    /// Checks if this is a preposition
    public var isPreposition: Bool {
        if case .preposition = self { return true }
        return false
    }

    /// Extracts the preposition if this is a preposition
    public var prepositionValue: Preposition? {
        if case .preposition(let prep) = self { return prep }
        return nil
    }

    /// Checks if this is a literal (string, number, bool, nil, regex)
    public var isLiteral: Bool {
        switch self {
        case .stringLiteral, .intLiteral, .floatLiteral, .regexLiteral, .true, .false, .nil:
            return true
        default:
            return false
        }
    }

    /// Checks if this is a comparison operator
    public var isComparisonOperator: Bool {
        switch self {
        case .equalEqual, .bangEqual, .lessThan, .greaterThan,
             .lessEqual, .greaterEqual, .is, .contains, .matches:
            return true
        default:
            return false
        }
    }

    /// Checks if this is an additive operator
    public var isAdditiveOperator: Bool {
        switch self {
        case .plus, .minus, .plusPlus:
            return true
        default:
            return false
        }
    }

    /// Checks if this is a multiplicative operator
    public var isMultiplicativeOperator: Bool {
        switch self {
        case .star, .slash, .percent:
            return true
        default:
            return false
        }
    }

    /// Checks if this is a keyword that starts a statement
    public var isStatementKeyword: Bool {
        switch self {
        case .if, .match, .for, .parallel, .guard, .defer, .assert, .precondition:
            return true
        default:
            return false
        }
    }
}
