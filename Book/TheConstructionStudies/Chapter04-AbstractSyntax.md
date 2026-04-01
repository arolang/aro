# Chapter 4: Abstract Syntax

## AST Node Hierarchy

ARO's AST (`AST.swift`, ~1600 lines) defines the tree structure produced by parsing. Every node conforms to `ASTNode`. That protocol asks for three things: be sendable across concurrency boundaries (Swift 6), know your source location, and accept a visitor. That's the whole protocol — three requirements, no more.

<svg viewBox="0 0 700 450" xmlns="http://www.w3.org/2000/svg">
  <style>
    .box { fill: #f5f5f5; stroke: #333; stroke-width: 1.5; }
    .protocol { fill: #e8e8f4; stroke: #66a; stroke-width: 2; }
    .statement { fill: #e8f4e8; }
    .expression { fill: #f4e8e8; }
    .arrow { fill: none; stroke: #333; stroke-width: 1.5; marker-end: url(#arrow8); }
    .inherit { fill: none; stroke: #666; stroke-width: 1; stroke-dasharray: 4,2; }
    .label { font-family: monospace; font-size: 10px; fill: #333; }
    .title { font-family: monospace; font-size: 11px; fill: #333; font-weight: bold; }
  </style>

  <defs>
    <marker id="arrow8" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#333"/>
    </marker>
  </defs>

  <!-- ASTNode protocol -->
  <rect x="280" y="20" width="140" height="50" rx="5" class="protocol"/>
  <text x="350" y="40" class="title" text-anchor="middle">ASTNode</text>
  <text x="350" y="55" class="label" text-anchor="middle">Sendable, Locatable</text>

  <!-- Program -->
  <rect x="280" y="100" width="140" height="40" rx="5" class="box"/>
  <text x="350" y="125" class="title" text-anchor="middle">Program</text>
  <path d="M 350 70 L 350 100" class="arrow"/>

  <!-- Import + FeatureSet -->
  <rect x="150" y="170" width="120" height="40" rx="5" class="box"/>
  <text x="210" y="195" class="label" text-anchor="middle">ImportDeclaration</text>

  <rect x="300" y="170" width="120" height="40" rx="5" class="box"/>
  <text x="360" y="195" class="label" text-anchor="middle">FeatureSet</text>

  <path d="M 310 140 L 210 170" class="arrow"/>
  <path d="M 390 140 L 360 170" class="arrow"/>

  <!-- Statement protocol -->
  <rect x="280" y="240" width="140" height="40" rx="5" class="protocol statement"/>
  <text x="350" y="265" class="title" text-anchor="middle">Statement</text>
  <path d="M 350 210 L 350 240" class="arrow"/>

  <!-- Statement types row 1 -->
  <rect x="30" y="310" width="90" height="35" rx="3" class="box statement"/>
  <text x="75" y="332" class="label" text-anchor="middle">AROStatement</text>

  <rect x="130" y="310" width="90" height="35" rx="3" class="box statement"/>
  <text x="175" y="332" class="label" text-anchor="middle">PublishStatement</text>

  <rect x="230" y="310" width="90" height="35" rx="3" class="box statement"/>
  <text x="275" y="332" class="label" text-anchor="middle">RequireStatement</text>

  <rect x="330" y="310" width="90" height="35" rx="3" class="box statement"/>
  <text x="375" y="332" class="label" text-anchor="middle">MatchStatement</text>

  <!-- Statement types row 2 -->
  <rect x="30" y="355" width="90" height="35" rx="3" class="box statement"/>
  <text x="75" y="377" class="label" text-anchor="middle">ForEachLoop</text>

  <rect x="130" y="355" width="90" height="35" rx="3" class="box statement"/>
  <text x="175" y="377" class="label" text-anchor="middle">RangeLoop</text>

  <rect x="230" y="355" width="90" height="35" rx="3" class="box statement"/>
  <text x="275" y="377" class="label" text-anchor="middle">WhileLoop</text>

  <rect x="330" y="355" width="90" height="35" rx="3" class="box statement"/>
  <text x="375" y="377" class="label" text-anchor="middle">BreakStatement</text>

  <!-- Lines from Statement to subtypes -->
  <path d="M 280 280 L 75 310" class="inherit"/>
  <path d="M 305 280 L 175 310" class="inherit"/>
  <path d="M 350 280 L 275 310" class="inherit"/>
  <path d="M 390 280 L 375 310" class="inherit"/>
  <path d="M 280 280 L 75 355" class="inherit"/>
  <path d="M 305 280 L 175 355" class="inherit"/>
  <path d="M 350 280 L 275 355" class="inherit"/>
  <path d="M 390 280 L 375 355" class="inherit"/>

  <!-- Expression protocol -->
  <rect x="480" y="240" width="140" height="40" rx="5" class="protocol expression"/>
  <text x="550" y="265" class="title" text-anchor="middle">Expression</text>
  <path d="M 550 70 L 550 240" class="arrow" stroke-dasharray="5,3"/>

  <!-- Expression types -->
  <rect x="580" y="310" width="100" height="30" rx="3" class="box expression"/>
  <text x="630" y="330" class="label" text-anchor="middle">LiteralExpr</text>

  <rect x="580" y="350" width="100" height="30" rx="3" class="box expression"/>
  <text x="630" y="370" class="label" text-anchor="middle">VariableRefExpr</text>

  <rect x="580" y="390" width="100" height="30" rx="3" class="box expression"/>
  <text x="630" y="410" class="label" text-anchor="middle">BinaryExpr</text>

  <path d="M 550 280 L 580 325" class="inherit"/>
  <path d="M 550 280 L 580 365" class="inherit"/>
  <path d="M 550 280 L 580 405" class="inherit"/>

  <!-- Legend -->
  <rect x="30" y="380" width="180" height="60" fill="none" stroke="#ccc"/>
  <text x="40" y="395" class="title">Legend</text>
  <rect x="40" y="405" width="15" height="10" class="protocol"/>
  <text x="60" y="413" class="label">Protocol</text>
  <rect x="40" y="420" width="15" height="10" class="statement"/>
  <text x="60" y="428" class="label">Statement type</text>
  <line x1="110" y1="413" x2="140" y2="413" class="inherit"/>
  <text x="145" y="417" class="label">Implements</text>
</svg>

**Figure 4.1**: Complete AST node hierarchy. `Program` contains `FeatureSet`s, which contain `Statement`s. `Expression` is a parallel hierarchy used within statements.

---

## Statement vs Expression Dichotomy

ARO draws a clear line between statements and expressions. This is not just syntactic ceremony — it reflects the language's philosophy.

**Statements** do things. They perform actions and produce side effects. `Statement` is a marker protocol — it adds no requirements beyond `ASTNode`, just marks the distinction.

The nine statement types:

| Statement | Purpose | Example |
|-----------|---------|---------|
| `AROStatement` | Core action-result-object | `Extract the <user> from the <request>.` |
| `PublishStatement` | Variable export | `Publish as <alias> <variable>.` |
| `RequireStatement` | Dependency declaration | `Require the <config> from the <environment>.` |
| `MatchStatement` | Pattern matching | `match <status> { case "active" { ... } }` |
| `ForEachLoop` | Collection iteration | `for each <item> in <items> { ... }` |
| `RangeLoop` | Numeric range iteration | `for <i> from 1 to <count> { ... }` |
| `WhileLoop` | Condition-based iteration | `while <condition> { ... }` |
| `BreakStatement` | Exit innermost loop | `Break.` |
| `PipelineStatement` | Chained statements | `Extract ... |> Compute ... .` |

**Expressions** compute values without side effects. `Expression` is likewise a marker protocol. Expression types:

| Expression Type | Represents |
|----------------|-----------|
| `LiteralExpression` | Constants: strings, numbers, booleans, objects |
| `VariableRefExpression` | Variable access `<name>` |
| `BinaryExpression` | Operators: `+`, `-`, `*`, `/`, `and`, `or`, etc. |
| `UnaryExpression` | Negation: `-`, `not` |
| `MemberAccessExpression` | `.property` access |
| `SubscriptExpression` | `[index]` access |
| `InterpolatedStringExpression` | `"Hello ${<name>}!"` |

Why does the distinction matter?

- **Semantic analysis**: Statements create variables; expressions read them. The analyzer applies different rules to each.
- **Code generation**: Statements map to bridge function calls; expressions map to LLVM instructions.
- **Error messages**: "Cannot execute statement" vs "Cannot evaluate expression" — much more useful than a generic failure.

---

## The QualifiedNoun Pattern

`QualifiedNoun` is ARO's way of representing a variable reference with optional type or specifier information. It shows up everywhere — in result position, object position, wherever a variable is named.

| Field | Type | Meaning |
|-------|------|---------|
| `base` | String | Variable name: `user`, `first-name`, `created-at` |
| `typeAnnotation` | String? | Optional qualifier: `String`, `address.city`, `List<Order>` |
| `span` | SourceSpan | Where it appears in source |

The `specifiers` computed property splits a dotted annotation like `address.city` into `["address", "city"]` for nested property access. Generic types like `List<Order>` are kept as-is (no splitting) to avoid parsing complications.

<svg viewBox="0 0 600 200" xmlns="http://www.w3.org/2000/svg">
  <style>
    .box { fill: #f5f5f5; stroke: #333; stroke-width: 1.5; }
    .field { fill: #e8f4e8; }
    .computed { fill: #f4e8e8; }
    .label { font-family: monospace; font-size: 10px; fill: #333; }
    .title { font-family: monospace; font-size: 11px; fill: #333; font-weight: bold; }
    .example { font-family: monospace; font-size: 12px; fill: #333; }
  </style>

  <!-- QualifiedNoun struct -->
  <rect x="30" y="30" width="250" height="150" rx="5" class="box"/>
  <text x="155" y="50" class="title" text-anchor="middle">QualifiedNoun</text>

  <!-- Stored properties -->
  <rect x="45" y="65" width="100" height="25" rx="3" class="field"/>
  <text x="55" y="82" class="label">base: String</text>

  <rect x="45" y="95" width="130" height="25" rx="3" class="field"/>
  <text x="55" y="112" class="label">typeAnnotation: String?</text>

  <rect x="45" y="125" width="110" height="25" rx="3" class="field"/>
  <text x="55" y="142" class="label">span: SourceSpan</text>

  <!-- Computed properties -->
  <rect x="180" y="65" width="85" height="25" rx="3" class="computed"/>
  <text x="190" y="82" class="label">specifiers</text>

  <rect x="180" y="95" width="85" height="25" rx="3" class="computed"/>
  <text x="190" y="112" class="label">fullName</text>

  <rect x="180" y="125" width="85" height="25" rx="3" class="computed"/>
  <text x="190" y="142" class="label">dataType</text>

  <!-- Examples -->
  <rect x="310" y="30" width="260" height="150" rx="5" class="box"/>
  <text x="440" y="50" class="title" text-anchor="middle">Examples</text>

  <text x="320" y="75" class="example">&lt;user&gt;</text>
  <text x="400" y="75" class="label">base="user", type=nil</text>

  <text x="320" y="100" class="example">&lt;name: String&gt;</text>
  <text x="400" y="100" class="label">base="name", type="String"</text>

  <text x="320" y="125" class="example">&lt;items: List&lt;Order&gt;&gt;</text>
  <text x="400" y="125" class="label">base="items", type="List&lt;Order&gt;"</text>

  <text x="320" y="150" class="example">&lt;user: address.city&gt;</text>
  <text x="400" y="150" class="label">base="user", specifiers=["address","city"]</text>
</svg>

**Figure 4.2**: QualifiedNoun structure. Stored properties (green) hold the parsed data; computed properties (red) derive useful forms.

### Design Rationale

The `QualifiedNoun` pattern serves multiple purposes in one tidy struct:

1. **Variable naming**: `base` becomes the variable name in the symbol table.
2. **Type annotation**: `typeAnnotation` provides optional type hints for the semantic analyzer.
3. **Property access**: `specifiers` enable nested property paths like `user.address.city`.
4. **Generic types**: `List<Order>` is kept as a single string — no extra parsing machinery needed.

---

## Visitor Pattern Implementation

ARO uses the visitor pattern to separate what the AST looks like from what you do with it. The AST defines structure. Visitors define behavior.

The `ASTVisitor` protocol declares a `visit` method for each node type. Every concrete visitor provides its own behavior for each node. The AST nodes themselves just call `visitor.visit(self)` — they don't know what the visitor will do.

The four active visitors:

| Visitor | Result Type | Purpose |
|---------|-------------|---------|
| `SemanticAnalyzer` | Void | Builds symbol tables, validates data flow |
| `FeatureSetExecutor` | Sendable | Executes statements at runtime |
| `LLVMCodeGenerator` | IR | Emits LLVM IR for compilation |
| `ASTPrinter` | String | Debug output |

<svg viewBox="0 0 650 300" xmlns="http://www.w3.org/2000/svg">
  <style>
    .box { fill: #f5f5f5; stroke: #333; stroke-width: 1.5; }
    .protocol { fill: #e8e8f4; }
    .impl { fill: #e8f4e8; }
    .arrow { fill: none; stroke: #333; stroke-width: 1.5; marker-end: url(#arrow9); }
    .label { font-family: monospace; font-size: 10px; fill: #333; }
    .title { font-family: monospace; font-size: 11px; fill: #333; font-weight: bold; }
  </style>

  <defs>
    <marker id="arrow9" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#333"/>
    </marker>
  </defs>

  <!-- ASTVisitor protocol -->
  <rect x="230" y="30" width="180" height="80" rx="5" class="box protocol"/>
  <text x="320" y="50" class="title" text-anchor="middle">ASTVisitor</text>
  <text x="240" y="70" class="label">associatedtype Result</text>
  <text x="240" y="85" class="label">visit(Program) → Result</text>
  <text x="240" y="100" class="label">visit(AROStatement) → Result</text>

  <!-- Implementations -->
  <rect x="30" y="160" width="150" height="60" rx="5" class="box impl"/>
  <text x="105" y="180" class="title" text-anchor="middle">SemanticAnalyzer</text>
  <text x="40" y="200" class="label">Result = Void</text>
  <text x="40" y="212" class="label">Builds symbol tables</text>

  <rect x="200" y="160" width="150" height="60" rx="5" class="box impl"/>
  <text x="275" y="180" class="title" text-anchor="middle">FeatureSetExecutor</text>
  <text x="210" y="200" class="label">Result = Sendable</text>
  <text x="210" y="212" class="label">Executes statements</text>

  <rect x="370" y="160" width="150" height="60" rx="5" class="box impl"/>
  <text x="445" y="180" class="title" text-anchor="middle">LLVMCodeGenerator</text>
  <text x="380" y="200" class="label">Result = String</text>
  <text x="380" y="212" class="label">Emits LLVM IR</text>

  <rect x="540" y="160" width="100" height="60" rx="5" class="box impl"/>
  <text x="590" y="180" class="title" text-anchor="middle">ASTPrinter</text>
  <text x="550" y="200" class="label">Result = String</text>
  <text x="550" y="212" class="label">Debug output</text>

  <!-- Arrows -->
  <path d="M 280 110 L 105 160" class="arrow"/>
  <path d="M 320 110 L 275 160" class="arrow"/>
  <path d="M 360 110 L 445 160" class="arrow"/>
  <path d="M 410 110 L 590 160" class="arrow"/>

  <!-- Node side -->
  <rect x="30" y="250" width="120" height="40" rx="5" class="box"/>
  <text x="90" y="275" class="title" text-anchor="middle">AROStatement</text>

  <text x="170" y="270" class="label">accept(visitor) {</text>
  <text x="180" y="285" class="label">visitor.visit(self)</text>
  <text x="170" y="300" class="label">}</text>

  <path d="M 150 270 L 400 200" class="arrow" stroke-dasharray="4,2"/>
  <text x="260" y="245" class="label">dispatch to correct</text>
  <text x="260" y="257" class="label">visit() overload</text>
</svg>

**Figure 4.3**: Visitor pattern classes. Each visitor implementation provides different behavior for the same AST structure.

### Default Traversal

Visitors that don't care about every node type get free traversal — the default implementation recurses into children automatically. Override only what matters. A visitor that only cares about `AROStatement` nodes can ignore `Program`, `FeatureSet`, loops, and everything else — the defaults handle the recursion.

---

## Sendable Conformance

Swift 6's strictness means everything that crosses concurrency boundaries must be `Sendable`. Structs with `Sendable` fields are automatically `Sendable` — that covers most AST nodes with no extra work.

The tricky case is existential types (`any Expression`). Existentials aren't automatically `Sendable` even when the underlying types are. The fix: wrap them in enums like `ValueSource`. The compiler accepts this because `Expression` inherits from `ASTNode` which requires `Sendable`.

Why does this matter operationally? Semantic analysis and code generation can run concurrently on different feature sets. `Sendable` AST nodes are what makes that safe.

---

## Source Spans

Every node knows where it came from: start position, end position. Spans are merged upward during parsing — a statement's span covers everything from its opening `<` to its closing `.`.

That span propagation is what makes error messages useful:

```text
Error: Cannot retrieve the user from the user-repository
  at line 5, columns 4-52

  5 |     Retrieve the <user> from the <user-repository>.
    |     ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
```

The underline is computed directly from the span. No guesswork.

---

## AROStatement Structure

`AROStatement` is the workhorse of the AST. Every action-result-object statement becomes one of these. Here are its fields:

| Field | Purpose |
|-------|---------|
| `action` | The verb, like `Extract` or `Compute` |
| `result` | What gets bound: `<user>`, `<count: length>` |
| `object` | What it operates on, including preposition |
| `valueSource` | Where the value comes from: literal, expression, or sink |
| `queryModifiers` | Optional `where`, aggregation, `by` clauses |
| `rangeModifiers` | Optional `to`, `with` clauses for ranges |
| `statementGuard` | Optional `when` condition |

The grouped clause types are the real win here. Before this design, we had flat optional properties everywhere — `literalValue`, `expression`, `whereClause`, `toClause` — all siblings. It was easy to end up with contradictory states. Now invalid combinations are literally unrepresentable.

| Group | Purpose | Prevents |
|-------|---------|----------|
| `ValueSource` | Where the value comes from | Setting both a literal and an expression simultaneously |
| `QueryModifiers` | Collection filtering — `where`, aggregation, `by` | Scattered, unrelated-looking fields |
| `RangeModifiers` | Range operations — `to`, `with` | Same |
| `StatementGuard` | Conditional execution — `when` | Same |

---

## ValueSource

`ValueSource` is an enum with four cases. Exactly one applies to any statement:

| Case | Meaning | Example |
|------|---------|---------|
| `none` | Standard: result binds from action output | `Extract the <user> from <req>.` |
| `literal` | With a literal value | `Log "Hello" to <console>.` |
| `expression` | With an arithmetic expression | `Compute the <total> from <a> + <b>.` |
| `sinkExpression` | Expression in result position (ARO-0043) | `Log <count> to <console>.` |

The enum makes the mutual exclusion structural. The semantic analyzer can match on it cleanly:

```text
switch statement.valueSource:
  case none      → result binds from action output
  case literal   → bind result to literal value
  case expression → evaluate expression, bind result
  case sinkExpression → evaluate expression in result position
```

No multi-way `if let` chains. No "which flags are set" puzzles.

---

## QueryModifiers, RangeModifiers, StatementGuard

These three structs group the optional clauses that extend the basic action-result-object form.

**QueryModifiers** bundles the filtering and aggregation clauses used with collections:

| Field | Clause | Example |
|-------|--------|---------|
| `whereClause` | `where <field> is "value"` | `Retrieve ... where status = "shipped".` |
| `aggregation` | `with sum(<field>)` | `Retrieve the <total: sum> from <orders>.` |
| `byClause` | `by /pattern/` | `Split the <parts> from <text> by /,/.` |

**RangeModifiers** bundles the range-based clauses:

| Field | Clause | Example |
|-------|--------|---------|
| `toClause` | `from <start> to <end>` | `Generate the <dates> from <start> to <end>.` |
| `withClause` | `from <a> with <b>` | `Compute the <result: intersect> from <a> with <b>.` |

**StatementGuard** carries the optional `when` condition:

```aro
Send the <notification> to the <user> when <user: subscribed> is true.
```

Having `StatementGuard` as its own struct makes it easy to check at a glance: does this statement have a guard? Pattern-match on `statementGuard.condition` — if it's `nil`, no guard; if it's an expression, evaluate it before executing.

---

## Action Semantic Classification

Actions carry their semantic role as part of the AST. This classification drives static analysis, runtime execution strategy, and code generation bridge function selection.

| Role | Direction | Example Verbs |
|------|-----------|---------------|
| `request` | External → Internal | Extract, Parse, Retrieve, Fetch |
| `own` | Internal → Internal | Compute, Validate, Compare, Create, Transform |
| `response` | Internal → External | Return, Throw |
| `export` | Makes globally accessible | Publish, Store, Log, Send, Emit |

The classifier is a lookup: check verb against known request verbs, then response verbs, then export verbs. Everything else is `own` — the default for internal transformations.

---

## Chapter Summary

ARO's AST design reflects the language's constraints. Nine statement types, fixed expression forms, and a consistent action-result-object shape make the tree predictable — which is exactly what you want when you're building a semantic analyzer, interpreter, and compiler on top of it.

The big ideas:

1. **Nine statement types**: Uniform structure enables simple tooling. Adding `RangeLoop`, `WhileLoop`, `BreakStatement`, and `PipelineStatement` expanded iteration and composition without breaking anything.

2. **Grouped clause types**: `ValueSource`, `QueryModifiers`, `RangeModifiers`, and `StatementGuard` organize optional clauses into semantic groups. Invalid combinations are unrepresentable. Pattern matching is clean.

3. **QualifiedNoun pattern**: Variable naming, type annotation, and property access in one small struct.

4. **Visitor pattern**: Decouples traversal from structure. The same AST runs through semantic analysis, interpretation, and code generation without knowing anything about them.

5. **Sendable throughout**: Swift 6 concurrency safety enforced at compile time. Feature sets can be processed concurrently.

6. **Span propagation**: Every node knows its source location. Error messages are precise.

Implementation reference: `Sources/AROParser/AST.swift`

---

*Next: Chapter 5 — Semantic Analysis*
