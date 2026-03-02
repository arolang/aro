# Chapter 2: Lexical Analysis

## The Lexer Architecture

ARO's lexer (`Lexer.swift`, 703 lines) is a hand-written scanner that produces tokens for the parser. It maintains source location tracking, handles string interpolation, and disambiguates between regex literals and division.

```swift
public final class Lexer: @unchecked Sendable {
    private let source: String
    private var currentIndex: String.Index
    private var location: SourceLocation
    private var tokens: [Token] = []
    private var lastTokenKind: TokenKind?
}
```

The `@unchecked Sendable` annotation is necessary because `String.Index` is not `Sendable`, but the lexer is used single-threaded during parsing.

---

## Character Classification

The scanner processes characters one at a time, advancing through the source string. Character classification happens in the main `scanToken()` switch statement.

<svg viewBox="0 0 700 450" xmlns="http://www.w3.org/2000/svg">
  <style>
    .state { fill: #f5f5f5; stroke: #333; stroke-width: 2; }
    .start { fill: #dfd; }
    .terminal { fill: #fdd; }
    .arrow { fill: none; stroke: #333; stroke-width: 1.5; marker-end: url(#arrow3); }
    .label { font-family: monospace; font-size: 10px; fill: #333; }
    .title { font-family: monospace; font-size: 12px; fill: #333; font-weight: bold; }
    .condition { font-family: monospace; font-size: 9px; fill: #666; }
  </style>

  <defs>
    <marker id="arrow3" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#333"/>
    </marker>
  </defs>

  <!-- Start state -->
  <circle cx="80" cy="200" r="25" class="state start"/>
  <text x="80" y="205" class="title" text-anchor="middle">Start</text>

  <!-- Single char delimiters -->
  <rect x="160" y="30" width="100" height="40" rx="5" class="state terminal"/>
  <text x="210" y="55" class="label" text-anchor="middle">Single Char</text>
  <path d="M 100 185 Q 130 100 160 50" class="arrow"/>
  <text x="120" y="120" class="condition">( ) { } [ ] , ; @ ? * %</text>

  <!-- Multi-char operators -->
  <rect x="160" y="90" width="100" height="40" rx="5" class="state"/>
  <text x="210" y="115" class="label" text-anchor="middle">Peek Next</text>
  <path d="M 105 190 Q 125 150 160 110" class="arrow"/>
  <text x="115" y="165" class="condition">&lt; &gt; - + = !</text>

  <rect x="300" y="90" width="100" height="40" rx="5" class="state terminal"/>
  <text x="350" y="115" class="label" text-anchor="middle">Operator</text>
  <path d="M 260 110 L 300 110" class="arrow"/>

  <!-- String -->
  <rect x="160" y="150" width="100" height="40" rx="5" class="state"/>
  <text x="210" y="175" class="label" text-anchor="middle">String Scan</text>
  <path d="M 105 200 L 160 170" class="arrow"/>
  <text x="115" y="195" class="condition">" or '</text>

  <rect x="300" y="150" width="100" height="40" rx="5" class="state terminal"/>
  <text x="350" y="175" class="label" text-anchor="middle">String Token</text>
  <path d="M 260 170 L 300 170" class="arrow"/>

  <!-- Number -->
  <rect x="160" y="210" width="100" height="40" rx="5" class="state"/>
  <text x="210" y="235" class="label" text-anchor="middle">Number Scan</text>
  <path d="M 105 210 L 160 230" class="arrow"/>
  <text x="115" y="225" class="condition">0-9</text>

  <rect x="300" y="210" width="100" height="40" rx="5" class="state terminal"/>
  <text x="350" y="235" class="label" text-anchor="middle">Int/Float</text>
  <path d="M 260 230 L 300 230" class="arrow"/>

  <!-- Identifier -->
  <rect x="160" y="270" width="100" height="40" rx="5" class="state"/>
  <text x="210" y="295" class="label" text-anchor="middle">Ident Scan</text>
  <path d="M 105 210 L 160 290" class="arrow"/>
  <text x="105" y="255" class="condition">a-z A-Z _</text>

  <!-- Identifier branches -->
  <rect x="300" y="250" width="80" height="30" rx="5" class="state terminal"/>
  <text x="340" y="270" class="label" text-anchor="middle">Keyword</text>

  <rect x="300" y="290" width="80" height="30" rx="5" class="state terminal"/>
  <text x="340" y="310" class="label" text-anchor="middle">Article</text>

  <rect x="300" y="330" width="80" height="30" rx="5" class="state terminal"/>
  <text x="340" y="350" class="label" text-anchor="middle">Preposition</text>

  <rect x="300" y="370" width="80" height="30" rx="5" class="state terminal"/>
  <text x="340" y="390" class="label" text-anchor="middle">Identifier</text>

  <path d="M 260 285 L 280 265 L 300 265" class="arrow" style="marker-end: none;"/>
  <path d="M 280 265 L 300 265" class="arrow"/>
  <path d="M 260 290 L 300 305" class="arrow"/>
  <path d="M 260 295 L 280 345 L 300 345" class="arrow" style="marker-end: none;"/>
  <path d="M 280 345 L 300 345" class="arrow"/>
  <path d="M 260 300 L 280 385 L 300 385" class="arrow" style="marker-end: none;"/>
  <path d="M 280 385 L 300 385" class="arrow"/>

  <!-- Slash ambiguity -->
  <rect x="160" y="340" width="100" height="40" rx="5" class="state"/>
  <text x="210" y="365" class="label" text-anchor="middle">/ Ambiguous</text>
  <path d="M 100 215 Q 80 340 160 360" class="arrow"/>
  <text x="70" y="290" class="condition">/</text>

  <rect x="300" y="410" width="80" height="30" rx="5" class="state terminal"/>
  <text x="340" y="430" class="label" text-anchor="middle">Slash</text>

  <rect x="400" y="340" width="80" height="30" rx="5" class="state terminal"/>
  <text x="440" y="360" class="label" text-anchor="middle">Regex</text>

  <path d="M 260 350 L 400 350" class="arrow"/>
  <text x="320" y="345" class="condition">try regex succeeds</text>

  <path d="M 260 370 L 280 425 L 300 425" class="arrow" style="marker-end: none;"/>
  <path d="M 280 425 L 300 425" class="arrow"/>
  <text x="265" y="400" class="condition">else</text>

  <!-- Legend -->
  <rect x="500" y="30" width="180" height="100" fill="none" stroke="#ccc"/>
  <text x="510" y="50" class="title">Legend</text>
  <rect x="510" y="60" width="20" height="15" class="state start"/>
  <text x="535" y="72" class="label">Start state</text>
  <rect x="510" y="85" width="20" height="15" class="state"/>
  <text x="535" y="97" class="label">Processing</text>
  <rect x="510" y="110" width="20" height="15" class="state terminal"/>
  <text x="535" y="122" class="label">Emit token</text>
</svg>

**Figure 2.1**: Character classification state machine. The lexer advances character by character, branching based on the current character into specialized scanning functions.

---

## First-Class Language Elements

A distinctive feature of ARO's lexer is that articles and prepositions are first-class token types, not just keywords or identifiers.

```swift
// Token.swift:203-230
public enum Article: String, Sendable, CaseIterable {
    case a = "a"
    case an = "an"
    case the = "the"
}

public enum Preposition: String, Sendable, CaseIterable {
    case from = "from"
    case `for` = "for"
    case against = "against"
    case to = "to"
    case into = "into"
    case via = "via"
    case with = "with"
    case on = "on"
    case at = "at"
    case by = "by"
}
```

### Why This Matters

Most languages would treat `from` as either a keyword or an identifier. In ARO, it is a `TokenKind.preposition(.from)`. This distinction enables:

1. **Parser simplification**: The parser can match on `.preposition` directly without string comparisons.

2. **Semantic information in tokens**: `Preposition.indicatesExternalSource` property allows early classification of data sources.

3. **Error messages**: "Expected preposition, found identifier" is more helpful than "Expected 'from', found 'foo'".

<svg viewBox="0 0 600 300" xmlns="http://www.w3.org/2000/svg">
  <style>
    .box { fill: #f5f5f5; stroke: #333; stroke-width: 1.5; }
    .category { fill: #e8e8f4; }
    .label { font-family: monospace; font-size: 10px; fill: #333; }
    .title { font-family: monospace; font-size: 12px; fill: #333; font-weight: bold; }
  </style>

  <!-- TokenKind enum -->
  <rect x="20" y="20" width="560" height="260" rx="5" class="box"/>
  <text x="30" y="40" class="title">enum TokenKind</text>

  <!-- Delimiters -->
  <rect x="30" y="50" width="120" height="70" rx="3" class="box category"/>
  <text x="40" y="68" class="title">Delimiters</text>
  <text x="40" y="85" class="label">leftParen</text>
  <text x="40" y="97" class="label">leftAngle</text>
  <text x="40" y="109" class="label">colon, dot...</text>

  <!-- Operators -->
  <rect x="160" y="50" width="120" height="70" rx="3" class="box category"/>
  <text x="170" y="68" class="title">Operators</text>
  <text x="170" y="85" class="label">plus, minus</text>
  <text x="170" y="97" class="label">equalEqual</text>
  <text x="170" y="109" class="label">lessEqual...</text>

  <!-- Keywords -->
  <rect x="290" y="50" width="120" height="70" rx="3" class="box category"/>
  <text x="300" y="68" class="title">Keywords</text>
  <text x="300" y="85" class="label">if, when, match</text>
  <text x="300" y="97" class="label">for, each, in</text>
  <text x="300" y="109" class="label">and, or, not...</text>

  <!-- Literals -->
  <rect x="420" y="50" width="150" height="70" rx="3" class="box category"/>
  <text x="430" y="68" class="title">Literals</text>
  <text x="430" y="85" class="label">identifier(String)</text>
  <text x="430" y="97" class="label">stringLiteral(String)</text>
  <text x="430" y="109" class="label">intLiteral(Int)...</text>

  <!-- Articles - highlighted -->
  <rect x="30" y="130" width="120" height="60" rx="3" class="box" fill="#dfd"/>
  <text x="40" y="148" class="title">Articles</text>
  <text x="40" y="165" class="label">article(Article)</text>
  <text x="40" y="180" class="label">.a, .an, .the</text>

  <!-- Prepositions - highlighted -->
  <rect x="160" y="130" width="150" height="60" rx="3" class="box" fill="#dfd"/>
  <text x="170" y="148" class="title">Prepositions</text>
  <text x="170" y="165" class="label">preposition(Preposition)</text>
  <text x="170" y="180" class="label">.from, .to, .with...</text>

  <!-- String Interpolation -->
  <rect x="320" y="130" width="130" height="60" rx="3" class="box category"/>
  <text x="330" y="148" class="title">Interpolation</text>
  <text x="330" y="165" class="label">stringSegment</text>
  <text x="330" y="180" class="label">interpolationStart/End</text>

  <!-- Special -->
  <rect x="460" y="130" width="110" height="60" rx="3" class="box category"/>
  <text x="470" y="148" class="title">Special</text>
  <text x="470" y="165" class="label">eof</text>
  <text x="470" y="180" class="label">regexLiteral</text>

  <!-- Note -->
  <rect x="30" y="200" width="540" height="70" rx="3" fill="#ffe" stroke="#cc9"/>
  <text x="40" y="220" class="title">Design Decision</text>
  <text x="40" y="240" class="label">Articles and prepositions are distinct token types, not keywords.</text>
  <text x="40" y="255" class="label">This enables parser-level grammar matching and semantic classification.</text>
</svg>

**Figure 2.2**: Token type hierarchy. Articles and prepositions (green) are separate categories from keywords, enabling grammar-level matching.

---

## String Interpolation Challenge

String interpolation (`"Hello ${<name>}!"`) requires the lexer to emit multiple tokens for a single string literal. This is handled by a state machine within `scanString()`.

### The Problem

A naive approach would produce:
```
stringLiteral("Hello ${<name>}!")  // Wrong: expression is lost
```

ARO needs:
```
stringSegment("Hello ")
interpolationStart
leftAngle
identifier("name")
rightAngle
interpolationEnd
```

### Implementation Strategy

```swift
// Lexer.swift:263-276
} else if char == "$" && peekNext() == "{" {
    hasInterpolation = true
    let segmentStart = location
    if !value.isEmpty {
        segments.append((value, segmentStart))
        value = ""
    }
    _ = advance() // $
    _ = advance() // {
    segments.append(("${", location))
    try scanInterpolationContent(quote: quote, start: start, segments: &segments)
}
```

The key insight is that interpolation content is **re-lexed**. The scanner extracts the content between `${` and `}`, then creates a fresh lexer to tokenize it:

```swift
// Lexer.swift:386-393
if let exprTokens = try? Lexer.tokenize(exprContent) {
    for token in exprTokens where token.kind != .eof {
        tokens.append(token)
    }
}
```

<svg viewBox="0 0 700 200" xmlns="http://www.w3.org/2000/svg">
  <style>
    .box { fill: #f5f5f5; stroke: #333; stroke-width: 1.5; }
    .token { fill: #e8f4e8; stroke: #4a4; stroke-width: 1.5; }
    .arrow { fill: none; stroke: #333; stroke-width: 1.5; marker-end: url(#arrow4); }
    .label { font-family: monospace; font-size: 10px; fill: #333; }
    .source { font-family: monospace; font-size: 14px; fill: #333; }
    .title { font-family: monospace; font-size: 11px; fill: #333; font-weight: bold; }
  </style>

  <defs>
    <marker id="arrow4" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#333"/>
    </marker>
  </defs>

  <!-- Source string -->
  <rect x="30" y="30" width="640" height="35" rx="5" class="box"/>
  <text x="40" y="55" class="source">"Hello ${&lt;name&gt;}!"</text>

  <!-- Arrow down -->
  <line x1="350" y1="65" x2="350" y2="90" class="arrow"/>

  <!-- Token sequence -->
  <rect x="30" y="100" width="85" height="40" rx="3" class="token"/>
  <text x="45" y="115" class="title">segment</text>
  <text x="45" y="130" class="label">"Hello "</text>

  <rect x="125" y="100" width="60" height="40" rx="3" class="token"/>
  <text x="133" y="115" class="title">interp</text>
  <text x="133" y="130" class="label">${</text>

  <rect x="195" y="100" width="40" height="40" rx="3" class="token"/>
  <text x="205" y="115" class="title">&lt;</text>
  <text x="200" y="130" class="label">angle</text>

  <rect x="245" y="100" width="80" height="40" rx="3" class="token"/>
  <text x="255" y="115" class="title">ident</text>
  <text x="255" y="130" class="label">"name"</text>

  <rect x="335" y="100" width="40" height="40" rx="3" class="token"/>
  <text x="345" y="115" class="title">&gt;</text>
  <text x="340" y="130" class="label">angle</text>

  <rect x="385" y="100" width="60" height="40" rx="3" class="token"/>
  <text x="393" y="115" class="title">interp</text>
  <text x="393" y="130" class="label">}</text>

  <rect x="455" y="100" width="60" height="40" rx="3" class="token"/>
  <text x="463" y="115" class="title">segment</text>
  <text x="463" y="130" class="label">"!"</text>

  <!-- Legend -->
  <rect x="530" y="100" width="140" height="70" fill="none" stroke="#ccc"/>
  <text x="540" y="118" class="title">7 tokens from</text>
  <text x="540" y="133" class="title">1 string literal</text>
  <text x="540" y="155" class="label">Inner tokens from</text>
  <text x="540" y="168" class="label">recursive lexing</text>
</svg>

**Figure 2.3**: Interpolation token sequence. A single interpolated string produces multiple tokens, with the interpolated expression re-lexed recursively.

### Nested Brace Handling

Interpolations can contain nested braces (e.g., `${<map>["key"]}`). The lexer tracks brace depth:

```swift
// Lexer.swift:340-360
while !isAtEnd && braceDepth > 0 {
    let char = peek()
    if char == "{" {
        braceDepth += 1
        content.append(advance())
    } else if char == "}" {
        braceDepth -= 1
        if braceDepth > 0 {
            content.append(advance())
        } else {
            _ = advance() // closing }
        }
    }
    // ...
}
```

---

## Regex vs Division Ambiguity

The character `/` is ambiguous: it could start a regex literal (`/pattern/flags`) or be a division operator (`a / b`). This is a classic lexer challenge that ARO solves with context and lookahead.

### The Heuristic

```swift
// Lexer.swift:131-150
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
```

The rules:
1. If the previous token was an identifier, `/` is division (e.g., `a / b`)
2. If the previous token was `.`, `/` is division (import paths like `../../shared`)
3. If followed by whitespace, `/` is division
4. Otherwise, attempt regex scanning

### Regex Scanning with Backtracking

If the heuristic suggests a regex, the lexer attempts to scan it. If scanning fails (no closing `/`), it backtracks:

```swift
// Lexer.swift:513-556
private func tryScanRegex(start: SourceLocation) -> (pattern: String, flags: String)? {
    let savedIndex = currentIndex
    let savedLocation = location

    // Attempt to scan pattern...

    if !foundClosingSlash || pattern.isEmpty {
        currentIndex = savedIndex
        location = savedLocation
        return nil
    }

    return (pattern: pattern, flags: flags)
}
```

This is one of the few places in the lexer that requires backtracking. The alternative would be a more complex grammar or forcing regex literals to use different delimiters.

---

## Source Location Tracking

Every token carries a `SourceSpan` indicating where it came from in the source. This is essential for error reporting.

```swift
// SourceLocation.swift
public struct SourceLocation: Sendable, Equatable {
    public let line: Int      // 1-based
    public let column: Int    // 1-based
    public let offset: Int    // 0-based byte offset
}

public struct SourceSpan: Sendable, Equatable {
    public let start: SourceLocation
    public let end: SourceLocation
}
```

The lexer updates location on every `advance()`:

```swift
// Lexer.swift:660-665
@discardableResult
private func advance() -> Character {
    let char = source[currentIndex]
    currentIndex = source.index(after: currentIndex)
    location = location.advancing(past: char)
    return char
}
```

The `advancing(past:)` method handles newlines specially, incrementing the line number and resetting the column.

---

## Keyword Recognition

ARO's keywords are recognized after identifier scanning, not during character classification. This avoids the "keyword vs identifier" problem where a language accidentally reserves useful names.

```swift
// Lexer.swift:572-601
private func scanIdentifierOrKeyword(start: SourceLocation) throws {
    while !isAtEnd && (peek().isLetter || peek().isNumber || peek() == "_") {
        _ = advance()
    }

    let lexeme = String(source[...])
    let lowerLexeme = lexeme.lowercased()

    // Check keywords first
    if let keyword = Self.keywords[lowerLexeme] {
        addToken(keyword, lexeme: lexeme, start: start)
        return
    }

    // Check articles
    if let article = Article(rawValue: lowerLexeme) {
        addToken(.article(article), lexeme: lexeme, start: start)
        return
    }

    // Check prepositions
    if let preposition = Preposition(rawValue: lowerLexeme) {
        addToken(.preposition(preposition), lexeme: lexeme, start: start)
        return
    }

    // Regular identifier
    addToken(.identifier(lexeme), lexeme: lexeme, start: start)
}
```

Note that keyword matching is case-insensitive (`lowerLexeme`), but the original case is preserved in the lexeme for error messages.

---

## Comment Handling

ARO supports two comment styles:
- Block comments: `(* comment *)`
- Line comments: `// comment`

Comments are skipped entirely; they do not produce tokens:

```swift
// Lexer.swift:605-640
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
```

Block comments use `(* *)` rather than `/* */` to avoid ambiguity with the star operator in multiplication expressions.

---

## Error Handling

Lexer errors are thrown as `LexerError`:

```swift
public enum LexerError: Error {
    case unexpectedCharacter(Character, at: SourceLocation)
    case unterminatedString(at: SourceLocation)
    case invalidEscapeSequence(Character, at: SourceLocation)
    case invalidUnicodeEscape(String, at: SourceLocation)
    case invalidNumber(String, at: SourceLocation)
}
```

Each error carries the source location where it occurred, enabling precise error reporting:

```
Error: Unterminated string literal
  at line 5, column 12
```

---

## Chapter Summary

ARO's lexer demonstrates several design choices:

1. **Articles and prepositions as token types**: Enables grammar-level matching rather than string comparison in the parser.

2. **String interpolation via recursive lexing**: The content of `${...}` is extracted and re-tokenized, producing multiple tokens from a single string.

3. **Regex/division disambiguation**: Uses context (previous token) and backtracking to resolve the `/` ambiguity.

4. **Source location on every token**: Enables precise error messages throughout the compilation pipeline.

The lexer is 703 lines—small for a language implementation. The constrained syntax (no user-defined operators, fixed token types) keeps it manageable.

Implementation reference: `Sources/AROParser/Lexer.swift`

---

*Next: Chapter 3 — Syntactic Analysis*
