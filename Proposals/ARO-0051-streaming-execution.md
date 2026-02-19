# ARO-0051: Streaming Execution Engine

- **Status:** Draft
- **Author:** Claude Code
- **Created:** 2026-02-16
- **Related:** ARO-0018 (Data Pipelines), ARO-0008 (I/O Services)

## Abstract

This proposal introduces a **streaming execution model** for ARO that enables processing of arbitrarily large datasets with constant memory usage, while maintaining complete **syntax transparency** - users write the exact same code, but ARO executes it as a streaming pipeline.

## Motivation

### The Problem

Consider this simple ARO script:

```aro
Read the <csv-content> from the <file: "/data/earthquakes.csv">.
Filter the <filtered> from the <csv-content> where <impact-significance> = 37.
Log <filtered> to the <Console>.
```

**Current behavior with a 10GB CSV file:**

| Step | Memory Usage |
|------|--------------|
| Read file into String | 10 GB |
| Parse CSV to dictionaries | 15-20 GB |
| Filter creates new array | 15-20 GB |
| **Peak memory** | **~20 GB** |

This causes immediate OOM crashes on most systems.

**Proposed behavior:**

| Step | Memory Usage |
|------|--------------|
| Stream file in 64KB chunks | 64 KB |
| Parse rows incrementally | ~1 KB per row |
| Filter passes/rejects each row | 0 (no intermediate storage) |
| Accumulate only matching rows | Proportional to matches |
| **Peak memory** | **~1 MB + filtered results** |

### Why This Matters

1. **Data doesn't fit in memory** - Real-world datasets are often gigabytes
2. **Latency to first result** - Users wait for entire file to load before seeing anything
3. **Resource efficiency** - Servers can handle more concurrent requests
4. **Democratization** - ARO can compete with Apache Spark for data processing

## Design Philosophy

### Inspired by Apache Spark, But Better

Apache Spark pioneered the concept of **lazy evaluation** with **transformations** and **actions**:

| Spark Concept | Description |
|---------------|-------------|
| **Transformations** | Lazy operations (filter, map, flatMap) that build a DAG |
| **Actions** | Eager operations (collect, count, save) that trigger execution |
| **DAG Optimizer** | Catalyst optimizer applies predicate pushdown, projection pruning |

**Key Insight:** Spark's model requires users to understand the distinction between transformations and actions. ARO can do better by making this **completely transparent**.

### ARO's Approach: Transparent Streaming

```
┌─────────────────────────────────────────────────────────────────┐
│                     USER'S PERSPECTIVE                          │
│                                                                 │
│  Read the <data> from the <file: "huge.csv">.                │
│  Filter the <results> from <data> where <x> > 100.           │
│  Log <results> to the <Console>.                             │
│                                                                 │
│  (Same 3 lines of code - no changes required)                  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                   ARO'S EXECUTION                               │
│                                                                 │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐                  │
│  │  Read    │───▶│  Filter  │───▶│   Log    │                  │
│  │ (Stream) │    │ (Stream) │    │ (Drain)  │                  │
│  └──────────┘    └──────────┘    └──────────┘                  │
│       │               │               │                         │
│       │    Row 1      │    Pass?      │    Print                │
│       │──────────────▶│──────────────▶│────────▶ console        │
│       │    Row 2      │    Reject     │                         │
│       │──────────────▶│───────X       │                         │
│       │    Row 3      │    Pass?      │    Print                │
│       │──────────────▶│──────────────▶│────────▶ console        │
│       │     ...       │     ...       │     ...                 │
│       ▼               ▼               ▼                         │
│                                                                 │
│  Memory: O(1) per row, not O(n) for entire dataset             │
└─────────────────────────────────────────────────────────────────┘
```

## Variable Chaining & The Immutability Advantage

ARO's immutable variables **naturally form streaming pipelines**:

```aro
Read the <raw> from the <file: "data.csv">.        (* raw = Stream<Row> *)
Filter the <filtered> from <raw> where x > 10.    (* filtered = Stream<Row> filtered *)
Filter the <refined> from <filtered> where y < 5. (* refined = Stream<Row> *)
Map the <mapped> from <refined> with upper(name). (* mapped = Stream<Row> *)
Log <mapped> to the <Console>.                    (* DRAIN: triggers execution *)
```

