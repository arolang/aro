// ============================================================
// Lexer.swift
// ARO Parser - Lexical Analysis
// ============================================================

import Foundation

/// Tokenizes ARO source code
public final class Lexer: @unchecked Sendable {
    
    // MARK: - Properties

    private let source: String
    private var currentIndex: String.Index
    private var nextIndex: String.Index  // ARO-0057: Cached next index for peekNext() optimization
    private var location: SourceLocation
    private var tokens: [Token] = []
    private var lastTokenKind: TokenKind?
    
    /// Reserved word classification for unified lookup
    private enum ReservedWord {
        case keyword(TokenKind)
        case article(Article)
        case preposition(Preposition)
    }

    /// All reserved words (keywords, articles, prepositions) in a single lookup table
    /// This optimizes identifier scanning from 3 lookups to 1 lookup (ARO-0055)
    private static let reservedWords: [String: ReservedWord] = [
        // Keywords - Core
        "publish": .keyword(.publish),
        "require": .keyword(.require),
        "import": .keyword(.import),
        "as": .keyword(.as),

        // Keywords - Control Flow
        "if": .keyword(.if),
        "then": .keyword(.then),
        "else": .keyword(.else),
        "when": .keyword(.when),
        "match": .keyword(.match),
        "case": .keyword(.case),
        "otherwise": .keyword(.otherwise),
        "where": .keyword(.where),

        // Keywords - Iteration
        "for": .keyword(.for),
        "each": .keyword(.each),
        "in": .keyword(.in),
        "at": .keyword(.atKeyword),
        "parallel": .keyword(.parallel),
        "concurrency": .keyword(.concurrency),

        // Keywords - Types
        "type": .keyword(.type),
        "enum": .keyword(.enum),
        "protocol": .keyword(.protocol),

        // Keywords - Error Handling
        "error": .keyword(.error),
        "guard": .keyword(.guard),
        "defer": .keyword(.defer),
        "assert": .keyword(.assert),
        "precondition": .keyword(.precondition),

        // Keywords - Logical Operators
        "and": .keyword(.and),
        "or": .keyword(.or),
        "not": .keyword(.not),
        "is": .keyword(.is),
        "exists": .keyword(.exists),
        "defined": .keyword(.defined),
        "null": .keyword(.nil),
        "nil": .keyword(.nil),
        "none": .keyword(.nil),
        "empty": .keyword(.empty),
        "contains": .keyword(.contains),
        "matches": .keyword(.matches),

        // Boolean literals
        "true": .keyword(.true),
        "false": .keyword(.false),

        // Articles
        "a": .article(.a),
        "an": .article(.an),
        "the": .article(.the),

        // Prepositions (note: "for" and "at" are keywords, not prepositions)
        "from": .preposition(.from),
        "against": .preposition(.against),
        "to": .preposition(.to),
        "into": .preposition(.into),
        "via": .preposition(.via),
        "with": .preposition(.with),
        "on": .preposition(.on),
        "by": .preposition(.by)
    ]

    // MARK: - Initialization
    
    public init(source: String) {
        self.source = source
        self.currentIndex = source.startIndex
        // ARO-0057: Pre-compute next index for peekNext() optimization
        if source.isEmpty {
            self.nextIndex = source.endIndex
        } else {
            self.nextIndex = source.index(after: source.startIndex)
        }
        self.location = SourceLocation()
    }
    
    // MARK: - Public Interface
    
    /// Tokenizes the entire source and returns all tokens
    public func tokenize() throws -> [Token] {
        tokens = []
        
        while !isAtEnd {
            try scanToken()
        }
        
        // Add EOF token
        tokens.append(Token(
            kind: .eof,
            span: SourceSpan(at: location),
            lexeme: ""
        ))
        
        return tokens
    }
    
    // MARK: - Scanner
    
