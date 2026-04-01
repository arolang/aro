# Chapter 2: Lexical Analysis

## The Lexer Architecture

ARO's lexer (`Lexer.swift`, ~962 lines) is hand-written — no lexer generator, no parser combinator library. It processes source characters one at a time and produces a flat list of tokens for the parser to consume.

You might wonder why hand-written. The short answer is control. A generated lexer would make the interesting bits — regex disambiguation, recursive string interpolation, article and preposition recognition — harder to customize. The hand-written approach lets us do unusual things where ARO's grammar is unusual.

The lexer maintains four pieces of state as it scans:

| Field | Purpose |
|-------|---------|
| `source` | The full source string being scanned |
| `currentIndex` | Where we are right now |
| `location` | Current line/column for error messages |
| `lastTokenKind` | What we just emitted (needed for `/` disambiguation) |

That last field — `lastTokenKind` — is subtle. Most lexers are purely forward-looking. ARO's needs one token of backwards context to resolve whether `/` starts a regex or is a division operator. More on that shortly.

---

## Character Classification

The main scanning loop calls `scanToken()` on each iteration. That function reads the current character and branches into specialized scanning functions: single-character delimiters go straight to token emission, multi-character operators peek one character ahead, strings and numbers each have their own scanner, and identifiers get post-processed for keyword recognition.

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

Every time the lexer advances past a character, it updates the source location — incrementing the column, or resetting to column 1 and incrementing the line on a newline. This happens on every single character, all the way through the file. It is not exciting work, but it is the reason error messages can underline exactly the right token.

---

## First-Class Language Elements

The interesting bit here is that articles and prepositions are not keywords in ARO. They are their own token categories.

**Articles** recognized by the lexer:

| Token | Value |
|-------|-------|
| `article(.a)` | `a` |
| `article(.an)` | `an` |
| `article(.the)` | `the` |

**Prepositions** recognized by the lexer:

| Token | Value |
|-------|-------|
| `preposition(.from)` | `from` |
| `preposition(.for)` | `for` |
| `preposition(.against)` | `against` |
| `preposition(.to)` | `to` |
| `preposition(.into)` | `into` |
| `preposition(.via)` | `via` |
| `preposition(.with)` | `with` |
| `preposition(.on)` | `on` |
| `preposition(.at)` | `at` |
| `preposition(.by)` | `by` |

Most languages would treat `from` as a keyword — just another string to match against. In ARO, it becomes `TokenKind.preposition(.from)`. That is a richer token. The parser can match on `.preposition` directly and ask whether a given preposition indicates an external source. The semantic analyzer can classify data flow direction from the preposition alone.

You might wonder why that distinction matters. It matters because ARO's grammar is built around sentence structure. The preposition is not an afterthought — it is the structural indicator that separates the result from the object. Making it a first-class token type means the parser sees the grammar's intent, not just a bag of strings.

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

String interpolation (`"Hello ${<name>}!"`) turned out to be trickier than expected. A single string literal in the source becomes a sequence of tokens that the parser weaves together. The naive approach of treating the whole thing as one token loses the embedded expression entirely.

What we actually want is this token sequence:

```text
stringSegment("Hello ")
interpolationStart
leftAngle
identifier("name")
rightAngle
interpolationEnd
stringSegment("!")
```

Seven tokens from what looks like one string. The strategy is recursive lexing. When the scanner hits `${`, it extracts the content between the braces and re-runs the full lexer on it, splicing the resulting tokens back into the stream. The same scanner rules, applied again inside the expression. Whatever appears inside `${...}` is treated exactly as it would be in any other context — because it is lexed by the same code.

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

Nested braces inside an interpolation (`${<map>["key"]}`) are handled by tracking brace depth. The scanner counts opens and closes, only stopping when depth returns to zero. This means arbitrarily nested expressions inside `${}` work correctly — the outer scanner just waits patiently for the depth counter to reach zero before handing the extracted content off to the recursive lexer.

---

## Regex vs Division Ambiguity

The `/` character is genuinely ambiguous. It could be division (`total / count`) or the start of a regex literal (`/\d+/`). This is a classic problem — JavaScript famously struggled with it — and ARO solves it with a simple decision table based on the previous token.

| Previous token | `/` means... |
|----------------|-------------|
| Identifier | Division operator |
| `.` (dot) | Division operator |
| Followed by whitespace | Division operator |
| Anything else | Try to scan a regex |

The interesting bit is what "try to scan a regex" means. The lexer saves its current position, then attempts to consume a regex pattern all the way to the closing `/` and optional flags. If it succeeds and the pattern is non-empty, we emit a `regexLiteral` token. If it fails — no closing `/`, or empty pattern — the lexer resets to the saved position and emits a plain slash instead.

This is one of the very few places in the lexer that requires backtracking. The alternative would have been forcing regex literals to use different delimiters (like `r/.../`), which would have broken the natural reading of Split statements. Instead, we accepted a small amount of complexity to keep the syntax clean.

