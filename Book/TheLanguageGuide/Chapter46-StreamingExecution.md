# Chapter 46: Streaming Execution

ARO's streaming execution engine enables processing of arbitrarily large datasets with constant memory usage. Inspired by Apache Spark's lazy evaluation model, ARO automatically optimizes data pipelines to process data incrementally rather than loading entire files into memory.

Combined with **automatic pipeline detection** (ARO-0067), ARO transparently recognizes data flow chains and applies streaming optimizations without requiring explicit pipeline operators or syntax changes. The same natural-language code that works for small datasets automatically streams for large datasets.

## The Problem with Eager Loading

<div style="text-align: center; margin: 2em 0;">
<svg width="460" height="200" viewBox="0 0 460 200" xmlns="http://www.w3.org/2000/svg" font-family="sans-serif">
  <!-- Memory axis -->
  <line x1="30" y1="10" x2="30" y2="170" stroke="#374151" stroke-width="1.5"/>
  <polygon points="30 8, 26 18, 34 18" fill="#374151"/>
  <text x="28" y="185" text-anchor="middle" font-size="9" fill="#374151">Memory</text>

  <!-- Eager column -->
  <text x="150" y="16" text-anchor="middle" font-size="11" font-weight="bold" fill="#991b1b">Eager (O(n))</text>
  <!-- Big red block representing all data in memory -->
  <rect x="70" y="30" width="160" height="130" rx="4" fill="#fee2e2" stroke="#ef4444" stroke-width="2"/>
  <text x="150" y="80" text-anchor="middle" font-size="10" fill="#991b1b">All 1M items</text>
  <text x="150" y="96" text-anchor="middle" font-size="10" fill="#991b1b">loaded into memory</text>
  <text x="150" y="118" text-anchor="middle" font-size="10" fill="#991b1b">before processing</text>
  <!-- O(n) label on axis -->
  <line x1="30" y1="30" x2="70" y2="30" stroke="#ef4444" stroke-width="1" stroke-dasharray="3,2"/>
  <text x="15" y="34" text-anchor="middle" font-size="9" fill="#991b1b">O(n)</text>

  <!-- Divider -->
  <line x1="245" y1="10" x2="245" y2="180" stroke="#d1d5db" stroke-width="1" stroke-dasharray="4,2"/>

  <!-- Streaming column -->
  <text x="360" y="16" text-anchor="middle" font-size="11" font-weight="bold" fill="#166534">Streaming (O(1))</text>
  <!-- Small green block representing current chunk only -->
  <rect x="280" y="130" width="160" height="30" rx="4" fill="#d1fae5" stroke="#22c55e" stroke-width="2"/>
  <text x="360" y="150" text-anchor="middle" font-size="10" fill="#166534">current chunk only</text>
  <!-- O(1) label on axis -->
  <line x1="30" y1="145" x2="280" y2="145" stroke="#22c55e" stroke-width="1" stroke-dasharray="3,2"/>
  <text x="15" y="149" text-anchor="middle" font-size="9" fill="#166534">O(1)</text>

  <!-- Sliding window annotation -->
  <text x="360" y="118" text-anchor="middle" font-size="9" fill="#166534">sliding window</text>
  <line x1="360" y1="121" x2="360" y2="128" stroke="#22c55e" stroke-width="1" stroke-dasharray="2,2"/>
</svg>
</div>

Consider this simple pipeline processing a 10GB CSV file:

```aro
Read the <data> from the <file: "transactions.csv">.
Filter the <high-value> from the <data> where <amount> > 1000.
Reduce the <total> from the <high-value> with sum(<amount>).
Log <total> to the <console>.
```

**Without streaming:** The runtime loads the entire 10GB file into memory, parses it into ~15-20GB of dictionaries, then filters and reduces. This causes out-of-memory crashes on most systems.

**With streaming:** The runtime processes the file in 64KB chunks, parsing and filtering each row as it arrives. Only matching rows accumulate, and the total is computed incrementally. Memory usage stays under 1MB regardless of file size.

---

## How Streaming Works

ARO's streaming engine classifies operations into three categories:

### Transformations (Streamable)

Operations that process one element at a time without needing the full collection:

| Operation | Streaming Behavior |
|-----------|-------------------|
| `Filter` | Pass/reject each element immediately |
| `Map` | Transform each element immediately |
| `Transform` | Process each element immediately |
| `Parse` | Parse each chunk as it arrives |

### Drains (Trigger Execution)

Operations that consume the stream and produce a final result:

