// ============================================================
// Lexer.swift
// ARO Parser - Lexical Analysis
// ============================================================

import Foundation

/// Tokenizes ARO source code
public final class Lexer: @unchecked Sendable {
    
    // MARK: - Properties

    // GitLab #115: UTF-8 byte buffer replaces String.Index arithmetic for O(1) position operations.
    // All scanning uses integer byte positions into `utf8`; `source` is kept only for the
    // public initialiser signature and for fallback multi-byte Character decoding.
    private let source: String
    private let utf8: [UInt8]           // Source encoded as UTF-8 bytes
    private var pos: Int                // Current byte position
    private var nextPos: Int            // Cached next byte position (O(1) peekNext)
    private var location: SourceLocation
    private var tokens: [Token] = []
    private var lastTokenKind: TokenKind?

    /// String intern table — deduplicates identifier and keyword lexemes.
    /// Avoids thousands of duplicate heap allocations for repeated strings
    /// like action verbs, prepositions, and variable names.
    private var internTable: [String: String] = [:]

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

        // Keywords - While Loop (ARO-0002 extension, GitLab #131)
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
    
    /// Optional diagnostics collector for error recovery.
    /// When set, invalid characters emit a diagnostic and are skipped
    /// instead of throwing, allowing the lexer to report multiple errors.
    private let diagnostics: DiagnosticCollector?

    public init(source: String, diagnostics: DiagnosticCollector? = nil) {
        self.source = source
        self.utf8 = Array(source.utf8)
        self.pos = 0
        // GitLab #115: Cache the next byte position for O(1) peekNext()
        self.nextPos = Self.advanceBytePos(0, in: Array(source.utf8))
        self.location = SourceLocation()
        self.diagnostics = diagnostics
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
                // Bare | used as qualifier chain separator inside <result: q1 | q2>
                addToken(.bar, start: startLocation)
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
            } else if let diagnostics {
                diagnostics.error("Unexpected character '!'", at: startLocation)
            } else {
                throw LexerError.unexpectedCharacter(char, at: startLocation)
            }

