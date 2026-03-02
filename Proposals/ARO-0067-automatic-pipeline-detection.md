# ARO-0067: Automatic Pipeline Detection

- **Status:** Implemented
- **Author:** ARO Team
- **Created:** 2026-02-22
- **Related:** ARO-0051 (Streaming Execution), ARO-0018 (Data Pipelines)

## Abstract

This proposal documents ARO's **automatic pipeline detection** - the runtime's ability to recognize data flow chains without requiring explicit pipeline operators like `|>`. Instead of introducing new syntax, ARO leverages its immutable variable semantics to automatically detect when statements form a processing pipeline.

## Motivation

### The Problem with Explicit Pipeline Operators

Many languages use explicit operators to chain operations:

**F#, Elixir, JavaScript (Proposed):**
```
data |> filter |> map |> reduce
```

**Advantages:**
- Clear data flow direction
- Explicit about chaining intent

**Disadvantages:**
- New syntax to learn
- Breaks natural language feel
- Requires understanding operator precedence
- Not backwards compatible

### ARO's Better Approach

ARO's immutable variables **naturally form pipelines** through variable dependencies:

```aro
(* No special syntax - just immutable variable chains *)
Filter the <current-year> from <transactions> where <year> = "2024".
Filter the <high-value> from <current-year> where <amount> > 500.
Filter the <completed> from <high-value> where <status> = "completed".
Filter the <electronics> from <completed> where <category> = "electronics".
```

The runtime **automatically detects** the pipeline:
```
transactions → current-year → high-value → completed → electronics
```

## Design Philosophy

### Three Core Principles

1. **Zero New Syntax**: No `|>`, no `then`, no special keywords
2. **Natural Language**: Reads like instructions to a human
3. **Automatic Optimization**: Compiler and runtime handle the rest

### Why Immutability Enables This

```aro
(* Each statement binds a NEW variable *)
Filter the <step1> from <input> where x > 10.    (* step1 depends on input *)
Filter the <step2> from <step1> where y < 5.     (* step2 depends on step1 *)
Map the <step3> from <step2> with upper(name).   (* step3 depends on step2 *)
```

**Key Insight:** Because variables are immutable, the data flow graph is **explicit in the code**:
- `<step1>` is bound once and never changes
- `<step2>` can only come from `<step1>`
- `<step3>` can only come from `<step2>`

This forms a **directed acyclic graph (DAG)** that the runtime can traverse.

## How It Works

### 1. Semantic Analysis Phase

The parser builds a **dependency graph** during semantic analysis:

```
┌─────────────────────────────────────────────────────────────┐
│               DEPENDENCY GRAPH CONSTRUCTION                 │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   Statement 1: Filter <a> from <input> where x > 10        │
│                  ▲                    │                     │
│                  │                    │                     │
│                  └─── depends on ─────┘                     │
│   Statement 2: Filter <b> from <a> where y < 5             │
│                  ▲                │                         │
│                  │                │                         │
│                  └─── depends on ─┘                         │
│   Statement 3: Map <c> from <b> with upper(name)           │
│                  ▲            │                             │
│                  │            │                             │
│                  └── depends on                             │
│                                                             │
│   Result: DAG of dependencies                               │
│   input → a → b → c                                         │
└─────────────────────────────────────────────────────────────┘
```

### 2. Pipeline Recognition

The runtime identifies **pipeline patterns**:

| Pattern | Description | Example |
|---------|-------------|---------|
| **Linear chain** | Each step depends on exactly one previous step | `a → b → c → d` |
| **Fan-out** | One source feeds multiple consumers | `a → [b, c, d]` |
| **Diamond** | Multiple paths converge | `a → [b, c] → d` |

### 3. Execution Strategy

Based on the detected pattern, the runtime chooses an execution strategy:

| Pattern | Strategy | Optimization |
|---------|----------|--------------|
| Linear chain | **Streaming pipeline** | O(1) memory, lazy evaluation |
| Fan-out (same operation type) | **Aggregation fusion** | Single pass, multiple results |
| Fan-out (different types) | **Stream tee** | Bounded buffer, concurrent execution |
| Diamond | **Materialize at convergence** | Cache intermediate result |

## Examples

### Example 1: Simple Linear Pipeline

```aro
(* User writes this - no special syntax *)
Extract the <data> from the <request: body>.
Transform the <cleaned> from the <data> with "trim".
Transform the <parsed> from the <cleaned> with "parse-json".
Validate the <valid> from the <parsed> against the <schema>.
Store the <valid> in the <repository>.
```

**What the runtime sees:**
```
Pipeline detected: data → cleaned → parsed → valid → repository
Execution mode: Streaming (O(1) memory)
```

### Example 2: Multi-Stage Filter Chain