    private func scanToken() throws {
        skipWhitespaceAndComments()

        guard !isAtEnd else { return }

        let startLocation = location
        let char = advance()

        switch char {
        case "(": addToken(.leftParen, start: startLocation)
        case ")": addToken(.rightParen, start: startLocation)
        case "{": addToken(.leftBrace, start: startLocation)
        case "}": addToken(.rightBrace, start: startLocation)
        case "[": addToken(.leftBracket, start: startLocation)
        case "]": addToken(.rightBracket, start: startLocation)
        case ",": addToken(.comma, start: startLocation)
        case ";": addToken(.semicolon, start: startLocation)
        case "@": addToken(.atSign, start: startLocation)
        case "?": addToken(.question, start: startLocation)
        case "*": addToken(.star, start: startLocation)
        case "/":
            // Check if this could be a regex literal
            // Regex starts with / and contains at least one character before closing /
            // Don't try regex after dots (used in import paths like ../../shared/common)
            // or after identifiers (division: a / b)
            let isAfterIdentifier: Bool
            if case .identifier = lastTokenKind {
                isAfterIdentifier = true
            } else {
                isAfterIdentifier = false
            }
            let shouldTryRegex = !isAtEnd &&
                peek() != " " && peek() != "\n" && peek() != "\t" &&
                lastTokenKind != .dot &&
                !isAfterIdentifier
            if shouldTryRegex {
                // Try to scan as regex - if we find a closing /, it's a regex
                if let regexResult = tryScanRegex(start: startLocation) {
                    addToken(.regexLiteral(pattern: regexResult.pattern, flags: regexResult.flags), start: startLocation)
                } else {
                    addToken(.slash, start: startLocation)
                }
            } else {
                addToken(.slash, start: startLocation)
            }
        case "%": addToken(.percent, start: startLocation)
        case ".": addToken(.dot, start: startLocation)

        case ":":
            if peek() == ":" {
                _ = advance()
                addToken(.doubleColon, start: startLocation)
            } else {
                addToken(.colon, start: startLocation)
            }

        case "<":
            if peek() == "=" {
                _ = advance()
                addToken(.lessEqual, start: startLocation)
            } else {
                addToken(.leftAngle, start: startLocation)
            }

        case ">":
            if peek() == "=" {
                _ = advance()
                addToken(.greaterEqual, start: startLocation)
            } else {
                addToken(.rightAngle, start: startLocation)
            }

        case "-":
            if peek() == ">" {
                _ = advance()
                addToken(.arrow, start: startLocation)
            } else if peek().isNumber {
                try scanNumber(start: startLocation, negative: true)
            } else {
                addToken(.hyphen, start: startLocation)
            }

        case "+":
            if peek() == "+" {
                _ = advance()
                addToken(.plusPlus, start: startLocation)
            } else {
                addToken(.plus, start: startLocation)
            }

        case "=":
            if peek() == "=" {
                _ = advance()
                addToken(.equalEqual, start: startLocation)
            } else if peek() == ">" {
                _ = advance()
                addToken(.fatArrow, start: startLocation)
            } else {
                addToken(.equals, start: startLocation)
            }

        case "!":
            if peek() == "=" {
                _ = advance()
                addToken(.bangEqual, start: startLocation)
            } else {
                throw LexerError.unexpectedCharacter(char, at: startLocation)
            }

        case "\"", "'":
            try scanString(quote: char, start: startLocation)

        default:
            if char.isLetter || char == "_" {
                try scanIdentifierOrKeyword(start: startLocation)
            } else if char.isNumber {
                try scanNumber(start: startLocation, negative: false)
            } else {
                throw LexerError.unexpectedCharacter(char, at: startLocation)
            }
        }
    }

    // MARK: - String Scanning