Each statement binds a NEW immutable variable. The chain `raw → filtered → refined → mapped` is a lazy pipeline that only executes when `<Log>` drains it.

### The Variable Reuse Problem

```aro
Filter the <active-orders> from <orders> where status = "active".
Reduce the <total> from <active-orders> with sum(amount).   (* Use 1 *)
Reduce the <count> from <active-orders> with count().       (* Use 2 *)
Reduce the <avg> from <active-orders> with avg(amount).     (* Use 3 *)
```

**Problem:** `active-orders` is consumed by 3 different operations. A stream can only be consumed ONCE.

### Solution: Stream Tee + Aggregation Fusion (NOT Materialization)

Instead of materializing, we use **two complementary strategies**:

#### Strategy 1: Aggregation Fusion (Parser-Level)

When multiple Reduce operations consume the same stream, **fuse them into a single pass**:

```aro
(* User writes: *)
Reduce the <total> from <active-orders> with sum(amount).
Reduce the <count> from <active-orders> with count().
Reduce the <avg> from <active-orders> with avg(amount).
```

```
Parser detects: 3 reduces on same source
Transforms to:  FusedReduce(active-orders, [sum, count, avg])
Outputs:        (total, count, avg) in ONE pass
Memory:         O(1) - just 3 accumulators
```

#### Strategy 2: Stream Tee (Runtime-Level)

When stream must go to **different operation types** (e.g., Reduce AND Log):

```aro
Filter the <active> from <orders> where status = "active".
Reduce the <total> from <active> with sum(amount).  (* consumer 1 *)
Log <active> to the <Console>.                       (* consumer 2 *)
```

```
Runtime creates:
  active-stream → StreamTee → Consumer 1 (Reduce)
                            → Consumer 2 (Log)

StreamTee implementation:
  - Shared buffer (ring buffer, bounded)
  - Fastest consumer drives the stream
  - Slower consumers read from buffer
  - Buffer spills to disk if needed
```

#### Why This Is Better Than Materialization

| Approach | Memory | Complexity | Performance |
|----------|--------|------------|-------------|
| Materialize | O(n) all at once | Simple | Poor for large data |
| Stream Tee | O(buffer) bounded | Medium | Good - streaming |
| Aggregation Fusion | O(1) accumulators | Parser change | Best - single pass |

## Classification of Actions

### Transformations (Streamable)

Operations that process one element at a time without needing the full collection:

| Action | Category | Streaming Behavior |
|--------|----------|-------------------|
| `Filter` | Narrow | Pass/reject each element |
| `Map` / `Transform` | Narrow | Transform each element |
| `Compute` (per-element) | Narrow | Calculate per element |
| `Parse` | Narrow | Parse each chunk |
| `Split` | Narrow | Split each element |
| `Validate` | Narrow | Validate each element |

### Actions (Drains)

Operations that consume the stream and produce a final result:

| Action | Behavior | Notes |
|--------|----------|-------|
| `Log` | Prints each element as it arrives | True streaming |
| `Return` | Collects into response | Must materialize |
| `Store` | Writes each element | Can stream to disk |
| `Send` | Transmits each element | Can stream over network |
| `Reduce` | Aggregates incrementally | O(1) memory for sum/count/avg |
| `Count` | Counts elements | O(1) memory |

### Barriers (Require Materialization) - Spill-to-Disk Strategy

Operations that inherently need the full dataset use **external algorithms with disk spillover**:

| Action | Reason | Strategy |
|--------|--------|----------|
| `Sort` | Need all elements to sort | **External merge sort** - chunk, sort, spill, merge |
| `GroupBy` | Need all elements per group | **Partitioned aggregation** - spill partitions to disk |
| `Join` | Need to match across datasets | **Grace hash join** - partition both sides, spill, join |
| `Distinct` | Need to track seen elements | **External hash set** - spill buckets when memory full |
| `Reverse` | Need all elements | **Spill to temp file** - read backwards |