---

## Source Location on Every Token

Every token carries start and end positions: line number, column number, and byte offset into the source. These three numbers flow all the way through the compilation pipeline to error messages, which can underline exactly the right text in the terminal.

Line numbers and column numbers are 1-based (humans count from 1). Byte offsets are 0-based (computers count from 0). The `advancing(past:)` method on the location struct handles newlines specially — when the scanner crosses a newline character, it increments the line number and resets the column to 1.

This location tracking happens on every single `advance()` call, which is every single character in the source file. It is a little tedious to implement but completely invisible when it works — and very obvious when it is missing.

---

## Keyword Recognition

After scanning an identifier, we do a quick table lookup: is this word a keyword, an article, or a preposition? The lookup order matters:

```text
scan word as identifier
→ check keyword table (lowercased)   → if match, emit keyword token
→ check article values               → if match, emit article token
→ check preposition values           → if match, emit preposition token
→ otherwise, emit identifier token
```

One important detail: the lookup is case-insensitive. `FROM`, `From`, and `from` all become `preposition(.from)`. But the original case is preserved in the lexeme field — so error messages can show you exactly what you wrote, not what the lexer normalized it to.

This "scan then classify" approach also means that a word like `format` does not accidentally become a keyword just because it starts with `for`. The scanner greedily consumes the whole word before checking any lookup table.

---

## Comments

Comments are skipped during scanning — they produce no tokens and leave no trace in the AST.

ARO supports two styles:

- **Block comments**: `(* this can span multiple lines *)` — uses `(* *)` rather than `/* */` to avoid ambiguity with the `*` multiplication operator in arithmetic expressions.
- **Line comments**: `// this runs to end of line`

The `skipWhitespaceAndComments()` function runs before every token scan. It loops, consuming whitespace and comments, until it hits a character that is neither. Nested block comments are not supported — `(* outer (* inner *) still outer *)` would close at the first `*)`.

---

## Error Handling

When the lexer encounters something it cannot handle, it throws. The error types are:

- **Unexpected character** — a character that does not start any valid token
- **Unterminated string** — a string literal that reaches end-of-file without a closing quote
- **Invalid escape sequence** — something like `\q` inside a string
- **Invalid unicode escape** — a malformed `\u{...}` sequence
- **Invalid number** — something that looked like a number but was not (e.g., `0x` with no hex digits)

Every error carries the source location where it occurred. The parser catches these and formats them with the line and column for display.

---

## Extended Literal Support

ARO 0.7 added several literal forms without changing the overall scanner architecture. The interesting thing is how cleanly they fit in — each is just a new branch in the existing scanning logic.

### Triple-Quoted Strings

Multi-line string literals use triple-quote delimiters:

```aro
Log """
Hello,
World!
""" to the <console>.
```

The scanner's `scanTripleQuotedString()` function handles `"""..."""`, allowing embedded newlines and single quotes without escaping. The only escape needed is if you want three consecutive double-quotes inside the string — which is rare enough not to worry about.

### Raw Strings

Raw string literals disable escape processing entirely:

```aro
Compute the <pattern: regex> with r"\.aro$".
```

The `r` prefix signals `scanRawString()`, which emits the content verbatim. This is especially useful for regex patterns where backslashes are everywhere — without raw strings, `\.aro$` would require `\\.aro$`, which is unpleasant to read.

### Hexadecimal and Binary Integer Literals

```aro
Compute the <mask> with 0xFF.
Compute the <flags> with 0b1010.
```

The `0x` and `0b` prefixes route to `scanHexNumber()` and `scanBinaryNumber()` respectively. Both produce `intLiteral` tokens containing the converted integer value — the parser never sees the prefix notation, just a regular integer.

---

## Chapter Summary

The lexer is 962 lines for what seems like a simple job. It earns those lines with five interesting choices:

1. **Articles and prepositions as token types**: Not keywords — their own category. The parser matches grammar structure, not strings.

2. **Recursive string interpolation**: When the scanner hits `${`, it extracts the content and re-runs the full lexer on it. Same rules, applied recursively inside the expression.

3. **Regex/division disambiguation**: One token of backwards context (`lastTokenKind`) plus a simple decision table. Backtrack on failure.

4. **Source location on every token**: Line, column, and byte offset, tracked on every character advance. These flow all the way to terminal error output.

5. **Extended literal forms**: Triple-quoted strings, raw strings, hex and binary integers — all added in ARO 0.7 as new branches in the existing scanner without restructuring anything.

The constrained syntax actually helps here. No user-defined operators means no new token types to worry about. No metaclass syntax means no special-casing. The scanner is longer than you might expect, but it is not complicated.

Implementation reference: `Sources/AROParser/Lexer.swift`

---

*Next: Chapter 3 — Syntactic Analysis*
