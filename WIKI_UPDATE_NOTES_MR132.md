# Wiki Update Notes for MR !132

This document lists the wiki pages that need to be updated to reflect the changes in MR !132.

## Summary of Changes

MR !132 implements several critical features:

1. **ARO-0067: Automatic Pipeline Detection** - ARO automatically detects pipelines without `|>` operator
2. **ARO-0101: EventBus Actor Conversion** - Thread-safe event handling
3. **ARO-0102: Constant Folding Optimization** - Compile-time expression evaluation
4. **ARO-0124: Event Recording and Replay** - Debug/testing infrastructure

## Primary Focus: Automatic Pipeline Detection

**Key Message**: ARO does NOT use explicit pipeline operators like `|>`. Instead, it automatically detects pipelines through immutable variable dependencies.

---

## Wiki Pages to Update

### 1. Language Features / Data Pipelines

**Update the pipeline section to emphasize automatic detection:**

**Before:**
> ARO supports data pipeline operations like Filter, Map, and Reduce.

**After:**
> ARO automatically detects data pipelines without requiring explicit operators like `|>`. The runtime recognizes data flow chains through immutable variable dependencies.
>
> ```aro
> (* ARO automatically detects this as a pipeline *)
> Filter the <current-year> from <transactions> where <year> = "2024".
> Filter the <high-value> from <current-year> where <amount> > 500.
> Filter the <completed> from <high-value> where <status> = "completed".
> ```
>
> The runtime automatically recognizes: `transactions → current-year → high-value → completed`

### 2. Getting Started / Quick Tutorial

**Add a note about pipeline detection:**

> **Pipeline Operations**: When you chain operations using immutable variables, ARO automatically detects the pipeline and applies optimizations. No special syntax needed!
>
> ```aro
> Filter the <active> from <users> where <status> = "active".
> Reduce the <count> from <active> with count().
> (* ARO detects: users → active → count *)
> ```

### 3. Advanced Features / Streaming Execution

**Update streaming documentation:**

**Add this section:**
> ### Automatic Pipeline Detection
>
> ARO's streaming engine works seamlessly with automatic pipeline detection (ARO-0067). When you write chained operations, ARO:
>
> 1. Detects the data flow graph through variable dependencies
> 2. Builds a lazy pipeline that defers execution
> 3. Applies streaming optimizations transparently
> 4. Fuses multiple aggregations into single-pass operations
>
> This means the same code works for both small and large datasets without modification.

### 4. Language Design / Design Decisions

**Add a new section:**