| Operation | Behavior |
|-----------|----------|
| `Log` | Prints each element as it arrives |
| `Return` | Collects results for response |
| `Store` | Writes each element to repository |
| `Send` | Transmits each element over network |
| `Reduce` | Aggregates incrementally (O(1) memory) |

### Barriers (Require Full Data)

Operations that inherently need the full dataset:

| Operation | Reason |
|-----------|--------|
| `Sort` | Must see all elements to order them |
| `GroupBy` | Must collect all elements per group |
| `Distinct` | Must track all seen elements |

Barrier operations use **spill-to-disk** strategies for datasets larger than memory.

---

## Streaming by Default

ARO streams data **by default**. No syntax changes are required:

```aro
(* This automatically streams - same syntax as always *)
Read the <data> from the <file: "huge.csv">.
Filter the <filtered> from <data> where <status> = "active".
Log <filtered> to the <console>.
```

The runtime automatically:
1. Reads the file in 64KB chunks
2. Parses CSV rows incrementally
3. Filters each row as it's parsed
4. Logs matching rows immediately
5. Discards non-matching rows without storing them

---

## Explicit Mode Control

For cases where you need explicit control, use qualifiers:

```aro
(* Force streaming (default behavior) *)
<Read: streaming> the <data> from the <file: "huge.csv">.

(* Force eager loading (loads entire file into memory) *)
<Read: eager> the <data> from the <file: "small.csv">.
```

| Qualifier | Memory | Use Case |
|-----------|--------|----------|
| `streaming` (default) | O(1) constant | Large files, pipelines |
| `eager` | O(n) full file | Small files, random access |

---

## Multi-Stage Pipelines

Streaming shines with chained operations. Each stage processes data as it flows through:

```aro
(Process Transactions: Analytics) {
    (* Stage 1: Read CSV file incrementally *)
    Read the <transactions> from the <file: "transactions.csv">.

    (* Stage 2: Filter by date range *)
    Filter the <recent> from <transactions>
        where <date> >= "2024-01-01".

    (* Stage 3: Filter by amount *)
    Filter the <significant> from <recent>
        where <amount> > 100.

    (* Stage 4: Filter by status *)
    Filter the <completed> from <significant>
        where <status> = "completed".

    (* Stage 5: Aggregate - triggers pipeline execution *)
    Reduce the <total> from <completed>
        with sum(<amount>).

    Log "Total completed transactions: " to the <console>.
    Log <total> to the <console>.

    Return an <OK: status> with { total: <total> }.
}
```

**Execution flow:**

```
File → [64KB chunk] → Parse Row → Filter(date) → Filter(amount) → Filter(status) → Accumulate
      → [64KB chunk] → Parse Row → Filter(date) → REJECT
      → [64KB chunk] → Parse Row → Filter(date) → Filter(amount) → REJECT
      → ...continues until EOF...
                                                                   → Return total
```

Each row flows through all filter stages immediately. Rejected rows are discarded without accumulation. Only the running sum is kept in memory.

---

## Multi-Consumer Scenarios

When a variable is used by multiple operations, ARO uses **stream teeing**:

```aro
(Order Analytics: Report Generator) {
    Read the <orders> from the <file: "orders.csv">.

    (* Filter to active orders - consumed by 3 operations *)
    Filter the <active> from <orders> where <status> = "active".

    (* Consumer 1: Calculate total *)
    Reduce the <total> from <active> with sum(<amount>).

    (* Consumer 2: Count orders *)
    Reduce the <count> from <active> with count().

    (* Consumer 3: Find average *)
    Reduce the <average> from <active> with avg(<amount>).

    Return an <OK: status> with {
        total: <total>,
        count: <count>,
        average: <average>
    }.
}
```

### How Stream Teeing Works

Instead of materializing `<active>` into memory, ARO creates a **stream tee** with a bounded buffer:

```
active-stream → StreamTee → Consumer 1 (sum)
                          → Consumer 2 (count)
                          → Consumer 3 (avg)
```

The tee uses a ring buffer that holds elements between the fastest and slowest consumer. Once all consumers have processed an element, it's discarded.

### Aggregation Fusion

For multiple `Reduce` operations on the same source, ARO can **fuse** them into a single pass:

```aro
(* User writes: *)
Reduce the <total> from <orders> with sum(<amount>).
Reduce the <count> from <orders> with count().
Reduce the <avg> from <orders> with avg(<amount>).

(* ARO executes as single pass: *)
(* sum=0, count=0 *)
(* for each row: sum += amount, count += 1 *)
(* avg = sum / count *)
```

This keeps memory at O(1) regardless of collection size.

---

## The `Stream` Action: Explicit File Streaming

