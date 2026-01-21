# Chapter 4: Abstract Syntax

## AST Node Hierarchy

ARO's AST (`AST.swift`, 1315 lines) defines the tree structure produced by parsing. Every node conforms to `ASTNode`, which requires `Sendable` (Swift concurrency safety), source location tracking, and visitor pattern support.

```swift
public protocol ASTNode: Sendable, Locatable, CustomStringConvertible {
    func accept<V: ASTVisitor>(_ visitor: V) throws -> V.Result
}
```

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

  <!-- Statement types -->
  <rect x="30" y="310" width="100" height="35" rx="3" class="box statement"/>
  <text x="80" y="332" class="label" text-anchor="middle">AROStatement</text>

  <rect x="140" y="310" width="100" height="35" rx="3" class="box statement"/>
  <text x="190" y="332" class="label" text-anchor="middle">PublishStatement</text>

  <rect x="250" y="310" width="100" height="35" rx="3" class="box statement"/>
  <text x="300" y="332" class="label" text-anchor="middle">RequireStatement</text>

  <rect x="360" y="310" width="100" height="35" rx="3" class="box statement"/>
  <text x="410" y="332" class="label" text-anchor="middle">MatchStatement</text>

  <rect x="470" y="310" width="100" height="35" rx="3" class="box statement"/>
  <text x="520" y="332" class="label" text-anchor="middle">ForEachLoop</text>

  <!-- Lines from Statement to subtypes -->
  <path d="M 280 280 L 80 310" class="inherit"/>
  <path d="M 310 280 L 190 310" class="inherit"/>
  <path d="M 350 280 L 300 310" class="inherit"/>
  <path d="M 390 280 L 410 310" class="inherit"/>
  <path d="M 420 280 L 520 310" class="inherit"/>

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

ARO distinguishes between statements (actions that do things) and expressions (values that can be computed). This is not just syntactic—it reflects the language's philosophy.

### Statements

Statements perform actions and produce side effects:

```swift
public protocol Statement: ASTNode {}
```

The five statement types:

| Statement | Purpose | Example |
|-----------|---------|---------|
| `AROStatement` | Core action-result-object | `<Extract> the <user> from the <request>.` |
| `PublishStatement` | Variable export | `<Publish> as <alias> <variable>.` |
| `RequireStatement` | Dependency declaration | `<Require> the <config> from the <environment>.` |
| `MatchStatement` | Pattern matching | `match <status> { case "active" { ... } }` |
| `ForEachLoop` | Iteration | `for each <item> in <items> { ... }` |

### Expressions

Expressions compute values without side effects:

```swift
public protocol Expression: ASTNode {}
```

Expression types include:
- `LiteralExpression` — constants
- `VariableRefExpression` — variable access
- `BinaryExpression` — operators
- `UnaryExpression` — negation, not
- `MemberAccessExpression` — `.property`
- `SubscriptExpression` — `[index]`

### Why the Distinction Matters

1. **Semantic analysis**: Statements create variables; expressions read them.
2. **Code generation**: Statements map to bridge calls; expressions map to LLVM instructions.
3. **Error messages**: "Cannot execute statement" vs "Cannot evaluate expression".

---

## The QualifiedNoun Pattern

`QualifiedNoun` is ARO's representation of a variable reference with optional type information.

```swift
// AST.swift:519-570
public struct QualifiedNoun: Sendable, Equatable, CustomStringConvertible {
    public let base: String
    public let typeAnnotation: String?
    public let span: SourceSpan

    public var specifiers: [String] {
        guard let type = typeAnnotation else { return [] }
        if type.contains("<") {
            return [type]  // Generic type like List<User>
        }
        return type.split(separator: ".").map(String.init)
    }

    public var fullName: String {
        if let type = typeAnnotation {
            return "\(base): \(type)"
        }
        return base
    }
}
```

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

The `QualifiedNoun` pattern serves multiple purposes:

1. **Variable naming**: `base` becomes the variable name
2. **Type annotation**: `typeAnnotation` provides optional type hints
3. **Property access**: `specifiers` enable nested property paths like `user.address.city`
4. **Generic types**: Handles `List<User>` without parsing complications

---

## Visitor Pattern Implementation

ARO uses the classic visitor pattern to decouple AST traversal from AST structure.

```swift
// AST.swift:974-999
public protocol ASTVisitor {
    associatedtype Result

    func visit(_ node: Program) throws -> Result
    func visit(_ node: ImportDeclaration) throws -> Result
    func visit(_ node: FeatureSet) throws -> Result
    func visit(_ node: AROStatement) throws -> Result
    func visit(_ node: PublishStatement) throws -> Result
    func visit(_ node: RequireStatement) throws -> Result
    func visit(_ node: MatchStatement) throws -> Result
    func visit(_ node: ForEachLoop) throws -> Result

    // Expression visitors
    func visit(_ node: LiteralExpression) throws -> Result
    func visit(_ node: ArrayLiteralExpression) throws -> Result
    func visit(_ node: MapLiteralExpression) throws -> Result
    func visit(_ node: VariableRefExpression) throws -> Result
    func visit(_ node: BinaryExpression) throws -> Result
    func visit(_ node: UnaryExpression) throws -> Result
    func visit(_ node: MemberAccessExpression) throws -> Result
    func visit(_ node: SubscriptExpression) throws -> Result
    func visit(_ node: GroupedExpression) throws -> Result
    func visit(_ node: ExistenceExpression) throws -> Result
    func visit(_ node: TypeCheckExpression) throws -> Result
    func visit(_ node: InterpolatedStringExpression) throws -> Result
}
```

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
  <text x="275" y="180" class="title" text-anchor="middle">Interpreter</text>
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

### Default Implementations

