# Chapter 6: Interpreted Execution

## Execution Engine Architecture

The engine is a Swift actor — which means the compiler ensures no two tasks touch its state simultaneously. It holds the event bus, the action registry, and one executor per feature set.

<svg viewBox="0 0 700 400" xmlns="http://www.w3.org/2000/svg">
  <style>
    .box { fill: #f5f5f5; stroke: #333; stroke-width: 1.5; }
    .engine { fill: #e8f4e8; }
    .bus { fill: #f4e8e8; }
    .executor { fill: #e8e8f4; }
    .arrow { fill: none; stroke: #333; stroke-width: 1.5; marker-end: url(#arrow13); }
    .label { font-family: monospace; font-size: 10px; fill: #333; }
    .title { font-family: monospace; font-size: 12px; fill: #333; font-weight: bold; }
  </style>

  <defs>
    <marker id="arrow13" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#333"/>
    </marker>
  </defs>

  <!-- ExecutionEngine -->
  <rect x="230" y="30" width="240" height="80" rx="5" class="box engine"/>
  <text x="350" y="55" class="title" text-anchor="middle">ExecutionEngine</text>
  <text x="240" y="75" class="label">• Loads program</text>
  <text x="240" y="90" class="label">• Registers handlers with EventBus</text>
  <text x="240" y="105" class="label">• Executes Application-Start</text>

  <!-- EventBus -->
  <rect x="230" y="140" width="240" height="70" rx="5" class="box bus"/>
  <text x="350" y="165" class="title" text-anchor="middle">EventBus</text>
  <text x="240" y="185" class="label">• Routes events to handlers</text>
  <text x="240" y="200" class="label">• Async dispatch with AsyncStream</text>

  <!-- FeatureSetExecutors -->
  <rect x="30" y="250" width="180" height="100" rx="5" class="box executor"/>
  <text x="120" y="275" class="title" text-anchor="middle">FeatureSetExecutor</text>
  <text x="120" y="295" class="label" text-anchor="middle">"Application-Start"</text>
  <text x="40" y="315" class="label">Executes statements</text>
  <text x="40" y="330" class="label">Manages context</text>

  <rect x="260" y="250" width="180" height="100" rx="5" class="box executor"/>
  <text x="350" y="275" class="title" text-anchor="middle">FeatureSetExecutor</text>
  <text x="350" y="295" class="label" text-anchor="middle">"UserCreated Handler"</text>

  <rect x="490" y="250" width="180" height="100" rx="5" class="box executor"/>
  <text x="580" y="275" class="title" text-anchor="middle">FeatureSetExecutor</text>
  <text x="580" y="295" class="label" text-anchor="middle">"getUser API"</text>

  <!-- ActionRegistry -->
  <rect x="530" y="30" width="140" height="80" rx="5" class="box"/>
  <text x="600" y="55" class="title" text-anchor="middle">ActionRegistry</text>
  <text x="540" y="75" class="label">verb → Action</text>
  <text x="540" y="90" class="label">61 built-in</text>

  <!-- Arrows -->
  <path d="M 350 110 L 350 140" class="arrow"/>
  <path d="M 280 210 L 120 250" class="arrow"/>
  <path d="M 350 210 L 350 250" class="arrow"/>
  <path d="M 420 210 L 580 250" class="arrow"/>
  <path d="M 470 70 L 530 70" class="arrow"/>
</svg>

**Figure 6.1**: Execution engine architecture. The engine coordinates between EventBus and FeatureSetExecutors.

---

## Actor-Based Concurrency

ARO's runtime uses Swift actors for thread-safe shared state. `ExecutionEngine` and `ActionRegistry` are actors, not classes.

### Why Actors?

Swift 6.2 made data races compile errors. Actors are the answer: the compiler enforces that mutable state is only touched by one task at a time. No manual locking, no `DispatchQueue` gymnastics — the type system does it.

### Actor Isolation in Practice

All actor method calls must be `await`-ed. This propagates up the call stack, making the entire execution path asynchronous — which is exactly what we want for I/O-heavy work.

### EventBus as Actor

EventBus is also an actor, but its `SubscriptionStore` is a lock-backed class so `subscribe()` can register handlers synchronously — an event emitted on the very next instruction is guaranteed to find the new handler. Async coordination (`publishAndWait`, `publishAndTrack`, `awaitPendingEvents`) stays actor-isolated and uses `withTaskGroup` to run handlers concurrently while the bus tracks the in-flight count.

---

## ExecutionContext Protocol

Actions access runtime services through the context. Think of it as the action's window into the world — variables, services, events, metadata.

| Method Group | Methods | Purpose |
|-------------|---------|---------|
| Variables | `resolve`, `require`, `bind`, `exists`, `unbind` | Read/write the variable space |
| Type-Aware | `resolveTyped`, `bindTyped`, `typeOf` | Typed value management |
| Services | `service`, `register` | Access HTTP, file, socket services |
| Repositories | `repository`, `registerRepository` | CRUD storage access |
| Response | `setResponse`, `getResponse` | Track the response for short-circuit |
| Events | `emit` | Fire events into the bus |
| Schema | `schemaRegistry` | OpenAPI schema access (ARO-0046) |
| Wait State | `enterWaitState`, `waitForShutdown`, `signalShutdown` | Keepalive management |
| Streaming | `bindLazy`, `resolveAsStream`, `isLazy`, `teeIfNeeded` | Lazy stream support (ARO-0051) |
| Templates | `appendToTemplateBuffer`, `flushTemplateBuffer` | Template rendering (ARO-0050) |
| Output | `outputContext`, `isDebugMode`, `isTestMode`, `isCompiled` | Execution mode |
| Metadata | `featureSetName`, `businessActivity`, `executionId`, `parent` | Who am I? |

---

## FeatureSetExecutor

Each feature set gets an executor that processes statements sequentially. The loop is simple on purpose:

```text
execute:
  for each statement in featureSet:
    executeStatement(statement)
    if response has been set:
      break  ← short-circuit on Return/Throw
```

Once a `Return` or `Throw` runs, the response is set and the loop stops. Remaining statements are skipped.

<svg viewBox="0 0 600 300" xmlns="http://www.w3.org/2000/svg">
  <style>
    .box { fill: #f5f5f5; stroke: #333; stroke-width: 1.5; }
    .stmt { fill: #e8f4e8; }
    .response { fill: #f4e8e8; }
    .arrow { fill: none; stroke: #333; stroke-width: 1.5; marker-end: url(#arrow14); }
    .label { font-family: monospace; font-size: 10px; fill: #333; }
    .title { font-family: monospace; font-size: 11px; fill: #333; font-weight: bold; }
  </style>

  <defs>
    <marker id="arrow14" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#333"/>
    </marker>
  </defs>

  <!-- Statements -->
  <rect x="50" y="30" width="200" height="40" rx="5" class="box stmt"/>
  <text x="150" y="55" class="label" text-anchor="middle">&lt;Extract&gt; the &lt;id&gt; from &lt;request&gt;.</text>

  <rect x="50" y="90" width="200" height="40" rx="5" class="box stmt"/>
  <text x="150" y="115" class="label" text-anchor="middle">&lt;Retrieve&gt; the &lt;user&gt; from &lt;repo&gt;.</text>

  <rect x="50" y="150" width="200" height="40" rx="5" class="box response"/>
  <text x="150" y="175" class="label" text-anchor="middle">&lt;Return&gt; an &lt;OK&gt; with &lt;user&gt;.</text>

  <rect x="50" y="210" width="200" height="40" rx="5" class="box" fill="#ddd"/>
  <text x="150" y="235" class="label" text-anchor="middle">(not executed - response set)</text>

  <!-- Arrows -->
  <path d="M 150 70 L 150 90" class="arrow"/>
  <path d="M 150 130 L 150 150" class="arrow"/>
  <path d="M 250 170 L 350 170" class="arrow"/>

  <!-- Response check -->
  <rect x="360" y="140" width="180" height="60" rx="5" class="box"/>
  <text x="450" y="165" class="title" text-anchor="middle">Response Short-Circuit</text>
  <text x="370" y="185" class="label">Return/Throw sets response</text>
  <text x="370" y="195" class="label">→ execution stops</text>
</svg>

**Figure 6.2**: Statement execution sequence. Return or Throw sets a response, causing remaining statements to be skipped.

---

## ActionRegistry Design

The registry maps lowercase verb strings to action types. Registration happens at startup; lookup happens for every statement execution. Both operations are actor-protected.

61 built-in actions are registered at startup. Each registers one or more verbs. Lookup is a dictionary hit on the lowercase verb string. A fresh action instance is created per invocation — actions are stateless.

Because the registry and engine are actors, action protocols are defined as `async throws`. Every action can do async I/O — network calls, file reads, database queries — without blocking.

<svg viewBox="0 0 600 250" xmlns="http://www.w3.org/2000/svg">
  <style>
    .box { fill: #f5f5f5; stroke: #333; stroke-width: 1.5; }
    .arrow { fill: none; stroke: #333; stroke-width: 1.5; marker-end: url(#arrow15); }
    .label { font-family: monospace; font-size: 10px; fill: #333; }
    .title { font-family: monospace; font-size: 11px; fill: #333; font-weight: bold; }
  </style>

  <defs>
    <marker id="arrow15" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#333"/>
    </marker>
  </defs>

  <!-- Statement -->
  <rect x="30" y="30" width="220" height="40" rx="5" class="box"/>
  <text x="140" y="55" class="label" text-anchor="middle">&lt;Extract&gt; the &lt;user&gt; from &lt;request&gt;.</text>

  <!-- Verb lookup -->
  <rect x="30" y="100" width="100" height="30" rx="5" class="box"/>
  <text x="80" y="120" class="label" text-anchor="middle">verb: "extract"</text>

  <!-- Registry -->
  <rect x="170" y="90" width="180" height="110" rx="5" class="box"/>
  <text x="260" y="110" class="title" text-anchor="middle">ActionRegistry</text>
  <text x="180" y="135" class="label">"extract" → ExtractAction</text>
  <text x="180" y="150" class="label">"compute" → ComputeAction</text>
  <text x="180" y="165" class="label">"return" → ReturnAction</text>
  <text x="180" y="180" class="label">... (61 total)</text>

  <!-- Action instance -->
  <rect x="400" y="90" width="160" height="70" rx="5" class="box"/>
  <text x="480" y="110" class="title" text-anchor="middle">ExtractAction</text>
  <text x="410" y="130" class="label">role: .request</text>
  <text x="410" y="145" class="label">prepositions: [.from, .via]</text>

  <!-- Arrows -->
  <path d="M 140 70 L 80 100" class="arrow"/>
  <path d="M 130 115 L 170 115" class="arrow"/>
  <path d="M 350 125 L 400 125" class="arrow"/>
  <text x="365" y="118" class="label">init()</text>
</svg>

**Figure 6.3**: Action dispatch sequence. The verb is looked up in the registry, and a fresh action instance is created.

---

## Descriptor-Based Invocation

Actions receive structured information via descriptors. The executor builds these from the AST node and hands them to the action.

| Descriptor | Fields |
|-----------|--------|
| `ResultDescriptor` | `base` (variable to bind), `specifiers` (qualifiers), `span` |
| `ObjectDescriptor` | `preposition`, `base`, `specifiers`, `keyPath` |

---

## Context Hierarchy

For loops, child contexts are created per iteration. The loop variable is bound fresh each time. Parent variables are still visible — child contexts inherit from parent but have their own bindings.

```aro
For each <item> in <items> {
    (* each iteration gets its own child context *)
    (* <item> is bound fresh *)
    (* <items> from parent is still visible *)
}
```

<svg viewBox="0 0 500 200" xmlns="http://www.w3.org/2000/svg">
  <style>
    .box { fill: #f5f5f5; stroke: #333; stroke-width: 1.5; }
    .child { fill: #e8f4e8; }
    .arrow { fill: none; stroke: #333; stroke-width: 1.5; marker-end: url(#arrow16); }
    .label { font-family: monospace; font-size: 10px; fill: #333; }
    .title { font-family: monospace; font-size: 11px; fill: #333; font-weight: bold; }
  </style>

  <defs>
    <marker id="arrow16" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#333"/>
    </marker>
  </defs>

  <!-- Parent context -->
  <rect x="150" y="20" width="200" height="60" rx="5" class="box"/>
  <text x="250" y="40" class="title" text-anchor="middle">Parent Context</text>
  <text x="160" y="60" class="label">items: [a, b, c]</text>
  <text x="160" y="75" class="label">user: {...}</text>

  <!-- Child contexts -->
  <rect x="30" y="120" width="130" height="60" rx="5" class="box child"/>
  <text x="95" y="140" class="title" text-anchor="middle">Iteration 1</text>
  <text x="40" y="160" class="label">item: a</text>

  <rect x="185" y="120" width="130" height="60" rx="5" class="box child"/>
  <text x="250" y="140" class="title" text-anchor="middle">Iteration 2</text>
  <text x="195" y="160" class="label">item: b</text>

  <rect x="340" y="120" width="130" height="60" rx="5" class="box child"/>
  <text x="405" y="140" class="title" text-anchor="middle">Iteration 3</text>
  <text x="350" y="160" class="label">item: c</text>

  <!-- Arrows -->
  <path d="M 200 80 L 95 120" class="arrow"/>
  <path d="M 250 80 L 250 120" class="arrow"/>
  <path d="M 300 80 L 405 120" class="arrow"/>
  <text x="170" y="105" class="label">parent</text>
</svg>

**Figure 6.4**: Context tree. Child contexts inherit from parent but have their own bindings for loop variables.

---

## Streaming Execution

ARO supports streaming execution for processing large datasets with constant memory (ARO-0051). The key architectural decision is **lazy vs eager evaluation**.

Lazy evaluation kicks in when the object being processed is an `AnyStreamingValue` (detected via `isLazy()`). Filter, Map, and Reduce recognize this and chain lazily. Drain operations like `Log` or `Return` trigger actual computation. Regular arrays always go through the eager path.

### Streaming Pipeline Architecture

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│   Read      │───▶│   Filter    │───▶│   Reduce    │───▶│   Result    │
│ (lazy load) │    │ (transform) │    │   (drain)   │    │             │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘
     │                   │                   │
     ▼                   ▼                   ▼
  Produces           Transforms          Consumes
  stream              stream              stream
```

Key points:
1. File-based sources (`Read` action with large files) produce lazy streams
2. Transformations (`Filter`, `Map`) are applied lazily, element by element
3. Drains (`Reduce`, `Log`, `Return`) trigger actual execution
4. The `isLazy()` check prevents regular arrays from entering the streaming path

Implementation references:
- `Sources/ARORuntime/Core/RuntimeContext.swift` (isLazy check)
- `Sources/ARORuntime/Streaming/JSONStreamParser.swift` (incremental parsing)
- `Sources/ARORuntime/Actions/BuiltIn/QueryActions.swift` (streaming filter/reduce)

---

## Chapter Summary

The interpreted execution model is straightforward:

1. **ExecutionEngine** (actor) loads the program and registers feature sets with EventBus
2. **ActionRegistry** (actor) maps verbs to action implementations with thread-safe access
3. **EventBus** (actor) routes events to matching handlers
4. **FeatureSetExecutor** processes statements sequentially
5. **Descriptors** carry structured information to actions
6. **Context hierarchy** enables scoped variable binding for loops

The use of Swift actors ensures thread safety without manual lock management. All action methods are async, enabling cooperative scheduling.

The interpreter is the reference implementation. Native compilation (Chapter 8) generates code that calls the same action implementations through a C bridge.

Implementation references:
- `Sources/ARORuntime/Core/ExecutionEngine.swift`
- `Sources/ARORuntime/Core/FeatureSetExecutor.swift`
- `Sources/ARORuntime/Actions/ActionRegistry.swift`

---

*Next: Chapter 7 — Event Architecture*