    private func scanString(quote: Character, start: SourceLocation) throws {
        var value = ""
        var hasInterpolation = false
        var segments: [(String, SourceLocation)] = []  // For interpolated strings

        while !isAtEnd && peek() != quote {
            let char = peek()
            if char == "\n" {
                throw LexerError.unterminatedString(at: start)
            }
            if char == "\\" {
                _ = advance()
                if isAtEnd {
                    throw LexerError.unterminatedString(at: start)
                }
                let escaped = advance()
                switch escaped {
                case "n": value.append("\n")
                case "r": value.append("\r")
                case "t": value.append("\t")
                case "\\": value.append("\\")
                case "\"": value.append("\"")
                case "'": value.append("'")
                case "0": value.append("\0")
                case "$": value.append("$")  // Escape dollar sign
                case "u":
                    // Unicode escape: \u{XXXX}
                    let unicodeChar = try scanUnicodeEscape(start: start)
                    value.append(unicodeChar)
                default:
                    throw LexerError.invalidEscapeSequence(escaped, at: location)
                }
            } else if char == "$" && peekNext() == "{" {
                // String interpolation: ${...}
                hasInterpolation = true
                let segmentStart = location
                if !value.isEmpty {
                    segments.append((value, segmentStart))
                    value = ""
                }
                _ = advance() // $
                _ = advance() // {
                // Mark interpolation start position for later scanning
                segments.append(("${", location))
                // Scan until matching }
                try scanInterpolationContent(quote: quote, start: start, segments: &segments)
            } else {
                value.append(advance())
            }
        }

        if isAtEnd {
            throw LexerError.unterminatedString(at: start)
        }

        _ = advance() // Closing quote

        if hasInterpolation {
            // Add final segment if any
            if !value.isEmpty {
                segments.append((value, location))
            }
            // Emit interpolation tokens
            emitInterpolationTokens(segments: segments, start: start)
        } else {
            addToken(.stringLiteral(value), start: start)
        }
    }

    /// Scans a unicode escape sequence: \u{XXXX}
    private func scanUnicodeEscape(start: SourceLocation) throws -> Character {
        guard peek() == "{" else {
            throw LexerError.invalidEscapeSequence("u", at: location)
        }
        _ = advance() // consume {

        var hexStr = ""
        while !isAtEnd && peek() != "}" {
            let c = advance()
            guard c.isHexDigit else {
                throw LexerError.invalidUnicodeEscape(hexStr + String(c), at: location)
            }
            hexStr.append(c)
        }

        guard !isAtEnd && peek() == "}" else {
            throw LexerError.invalidUnicodeEscape(hexStr, at: location)
        }
        _ = advance() // consume }

        guard !hexStr.isEmpty,
              let codePoint = UInt32(hexStr, radix: 16),
              let scalar = Unicode.Scalar(codePoint) else {
            throw LexerError.invalidUnicodeEscape(hexStr, at: location)
        }

        return Character(scalar)
    }

    /// Scans content inside ${...} interpolation, handling nested braces
    private func scanInterpolationContent(
        quote: Character,
        start: SourceLocation,
        segments: inout [(String, SourceLocation)]
    ) throws {
        var braceDepth = 1
        var content = ""
        let contentStart = location

        while !isAtEnd && braceDepth > 0 {
            let char = peek()
            if char == "\n" {
                throw LexerError.unterminatedString(at: start)
            }
            if char == "{" {
                braceDepth += 1
                content.append(advance())
            } else if char == "}" {
                braceDepth -= 1
                if braceDepth > 0 {
                    content.append(advance())
                } else {
                    _ = advance() // consume closing }
                }
            } else if char == quote {
                // String ended before interpolation closed
                throw LexerError.unterminatedString(at: start)
            } else {
                content.append(advance())
            }
        }

        if braceDepth > 0 {
            throw LexerError.unterminatedString(at: start)
        }

        // Store the interpolation content
        segments.append((content, contentStart))
        segments.append(("}", location))
    }

    /// Emits tokens for an interpolated string
    private func emitInterpolationTokens(segments: [(String, SourceLocation)], start: SourceLocation) {
        var i = 0
        while i < segments.count {
            let (content, loc) = segments[i]
            let span = SourceSpan(start: loc, end: loc)

            if content == "${" {
                addToken(.interpolationStart, start: loc)
                i += 1
                // Next segment is the expression content
                if i < segments.count {
                    let (exprContent, _) = segments[i]
                    if exprContent != "}" {
                        // Re-lex the expression content to get real tokens
                        if let exprTokens = try? Lexer.tokenize(exprContent) {
                            // Add all tokens except EOF
                            for token in exprTokens where token.kind != .eof {
                                tokens.append(token)
                            }
                        }
                        i += 1
                    }
                }
                // Next should be }
                if i < segments.count && segments[i].0 == "}" {
                    addToken(.interpolationEnd, start: segments[i].1)
                    i += 1
                }
            } else if content != "}" {
                // Regular string segment
                tokens.append(Token(
                    kind: .stringSegment(content),
                    span: span,
                    lexeme: content
                ))
                i += 1
            } else {
                i += 1
            }
        }
    }