The automatic streaming described above applies to `Read` + pipeline operations. For cases where you want to make the lazy semantics explicit at the call site — or where you are iterating a plain-text file line by line and do not need format detection — ARO provides the `Stream` action.

### Syntax

```aro
Stream the <result> from <file-path>.
```

`Stream` opens the file and yields one raw line at a time directly to your `for each` loop. No `Split` step is needed.

### Read + Split vs Stream

| | `Read` + `Split` | `Stream` |
|---|---|---|
| Peak memory | O(file size) × 3 | O(1) |
| Format detection | ✅ JSON / CSV / YAML / JSONL | ❌ Raw lines only |
| Count lines before iterating | ✅ `Compute the <n: count>` | ❌ Materialises stream |
| Best for | Structured formats, small/medium files | Large plain-text files, log files, data files |

The three-times multiplier for `Read` + `Split` occurs because three copies of the data live in memory simultaneously:

1. The raw file content (`String` from `Read`)
2. The split array (`[String]` from `Split`)
3. The boxed iteration copy (`[any Sendable]` inside `for each`)

`Stream` keeps only the current line in memory at any point.

### Example

```aro
(Application-Start: Sum Numbers) {
    (* Stream opens the file lazily — no full-file load.
       The 1 GB file uses ~10 MB peak memory instead of ~15 GB. *)
    Stream the <lines> from "./numbers.dat".

    Create the <init> with { sum: 0.0, count: 0 }.
    Store the <seeded: init> into <acc>.
    Extract the <acc-id> from the <seeded: id>.

    for each <raw-line> in <lines> {
        Transform the <num: float> from the <raw-line>.

        Retrieve the <cur>       from the <acc> where <id> = <acc-id>.
        Extract the <prev-sum>   from the <cur: sum>.
        Extract the <prev-count> from the <cur: count>.

        Compute the <new-sum>   from <prev-sum>   + <num>.
        Compute the <new-count> from <prev-count> + 1.

        Create the <upd> with { id: <acc-id>, sum: <new-sum>, count: <new-count> }.
        Update the <upd> into <acc>.
    }

    Retrieve the <result>     from the <acc> where <id> = <acc-id>.
    Extract the <total-sum>   from the <result: sum>.
    Extract the <total-count> from the <result: count>.
    Compute the <avg>         from <total-sum> / <total-count>.

    Log "Processed:" to the <console>.
    Log <total-count> to the <console>.
    Log "Sum:"     to the <console>.
    Log <total-sum> to the <console>.
    Log "Average:" to the <console>.
    Log <avg> to the <console>.

    Return an <OK: status> for the <sumup>.
}
```

### Why `count` Does Not Work on Streams

Counting a stream requires reading every element — that defeats the purpose of streaming:

```aro
Stream the <lines> from "./bigfile.dat".

(* ✗ Runtime error: "Cannot count a stream — streams must be consumed
      with 'for each'. Remove this count statement, or replace 'Stream'
      with 'Read' if you need the total count." *)
Compute the <n: count> from <lines>.
```

If you need the line count before iterating, use `Read` instead (which loads the file eagerly):

```aro
Read the <raw> from "./bigfile.dat".
Split the <lines> from <raw> by /\n/.
Compute the <n: count> from <lines>.    (* ✓ works — full file is in memory *)
for each <line> in <lines> { ... }
```

### SSE and WebSocket Streaming

`Stream` also handles HTTP streaming sources. When the source starts with `http://`, `https://`, `ws://`, or `wss://`, it opens a persistent Server-Sent Events or WebSocket connection and emits domain events for each message (see **Chapter 45: WebSockets**):

```aro
(* File streaming — lazy line-by-line, iterated with for each *)
Stream the <lines> from "./access.log".

(* SSE streaming — emits domain events for incoming server messages *)
Stream the <price-update> from "https://api.example.com/prices/stream".
Keepalive the <application> for the <events>.
```

Both uses share the same verb; the runtime distinguishes them by the source prefix.

### How It Fits Into the Runtime

Internally, `Stream` (file mode) creates an `AROStream<String>` backed by `URL.lines` (64 KB kernel reads) and binds it lazily via `RuntimeContext.bindLazy`. The `for each` loop detects the lazy binding and iterates the stream directly — no array is ever allocated. `Task.yield()` is called every 500 iterations so Swift's cooperative scheduler can dispatch other pending tasks, keeping all CPU cores available.

---

## Choosing the Right Format for Streaming

Different file formats have dramatically different streaming characteristics. Choosing the right format can mean the difference between O(1) and O(n) memory usage.