        case "\"":
            // `"""` was the multiline delimiter until GitLab #523 gave a
            // plain "…" string the same power; #524 removed it. Detecting
            // it here is what keeps the diagnostic useful: left alone, the
            // lexer would read `"""` as an empty string followed by an
            // unterminated one and report something unrecognisable.
            if peek() == "\"" && peekNext() == "\"" {
                _ = advance()  // second "
                _ = advance()  // third "
                if let diagnostics {
                    diagnostics.error(
                        LexerError.tripleQuotedStringRemoved(at: startLocation).message,
                        at: startLocation,
                        hints: [
                            "Write the text in a plain \"…\" string — newlines inside it are content.",
                            "The dedent is gone with the delimiter, so the text goes flush against the margin it should print at."
                        ]
                    )
                    // Skip to the closing delimiter, then stand in for the
                    // literal: one mistake earns one diagnostic. Without the
                    // placeholder the statement loses its value and the
                    // parser adds "Expected object" on the closing line,
                    // which points away from the actual problem.
                    skipPastTripleQuoteBody()
                    addToken(.stringLiteral(""), start: startLocation)
                } else {
                    throw LexerError.tripleQuotedStringRemoved(at: startLocation)
                }
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
            } else if let diagnostics {
                diagnostics.error("Unexpected character '\(char)'", at: startLocation)
                // Skip the invalid character and continue lexing
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
            // A newline is content: plain "…" strings span lines
            // (GitLab #523). An unterminated string is still reported
            // at its OPENING quote, so the missing-quote typo points
            // at the right line, not at end of file.
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
            try emitInterpolationTokens(segments: segments, start: start)
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

    /// Skips the body of a removed `"""…"""` literal (GitLab #524).
    ///
    /// The text is already reported as one error; this walks to the
    /// closing delimiter (or end of file) so its contents do not lex into
    /// a second, unrelated complaint.
    private func skipPastTripleQuoteBody() {
        while !isAtEnd {
            if peek() == "\"" {
                let savedPos = pos
                let savedNext = nextPos
                let savedLoc = location
                _ = advance()
                if !isAtEnd && peek() == "\"" {
                    _ = advance()
                    if !isAtEnd && peek() == "\"" {
                        _ = advance()
                        return
                    }
                }
                pos = savedPos
                nextPos = savedNext
                location = savedLoc
            }
            _ = advance()
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

    /// Scans content inside ${...} interpolation, handling nested braces and single-quoted strings.
    ///
    /// Single quotes inside `${}` open a nested string region where `}` does not close the
    /// interpolation and the outer quote character is treated as a literal. This enables patterns like:
    /// ```aro
    /// "Query: ${SELECT * FROM t WHERE name = 'test'}"
    /// "Result: ${<items> where category = 'books'}"
    /// ```
    private func scanInterpolationContent(
        quote: Character,
        start: SourceLocation,
        segments: inout [(String, SourceLocation)]
    ) throws {
        var braceDepth = 1
        var content = ""
        let contentStart = location
        var insideSingleQuote = false  // Whether we're inside a '...' region

        while !isAtEnd && braceDepth > 0 {
            let char = peek()

            if char == "'" {
                // Toggle single-quote region
                insideSingleQuote.toggle()
                content.append(advance())
            } else if char == "\\" && insideSingleQuote {
                // Handle escape sequences inside single-quoted regions
                content.append(advance()) // backslash
                if !isAtEnd {
                    content.append(advance()) // escaped char
                }
            } else if char == "\n" && !insideSingleQuote {
                throw LexerError.unterminatedString(at: start)
            } else if char == "{" && !insideSingleQuote {
                braceDepth += 1
                content.append(advance())
            } else if char == "}" && !insideSingleQuote {
                braceDepth -= 1
                if braceDepth > 0 {
                    content.append(advance())
                } else {
                    _ = advance() // consume closing }
                }
            } else if char == quote && !insideSingleQuote {
                // Outer quote encountered outside any nested string — unterminated interpolation
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
    private func emitInterpolationTokens(segments: [(String, SourceLocation)], start: SourceLocation) throws {
        var i = 0
        while i < segments.count {
            let (content, loc) = segments[i]
            let span = SourceSpan(start: loc, end: loc)

            if content == "${" {
                addToken(.interpolationStart, lexeme: "${", start: loc)
                i += 1
                // Next segment is the expression content
                if i < segments.count {
                    let (exprContent, exprStart) = segments[i]
                    if exprContent != "}" {
                        // Re-lex the expression content to get real tokens,
                        // then move their spans onto this document.
                        tokens.append(contentsOf: try lexInterpolation(exprContent, at: exprStart))
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

    // MARK: - Interpolation Sub-Lexing (GitLab #659)

    /// Lexes the inside of a `${…}` interpolation and returns its tokens with
    /// spans expressed in *this* document's coordinates.
    ///
    /// The content is lexed by a second `Lexer` over a substring, so every
    /// location it produces starts again at 1:1. This used to be run as
    /// `try? Lexer.tokenize(exprContent)`, which had two consequences: a typo
    /// inside an interpolation produced an empty interpolation and no
    /// diagnostic at all, and the tokens that *did* come back carried spans
    /// into a fragment the editor has never seen — so hover, rename and
    /// go-to-definition inside an interpolation landed on line 1 of the file.
    ///
    /// Both halves are fixed here: the sub-lexer gets the enclosing
    /// collector's twin so its diagnostics can be re-based and merged, and a
    /// thrown `LexerError` is re-thrown at the position it actually occupies
    /// in this file rather than swallowed. The `try?` this replaces is exactly
    /// the kind CLAUDE.md forbids — a silent fallback that loses data.
    private func lexInterpolation(_ content: String, at base: SourceLocation) throws -> [Token] {
        // Mirror the enclosing lexer's error mode: with a collector it
        // recovers and reports, without one it throws. Its diagnostics land in
        // a private collector first so they can be re-based before merging.
        let inner: DiagnosticCollector? = diagnostics == nil ? nil : DiagnosticCollector()

        func drainDiagnostics() {
            guard let inner, let diagnostics else { return }
            for diagnostic in inner.diagnostics {
                diagnostics.add(Diagnostic(
                    severity: diagnostic.severity,
                    message: diagnostic.message,
                    location: diagnostic.location.map { Self.rebase($0, onto: base) },
                    hints: diagnostic.hints,
                    category: diagnostic.category
                ))
            }
        }

        do {
            let innerTokens = try Lexer.tokenize(content, diagnostics: inner)
            drainDiagnostics()
            return innerTokens
                .filter { $0.kind != .eof }
                .map {
                    Token(
                        kind: $0.kind,
                        span: SourceSpan(
                            start: Self.rebase($0.span.start, onto: base),
                            end: Self.rebase($0.span.end, onto: base)
                        ),
                        lexeme: intern($0.lexeme)
                    )
                }
        } catch let error as LexerError {
            // Report whatever the sub-lexer managed to collect before it gave
            // up, then re-throw at the right place in this file.
            drainDiagnostics()
            throw error.relocated(to: Self.rebase(error.location ?? SourceLocation(), onto: base))
        }
    }

    /// Maps a location inside an interpolation's content onto the enclosing
    /// document, given where that content starts.
    ///
    /// Column is relative only on the content's *first* line; after a line
    /// break inside the interpolation the inner column is already absolute.
    private static func rebase(_ inner: SourceLocation, onto base: SourceLocation) -> SourceLocation {
        SourceLocation(
            line: base.line + inner.line - 1,
            column: inner.line == 1 ? base.column + inner.column - 1 : inner.column,
            offset: base.offset + inner.offset,
            byteOffset: base.byteOffset + inner.byteOffset
        )
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
        // Save current position for backtracking (GitLab #115: byte positions)
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

        let raw = String(bytes: utf8[start.byteOffset..<pos], encoding: .utf8) ?? ""
        let lexeme = intern(raw)
        let lowerLexeme = intern(lexeme.lowercased())

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
    
    // MARK: - Character Access (GitLab #115: UTF-8 byte buffer)

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

    /// O(1) lookahead — uses the cached `nextPos` (GitLab #115, supersedes ARO-0057).
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

    // MARK: - String Interning

    /// Returns the canonical copy of `string`, reusing an existing allocation
    /// if the same content has been seen before.
    private func intern(_ string: String) -> String {
        if let existing = internTable[string] {
            return existing
        }
        internTable[string] = string
        return string
    }

    // MARK: - Token Creation

    /// Extracts the token's lexeme via O(1) byte-range slicing (GitLab #115).
    private func addToken(_ kind: TokenKind, start: SourceLocation) {
        let raw = String(bytes: utf8[start.byteOffset..<pos], encoding: .utf8) ?? ""
        let lexeme = intern(raw)
        addToken(kind, lexeme: lexeme, start: start)
    }

    private func addToken(_ kind: TokenKind, lexeme: String, start: SourceLocation) {
        let span = SourceSpan(start: start, end: location)
        tokens.append(Token(kind: kind, span: span, lexeme: intern(lexeme)))
        lastTokenKind = kind
    }
}

// MARK: - Convenience Extension

extension Lexer {
    /// Creates a lexer and tokenizes the source in one step
    public static func tokenize(_ source: String, diagnostics: DiagnosticCollector? = nil) throws -> [Token] {
        try Lexer(source: source, diagnostics: diagnostics).tokenize()
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