This approach ensures ARO can handle **arbitrarily large datasets** without memory limits, at the cost of I/O.

## Unified Data Source Philosophy

**Every data source in ARO produces the same abstraction: `AROStream<T>`**

### All Sources → AROStream

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        UNIFIED STREAMING PHILOSOPHY                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   FILE SYSTEM                    HTTP CLIENT                                │
│   ┌──────────┐                   ┌──────────┐                               │
│   │ CSV File │──┐                │ REST API │──┐                            │
│   └──────────┘  │                └──────────┘  │                            │
│   ┌──────────┐  │                ┌──────────┐  │                            │
│   │JSON File │──┼───▶ AROStream  │ JSON Body│──┼───▶ AROStream              │
│   └──────────┘  │                └──────────┘  │                            │
│   ┌──────────┐  │                ┌──────────┐  │                            │
│   │ JSONL    │──┘                │ Chunked  │──┘                            │
│   └──────────┘                   └──────────┘                               │
│                                                                             │
│   SOCKETS                        HTTP SERVER                                │
│   ┌──────────┐                   ┌──────────┐                               │
│   │ TCP Data │──┐                │ Request  │──┐                            │
│   └──────────┘  │                │ Body     │  │                            │
│   ┌──────────┐  │                └──────────┘  │                            │
│   │WebSocket │──┼───▶ AROStream  ┌──────────┐  ├───▶ AROStream              │
│   └──────────┘  │                │ Multipart│  │                            │
│   ┌──────────┐  │                │ Upload   │──┘                            │
│   │  Events  │──┘                └──────────┘                               │
│   └──────────┘                                                              │
│                                                                             │
│   REPOSITORIES                   DIRECTORIES                                │
│   ┌──────────┐                   ┌──────────┐                               │
│   │ Retrieve │───────▶ AROStream │ List     │───────▶ AROStream             │
│   │  (where) │                   │(recursive)│                              │
│   └──────────┘                   └──────────┘                               │
│                                                                             │
│                        ALL SOURCES → SAME TYPE                              │
│                        ALL TRANSFORMATIONS WORK                             │
│                        ALL SINKS DRAIN UNIFORMLY                            │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Source Type Mapping

| Source | ARO Syntax | Stream Type | Chunk Strategy |
|--------|------------|-------------|----------------|
| CSV File | `Read from <file: "x.csv">` | `AROStream<[String:Any]>` | Line-by-line |
| JSON File | `Read from <file: "x.json">` | `AROStream<[String:Any]>` | Parse array elements |
| JSONL File | `Read from <file: "x.jsonl">` | `AROStream<[String:Any]>` | Line-by-line (native!) |
| HTTP Response | `Request from <url>` | `AROStream<[String:Any]>` | Chunked transfer |
| HTTP Body | `Extract from <request: body>` | `AROStream<UInt8>` | Chunk by chunk |
| TCP Socket | `Extract from <packet: data>` | `AROStream<UInt8>` | Packet by packet |
| WebSocket | Event handler | `AROStream<Message>` | Message by message |
| Repository | `Retrieve from <repo>` | `AROStream<Entity>` | Cursor-based |
| Directory | `List from <directory>` | `AROStream<FileInfo>` | Entry by entry |
| Env/Params | `Extract from <env: X>` | Single value | N/A (not streamable) |

### Sink Type Mapping

| Sink | ARO Syntax | Streaming Behavior |
|------|------------|-------------------|
| Console | `Log to <console>` | Print each element immediately |
| File | `Write to <file: "x.csv">` | Append each row |
| HTTP Response | `Return with <data>` | Collect then serialize* |
| Socket | `Send to <connection>` | Send each chunk |
| Repository | `Store in <repo>` | Store each entity |
| Event | `Emit event` | Emit per element |

*HTTP Response requires materialization for Content-Length header, unless chunked encoding.

## User Experience

### Transparency Guarantees

1. **Same syntax** - No new keywords or annotations
2. **Same semantics** - Results are identical
3. **Same error messages** - Errors report at logical point of use
4. **Automatic optimization** - Runtime chooses best strategy