### Format Comparison

| Feature | CSV | JSON Array | JSONL | XML |
|---------|-----|------------|-------|-----|
| **True streaming** | ⚠️ Header needed | ❌ Must parse full array | ✅ Line = record | ⚠️ SAX required |
| **Self-describing** | ❌ Types ambiguous | ✅ | ✅ | ✅ |
| **Memory efficient** | ✅ | ❌ | ✅ | ⚠️ |
| **Error recovery** | ⚠️ Skip line | ❌ Corrupts parse | ✅ Skip bad line | ❌ |
| **Human readable** | ✅ | ✅ | ✅ | ⚠️ |
| **Nested data** | ❌ | ✅ | ✅ | ✅ |

### JSONL: The Ideal Streaming Format

**JSON Lines (JSONL)** is the recommended format for streaming workloads. Each line is a complete, independent JSON object:

```jsonl
{"id": 1, "name": "Alice", "amount": 100, "status": "active"}
{"id": 2, "name": "Bob", "amount": 200, "status": "pending"}
{"id": 3, "name": "Charlie", "amount": 150, "status": "active"}
```

**Why JSONL excels for streaming:**

1. **Line = Record**: Each line is independently parseable
2. **No global state**: No header row, no array boundaries
3. **Error isolation**: A corrupted line doesn't break the entire file
4. **Append-friendly**: Add new records by appending lines
5. **Self-describing**: Each record contains its own field names

### Streaming JSONL in ARO

```aro
(Process Events: Log Processor) {
    (* Read JSONL file - automatically streams line by line *)
    Read the <events> from the <file: "events.jsonl">.

    (* Filter errors - each line processed independently *)
    Filter the <errors> from <events>
        where <level> = "error".

    (* Filter by service *)
    Filter the <api-errors> from <errors>
        where <service> = "api".

    (* Aggregate - O(1) memory regardless of file size *)
    Reduce the <error-count> from <api-errors>
        with count().

    Log "API errors found: " to the <console>.
    Log <error-count> to the <console>.

    Return an <OK: status> for the <processing>.
}
```

### JSONL vs JSON Array

**JSON Array** (not recommended for large data):
```json
[
  {"id": 1, "name": "Alice"},
  {"id": 2, "name": "Bob"},
  {"id": 3, "name": "Charlie"}
]
```

The parser must find the closing `]` before knowing the array is complete. This prevents true streaming.

**JSONL** (recommended):
```jsonl
{"id": 1, "name": "Alice"}
{"id": 2, "name": "Bob"}
{"id": 3, "name": "Charlie"}
```

Each line can be parsed and processed immediately upon reading.

### Best Practices for Format Selection

| Use Case | Recommended Format | Reason |
|----------|-------------------|--------|
| Log files | JSONL | Append-only, error recovery |
| Event streams | JSONL | Real-time processing |
| ETL pipelines | JSONL or CSV | Line-by-line streaming |
| API exports | JSONL | Incremental processing |
| Configuration | JSON/YAML | Small, needs random access |
| Tabular data | CSV | Universal compatibility |
| Documents | JSON | Nested structure |

### Converting to JSONL

If you have JSON arrays, convert them to JSONL for better streaming:

**Before (events.json):**
```json
[
  {"timestamp": "2024-01-01", "event": "login"},
  {"timestamp": "2024-01-02", "event": "purchase"}
]
```

**After (events.jsonl):**
```jsonl
{"timestamp": "2024-01-01", "event": "login"}
{"timestamp": "2024-01-02", "event": "purchase"}
```

### Error Recovery with JSONL

One of JSONL's key advantages is error isolation:

```jsonl
{"id": 1, "valid": true}
{"id": 2, "broken json here
{"id": 3, "valid": true}
```

With JSONL streaming, ARO can:
1. Process record 1 successfully
2. Log warning for malformed record 2
3. Continue processing record 3

With JSON arrays, a single malformed record corrupts the entire parse.

---

## Memory Characteristics

| Operation | Memory Usage |
|-----------|--------------|
| Read (streaming) | O(chunk size) ~64KB |
| Filter | O(1) per element |
| Map | O(1) per element |
| Reduce (sum/count/avg) | O(1) accumulators |
| Reduce (first/last) | O(1) single element |
| Stream Tee | O(buffer size) bounded |
| Sort | O(n) or spill to disk |

---

## Streaming Heuristics

ARO automatically decides whether to stream based on data size:

| Source | Threshold | Default Mode |
|--------|-----------|--------------|
| File | < 10MB | Eager |
| File | >= 10MB | Streaming |
| In-memory collection | < 10,000 elements | Eager |
| In-memory collection | >= 10,000 elements | Streaming |