> ### Why No Pipeline Operator?
>
> **Decision**: ARO does NOT use explicit pipeline operators like `|>` (F#, Elixir) or `.` (method chaining).
>
> **Reason**: ARO's immutable variables naturally form pipelines. Each statement creates a new binding that later statements reference, creating an explicit data flow graph that the runtime can optimize.
>
> **Benefits**:
> - Natural language syntax maintained
> - Better debugging (named intermediate values)
> - Clear error messages referencing specific variables
> - Backward compatible (no syntax changes)
>
> See **ARO-0067** for complete specification.

### 5. Performance / Optimizations

**Add information about pipeline optimizations:**

> ### Pipeline Optimizations
>
> ARO automatically optimizes detected pipelines:
>
> | Pattern | Optimization | Memory |
> |---------|--------------|--------|
> | Linear chain | Streaming pipeline | O(1) |
> | Multiple aggregations | Aggregation fusion | O(k accumulators) |
> | Fan-out | Stream tee | O(buffer size) |
>
> These optimizations are transparent - same code, automatic performance improvements.

### 6. Runtime Features / Event System

**Update with EventBus actor conversion:**

> ### Thread-Safe Event Handling
>
> The EventBus uses Swift actors for thread-safe concurrent event handling (#101). Multiple feature sets can emit and handle events concurrently without race conditions.

### 7. Compiler Features / Optimizations

**Add constant folding:**

> ### Constant Folding (#102)
>
> The compiler evaluates constant expressions at compile time:
>
> ```aro
> Compute the <value> from 5 * 10 + 2.
> (* Compiler emits: 52 directly *)
> ```
>
> This optimization reduces runtime computation for expressions with literal values.

### 8. Debugging / Event Replay

**Add event recording and replay:**

> ### Event Recording and Replay (#124)
>
> ARO can record events during execution for debugging and testing:
>
> ```bash
> # Record events
> aro run --record-events events.json my-app/
>
> # Replay events
> aro replay events.json my-app/
> ```
>
> This enables deterministic debugging of event-driven applications.

---

## Code Examples to Add/Update

### Example 1: Pipeline Detection

```aro
(* Automatic pipeline detection example *)
(Process Data: Analytics) {
    Create the <transactions> with [...].

    (* Stage 1: Filter by year - ARO detects pipeline starts here *)
    Filter the <current-year> from <transactions> where <year> = "2024".

    (* Stage 2: Filter by amount *)
    Filter the <high-value> from <current-year> where <amount> > 500.

    (* Stage 3: Filter by status *)
    Filter the <completed> from <high-value> where <status> = "completed".

    (* Stage 4: Aggregate - triggers pipeline execution *)
    Reduce the <total> from <completed> with sum(<amount>).

    Return an <OK: status> with { total: <total> }.
}
```

**Runtime behavior**:
- Detects 4-stage pipeline automatically
- Applies streaming optimizations
- O(1) memory usage (only accumulates matching items)

### Example 2: Multiple Aggregations (Fusion)

```aro
(* ARO fuses these into a single pass *)
Filter the <active-orders> from <orders> where <status> = "active".

Reduce the <total> from <active-orders> with sum(<amount>).
Reduce the <count> from <active-orders> with count().
Reduce the <avg> from <active-orders> with avg(<amount>).

(* Single iteration computes all three results *)
```

---

## FAQ Additions

### Q: Does ARO use the `|>` pipeline operator?

**A:** No. ARO automatically detects pipelines through immutable variable dependencies. This provides all the benefits of pipeline operators without new syntax, and enables better debugging through named intermediate values.

### Q: How do I create a pipeline in ARO?

**A:** Just write normal ARO code with immutable variables. If one operation uses the result of another, ARO automatically detects the pipeline:

```aro
Filter the <step1> from <input> where x > 10.
Filter the <step2> from <step1> where y < 5.
Reduce the <result> from <step2> with sum(z).
(* ARO detects: input → step1 → step2 → result *)
```

### Q: How can I debug a pipeline?

**A:** Because each stage has a named variable, you can inspect intermediate values:

```aro
Filter the <step1> from <input> where x > 10.
Log <step1> to the <console>.  (* Debug: see step1 data *)

Filter the <step2> from <step1> where y < 5.
Log <step2> to the <console>.  (* Debug: see step2 data *)
```

---

## References

- **Proposal**: `Proposals/ARO-0067-automatic-pipeline-detection.md`
- **Book Updates**:
  - `Book/TheLanguageGuide/Chapter29-DataPipelines.md` (new section on automatic detection)
  - `Book/TheLanguageGuide/Chapter40-StreamingExecution.md` (references ARO-0067)
- **Examples**:
  - `Examples/DataPipeline/` - Filter, Map, Reduce chains
  - `Examples/StreamingPipeline/` - Multi-stage filter pipeline
  - `Examples/ConstantFolding/` - Compile-time optimization
  - `Examples/EventReplay/` - Event recording/replay

---

## Implementation Status

✅ ARO-0067 proposal written
✅ Automatic pipeline detection implemented
✅ Book chapters updated
✅ Issue #105 closed with explanation
✅ MR !132 description updated
⏳ Wiki updates pending (external wiki - manual update required)

---

## Migration Notes

**No breaking changes.** All existing ARO code continues to work unchanged. Pipeline detection is a transparent runtime optimization.

Users who were waiting for pipeline operators can use the existing syntax - it already has automatic pipeline detection!

---

## Communication Points

When announcing this feature:

1. **Emphasize simplicity**: "No new syntax to learn"
2. **Highlight debugging**: "Named intermediate values make debugging easy"
3. **Show performance**: "Automatic streaming optimizations"
4. **Compare favorably**: "Better than explicit `|>` operators"

**Example announcement**:

> ARO now features automatic pipeline detection! Write natural-language code, get optimized pipelines automatically. No new syntax, better debugging, automatic streaming. See ARO-0067 for details.