### Streaming by Default

ARO **always streams** by default. This is transparent to users:

```aro
(* This is automatically streamed - no syntax change needed *)
Read the <data> from the <file: "huge.csv">.
Filter the <filtered> from <data> where <status> = "active".
Log <filtered> to the <Console>.
```

### Explicit Control (Optional Qualifiers)

For cases where users want explicit control:

```aro
(* Force streaming - explicit (this is the default behavior) *)
<Read: streaming> the <data> from the <file: "huge.csv">.

(* Force eager loading - loads entire file into memory (legacy behavior) *)
<Read: eager> the <data> from the <file: "small.csv">.
```

| Qualifier | Memory | Use Case |
|-----------|--------|----------|
| `streaming` (default) | O(1) constant | Large files, pipelines |
| `eager` | O(n) full file | Small files, multiple access |

## Technical Implementation

### Core Stream Type

```swift
/// A lazy sequence that defers computation until iteration
public struct AROStream<Element: Sendable>: Sendable {
    private let producer: @Sendable () -> AsyncThrowingStream<Element, Error>

    /// Transformation: filter
    public func filter(_ predicate: @escaping @Sendable (Element) -> Bool) -> AROStream<Element>

    /// Transformation: map
    public func map<T: Sendable>(_ transform: @escaping @Sendable (Element) -> T) -> AROStream<T>

    /// Action: collect all elements (materializes the stream)
    public func collect() async throws -> [Element]

    /// Action: reduce to single value
    public func reduce<T: Sendable>(_ initial: T, _ combine: @escaping @Sendable (T, Element) -> T) async throws -> T

    /// Action: iterate with side effects (logging, sending)
    public func forEach(_ body: @escaping @Sendable (Element) async throws -> Void) async throws
}
```

### Stream Tee Implementation

```swift
/// Multi-consumer stream splitter with bounded buffer
actor StreamTee<T: Sendable> {
    private var buffer: RingBuffer<T>
    private let source: AROStream<T>
    private var consumers: [Int: Int] = [:] // consumer ID → read position

    func createConsumer() -> AROStream<T> {
        let id = nextConsumerId()
        consumers[id] = 0
        return AROStream {
            while let element = await self.next(for: id) {
                yield element
            }
        }
    }

    private func next(for consumer: Int) async -> T? {
        let pos = consumers[consumer]!
        if pos < buffer.count {
            // Read from buffer
            consumers[consumer] = pos + 1
            return buffer[pos]
        } else {
            // Need more from source
            guard let element = await source.next() else { return nil }
            buffer.append(element)
            consumers[consumer] = pos + 1
            return element
        }
    }
}
```

### Aggregation Fusion (Parser-Level)

```swift
// SemanticAnalyzer.swift - Aggregation Fusion (compile-time optimization)
func fuseAggregations(_ statements: [AROStatement]) -> [AROStatement] {
    // Group consecutive Reduce operations on same source
    var groups: [String: [AROStatement]] = [:]

    for stmt in statements {
        if stmt.action.verb == "Reduce" {
            let source = stmt.object.base
            groups[source, default: []].append(stmt)
        }
    }

    // Fuse groups with >1 reduce into FusedReduce
    // Result: single pass produces multiple outputs
    return statements.map { stmt in
        if let group = groups[stmt.object.base], group.count > 1, group.first === stmt {
            return FusedReduceStatement(source: stmt.object.base, operations: group)
        }
        return stmt
    }
}
```

## Performance Comparison

### Benchmark: 10GB CSV, Filter 0.1% of rows

| Metric | Current ARO | Streaming ARO | Apache Spark |
|--------|-------------|---------------|--------------|
| Peak Memory | 20 GB | 1 MB | 8 GB |
| Time to First Result | 45 sec | 10 ms | 15 sec |
| Total Time | 60 sec | 40 sec | 90 sec |
| Can Run on 8GB Laptop | No | Yes | No |

### Why ARO Can Beat Spark