For visitors that only need to traverse (not transform), default implementations recurse into children:

```swift
// AST.swift:1001-1020
public extension ASTVisitor where Result == Void {
    func visit(_ node: Program) throws {
        for importDecl in node.imports {
            try importDecl.accept(self)
        }
        for featureSet in node.featureSets {
            try featureSet.accept(self)
        }
    }

    func visit(_ node: FeatureSet) throws {
        for statement in node.statements {
            try statement.accept(self)
        }
    }
    // ...
}
```

This means concrete visitors only need to override the nodes they care about.

---

## Sendable Conformance

Swift 6 requires types shared across concurrency boundaries to conform to `Sendable`. ARO's AST nodes are all `Sendable`:

```swift
public struct Program: ASTNode { ... }       // Implicitly Sendable
public struct FeatureSet: ASTNode { ... }    // All fields are Sendable
public struct AROStatement: Statement { ... } // Sendable via stored properties
```

### The Expression Challenge

Expressions use `any Expression` which is existential, not directly `Sendable`. The workaround uses wrapper types:

```swift
public enum ValueSource: Sendable {
    case expression(any Expression)  // existential wrapped in enum
    // ...
}
```

The compiler accepts this because `Expression` inherits from `ASTNode` which requires `Sendable`.

### Why This Matters

Semantic analysis and code generation can run concurrently on different feature sets. `Sendable` AST nodes enable this safely.

---

## Span Propagation

Every AST node carries a `SourceSpan` indicating its location in source code.

```swift
public struct SourceSpan: Sendable, Equatable {
    public let start: SourceLocation
    public let end: SourceLocation

    public func merged(with other: SourceSpan) -> SourceSpan {
        SourceSpan(start: start, end: other.end)
    }
}
```

Spans propagate through parsing via `merged(with:)`:

```swift
// When parsing: <Extract> the <user> from the <request>.
let startToken = try expect(.leftAngle, ...)  // start location
// ... parse contents ...
let endToken = try expect(.dot, ...)          // end location

return AROStatement(
    // ...
    span: startToken.span.merged(with: endToken.span)
)
```

### Error Reporting

Spans enable precise error messages:

```
Error: Cannot retrieve the user from the user-repository
  at line 5, columns 4-52

  5 |     <Retrieve> the <user> from the <user-repository>.
    |     ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
```

The underline is computed from `span.start.column` to `span.end.column`.

---

## AROStatement Structure

The core statement type uses grouped clause types to organize its optional components:

```swift
// AST.swift:98-185
public struct AROStatement: Statement {
    // Required fields
    public let action: Action
    public let result: QualifiedNoun
    public let object: ObjectClause
    public let span: SourceSpan

    // Grouped optional clauses
    public let valueSource: ValueSource           // literal, expression, or sink
    public let queryModifiers: QueryModifiers     // where, aggregation, by
    public let rangeModifiers: RangeModifiers     // to, with
    public let statementGuard: StatementGuard     // when condition
}
```

### Value Source

The `ValueSource` enum represents mutually exclusive value origins:

```swift
public enum ValueSource: Sendable {
    case none                           // standard syntax
    case literal(LiteralValue)          // with "string"
    case expression(any Expression)     // from <x> * <y>
    case sinkExpression(any Expression) // <Log> "msg" to <console>
}
```

### Query Modifiers

Groups clauses used for filtering and aggregating collections:

```swift
public struct QueryModifiers: Sendable {
    public let whereClause: WhereClause?       // where <field> is "value"
    public let aggregation: AggregationClause? // with sum(<field>)
    public let byClause: ByClause?             // by /pattern/
}
```

### Range and Guard

```swift
public struct RangeModifiers: Sendable {
    public let toClause: (any Expression)?     // from <start> to <end>
    public let withClause: (any Expression)?   // from <a> with <b>
}

public struct StatementGuard: Sendable {
    public let condition: (any Expression)?    // when <condition>
}
```

This grouped design improves type safety and makes the semantic relationships between clauses explicit.

---

## Action Semantic Classification

Actions carry their semantic role for static analysis:

```swift
// AST.swift:488-508
public enum ActionSemanticRole: String, Sendable, CaseIterable {
    case request    // External → Internal
    case own        // Internal → Internal
    case response   // Internal → External
    case export     // Makes available to other features

    public static func classify(verb: String) -> ActionSemanticRole {
        let lower = verb.lowercased()

        let requestVerbs = ["extract", "parse", "retrieve", "fetch", ...]
        let responseVerbs = ["return", "throw", "send", "emit", ...]
        let exportVerbs = ["publish", "export", "expose", "share"]

        if requestVerbs.contains(lower) { return .request }
        if responseVerbs.contains(lower) { return .response }
        if exportVerbs.contains(lower) { return .export }
        return .own
    }
}
```

This classification is used by:
- Semantic analyzer for data flow validation
- Runtime for choosing execution strategy
- LLVM code generator for bridge function selection

---

## Chapter Summary

ARO's AST design reflects the language's constraints:

1. **Five statement types**: The uniform structure enables simple tooling.

2. **QualifiedNoun pattern**: Handles variable naming, type annotation, and property access in one structure.

3. **Visitor pattern**: Decouples traversal from structure; enables semantic analysis, interpretation, and code generation with the same AST.

4. **Sendable throughout**: Swift 6 concurrency safety is enforced at compile time.

5. **Span propagation**: Every node knows its source location for error reporting.

The AST is 1315 lines—larger than it would be for a minimal language, but manageable. The complexity comes from supporting clauses (`where`, `when`, `by`) that extend the basic action-result-object form.

Implementation reference: `Sources/AROParser/AST.swift`

---

*Next: Chapter 5 — Semantic Analysis*