    // MARK: - Number Scanning

    private func scanNumber(start: SourceLocation, negative: Bool) throws {
        var numStr = negative ? "-" : ""

        // Check for hex (0x) or binary (0b)
        if !negative && previous() == "0" {
            if peek() == "x" || peek() == "X" {
                _ = advance()
                try scanHexNumber(start: start)
                return
            } else if peek() == "b" || peek() == "B" {
                _ = advance()
                try scanBinaryNumber(start: start)
                return
            }
            numStr.append("0")
        } else if !negative {
            numStr.append(previous())
        }

        // Scan integer part (ARO-0056: support underscores)
        while !isAtEnd && (peek().isNumber || peek() == "_") {
            let char = advance()
            if char != "_" {
                numStr.append(char)
            }
        }

        // Check for decimal point
        var isFloat = false
        if !isAtEnd && peek() == "." && peekNext().isNumber {
            isFloat = true
            numStr.append(advance()) // .
            // Scan fractional part (ARO-0056: support underscores)
            while !isAtEnd && (peek().isNumber || peek() == "_") {
                let char = advance()
                if char != "_" {
                    numStr.append(char)
                }
            }
        }

        // Check for exponent
        if !isAtEnd && (peek() == "e" || peek() == "E") {
            isFloat = true
            numStr.append(advance()) // e or E
            if !isAtEnd && (peek() == "+" || peek() == "-") {
                numStr.append(advance())
            }
            // Scan exponent (ARO-0056: support underscores)
            while !isAtEnd && (peek().isNumber || peek() == "_") {
                let char = advance()
                if char != "_" {
                    numStr.append(char)
                }
            }
        }

        if isFloat {
            guard let value = Double(numStr) else {
                throw LexerError.invalidNumber(numStr, at: start)
            }
            addToken(.floatLiteral(value), start: start)
        } else {
            guard let value = Int(numStr) else {
                throw LexerError.invalidNumber(numStr, at: start)
            }
            addToken(.intLiteral(value), start: start)
        }
    }

    private func scanHexNumber(start: SourceLocation) throws {
        var hexStr = ""
        while !isAtEnd && (peek().isHexDigit || peek() == "_") {
            let char = advance()
            if char != "_" {
                hexStr.append(char)
            }
        }
        guard !hexStr.isEmpty, let value = Int(hexStr, radix: 16) else {
            throw LexerError.invalidNumber("0x" + hexStr, at: start)
        }
        addToken(.intLiteral(value), start: start)
    }

    private func scanBinaryNumber(start: SourceLocation) throws {
        var binStr = ""
        while !isAtEnd && (peek() == "0" || peek() == "1" || peek() == "_") {
            let char = advance()
            if char != "_" {
                binStr.append(char)
            }
        }
        guard !binStr.isEmpty, let value = Int(binStr, radix: 2) else {
            throw LexerError.invalidNumber("0b" + binStr, at: start)
        }
        addToken(.intLiteral(value), start: start)
    }

    private func previous() -> Character {
        let prevIndex = source.index(before: currentIndex)
        return source[prevIndex]
    }

    // MARK: - Regex Scanning

    /// Attempts to scan a regex literal. Returns pattern and flags if successful, nil otherwise.
    /// This method saves and restores state if the scan fails.
    private func tryScanRegex(start: SourceLocation) -> (pattern: String, flags: String)? {
        // Save current position for backtracking
        let savedIndex = currentIndex
        let savedLocation = location

        var pattern = ""
        var foundClosingSlash = false

        // Scan pattern until closing /
        while !isAtEnd {
            let char = peek()

            // Newline means this isn't a regex literal
            if char == "\n" {
                currentIndex = savedIndex
                location = savedLocation
                return nil
            }

            // Escaped character
            if char == "\\" {
                pattern.append(advance())
                if !isAtEnd && peek() != "\n" {
                    pattern.append(advance())
                }
                continue
            }

            // Closing slash
            if char == "/" {
                _ = advance()  // consume /
                foundClosingSlash = true
                break
            }

            pattern.append(advance())
        }

        // Must have a closing slash and non-empty pattern
        if !foundClosingSlash || pattern.isEmpty {
            currentIndex = savedIndex
            location = savedLocation
            return nil
        }

        // Scan optional flags (i, s, m, g)
        var flags = ""
        while !isAtEnd {
            let char = peek()
            if char == "i" || char == "s" || char == "m" || char == "g" {
                flags.append(advance())
            } else {
                break
            }
        }

        return (pattern: pattern, flags: flags)
    }