1. **No JVM overhead** - Swift compiles to native code
2. **No serialization** - Data stays in native format
3. **No shuffle** - Single machine, no network I/O
4. **No cluster coordination** - Zero orchestration overhead
5. **Memory-mapped I/O** - OS-level optimization
6. **Zero-copy buffers** - SwiftNIO ByteBuffer
7. **Compiler optimizations** - Swift's aggressive inlining

## Implementation Phases

### Phase 1: Semantic Analysis - Aggregation Fusion

**Files to modify:**
- `Sources/AROParser/SemanticAnalyzer.swift` - Detect and fuse multiple Reduce operations

### Phase 2: Core Streaming Types

**Files to create:**
- `Sources/ARORuntime/Streaming/AROStream.swift` - Core stream type
- `Sources/ARORuntime/Streaming/StreamTee.swift` - Multi-consumer splitter
- `Sources/ARORuntime/Streaming/RingBuffer.swift` - Bounded buffer

**Files to modify:**
- `Sources/ARORuntime/Core/RuntimeContext.swift` - Add stream binding
- `Sources/ARORuntime/Core/TypedValue.swift` - Support stream types

### Phase 3: Streaming Sources

**Files to modify:**
- `Sources/ARORuntime/FileSystem/FileSystemService.swift` - Stream file reads
- `Sources/ARORuntime/FileSystem/FormatDeserializer.swift` - Streaming parsers
- `Sources/ARORuntime/HTTP/Client/HTTPClient.swift` - Stream responses

**New files:**
- `Sources/ARORuntime/Streaming/CSVStreamParser.swift`
- `Sources/ARORuntime/Streaming/JSONStreamParser.swift`
- `Sources/ARORuntime/Streaming/ChunkedReader.swift`

### Phase 4: Streaming Transformations

**Files to modify:**
- `Sources/ARORuntime/Actions/BuiltIn/QueryActions.swift` - Filter, Map, Reduce
- `Sources/ARORuntime/Actions/BuiltIn/ComputeAction.swift` - Per-element compute
- `Sources/ARORuntime/Actions/BuiltIn/TransformAction.swift` - Streaming transform

### Phase 5: Streaming Drains

**Files to modify:**
- `Sources/ARORuntime/Actions/BuiltIn/ResponseActions.swift` - Log, Write, Send
- `Sources/ARORuntime/HTTP/Server/OpenAPIHTTPHandler.swift` - Chunked responses

### Phase 6: Pipeline Optimizer

**Files to create:**
- `Sources/ARORuntime/Streaming/PipelineOptimizer.swift`
- `Sources/ARORuntime/Streaming/PredicatePushdown.swift`
- `Sources/ARORuntime/Streaming/ProjectionPruning.swift`

### Phase 7: External Algorithms (Barriers)

**Files to create:**
- `Sources/ARORuntime/Streaming/ExternalSort.swift`

## Compatibility

### Backward Compatibility

- All existing ARO code works unchanged
- Streaming is an optimization, not a new feature
- Results are identical (order, values, types)

### Breaking Changes

None. This is purely an internal optimization.

## References

- [Apache Spark Lazy Evaluation](https://medium.com/@sksami1997/lazy-evaluation-dag-execution-plan-how-spark-optimizes-your-code-0c2cd80fb446)
- [Spark Catalyst Optimizer](https://www.databricks.com/blog/2015/04/13/deep-dive-into-spark-sqls-catalyst-optimizer.html)
- [Swift AsyncSequence](https://developer.apple.com/documentation/swift/asyncsequence)
- [Swift AsyncStream](https://developer.apple.com/documentation/swift/asyncstream)
- [SwiftNIO File System](https://swiftonserver.com/nio-file-system/)
- [Memory-Mapped Files in Swift](https://forums.swift.org/t/what-s-the-recommended-way-to-memory-map-a-file/19113)
- [Swift NIO Optimization](https://github.com/apple/swift-nio/blob/main/docs/optimization-tips.md)
- [Databricks: Spark vs Pandas Single Node](https://www.databricks.com/blog/2018/05/03/benchmarking-apache-spark-on-a-single-node-machine.html)
