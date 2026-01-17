# Chapter 5: Semantic Analysis

## Overview

Semantic analysis (`SemanticAnalyzer.swift`) bridges parsing and execution. It builds symbol tables, tracks data flow, enforces immutability, and detects problems that parsing alone cannot catch.

```swift
public final class SemanticAnalyzer {
    private let diagnostics: DiagnosticCollector
    private let globalRegistry: GlobalSymbolRegistry

    public func analyze(_ program: Program) -> AnalyzedProgram {
        // Four-pass analysis
    }
}
```

The analyzer performs four passes:
1. Build symbol tables and detect duplicates
2. Verify external dependencies
3. Detect circular event chains
4. Detect orphaned event emissions

---

## Symbol Table Design

Each feature set gets its own symbol table, built during the first pass.

```swift
// SemanticAnalyzer.swift:29-50
public struct AnalyzedFeatureSet: Sendable {
    public let featureSet: FeatureSet
    public let symbolTable: SymbolTable
    public let dataFlows: [DataFlowInfo]
    public let dependencies: Set<String>  // External dependencies
    public let exports: Set<String>       // Published symbols
}
```

<svg viewBox="0 0 700 350" xmlns="http://www.w3.org/2000/svg">
  <style>
    .box { fill: #f5f5f5; stroke: #333; stroke-width: 1.5; }
    .scope { fill: #e8f4e8; }
    .external { fill: #f4e8e8; }
    .published { fill: #e8e8f4; }
    .arrow { fill: none; stroke: #333; stroke-width: 1.5; marker-end: url(#arrow10); }
    .label { font-family: monospace; font-size: 10px; fill: #333; }
    .title { font-family: monospace; font-size: 11px; fill: #333; font-weight: bold; }
  </style>

  <defs>
    <marker id="arrow10" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#333"/>
    </marker>
  </defs>

  <!-- Global Registry -->
  <rect x="200" y="20" width="300" height="60" rx="5" class="box"/>
  <text x="350" y="40" class="title" text-anchor="middle">GlobalSymbolRegistry</text>
  <text x="210" y="60" class="label">Published symbols from all feature sets</text>
  <text x="210" y="72" class="label">Accessible by business activity</text>

  <!-- Feature Set 1 -->
  <rect x="30" y="110" width="200" height="200" rx="5" class="box scope"/>
  <text x="130" y="130" class="title" text-anchor="middle">FeatureSet: Authentication</text>
  <text x="130" y="150" class="label" text-anchor="middle">Business Activity: Security</text>

  <rect x="45" y="165" width="170" height="30" rx="3" class="box"/>
  <text x="55" y="185" class="label">user (internal)</text>

  <rect x="45" y="200" width="170" height="30" rx="3" class="box"/>
  <text x="55" y="220" class="label">credentials (internal)</text>

  <rect x="45" y="235" width="170" height="30" rx="3" class="box published"/>
  <text x="55" y="255" class="label">authenticated-user (published)</text>

  <rect x="45" y="270" width="170" height="30" rx="3" class="box external"/>
  <text x="55" y="290" class="label">request (external)</text>

  <!-- Feature Set 2 -->
  <rect x="260" y="110" width="200" height="200" rx="5" class="box scope"/>
  <text x="360" y="130" class="title" text-anchor="middle">FeatureSet: Profile</text>
  <text x="360" y="150" class="label" text-anchor="middle">Business Activity: Security</text>

  <rect x="275" y="165" width="170" height="30" rx="3" class="box"/>
  <text x="285" y="185" class="label">profile (internal)</text>

  <rect x="275" y="200" width="170" height="30" rx="3" class="box"/>
  <text x="285" y="220" class="label">authenticated-user (from global)</text>

  <!-- Feature Set 3 -->
  <rect x="490" y="110" width="200" height="200" rx="5" class="box scope"/>
  <text x="590" y="130" class="title" text-anchor="middle">FeatureSet: Orders</text>
  <text x="590" y="150" class="label" text-anchor="middle">Business Activity: Commerce</text>

  <rect x="505" y="165" width="170" height="30" rx="3" class="box"/>
  <text x="515" y="185" class="label">orders (internal)</text>

  <rect x="505" y="200" width="170" height="30" rx="3" class="box external"/>
  <text x="515" y="220" class="label">authenticated-user (NOT accessible)</text>

  <!-- Arrows -->
  <path d="M 130 235 L 130 80 L 350 80" class="arrow"/>
  <text x="200" y="95" class="label">register published</text>

  <path d="M 360 165 L 360 80" class="arrow"/>
  <text x="370" y="140" class="label">lookup (same activity)</text>

  <!-- X for blocked access -->
  <line x1="580" y1="85" x2="595" y2="100" stroke="red" stroke-width="3"/>
  <line x1="595" y1="85" x2="580" y2="100" stroke="red" stroke-width="3"/>
  <text x="490" y="95" class="label" fill="red">blocked (different activity)</text>

  <!-- Legend -->
  <rect x="30" y="320" width="250" height="25" fill="none"/>
  <rect x="40" y="325" width="15" height="12" class="scope"/>
  <text x="60" y="335" class="label">Internal scope</text>
  <rect x="130" y="325" width="15" height="12" class="published"/>
  <text x="150" y="335" class="label">Published</text>
  <rect x="210" y="325" width="15" height="12" class="external"/>
  <text x="230" y="335" class="label">External</text>
</svg>

**Figure 5.1**: Symbol table scope hierarchy. Published symbols are registered globally but only accessible within the same business activity.

---

## Visibility Levels

Symbols have three visibility levels:

```swift
public enum SymbolVisibility: Sendable {
    case `internal`   // Private to feature set
    case published    // Exported via Publish
    case external     // Provided by runtime
}
```

| Visibility | Created By | Accessible From |
|------------|------------|-----------------|
| `internal` | AROStatement result | Same feature set only |
| `published` | PublishStatement | Same business activity |
| `external` | Runtime (request, context) | Any feature set |

### Business Activity Isolation

Published symbols are scoped by business activity—not globally visible:

```swift
// SemanticAnalyzer.swift:104-106
for symbol in analyzed.symbolTable.publishedSymbols.values {
    globalRegistry.register(symbol: symbol, fromFeatureSet: featureSet.name)
}
```

<svg viewBox="0 0 600 250" xmlns="http://www.w3.org/2000/svg">
  <style>
    .box { fill: #f5f5f5; stroke: #333; stroke-width: 1.5; }
    .activity { stroke-width: 2; stroke-dasharray: 5,3; }
    .a1 { fill: #e8f4e8; stroke: #4a4; }
    .a2 { fill: #e8e8f4; stroke: #66a; }
    .arrow { fill: none; stroke: #333; stroke-width: 1.5; marker-end: url(#arrow11); }
    .blocked { stroke: red; stroke-width: 2; }
    .label { font-family: monospace; font-size: 10px; fill: #333; }
    .title { font-family: monospace; font-size: 11px; fill: #333; font-weight: bold; }
  </style>

  <defs>
    <marker id="arrow11" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#333"/>
    </marker>
  </defs>

  <!-- Activity: Security -->
  <rect x="30" y="30" width="250" height="180" rx="10" class="box activity a1"/>
  <text x="155" y="50" class="title" text-anchor="middle">Business Activity: Security</text>

  <rect x="50" y="70" width="100" height="50" rx="5" class="box"/>
  <text x="100" y="90" class="label" text-anchor="middle">Authentication</text>
  <text x="100" y="105" class="label" text-anchor="middle">→ user</text>

  <rect x="160" y="70" width="100" height="50" rx="5" class="box"/>
  <text x="210" y="90" class="label" text-anchor="middle">Profile</text>
  <text x="210" y="105" class="label" text-anchor="middle">← user</text>

  <path d="M 150 95 L 160 95" class="arrow"/>
  <text x="145" y="85" class="label">OK</text>

  <!-- Activity: Commerce -->
  <rect x="320" y="30" width="250" height="180" rx="10" class="box activity a2"/>
  <text x="445" y="50" class="title" text-anchor="middle">Business Activity: Commerce</text>

  <rect x="340" y="70" width="100" height="50" rx="5" class="box"/>
  <text x="390" y="90" class="label" text-anchor="middle">Orders</text>
  <text x="390" y="105" class="label" text-anchor="middle">← user?</text>

  <rect x="450" y="70" width="100" height="50" rx="5" class="box"/>
  <text x="500" y="90" class="label" text-anchor="middle">Checkout</text>

  <!-- Blocked arrow -->
  <path d="M 260 95 L 340 95" class="arrow blocked"/>
  <line x1="295" y1="85" x2="305" y2="105" class="blocked"/>
  <line x1="305" y1="85" x2="295" y2="105" class="blocked"/>
  <text x="270" y="130" class="label" fill="red">Different activity</text>
  <text x="270" y="145" class="label" fill="red">= not accessible</text>
</svg>

**Figure 5.2**: Business activity boundaries. The `user` symbol published in "Security" is only visible to other feature sets in "Security", not to "Commerce".

---

## Data Flow Classification

The analyzer tracks what each statement consumes and produces:

```swift
// SemanticAnalyzer.swift:11-25
public struct DataFlowInfo: Sendable, Equatable {
    public let inputs: Set<String>      // Variables consumed
    public let outputs: Set<String>     // Variables produced
    public let sideEffects: [String]    // External effects
}
```

<svg viewBox="0 0 650 280" xmlns="http://www.w3.org/2000/svg">
  <style>
    .box { fill: #f5f5f5; stroke: #333; stroke-width: 1.5; }
    .input { fill: #fdd; }
    .output { fill: #dfd; }
    .effect { fill: #ddf; }
    .arrow { fill: none; stroke: #333; stroke-width: 1.5; marker-end: url(#arrow12); }
    .label { font-family: monospace; font-size: 10px; fill: #333; }
    .title { font-family: monospace; font-size: 11px; fill: #333; font-weight: bold; }
    .code { font-family: monospace; font-size: 12px; fill: #333; }
  </style>

  <defs>
    <marker id="arrow12" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#333"/>
    </marker>
  </defs>

  <!-- Statement -->
  <rect x="30" y="30" width="590" height="35" rx="5" class="box"/>
  <text x="40" y="53" class="code">&lt;Retrieve&gt; the &lt;user&gt; from the &lt;user-repository&gt; where id = &lt;userId&gt;.</text>

  <!-- Analysis -->
  <rect x="30" y="85" width="180" height="80" rx="5" class="box input"/>
  <text x="120" y="105" class="title" text-anchor="middle">Inputs</text>
  <text x="40" y="125" class="label">• user-repository (external)</text>
  <text x="40" y="140" class="label">• userId (must be defined)</text>

  <rect x="235" y="85" width="180" height="80" rx="5" class="box output"/>
  <text x="325" y="105" class="title" text-anchor="middle">Outputs</text>
  <text x="245" y="125" class="label">• user (new internal variable)</text>

  <rect x="440" y="85" width="180" height="80" rx="5" class="box effect"/>
  <text x="530" y="105" class="title" text-anchor="middle">Side Effects</text>
  <text x="450" y="125" class="label">• repository-read</text>
  <text x="450" y="140" class="label">• (logged to execution trace)</text>

  <!-- DataFlowInfo -->
  <rect x="30" y="190" width="590" height="70" rx="5" class="box"/>
  <text x="40" y="210" class="title">DataFlowInfo for this statement:</text>
  <text x="40" y="230" class="label">inputs: {"user-repository", "userId"}</text>
  <text x="40" y="245" class="label">outputs: {"user"}</text>

  <!-- Arrows -->
  <path d="M 120 85 L 120 65" class="arrow"/>
  <path d="M 325 85 L 325 65" class="arrow"/>
  <path d="M 530 85 L 530 65" class="arrow"/>
</svg>

**Figure 5.3**: Data flow analysis for a single statement. The analyzer determines inputs (must exist), outputs (will be created), and side effects.

### Action Role Determines Flow

```swift
// SemanticAnalyzer.swift:292-330
switch statement.action.semanticRole {
case .request:
    // REQUEST: external -> internal
    inputs.insert(objectName)
    outputs.insert(resultName)

case .own:
    // OWN: internal -> internal
    inputs.insert(objectName)
    outputs.insert(resultName)

case .response:
    // RESPONSE: internal -> external
    inputs.insert(resultName)
    inputs.insert(objectName)
    sideEffects.append("response")

case .export:
    // EXPORT: internal -> persistent
    inputs.insert(resultName)
    sideEffects.append("export-\(objectName)")
}
```

---

## Immutability Enforcement

ARO enforces that variables cannot be rebound. This is checked during analysis:

```swift
// SemanticAnalyzer.swift:194-204
private func isInternalVariable(_ name: String) -> Bool {
    return name.hasPrefix("_")
}

private func isRebindingAllowed(_ verb: String) -> Bool {
    let rebindingVerbs: Set<String> = ["accept", "update", "modify", "change", "set"]
    return rebindingVerbs.contains(verb.lowercased())
}
```

When a statement would create a variable that already exists:

```swift
// Check for immutability violation
if definedSymbols.contains(resultName) &&
   !isInternalVariable(resultName) &&
   !isRebindingAllowed(statement.action.verb) {
    diagnostics.error(
        "Cannot rebind variable '\(resultName)' - variables are immutable",
        at: statement.span.start
    )
}
```

### Special Cases

| Variable | Can Rebind? | Reason |
|----------|-------------|--------|
| `user` | No | Normal variable |
| `_internal` | Yes | Framework prefix |
| With `Update` | Yes | Explicit rebind verb |
| With `Accept` | Yes | State transition verb |

---

## Unused Variable Detection

After building the symbol table, the analyzer checks for variables that are defined but never used:

```swift
// SemanticAnalyzer.swift:157-181
var usedVariables: Set<String> = []
for flow in dataFlows {
    usedVariables.formUnion(flow.inputs)
}

for (name, symbol) in symbolTable.symbols {
    if symbol.visibility == .published { continue }  // Used externally
    if case .alias = symbol.source { continue }       // Original tracked
    if symbol.visibility == .external { continue }    // Runtime-provided

    if !usedVariables.contains(name) {
        diagnostics.warning(
            "Variable '\(name)' is defined but never used",
            at: symbol.definedAt.start
        )
    }
}
```

This is a warning, not an error—unused variables don't break execution.

---

## Circular Event Chain Detection

ARO's event system allows feature sets to emit events that trigger other feature sets. The analyzer detects circular chains:

```
FeatureSet A emits EventX
  → triggers Handler for EventX
    → which emits EventY
      → triggers Handler for EventY
        → which emits EventX  // CYCLE!
```

```swift
// SemanticAnalyzer.swift - detectCircularEventChains
private func detectCircularEventChains(_ analyzedSets: [AnalyzedFeatureSet]) {
    // Build event emission graph
    var emissionGraph: [String: Set<String>] = [:]

    for analyzed in analyzedSets {
        let emittedEvents = findEmittedEvents(in: analyzed.featureSet)
        // Map: event -> events it can transitively emit
    }

    // DFS to detect cycles
    for eventName in emissionGraph.keys {
        var visited: Set<String> = []
        var path: [String] = []
        if hasCycle(from: eventName, graph: emissionGraph, visited: &visited, path: &path) {
            diagnostics.error(
                "Circular event chain detected: \(path.joined(separator: " → "))",
                at: ...
            )
        }
    }
}
```

---

## Orphaned Event Detection

Events that are emitted but never handled are flagged as warnings:

```swift
// SemanticAnalyzer.swift - detectOrphanedEventEmissions
private func detectOrphanedEventEmissions(_ analyzedSets: [AnalyzedFeatureSet]) {
    var emittedEvents: Set<String> = []
    var handledEvents: Set<String> = []

    for analyzed in analyzedSets {
        emittedEvents.formUnion(findEmittedEvents(in: analyzed.featureSet))

        // Check if this feature set handles events
        if analyzed.featureSet.businessActivity.contains("Handler") {
            let eventName = extractEventName(from: analyzed.featureSet.businessActivity)
            handledEvents.insert(eventName)
        }
    }

    for event in emittedEvents {
        if !handledEvents.contains(event) {
            diagnostics.warning(
                "Event '\(event)' is emitted but no handler is registered",
                at: ...
            )
        }
    }
}
```

---

## Multi-Pass Architecture

The four passes serve specific purposes:

```
Pass 1: Build Symbol Tables
  - Create symbols for each statement
  - Track defined variables
  - Build data flow info
  - Register published symbols in global registry

Pass 2: Verify Dependencies
  - Check that required variables exist
  - Validate cross-feature-set references
  - Enforce business activity boundaries

Pass 3: Detect Circular Events
  - Build event emission graph
  - DFS for cycles
  - Report circular chains

Pass 4: Detect Orphans
  - Collect all emitted events
  - Collect all handled events
  - Warn about orphans
```

Why multiple passes? Some checks require information from all feature sets (circular events, orphan events). Single-pass analysis would miss these.

---

## Diagnostic Collection

Rather than failing on the first error, the analyzer collects all diagnostics:

```swift
public final class DiagnosticCollector: @unchecked Sendable {
    private var diagnostics: [Diagnostic] = []

    public func error(_ message: String, at location: SourceLocation) {
        diagnostics.append(Diagnostic(severity: .error, message: message, location: location))
    }

    public func warning(_ message: String, at location: SourceLocation) {
        diagnostics.append(Diagnostic(severity: .warning, message: message, location: location))
    }

    public var hasErrors: Bool {
        diagnostics.contains { $0.severity == .error }
    }
}
```

This enables reporting all problems in a single compilation:

```
Warning: Variable 'temp' is defined but never used
  at line 3, column 13

Error: Cannot rebind variable 'user' - variables are immutable
  at line 5, column 13

Error: Circular event chain detected: UserCreated → NotificationSent → UserCreated
  at line 12, column 4
```

---

## Chapter Summary

ARO's semantic analysis enforces the language's design principles:

1. **Symbol tables per feature set**: Each scope is isolated; sharing requires explicit Publish.

2. **Business activity boundaries**: Published symbols are scoped to their business activity, not globally visible.

3. **Data flow tracking**: Inputs, outputs, and side effects are computed for each statement.

4. **Immutability enforcement**: Variables cannot be rebound except with special verbs or `_` prefix.

5. **Event chain validation**: Circular event chains and orphaned events are detected.

The analyzer is designed for reporting, not aborting. Multiple errors can be collected and shown to the user at once.

Implementation reference: `Sources/AROParser/SemanticAnalyzer.swift`

---

*Next: Chapter 6 — Interpreted Execution*