    private func scanIdentifierOrKeyword(start: SourceLocation) throws {
        // Continue consuming alphanumeric characters and underscores
        while !isAtEnd && (peek().isLetter || peek().isNumber || peek() == "_") {
            _ = advance()
        }
        
        let lexeme = String(source[source.index(source.startIndex, offsetBy: start.offset)..<currentIndex])
        let lowerLexeme = lexeme.lowercased()

        // Unified reserved word lookup (ARO-0055: single lookup instead of 3)
        if let reserved = Self.reservedWords[lowerLexeme] {
            switch reserved {
            case .keyword(let kind):
                addToken(kind, lexeme: lexeme, start: start)
            case .article(let article):
                addToken(.article(article), lexeme: lexeme, start: start)
            case .preposition(let preposition):
                addToken(.preposition(preposition), lexeme: lexeme, start: start)
            }
        } else {
            // Regular identifier
            addToken(.identifier(lexeme), lexeme: lexeme, start: start)
        }
    }
    
    // MARK: - Whitespace and Comments
    
    private func skipWhitespaceAndComments() {
        while !isAtEnd {
            let char = peek()
            
            if char.isWhitespace {
                _ = advance()
            } else if char == "(" && peekNext() == "*" {
                skipBlockComment()
            } else if char == "/" && peekNext() == "/" {
                skipLineComment()
            } else {
                break
            }
        }
    }
    
    private func skipBlockComment() {
        // Skip opening (*
        _ = advance()
        _ = advance()
        
        while !isAtEnd {
            if peek() == "*" && peekNext() == ")" {
                _ = advance()
                _ = advance()
                return
            }
            _ = advance()
        }
    }
    
    private func skipLineComment() {
        while !isAtEnd && peek() != "\n" {
            _ = advance()
        }
    }
    
    // MARK: - Character Access
    
    private var isAtEnd: Bool {
        currentIndex >= source.endIndex
    }
    
    private func peek() -> Character {
        guard !isAtEnd else { return "\0" }
        return source[currentIndex]
    }
    
    // ARO-0057: Use cached nextIndex for O(1) lookahead
    private func peekNext() -> Character {
        guard nextIndex < source.endIndex else { return "\0" }
        return source[nextIndex]
    }
    
    @discardableResult
    private func advance() -> Character {
        let char = source[currentIndex]
        // ARO-0057: Use cached nextIndex and update it for next call
        currentIndex = nextIndex
        if nextIndex < source.endIndex {
            nextIndex = source.index(after: nextIndex)
        }
        location = location.advancing(past: char)
        return char
    }
    
    // MARK: - Token Creation
    
    private func addToken(_ kind: TokenKind, start: SourceLocation) {
        let lexeme = String(source[source.index(source.startIndex, offsetBy: start.offset)..<currentIndex])
        addToken(kind, lexeme: lexeme, start: start)
    }
    
    private func addToken(_ kind: TokenKind, lexeme: String, start: SourceLocation) {
        let span = SourceSpan(start: start, end: location)
        tokens.append(Token(kind: kind, span: span, lexeme: lexeme))
        lastTokenKind = kind
    }
}

// MARK: - Convenience Extension

extension Lexer {
    /// Creates a lexer and tokenizes the source in one step
    public static func tokenize(_ source: String) throws -> [Token] {
        try Lexer(source: source).tokenize()
    }
}

// MARK: - Character Extension

extension Character {
    /// Returns true if this character is a valid hexadecimal digit
    var isHexDigit: Bool {
        switch self {
        case "0"..."9", "a"..."f", "A"..."F":
            return true
        default:
            return false
        }
    }
}
