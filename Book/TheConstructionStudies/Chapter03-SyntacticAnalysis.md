# Chapter 3: Syntactic Analysis

## Hybrid Parser Design

ARO's parser (`Parser.swift`, 1700+ lines) uses a hybrid approach: **recursive descent** for statements and program structure, **Pratt parsing** for expressions. This combination leverages the strengths of each technique.

```swift
public final class Parser {
    private let tokens: [Token]
    private var current: Int = 0
    private let diagnostics: DiagnosticCollector
}
```

<svg viewBox="0 0 700 350" xmlns="http://www.w3.org/2000/svg">
  <style>
    .box { fill: #f5f5f5; stroke: #333; stroke-width: 1.5; }
    .rd { fill: #e8f4e8; }
    .pratt { fill: #e8e8f4; }
    .arrow { fill: none; stroke: #333; stroke-width: 1.5; marker-end: url(#arrow5); }
    .label { font-family: monospace; font-size: 10px; fill: #333; }
    .title { font-family: monospace; font-size: 12px; fill: #333; font-weight: bold; }
  </style>

  <defs>
    <marker id="arrow5" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#333"/>
    </marker>
  </defs>

  <!-- Parser entry -->
  <rect x="50" y="30" width="120" height="50" rx="5" class="box"/>
  <text x="110" y="50" class="title" text-anchor="middle">parse()</text>
  <text x="110" y="68" class="label" text-anchor="middle">Entry point</text>

  <!-- Recursive Descent section -->
  <rect x="30" y="100" width="300" height="220" rx="5" class="box rd"/>
  <text x="180" y="120" class="title" text-anchor="middle">Recursive Descent</text>

  <rect x="50" y="140" width="120" height="40" rx="3" class="box"/>
  <text x="110" y="165" class="label" text-anchor="middle">parseFeatureSet()</text>

  <rect x="50" y="190" width="120" height="40" rx="3" class="box"/>
  <text x="110" y="215" class="label" text-anchor="middle">parseStatement()</text>

  <rect x="50" y="240" width="120" height="40" rx="3" class="box"/>
  <text x="110" y="265" class="label" text-anchor="middle">parseAROStatement()</text>

  <rect x="190" y="140" width="120" height="40" rx="3" class="box"/>
  <text x="250" y="165" class="label" text-anchor="middle">parseMatchStatement()</text>

  <rect x="190" y="190" width="120" height="40" rx="3" class="box"/>
  <text x="250" y="215" class="label" text-anchor="middle">parseForEachLoop()</text>

  <rect x="190" y="240" width="120" height="40" rx="3" class="box"/>
  <text x="250" y="265" class="label" text-anchor="middle">parseQualifiedNoun()</text>

  <!-- Arrows within RD -->
  <path d="M 110 80 L 110 140" class="arrow"/>
  <path d="M 110 180 L 110 190" class="arrow"/>
  <path d="M 110 230 L 110 240" class="arrow"/>

  <!-- Pratt Parsing section -->
  <rect x="370" y="100" width="300" height="220" rx="5" class="box pratt"/>
  <text x="520" y="120" class="title" text-anchor="middle">Pratt Parsing</text>

  <rect x="390" y="140" width="120" height="40" rx="3" class="box"/>
  <text x="450" y="165" class="label" text-anchor="middle">parseExpression()</text>

  <rect x="390" y="190" width="120" height="40" rx="3" class="box"/>
  <text x="450" y="215" class="label" text-anchor="middle">parsePrecedence()</text>

  <rect x="390" y="240" width="120" height="40" rx="3" class="box"/>
  <text x="450" y="265" class="label" text-anchor="middle">parsePrefix()</text>

  <rect x="530" y="190" width="120" height="40" rx="3" class="box"/>
  <text x="590" y="215" class="label" text-anchor="middle">parseInfix()</text>

  <rect x="530" y="240" width="120" height="40" rx="3" class="box"/>
  <text x="590" y="265" class="label" text-anchor="middle">infixPrecedence()</text>

  <!-- Arrows within Pratt -->
  <path d="M 450 180 L 450 190" class="arrow"/>
  <path d="M 450 230 L 450 240" class="arrow"/>
  <path d="M 510 210 L 530 210" class="arrow"/>

  <!-- Connection between RD and Pratt -->
  <path d="M 170 260 Q 280 290 390 160" class="arrow" stroke-dasharray="5,3"/>
  <text x="280" y="275" class="label">when clause,</text>
  <text x="280" y="290" class="label">filter, literal</text>

  <!-- Legend -->
  <rect x="30" y="330" width="200" height="15" fill="none"/>
  <rect x="30" y="330" width="15" height="15" class="rd"/>
  <text x="50" y="342" class="label">Recursive Descent</text>
  <rect x="150" y="330" width="15" height="15" class="pratt"/>
  <text x="170" y="342" class="label">Pratt Parsing</text>
</svg>

**Figure 3.1**: Parser architecture. Recursive descent handles statements; Pratt parsing handles expressions. The dashed line shows where statement parsing calls into expression parsing.

---

## Why Recursive Descent for Statements

ARO's statement syntax has a predictable structure that maps naturally to recursive descent:

```
FeatureSet  ::= "(" name ":" activity ")" "{" Statement* "}"
Statement   ::= AROStatement | MatchStatement | ForEachLoop
AROStatement ::= "<" verb ">" [article] "<" result ">" preposition [article] "<" object ">" "."
```

Each grammar rule becomes a parsing function:

```swift
// Parser.swift:119-159
private func parseFeatureSet() throws -> FeatureSet {
    let startToken = try expect(.leftParen, message: "'('")

    let name = try parseIdentifierSequence()
    try expect(.colon, message: "':'")
    let activity = try parseIdentifierSequence()

    try expect(.rightParen, message: "')'")
    try expect(.leftBrace, message: "'{'")

    var statements: [Statement] = []
    while !check(.rightBrace) && !isAtEnd {
        let statement = try parseStatement()
        statements.append(statement)
    }

    let endToken = try expect(.rightBrace, message: "'}'")
    return FeatureSet(name: name, businessActivity: activity, statements: statements, span: ...)
}
```

The advantages for statements:
1. **One-to-one mapping**: Each grammar rule is a function
2. **Natural error handling**: Try-catch at each level
3. **Easy to extend**: Adding a new statement type is adding a function

---

## Why Pratt for Expressions

Expression parsing requires handling operator precedence. Consider: `<a> + <b> * <c>`. This should parse as `<a> + (<b> * <c>)` because multiplication binds tighter than addition.

Pratt parsing (also called "top-down operator precedence") handles this elegantly with precedence levels:

```swift
// Parser.swift:1227-1241
private enum Precedence: Int, Comparable {
    case none = 0
    case or = 1           // or
    case and = 2          // and
    case equality = 3     // == != is
    case comparison = 4   // < > <= >=
    case term = 5         // + - ++
    case factor = 6       // * / %
    case unary = 7        // - not
    case postfix = 8      // . []
}
```

The core loop is remarkably simple:

```swift
// Parser.swift:1252-1269
private func parsePrecedence(_ minPrecedence: Precedence) throws -> any Expression {
    // Parse prefix (primary or unary)
    var left = try parsePrefix()

    // Parse infix operators at or above minPrecedence
    while let prec = infixPrecedence(peek()), prec > minPrecedence {
        left = try parseInfix(left: left, precedence: prec)
    }

    // Handle postfix existence check: <expr> exists
    if check(.exists) {
        advance()
        left = ExistenceExpression(expression: left, span: left.span)
    }

    return left
}
```

<svg viewBox="0 0 700 380" xmlns="http://www.w3.org/2000/svg">
  <style>
    .box { fill: #f5f5f5; stroke: #333; stroke-width: 1.5; }
    .active { fill: #ffe; }
    .done { fill: #efe; }
    .arrow { fill: none; stroke: #333; stroke-width: 1.5; marker-end: url(#arrow6); }
    .label { font-family: monospace; font-size: 10px; fill: #333; }
    .title { font-family: monospace; font-size: 11px; fill: #333; font-weight: bold; }
    .expr { font-family: monospace; font-size: 14px; fill: #333; }
  </style>

  <defs>
    <marker id="arrow6" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#333"/>
    </marker>
  </defs>

  <!-- Expression being parsed -->
  <text x="50" y="30" class="expr">Parsing: &lt;a&gt; + &lt;b&gt; * &lt;c&gt;</text>

  <!-- Step 1 -->
  <rect x="30" y="50" width="200" height="70" rx="5" class="box active"/>
  <text x="40" y="70" class="title">Step 1: parsePrecedence(.none)</text>
  <text x="40" y="90" class="label">parsePrefix() → &lt;a&gt;</text>
  <text x="40" y="105" class="label">infixPrecedence(+) = .term (5)</text>
  <text x="40" y="115" class="label">5 > 0, continue</text>

  <!-- Step 2 -->
  <rect x="250" y="50" width="200" height="70" rx="5" class="box"/>
  <text x="260" y="70" class="title">Step 2: parseInfix(a, .term)</text>
  <text x="260" y="90" class="label">consume +</text>
  <text x="260" y="105" class="label">parsePrecedence(.term)</text>
  <text x="260" y="115" class="label">↓ recursive call</text>

  <!-- Step 3 -->
  <rect x="470" y="50" width="200" height="70" rx="5" class="box"/>
  <text x="480" y="70" class="title">Step 3: parsePrecedence(.term)</text>
  <text x="480" y="90" class="label">parsePrefix() → &lt;b&gt;</text>
  <text x="480" y="105" class="label">infixPrecedence(*) = .factor (6)</text>
  <text x="480" y="115" class="label">6 > 5, continue</text>

  <!-- Step 4 -->
  <rect x="470" y="140" width="200" height="70" rx="5" class="box"/>
  <text x="480" y="160" class="title">Step 4: parseInfix(b, .factor)</text>
  <text x="480" y="180" class="label">consume *</text>
  <text x="480" y="195" class="label">parsePrecedence(.factor)</text>
  <text x="480" y="205" class="label">↓ recursive call</text>

  <!-- Step 5 -->
  <rect x="470" y="230" width="200" height="70" rx="5" class="box"/>
  <text x="480" y="250" class="title">Step 5: parsePrecedence(.factor)</text>
  <text x="480" y="270" class="label">parsePrefix() → &lt;c&gt;</text>
  <text x="480" y="285" class="label">infixPrecedence(.) = nil</text>
  <text x="480" y="295" class="label">return &lt;c&gt;</text>

  <!-- Unwind -->
  <rect x="250" y="230" width="200" height="70" rx="5" class="box done"/>
  <text x="260" y="250" class="title">Step 6: Back in step 4</text>
  <text x="260" y="270" class="label">right = &lt;c&gt;</text>
  <text x="260" y="285" class="label">return Binary(b, *, c)</text>

  <rect x="30" y="230" width="200" height="70" rx="5" class="box done"/>
  <text x="40" y="250" class="title">Step 7: Back in step 2</text>
  <text x="40" y="270" class="label">right = Binary(b, *, c)</text>
  <text x="40" y="285" class="label">return Binary(a, +, b*c)</text>

  <!-- Result -->
  <rect x="30" y="320" width="640" height="45" rx="5" class="box done"/>
  <text x="40" y="340" class="title">Result AST:</text>
  <text x="40" y="355" class="expr">BinaryExpr(a, +, BinaryExpr(b, *, c))</text>

  <!-- Arrows -->
  <path d="M 230 85 L 250 85" class="arrow"/>
  <path d="M 450 85 L 470 85" class="arrow"/>
  <path d="M 570 120 L 570 140" class="arrow"/>
  <path d="M 570 210 L 570 230" class="arrow"/>
  <path d="M 470 265 L 450 265" class="arrow"/>
  <path d="M 250 265 L 230 265" class="arrow"/>
</svg>

**Figure 3.2**: Precedence climbing for `<a> + <b> * <c>`. The key insight: when parsing the right side of `+`, we call `parsePrecedence(.term)`. This means `*` (which has higher precedence) will be consumed, but `+` (same or lower) would not.

---

## The AROStatement Parse

The core statement form is: `Action [article] <Result> preposition [article] <Object> [clauses] .`

```swift
// Parser.swift:197-350 (simplified)
private func parseAROStatement(startToken: Token) throws -> AROStatement {
    // Parse action verb
    let actionToken = try expectIdentifier(message: "action verb")
    let action = Action(verb: actionToken.lexeme, span: actionToken.span)
    try expect(.rightAngle, message: "'>'")

    // Skip optional article before result
    if case .article = peek().kind { advance() }

    // Parse result
    try expect(.leftAngle, message: "'<'")
    let result = try parseQualifiedNoun()
    try expect(.rightAngle, message: "'>'")

    // Parse preposition
    guard case .preposition(let prep) = peek().kind else {
        throw ParserError.unexpectedToken(expected: "preposition", got: peek())
    }
    advance()

    // Skip optional article before object
    if case .article = peek().kind { advance() }

    // Parse object
    try expect(.leftAngle, message: "'<'")
    let objectNoun = try parseQualifiedNoun()
    try expect(.rightAngle, message: "'>'")

    // Parse optional clauses (where, when)
    // ...

    try expect(.dot, message: "'.'")

    return AROStatement(action: action, result: result, preposition: prep, object: objectNoun, ...)
}
```

<svg viewBox="0 0 700 250" xmlns="http://www.w3.org/2000/svg">
  <style>
    .box { fill: #f5f5f5; stroke: #333; stroke-width: 1.5; }
    .token { fill: #e8f4e8; stroke: #4a4; stroke-width: 1.5; }
    .arrow { fill: none; stroke: #333; stroke-width: 1.5; marker-end: url(#arrow7); }
    .label { font-family: monospace; font-size: 10px; fill: #333; }
    .title { font-family: monospace; font-size: 11px; fill: #333; font-weight: bold; }
  </style>

  <defs>
    <marker id="arrow7" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#333"/>
    </marker>
  </defs>

  <!-- Source -->
  <text x="30" y="30" class="title">Source: &lt;Extract&gt; the &lt;user: id&gt; from the &lt;request: body&gt;.</text>

  <!-- Token flow -->
  <rect x="30" y="50" width="50" height="30" rx="3" class="token"/>
  <text x="55" y="70" class="label" text-anchor="middle">&lt;</text>

  <rect x="90" y="50" width="70" height="30" rx="3" class="token"/>
  <text x="125" y="70" class="label" text-anchor="middle">Extract</text>

  <rect x="170" y="50" width="30" height="30" rx="3" class="token"/>
  <text x="185" y="70" class="label" text-anchor="middle">&gt;</text>

  <rect x="210" y="50" width="40" height="30" rx="3" class="token"/>
  <text x="230" y="70" class="label" text-anchor="middle">the</text>

  <rect x="260" y="50" width="30" height="30" rx="3" class="token"/>
  <text x="275" y="70" class="label" text-anchor="middle">&lt;</text>

  <rect x="300" y="50" width="80" height="30" rx="3" class="token"/>
  <text x="340" y="70" class="label" text-anchor="middle">user: id</text>

  <rect x="390" y="50" width="30" height="30" rx="3" class="token"/>
  <text x="405" y="70" class="label" text-anchor="middle">&gt;</text>

  <rect x="430" y="50" width="50" height="30" rx="3" class="token"/>
  <text x="455" y="70" class="label" text-anchor="middle">from</text>

  <rect x="490" y="50" width="40" height="30" rx="3" class="token"/>
  <text x="510" y="70" class="label" text-anchor="middle">the</text>

  <rect x="540" y="50" width="30" height="30" rx="3" class="token"/>
  <text x="555" y="70" class="label" text-anchor="middle">&lt;</text>

  <rect x="580" y="50" width="80" height="30" rx="3" class="token"/>
  <text x="620" y="70" class="label" text-anchor="middle">request:body</text>

  <rect x="30" y="90" width="30" height="30" rx="3" class="token"/>
  <text x="45" y="110" class="label" text-anchor="middle">&gt;</text>

  <rect x="70" y="90" width="30" height="30" rx="3" class="token"/>
  <text x="85" y="110" class="label" text-anchor="middle">.</text>

  <!-- Parse steps -->
  <rect x="30" y="140" width="170" height="30" rx="3" class="box"/>
  <text x="40" y="160" class="label">expect(&lt;), ident, expect(&gt;)</text>

  <rect x="210" y="140" width="80" height="30" rx="3" class="box"/>
  <text x="220" y="160" class="label">skip article</text>

  <rect x="300" y="140" width="120" height="30" rx="3" class="box"/>
  <text x="310" y="160" class="label">parseQualifiedNoun()</text>

  <rect x="430" y="140" width="100" height="30" rx="3" class="box"/>
  <text x="440" y="160" class="label">expect(prep)</text>

  <rect x="540" y="140" width="130" height="30" rx="3" class="box"/>
  <text x="550" y="160" class="label">parseQualifiedNoun()</text>

  <rect x="30" y="180" width="70" height="30" rx="3" class="box"/>
  <text x="40" y="200" class="label">expect(.)</text>

  <!-- Arrows -->
  <path d="M 55 80 L 55 140" class="arrow" style="marker-end: none;"/>
  <path d="M 125 80 L 125 140" class="arrow" style="marker-end: none;"/>
  <path d="M 185 80 L 170 140" class="arrow" style="marker-end: none;"/>
  <path d="M 230 80 L 250 140" class="arrow" style="marker-end: none;"/>
  <path d="M 340 80 L 360 140" class="arrow" style="marker-end: none;"/>
  <path d="M 455 80 L 480 140" class="arrow" style="marker-end: none;"/>
  <path d="M 620 80 L 605 140" class="arrow" style="marker-end: none;"/>
  <path d="M 45 120 L 55 140" class="arrow" style="marker-end: none;"/>
  <path d="M 85 120 L 55 180" class="arrow" style="marker-end: none;"/>

  <!-- AST Result -->
  <rect x="30" y="220" width="640" height="30" rx="3" class="box" fill="#efe"/>
  <text x="40" y="240" class="label">AROStatement(action: "Extract", result: "user:id", prep: .from, object: "request:body")</text>
</svg>

**Figure 3.3**: Statement parsing flowchart. Each token is consumed in order, with optional articles skipped.

---

## Error Recovery Strategy

When parsing fails, the parser needs to recover and continue. ARO uses **synchronization points** to find safe places to resume.

### Feature Set Level Recovery

```swift
// Parser.swift:1191-1199
private func synchronize() {
    while !isAtEnd {
        // Look for the start of a new feature set
        if check(.leftParen) {
            return
        }
        advance()
    }
}
```

If parsing a feature set fails, skip tokens until we find `(` which starts the next feature set.

### Statement Level Recovery

```swift
// Parser.swift:1201-1221
private func synchronizeToNextStatement() {
    while !isAtEnd {
        // If we just passed a dot, we're at a new statement
        if previous().kind == .dot {
            return
        }

        // If we see a closing brace, stop
        if check(.rightBrace) {
            return
        }

        // If we see an opening angle bracket, we might be at a new statement
        if check(.leftAngle) {
            return
        }

        advance()
    }
}
```

The synchronization points are:
1. `.` (statement terminator—most reliable)
2. `}` (feature set end)
3. `<` (possible statement start)

### Diagnostic Collection

Errors are collected rather than immediately thrown:

```swift
// Parser.swift:44-51
while !isAtEnd {
    do {
        let featureSet = try parseFeatureSet()
        featureSets.append(featureSet)
    } catch let error as ParserError {
        diagnostics.report(error)  // Collect, don't abort
        synchronize()              // Recover
    }
}
```

This enables reporting multiple errors in a single parse pass.

---

## Single Lookahead Limitation

ARO's parser uses single-token lookahead (`peek()` returns the current token, `advance()` moves forward). This creates disambiguation challenges.

### The `<` Ambiguity

The character `<` can mean:
- Start of a variable reference: `<user>`
- Less-than operator: `<a> < <b>`
- Start of an action: `<Extract>`

The parser uses context to disambiguate:

```swift
// Parser.swift:1367-1376
case .leftAngle, .rightAngle:
    // Only treat as comparison if not followed by identifier
    let nextIndex = current + 1
    if nextIndex < tokens.count {
        if case .identifier = tokens[nextIndex].kind {
            // This could be starting a variable ref, don't treat as comparison
            return nil
        }
    }
    return .comparison
```

### The `.` Ambiguity

The character `.` can mean:
- Member access: `<user>.name`
- Statement terminator: `... object>.`

```swift
// Parser.swift:1381-1389
case .dot:
    // Only treat . as member access if followed by identifier
    let nextIndex = current + 1
    if nextIndex < tokens.count {
        if case .identifier = tokens[nextIndex].kind {
            return .postfix
        }
    }
    return nil  // Statement terminator
```

### The `for` Ambiguity

The keyword `for` is both:
- The preposition `.for` ("for the user")
- The loop keyword `.for` ("for each")

```swift
// Parser.swift:252-256
} else if case .for = peek().kind {
    // Accept "for" keyword as the preposition .for
    prep = .for
    advance()
}
```

These disambiguations work because ARO's grammar is constrained. A more complex language would need multi-token lookahead or backtracking.

---

## Qualified Noun Parsing

The `QualifiedNoun` is a core concept: `base` optionally followed by `: specifier`.

```swift
// Parser.swift:950-967
private func parseQualifiedNoun() throws -> QualifiedNoun {
    let startToken = peek()
    let base = try parseCompoundIdentifier()
    var typeAnnotation: String? = nil

    if check(.colon) {
        advance()
        typeAnnotation = try parseTypeAnnotation()
    }

    return QualifiedNoun(
        base: base,
        typeAnnotation: typeAnnotation,
        span: startToken.span.merged(with: previous().span)
    )
}
```

### Compound Identifiers

ARO allows hyphenated identifiers: `user-service`, `created-at`, `first-name`.

```swift
// Parser.swift:1069-1079
private func parseCompoundIdentifier() throws -> String {
    var result = try expectIdentifier(message: "identifier").lexeme

    while check(.hyphen) {
        advance()
        result += "-"
        result += try expectIdentifier(message: "identifier after '-'").lexeme
    }

    return result
}
```

This is implemented in the parser, not the lexer. The lexer produces separate tokens (`user`, `-`, `service`), and the parser combines them.

---

## Identifier Sequence Parsing

Feature set names and business activities are space-separated identifiers:

```
(User Authentication: Security and Access Control)
 └─────────────────┘  └─────────────────────────┘
      name                  business activity
```

```swift
// Parser.swift:1084-1120
private func parseIdentifierSequence() throws -> String {
    var parts: [String] = []

    while peek().kind.isIdentifierLike {
        var compound = advance().lexeme

        // Handle hyphens within identifiers
        while check(.hyphen) {
            advance()
            compound += "-"
            if peek().kind.isIdentifierLike {
                compound += advance().lexeme
            }
        }

        parts.append(compound)
    }

    return parts.joined(separator: " ")
}
```

The `isIdentifierLike` property allows certain keywords (like `Error`) to appear in names:

```swift
// Token.swift:260-270
public var isIdentifierLike: Bool {
    switch self {
    case .identifier:
        return true
    case .error, .match, .case, .otherwise, .if, .else:
        return true
    default:
        return false
    }
}
```

---

## Chapter Summary

ARO's parser demonstrates several techniques:

1. **Hybrid design**: Recursive descent for statements (clear structure), Pratt for expressions (elegant precedence).

2. **Single lookahead with context**: Disambiguates `<`, `.`, `for` based on what follows.

3. **Error recovery via synchronization**: Finds safe restart points (`.`, `}`, `<`) to continue after errors.

4. **Compound identifiers in parser**: Hyphenated names are assembled from separate tokens.

The parser is 1700+ lines—larger than the lexer but still manageable. The constrained grammar (five statement types, fixed expression operators) keeps complexity bounded.

Implementation reference: `Sources/AROParser/Parser.swift`

---

*Next: Chapter 4 — Abstract Syntax*
