// ============================================================
// Lexer.swift
// ARO Parser - Lexical Analysis
// ============================================================

import Foundation

/// Tokenizes ARO source code
public final class Lexer: @unchecked Sendable {
    
    // MARK: - Properties

    // ARO-0115: UTF-8 byte buffer replaces String.Index arithmetic for O(1) position operations.
    // All scanning uses integer byte positions into `utf8`; `source` is kept only for the
    // public initialiser signature and for fallback multi-byte Character decoding.
    private let source: String
    private let utf8: [UInt8]           // Source encoded as UTF-8 bytes
    private var pos: Int                // Current byte position
    private var nextPos: Int            // Cached next byte position (O(1) peekNext)
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
        // "for" and "at" are prepositions (also used as iteration keywords - parser accepts both)
        "for": .preposition(.for),
        "each": .keyword(.each),
        "in": .keyword(.in),
        "at": .preposition(.at),
        "parallel": .keyword(.parallel),
        "concurrency": .keyword(.concurrency),

        // Keywords - While Loop (ARO-0002 extension, ARO-0131)
        "while": .keyword(.while),
        "break": .keyword(.break),

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

        // Prepositions
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
        self.utf8 = Array(source.utf8)
        self.pos = 0
        // ARO-0115: Cache the next byte position for O(1) peekNext()
        self.nextPos = Self.advanceBytePos(0, in: Array(source.utf8))
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

        case "|":
            // ARO-0067: Pipeline operator |>
            if peek() == ">" {
                _ = advance()
                addToken(.pipe, start: startLocation)
            } else {
                throw LexerError.unexpectedCharacter("|", at: startLocation)
            }

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

        case "\"":
            // Check for triple-quoted multiline string: """
            if peek() == "\"" && peekNext() == "\"" {
                try scanTripleQuotedString(start: startLocation)
            } else {
                // Double quotes: regular string with full escape processing
                try scanString(quote: char, start: startLocation)
            }

        case "'":
            // Single quotes: raw string (no escape processing except \')
            try scanRawString(quote: char, start: startLocation)

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

    /// Scans a raw string literal (ARO-0060)
    /// Raw strings use r-prefix and don't process escape sequences except \"
    private func scanRawString(quote: Character, start: SourceLocation) throws {
        var value = ""

        while !isAtEnd && peek() != quote {
            let char = peek()
            if char == "\n" {
                throw LexerError.unterminatedString(at: start)
            }
            // Only allow \" or \' escape in raw strings
            if char == "\\" && peekNext() == quote {
                _ = advance()  // skip backslash
                value.append(advance())  // add quote
            } else {
                value.append(advance())
            }
        }

        if isAtEnd {
            throw LexerError.unterminatedString(at: start)
        }

        _ = advance()  // Closing quote

        addToken(.stringLiteral(value), start: start)
    }

    /// Scans a triple-quoted multiline string literal (ARO-0097).
    ///
    /// Syntax:
    /// ```
    /// """
    ///     content line 1
    ///     content line 2
    ///     """
    /// ```
    ///
    /// Rules:
    /// - Opening `"""` must be followed by optional whitespace then a newline.
    /// - Closing `"""` must be on its own line, preceded only by whitespace.
    /// - The indentation of the closing `"""` is stripped from all content lines.
    /// - Standard escape sequences (`\n`, `\t`, `\\`, `\"`, `\u{XXXX}`) are supported.
    /// - The first newline (after opening `"""`) and last newline (before closing `"""`)
    ///   are not included in the resulting string value.
    private func scanTripleQuotedString(start: SourceLocation) throws {
        // Consume the second and third opening quotes (first was consumed in scanToken)
        _ = advance() // second "
        _ = advance() // third "

        // Skip optional whitespace on the opening line (but not past newline)
        while !isAtEnd && peek() != "\n" && peek().isWhitespace {
            _ = advance()
        }
        // Enforce: opening """ must be followed immediately by a newline
        guard !isAtEnd && peek() == "\n" else {
            throw LexerError.unterminatedString(at: start)
        }
        _ = advance() // consume the opening newline

        // Collect raw lines until the closing """
        var rawLines: [String] = []
        var currentLine = ""

        while !isAtEnd {
            let ch = peek()

            if ch == "\n" {
                _ = advance()
                rawLines.append(currentLine)
                currentLine = ""
            } else if ch == "\"" {
                // Possibly the closing """ — save state for backtracking
                let savedIndex = pos
                let savedNext = nextPos
                let savedLoc = location

                _ = advance() // first "
                if !isAtEnd && peek() == "\"" {
                    _ = advance() // second "
                    if !isAtEnd && peek() == "\"" {
                        _ = advance() // third " — confirmed closing """

                        // currentLine is the indentation prefix on the closing """ line
                        let closingIndent = currentLine

                        // Apply dedentation: strip closingIndent from the front of each line
                        let dedentedLines = rawLines.map { line -> String in
                            if line.hasPrefix(closingIndent) {
                                return String(line.dropFirst(closingIndent.count))
                            }
                            // Blank / whitespace-only lines are kept as empty
                            if line.allSatisfy({ $0.isWhitespace }) { return "" }
                            return line // mismatched indent — leave as-is
                        }

                        // Drop trailing empty line produced by the newline before closing """
                        var finalLines = dedentedLines
                        if finalLines.last == "" {
                            finalLines.removeLast()
                        }

                        let value = finalLines.joined(separator: "\n")
                        addToken(.stringLiteral(value), start: start)
                        return
                    }
                    // Two quotes but not three — put them in the current line
                    currentLine.append("\"")
                    currentLine.append("\"")
                } else {
                    // Just one quote — restore and add it normally
                    pos = savedIndex
                    nextPos = savedNext
                    location = savedLoc
                    currentLine.append(advance())
                }
            } else if ch == "\\" {
                // Escape sequences inside triple-quoted strings
                _ = advance()
                guard !isAtEnd else { throw LexerError.unterminatedString(at: start) }
                let escaped = advance()
                switch escaped {
                case "n": currentLine.append("\n")
                case "r": currentLine.append("\r")
                case "t": currentLine.append("\t")
                case "\\": currentLine.append("\\")
                case "\"": currentLine.append("\"")
                case "'": currentLine.append("'")
                case "0": currentLine.append("\0")
                case "$": currentLine.append("$")
                case "u":
                    let unicodeChar = try scanUnicodeEscape(start: start)
                    currentLine.append(unicodeChar)
                default:
                    throw LexerError.invalidEscapeSequence(escaped, at: location)
                }
            } else {
                currentLine.append(advance())
            }
        }

        throw LexerError.unterminatedString(at: start)
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
                addToken(.interpolationStart, lexeme: "${", start: loc)
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
                    addToken(.interpolationEnd, lexeme: "}", start: segments[i].1)
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
        // Walk back past any UTF-8 continuation bytes (0x80–0xBF) to find the start
        // of the previous character. For ASCII (the common case) pos - 1 is sufficient.
        var p = pos - 1
        while p > 0 && (utf8[p] & 0xC0) == 0x80 { p -= 1 }
        return decodeChar(at: p)
    }

