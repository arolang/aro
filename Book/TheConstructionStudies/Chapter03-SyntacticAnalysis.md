# Chapter 3: Syntactic Analysis

## Hybrid Parser Design

ARO's parser (`Parser.swift`, ~2000 lines) uses a hybrid approach: **recursive descent** for statements and program structure, **Pratt parsing** for expressions. Each technique plays to its strengths, and together they cover everything ARO needs.

The parser holds three things: the token array from the lexer, a cursor (`current`) pointing to the next unconsumed token, and a diagnostic collector for accumulating errors without aborting. That's the whole data model.

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

ARO's statement syntax is wonderfully predictable. Look at the grammar — every rule maps straight to a function call:

```text
FeatureSet  ::= "(" name ":" activity ")" "{" Statement* "}"
Statement   ::= AROStatement | MatchStatement | ForEachLoop
AROStatement ::= "<" verb ">" [article] "<" result ">" preposition [article] "<" object ">" "."
```

Here is what `parseFeatureSet` does, in plain terms:

```text
parseFeatureSet:
  consume (
  name = parseIdentifierSequence
  consume :
  activity = parseIdentifierSequence
  consume )
  consume {
  statements = [ parseStatement() while not } ]
  consume }
  → FeatureSet(name, activity, statements)
```

One grammar rule, one function. The advantages are real:

1. **One-to-one mapping**: The code structure mirrors the grammar. Reading one tells you the other.
2. **Natural error handling**: Each parsing function can catch and report its own problems.
3. **Easy to extend**: Adding a new statement type means adding a new function — nothing else changes.

---

## Why Pratt for Expressions

Expressions need operator precedence. `<a> + <b> * <c>` should parse as `<a> + (<b> * <c>)` because `*` binds tighter than `+`. With recursive descent, you'd need to encode this by creating a chain of grammar rules — one per precedence level, getting messy fast.

Pratt parsing handles it with a single table of precedence levels:

| Precedence | Level | Operators |
|------------|-------|-----------|
| or | 1 | `or` |
| and | 2 | `and` |
| equality | 3 | `==`, `!=`, `is` |
| comparison | 4 | `<`, `>`, `<=`, `>=` |
| term | 5 | `+`, `-`, `++` |
| factor | 6 | `*`, `/`, `%` |
| unary | 7 | `-`, `not` |
| postfix | 8 | `.`, `[]` |

The algorithm is simple: parse a prefix (a primary expression or unary op), then keep consuming infix operators as long as they bind tighter than what the caller expects. That is the entire engine for correct precedence — no grammar rewrites needed.

In pseudocode:

```text
parsePrecedence(minPrecedence):
  left = parsePrefix()
  while infixPrecedence(peek()) > minPrecedence:
    left = parseInfix(left, infixPrecedence(peek()))
  if peek() == "exists":
    advance()
    left = ExistenceExpression(left)
  return left
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
  <text x="40" y="115" class="label">5 &gt; 0, continue</text>

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
  <text x="480" y="115" class="label">6 &gt; 5, continue</text>

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

Here is what the parser actually does, token by token:

```text
parseAROStatement:
  consume <
  action = identifier
  consume >
  [skip article: a / an / the]
  result = parseQualifiedNoun in < >
  preposition = consume preposition (from, to, for, with, ...)
  [skip article: a / an / the]
  object = parseQualifiedNoun in < >
  [parse optional clauses: where, when, with, to]
  consume .
  → AROStatement(action, result, preposition, object, clauses)
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

When a statement fails to parse, we don't want to give up on the whole file. The goal is to report as many errors as possible in one pass. To do that, the parser scans forward to a safe restart point after each failure.

When a statement fails, we scan forward until we find a `.` (statement end), `}` (feature set end), or `<` (possible new statement start). At those points, parsing can safely resume. The `.` is the most reliable — it's the statement terminator and rarely appears elsewhere. The `}` catches runaway errors that spill past statement boundaries. The `<` is a last resort that catches fresh statement starts.

If an entire feature set fails, the recovery point is `(` — the start of the next feature set. That way one badly-formed feature set doesn't poison the rest of the file.

The outer parse loop wraps each feature set attempt in a try/catch. On failure: record the error, call `synchronize()`, move on. Everything is collected. Nothing aborts. By the time parsing finishes, the diagnostics list has every error we found — all in one pass.

---

## Single Lookahead and Disambiguation

ARO's parser uses single-token lookahead: `peek()` returns the current token, `advance()` moves forward. One token of context is enough for ARO's constrained grammar — but a few characters need a little thought.

### The `<` Ambiguity

The character `<` can mean three different things:

- Start of a variable reference: `<user>`
- Start of an action verb: `<Extract>`
- Less-than operator: `<a> < <b>`

The parser uses one token of lookahead to disambiguate. If `<` is followed by an identifier, it is starting a variable reference — not a comparison. Context-dependent, single token of lookahead, and it works for ARO's constrained grammar.

### The `.` Ambiguity

`.` can be member access or a statement terminator:

- Member access: `<user>.name`
- Statement terminator: `... object>.`

The rule is symmetric: `.` is member access only when followed by an identifier. Otherwise it terminates the statement.

### The `for` Ambiguity

The keyword `for` doubles as both a preposition ("for the user") and the loop keyword ("for each"). The parser resolves this based on what follows — if the next token is `each`, it's a loop; otherwise it's the preposition `.for`.

These disambiguations work because ARO's grammar is constrained. A more complex language would need multi-token lookahead or backtracking. ARO doesn't.

---

## Qualified Noun Parsing

A qualified noun is an identifier (possibly hyphenated like `user-service`) optionally followed by `:` and a type annotation. Examples: `<user>`, `<user: id>`, `<items: List<Order>>`, `<user: address.city>`.

The base name is parsed first, then if a `:` follows, the type annotation is consumed. The whole thing becomes a `QualifiedNoun` carrying both pieces.

Hyphenated names are assembled in the parser from separate tokens — the lexer emits `user`, `-`, `service` as three tokens. The parser combines them by consuming a hyphen and the next identifier in a loop, building up the compound name piece by piece. The result is `user-service` as a single string.

---

## Identifier Sequence Parsing

Feature set names and business activities are space-separated word sequences:

```text
(User Authentication: Security and Access Control)
 └─────────────────┘  └─────────────────────────┘
      name                  business activity
```

We collect tokens as long as they look identifier-like, including some keywords that can appear in names (like `Error`, `match`, `case`). The `isIdentifierLike` check is permissive here — being too strict would make feature set names fragile. Hyphens within a word are handled too: `Application-Start` becomes a single compound identifier before the sequence collector moves on to the next word.

---

## Chapter Summary

ARO's parser demonstrates several clean techniques:

1. **Hybrid design**: Recursive descent for statements (clear structure), Pratt for expressions (elegant precedence).

2. **Single lookahead with context**: Disambiguates `<`, `.`, `for` based on what follows — one token is enough.

3. **Error recovery via synchronization**: Finds safe restart points (`.`, `}`, `<`) to continue after errors and report everything in one pass.

4. **Compound identifiers in parser**: Hyphenated names are assembled from separate tokens — the lexer keeps things simple, the parser assembles.

The parser is ~2000 lines — larger than the lexer but still manageable. The constrained grammar (eight statement types, fixed expression operators) keeps complexity bounded. And the hybrid design means each half is as simple as it can be.

Implementation reference: `Sources/AROParser/Parser.swift`

---

*Next: Chapter 4 — Abstract Syntax*