When an in-memory collection exceeds the element threshold, `Filter` and `Map` return lazy streams instead of materialised arrays. Downstream operations (`Filter`, `Map`, `Reduce`, `for each`) chain onto the stream without allocating intermediate arrays, giving O(1) memory per pipeline stage. Terminal actions (`Log`, `Return`) materialise the stream on demand. `Reduce` naturally produces a scalar with O(1) accumulators regardless of collection size.

You can override this with explicit qualifiers when needed.

---

## Complete Example: Log Analysis

This example demonstrates a multi-stage streaming pipeline for analyzing server logs:

### logs.csv

```csv
timestamp,level,service,message,response_time
2024-01-15T10:00:00Z,INFO,api,Request received,45
2024-01-15T10:00:01Z,ERROR,api,Database timeout,5000
2024-01-15T10:00:02Z,WARN,auth,Rate limit exceeded,120
2024-01-15T10:00:03Z,INFO,api,Request completed,89
2024-01-15T10:00:04Z,ERROR,auth,Authentication failed,15
```

### main.aro

```aro
(Application-Start: Log Analyzer) {
    Log "Starting log analysis..." to the <console>.

    (* Stage 1: Read logs incrementally *)
    Read the <logs> from the <file: "logs.csv">.

    (* Stage 2: Filter to errors only *)
    Filter the <errors> from <logs>
        where <level> = "ERROR".

    (* Stage 3: Filter to API service *)
    Filter the <api-errors> from <errors>
        where <service> = "api".

    (* Stage 4: Filter slow responses *)
    Filter the <slow-errors> from <api-errors>
        where <response-time> > 1000.

    (* Stage 5: Count critical issues *)
    Reduce the <critical-count> from <slow-errors>
        with count().

    (* Stage 6: Average response time of errors *)
    Reduce the <avg-response> from <api-errors>
        with avg(<response-time>).

    Log "Analysis complete:" to the <console>.
    Log "  Critical issues: " to the <console>.
    Log <critical-count> to the <console>.
    Log "  Avg error response time: " to the <console>.
    Log <avg-response> to the <console>.

    Return an <OK: status> for the <analysis>.
}
```

### Execution

```bash
$ aro run .
Starting log analysis...
Analysis complete:
  Critical issues:
1
  Avg error response time:
2507.5
```

Even with a 10GB log file, this pipeline uses constant memory because:
- Logs are read in chunks
- Non-error logs are immediately discarded
- Non-API errors are immediately discarded
- Only aggregation counters are kept

---

## Performance Comparison

| Metric | Eager Loading | Streaming |
|--------|---------------|-----------|
| 10GB CSV Peak Memory | 20 GB | ~1 MB |
| Time to First Result | 45 seconds | 10 milliseconds |
| Total Processing Time | 60 seconds | 40 seconds |
| Works on 8GB Laptop | No | Yes |

---

## Design Philosophy

ARO's streaming execution follows these principles:

1. **Transparent**: Same syntax, automatic optimization
2. **Memory-Bounded**: O(1) memory for transformations
3. **Lazy Evaluation**: Build pipeline, execute on drain
4. **Spill-to-Disk**: Handle datasets larger than memory
5. **Aggregation Fusion**: Single-pass multi-aggregation

For datasets that truly need random access or multiple iterations, use the `eager` qualifier explicitly.

---

## Pipeline Detection

The streaming engine works seamlessly with ARO's automatic pipeline detection (ARO-0067). When you write chained operations using immutable variables, ARO automatically:

1. **Detects the data flow graph** through variable dependencies
2. **Builds a lazy pipeline** that defers execution until a drain operation
3. **Applies streaming optimizations** transparently
4. **Fuses multiple aggregations** into single-pass operations

This means the same code works for both small and large datasets without modification:

```aro
(* This code works identically for 1KB or 10GB files *)
Read the <data> from the <file: "data.csv">.
Filter the <active> from <data> where <status> = "active".
Reduce the <total> from <active> with sum(<amount>).
```

For small files (< 10MB), ARO may use eager loading for better performance. For large files, it automatically streams with O(1) memory usage.

See **Chapter 34: Data Pipelines** for more details on automatic pipeline detection and composition patterns.

---

## Related Proposals

- **ARO-0051**: Streaming Execution Engine (this chapter)
- **ARO-0067**: Automatic Pipeline Detection
- **ARO-0018**: Data Pipeline Operations

---

*Next: Appendix A — Action Reference*