    // MARK: - Regex Scanning

    /// Attempts to scan a regex literal. Returns pattern and flags if successful, nil otherwise.
    /// This method saves and restores state if the scan fails.
    private func tryScanRegex(start: SourceLocation) -> (pattern: String, flags: String)? {
        // Save current position for backtracking (ARO-0115: byte positions)
        let savedPos = pos
        let savedNextPos = nextPos
        let savedLocation = location

        var pattern = ""
        var foundClosingSlash = false

        // Scan pattern until closing /
        while !isAtEnd {
            let char = peek()

            // Newline means this isn't a regex literal
            if char == "\n" {
                pos = savedPos
                nextPos = savedNextPos
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
            pos = savedPos
            nextPos = savedNextPos
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
        
        let lexeme = String(bytes: utf8[start.byteOffset..<pos], encoding: .utf8) ?? ""
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
    
    // MARK: - Character Access (ARO-0115: UTF-8 byte buffer)

    /// Returns the number of UTF-8 bytes in the character starting at byte position `p`.
    private static func charByteCount(at p: Int, in bytes: [UInt8]) -> Int {
        guard p < bytes.count else { return 0 }
        let b = bytes[p]
        if b < 0x80 { return 1 }      // ASCII
        if b < 0xE0 { return 2 }      // 2-byte sequence
        if b < 0xF0 { return 3 }      // 3-byte sequence
        return 4                        // 4-byte sequence
    }

    /// Returns the byte position of the character after the one at `p`.
    private static func advanceBytePos(_ p: Int, in bytes: [UInt8]) -> Int {
        p + charByteCount(at: p, in: bytes)
    }

    /// Decodes the Unicode character whose UTF-8 encoding starts at byte position `p`.
    ///
    /// Fast path for ASCII (O(1), no allocation). Non-ASCII falls back to String
    /// initialisation from raw bytes (rare: only string literals and comments).
    private func decodeChar(at p: Int) -> Character {
        guard p < utf8.count else { return "\0" }
        let b0 = utf8[p]
        if b0 < 0x80 {
            // ASCII fast path — no allocation
            return Character(UnicodeScalar(b0))
        }
        // Non-ASCII slow path (uncommon in ARO source)
        let count = Self.charByteCount(at: p, in: utf8)
        let end = min(p + count, utf8.count)
        return String(bytes: utf8[p..<end], encoding: .utf8).flatMap { $0.first } ?? "\0"
    }

    private var isAtEnd: Bool {
        pos >= utf8.count
    }

    private func peek() -> Character {
        decodeChar(at: pos)
    }

    /// O(1) lookahead — uses the cached `nextPos` (ARO-0115, supersedes ARO-0057).
    private func peekNext() -> Character {
        decodeChar(at: nextPos)
    }

    @discardableResult
    private func advance() -> Character {
        let char = decodeChar(at: pos)
        pos = nextPos
        nextPos = Self.advanceBytePos(nextPos, in: utf8)
        location = location.advancing(past: char)
        return char
    }

    // MARK: - Token Creation

    /// Extracts the token's lexeme via O(1) byte-range slicing (ARO-0115).
    private func addToken(_ kind: TokenKind, start: SourceLocation) {
        let lexeme = String(bytes: utf8[start.byteOffset..<pos], encoding: .utf8) ?? ""
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
