# Chapter 5: Semantic Analysis

## Overview

The parser gives you a tree of tokens. Semantic analysis gives that tree *meaning*.

The `SemanticAnalyzer` takes a parsed `Program` and produces an `AnalyzedProgram` — the same structure enriched with symbol tables, data flow info, and cross-feature-set dependency tracking. It runs four passes. Each pass builds on the last.

The four passes:
1. Build symbol tables and detect duplicates
2. Verify external dependencies
3. Detect circular event chains
4. Detect orphaned event emissions

---

## Symbol Table Design

Each feature set gets its own symbol table, built during the first pass. Here's everything the analyzer produces per feature set:

| Field | What it contains |
|-------|-----------------|
| `featureSet` | The original parsed feature set |
| `symbolTable` | All variables defined, their visibility and source |
| `dataFlows` | Per-statement inputs, outputs, and side effects |
| `dependencies` | External symbols this feature set needs |
| `exports` | Symbols published to the global registry |

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

| Visibility | Created By | Accessible From |
|------------|------------|-----------------|
| `internal` | AROStatement result | Same feature set only |
| `published` | PublishStatement | Same business activity |
| `external` | Runtime (request, context) | Any feature set |

### Business Activity Isolation

After analyzing each feature set, published symbols are registered in a global registry keyed by business activity. Same activity = can see each other. Different activity = invisible. The SVG diagram says it better than code does.

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

The analyzer tracks what each statement consumes and produces. Every statement gets a `DataFlowInfo`:

| Field | Meaning |
|-------|---------|
| `inputs` | Variables this statement reads (must already exist) |
| `outputs` | Variables this statement produces (must not already exist) |
| `sideEffects` | External effects: HTTP responses, repository writes, event emissions |

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

The action's semantic role tells the analyzer which direction data moves. This maps cleanly to what goes in `inputs`, `outputs`, and `sideEffects`:

| Role | Inputs | Outputs | Side Effects |
|------|--------|---------|--------------|
| REQUEST | object (external source) | result variable | — |
| OWN | object (internal) | result variable | — |
| RESPONSE | result + object | — | `"response"` |
| EXPORT | result | — | `"export-{objectName}"` |

---

## Immutability Enforcement

ARO variables cannot be rebound. When a statement would bind a variable that already exists in the symbol table, the analyzer flags an error — unless the verb is a mutation verb (`Update`, `Accept`, `Modify`) or the variable name starts with `_` (framework-internal).

### Special Cases

| Variable | Can Rebind? | Reason |
|----------|-------------|--------|
| `user` | No | Normal variable |
| `_internal` | Yes | Framework prefix |
| With `Update` | Yes | Explicit rebind verb |
| With `Accept` | Yes | State transition verb |

---

## Unused Variable Detection

After building all data flows, the analyzer computes the union of all input sets. Any symbol in the table that never appears as an input (and isn't published or external) gets a warning. This is a warning, not an error — unused variables don't break execution.

---

## Circular Event Chain Detection

ARO's event system lets feature sets emit events that trigger other feature sets. That's great — until a chain loops back to itself:

```
FeatureSet A emits EventX
  → triggers Handler for EventX
    → which emits EventY
      → triggers Handler for EventY
        → which emits EventX  // CYCLE!
```

The detection algorithm:

```text
Build graph: event name → set of events it can transitively emit
DFS each node, tracking the current path
If we revisit a node already in the path → cycle detected → error
```

---

## Orphaned Event Detection

Collect all emitted event names. Collect all handled event names (from feature sets with `Handler` in their business activity). Anything emitted but never handled gets a warning. You probably forgot to write the handler.

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

Why multiple passes? Some checks require information from all feature sets — circular events and orphan detection can only work once every feature set has been analyzed. A single-pass approach would miss them.

---

## Diagnostic Collection

The analyzer never aborts on first error. Errors and warnings accumulate in a `DiagnosticCollector`, and a single compilation run can surface all problems at once. You fix everything, not just the first thing.

Sample output from a bad program:

```
Warning: Variable 'temp' is defined but never used
  at line 3, column 13

Error: Cannot rebind variable 'user' - variables are immutable
  at line 5, column 13

Error: Circular event chain detected: UserCreated → NotificationSent → UserCreated
  at line 12, column 4
```

---

## Verb Classification: VerbSets

The analyzer needs to know what a verb *does* — is it a mutation? A response? A server operation that must run even when its argument is a literal? These classifications live in a shared module: `Sources/ARORuntime/Core/VerbSets.swift`.

| Category | Representative Verbs | Used For |
|----------|---------------------|----------|
| update | update, modify, change, set | Allow rebinding an existing variable |
| create | create, make, build, construct | New entity creation |
| response | log, print, send, emit, notify | Skip expression shortcut |
| server | start, stop, keepalive, schedule | Force execution even with literal arguments |
| request | extract, retrieve, fetch, parse | Mark as REQUEST role |
| own | compute, validate, compare, transform | Mark as OWN role |
| export | publish, store | Mark as EXPORT role |
| query | filter, sort, group | Collection processing |
| io | read, write, copy, move | File operations |
| state | accept | State transition (allow rebind) |

**Why a shared module matters.** Before `VerbSets.swift` existed, verb classification was duplicated between the interpreter (`FeatureSetExecutor`) and the compiler (`LLVMCodeGenerator`). When someone added a new verb to one, the other diverged silently. Now there's one canonical list and both modes reference it.

### Plugin Compatibility Checking

The `aro check plugins` subcommand validates that installed plugins are compatible with the current ARO version:

```
aro check plugins
aro check plugins --directory ./MyApp
```

Each plugin declares an `aro-version` constraint in `plugin.yaml` (e.g., `aro-version: ">=0.6.0"`). The checker uses semantic version comparison to detect incompatible plugins before they cause runtime errors.

---

## Chapter Summary

ARO's semantic analysis enforces the language's design principles:

1. **Symbol tables per feature set**: Each scope is isolated; sharing requires explicit Publish.

2. **Business activity boundaries**: Published symbols are scoped to their business activity, not globally visible.

3. **Data flow tracking**: Inputs, outputs, and side effects are computed for each statement.

4. **Immutability enforcement**: Variables cannot be rebound except with special verbs or `_` prefix.

5. **Event chain validation**: Circular event chains and orphaned events are detected.

6. **Shared verb classification**: `VerbSets.swift` provides a single authoritative source for verb categories, keeping interpreter and compiler behavior synchronized.

The analyzer is designed for reporting, not aborting. Multiple errors can be collected and shown to the user at once.

Implementation references:
- `Sources/AROParser/SemanticAnalyzer.swift`
- `Sources/ARORuntime/Core/VerbSets.swift`

---

*Next: Chapter 6 — Interpreted Execution*