```aro
(* From Examples/StreamingPipeline/main.aro *)
Create the <transactions> with [...].

(* Stage 1: Filter by year *)
Filter the <current-year> from <transactions> where <year> = "2024".

(* Stage 2: Filter by amount *)
Filter the <high-value> from <current-year> where <amount> > 500.

(* Stage 3: Filter by status *)
Filter the <completed> from <high-value> where <status> = "completed".

(* Stage 4: Filter by category *)
Filter the <electronics> from <completed> where <category> = "electronics".
```

**What the runtime does:**
```
Pipeline detected: transactions → current-year → high-value → completed → electronics
Optimization: Fused filter pipeline (4 conditions in single pass)
Memory: O(1) per element
```

### Example 3: Fan-Out with Multiple Aggregations

```aro
(* Single source, multiple consumers *)
Filter the <active-orders> from <orders> where <status> = "active".

Reduce the <total> from <active-orders> with sum(<amount>).
Reduce the <count> from <active-orders> with count().
Reduce the <avg> from <active-orders> with avg(<amount>).
```

**What the runtime does:**
```
Pipeline detected: active-orders → [total, count, avg]
Pattern: Fan-out with same source
Optimization: Aggregation fusion - single pass computes all 3 results
Memory: O(1) - three accumulators
```

### Example 4: Complex Data Pipeline

```aro
(* From Examples/DataPipeline/main.aro *)
Create the <orders> with [...].

(* Filter subset *)
Filter the <active-orders> from <orders> where <status> = "active".

(* Multiple operations on filtered data *)
Reduce the <active-total> from <active-orders> with sum(<amount>).
Reduce the <active-count> from <active-orders> with count().
Reduce the <active-avg> from <active-orders> with avg(<amount>).

(* Further filtering *)
Filter the <high-value> from <orders> where <amount> > 200.
Reduce the <high-value-total> from <high-value> with sum(<amount>).
```

**What the runtime does:**
```
Two pipelines detected:
  1. orders → active-orders → [active-total, active-count, active-avg]
  2. orders → high-value → high-value-total

Optimizations:
  - Pipeline 1: Fused aggregation (single pass, 3 results)
  - Pipeline 2: Streaming filter + aggregation
  - orders can be consumed by both (Stream Tee or dual iteration)
```

## Comparison with Explicit Operators

### Option 1: Explicit Pipeline Operator (Rejected)

```aro
(* What we DIDN'T do *)
Extract <data> from <request: body>
  |> Transform with "trim"
  |> Transform with "parse-json"
  |> Validate
  |> Store in <repository>.
```

**Problems:**
- Breaks natural language feel
- Requires learning new operator
- Not backwards compatible
- Harder to debug (where did it fail?)

### Option 2: ARO's Automatic Detection (Implemented)

```aro
(* What we DID do *)
Extract the <data> from the <request: body>.
Transform the <cleaned> from <data> with "trim".
Transform the <parsed> from <cleaned> with "parse-json".
Validate the <valid> from <parsed> against <schema>.
Store the <valid> in <repository>.
```

**Advantages:**
- Reads like natural language
- No new syntax to learn
- Each step has a name (great for debugging)
- Error messages reference specific variables
- Backwards compatible
- Can inspect intermediate values

## Implementation

### Files Modified

**Parser:**
- `Sources/AROParser/SemanticAnalyzer.swift` - Builds dependency graph

**Runtime:**
- `Sources/ARORuntime/Core/ExecutionEngine.swift` - Detects pipeline patterns
- `Sources/ARORuntime/Core/PipelineExecutor.swift` - Executes detected pipelines
- `Sources/ARORuntime/Streaming/` - Streaming support (see ARO-0051)

### Dependency Graph Structure

```swift
/// Represents a variable dependency in the feature set
struct VariableDependency: Sendable {
    let variable: String
    let dependsOn: Set<String>
    let statement: AROStatement
}

/// Dependency graph for a feature set
struct DependencyGraph: Sendable {
    let variables: [String: VariableDependency]

    /// Find all linear chains (pipelines)
    func findPipelines() -> [[String]] {
        // Traverse graph to find chains of dependencies
        // Returns: [[a, b, c], [d, e, f], ...]
    }

    /// Find fan-out patterns (one source, multiple consumers)
    func findFanOuts() -> [String: [String]] {
        // Returns: [source: [consumer1, consumer2, ...]]
    }
}
```

### Pipeline Execution

```swift
/// Execute a detected pipeline with streaming
actor PipelineExecutor {
    func executePipeline(
        steps: [AROStatement],
        context: ExecutionContext
    ) async throws {
        // For linear chains: execute as streaming pipeline
        // For fan-outs: use Stream Tee or Aggregation Fusion
        // For diamonds: materialize at convergence point
    }
}
```

## Debugging and Error Messages

### Error Reporting

Because each step has a named variable, errors are clear:

```aro
Extract the <data> from the <request: body>.
Transform the <cleaned> from <data> with "trim".
Transform the <parsed> from <cleaned> with "parse-json".
```

**If parsing fails:**
```
Error: Cannot transform the parsed from the cleaned with "parse-json"
  Input value: "invalid json {"
  Location: feature-set.aro:3
  Variable: <cleaned>
```

Compare with pipeline operator approach:
```
Error: Pipeline failed at step 3
  (No variable name to reference!)
```

### Debugging Intermediate Values

With named variables, you can inspect each step:

```aro
Extract the <data> from the <request: body>.
Log <data> to the <console>.  (* Debug: see raw data *)

Transform the <cleaned> from <data> with "trim".
Log <cleaned> to the <console>.  (* Debug: see cleaned data *)

Transform the <parsed> from <cleaned> with "parse-json".
Log <parsed> to the <console>.  (* Debug: see parsed data *)
```

## Performance Characteristics

### Memory Usage

| Code Pattern | Memory Complexity | Notes |
|--------------|-------------------|-------|
| Linear chain | O(1) | Streaming execution |
| Fused aggregations | O(k) | k = number of accumulators |
| Stream tee (2 consumers) | O(buffer size) | Bounded buffer |
| Diamond pattern | O(n) | Must materialize at merge |

### Execution Time

| Optimization | Time Complexity | Speedup |
|--------------|-----------------|---------|
| No optimization | O(n*k) | k passes over data |
| Fused filters | O(n) | Single pass |
| Fused aggregations | O(n) | Single pass |
| Streaming pipeline | O(n) | Lazy evaluation |

## Examples Directory

Examples demonstrating automatic pipeline detection:

- `Examples/DataPipeline/` - Filter, Map, Reduce chains
- `Examples/StreamingPipeline/` - Multi-stage filter pipeline
- `Examples/AutoPipeline/` - Explicit pipeline detection demo (if exists)

## Future Enhancements

### 1. Visual Pipeline Inspection

```bash
aro inspect my-app.aro --show-pipelines
```

Output:
```
Pipeline 1 (4 steps):
  transactions → current-year → high-value → completed → electronics
  Optimization: Fused filter (single pass)
  Memory: O(1)

Pipeline 2 (3 steps):
  active-orders → [total, count, avg]
  Optimization: Aggregation fusion
  Memory: O(3) accumulators
```

### 2. Pipeline Metrics

Track pipeline performance in production:

```aro
(* Runtime tracks these automatically *)
Filter <step1> from <input> where x > 10.
  (* Metrics: input_count=1000, output_count=100, filter_rate=0.1 *)

Filter <step2> from <step1> where y < 5.
  (* Metrics: input_count=100, output_count=20, filter_rate=0.2 *)
```

### 3. Pipeline Visualization

IDE support to visualize data flow:

```
┌─────────────────────────────────────────┐
│    Visual Pipeline (VS Code/IntelliJ)  │
├─────────────────────────────────────────┤
│                                         │
│   [transactions]                        │
│         │                               │
│         ↓  (year=2024)                  │
│   [current-year]                        │
│         │                               │
│         ↓  (amount>500)                 │
│   [high-value]                          │
│         │                               │
│         ↓  (status=completed)           │
│   [completed]                           │
│         │                               │
│         ↓  (category=electronics)       │
│   [electronics]                         │
│                                         │
│   Hover for metrics at each step        │
└─────────────────────────────────────────┘
```

## Compatibility

### Backward Compatibility

- ✅ All existing ARO code works unchanged
- ✅ No new keywords or operators required
- ✅ Transparent optimization (results identical)
- ✅ Can opt out with explicit materialization if needed

### Breaking Changes

None. This is a pure runtime optimization.

## Benefits Summary

| Aspect | Explicit `|>` Operator | ARO Automatic Detection |
|--------|----------------------|-------------------------|
| **Syntax** | New operator to learn | Natural language (no change) |
| **Debugging** | Hard (no variable names) | Easy (named variables) |
| **Error messages** | "Pipeline failed at step N" | "Cannot transform <parsed> from <cleaned>" |
| **Backward compat** | Breaking change | Transparent |
| **Optimization** | Must be explicit | Automatic |
| **Readability** | Terse but cryptic | Verbose but clear |

## References

- ARO-0051: Streaming Execution Engine
- ARO-0018: Data Pipeline Operations
- Issue #105: Pipeline Operator Discussion
- [F# Pipeline Operator](https://learn.microsoft.com/en-us/dotnet/fsharp/language-reference/symbol-and-operator-reference/)
- [Elixir Pipe Operator](https://hexdocs.pm/elixir/Kernel.html#%7C%3E/2)
- [JavaScript Pipeline Proposal](https://github.com/tc39/proposal-pipeline-operator)

## Conclusion

ARO's automatic pipeline detection demonstrates that **good language design can eliminate the need for new syntax**. By leveraging immutable variables and data flow analysis, ARO provides all the benefits of pipeline operators without the cognitive overhead.

The result: code that reads like natural language while executing like optimized streaming pipelines.
