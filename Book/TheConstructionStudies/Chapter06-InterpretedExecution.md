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
  <text x="540" y="90" class="label">71 built-in</text>

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

ARO's runtime uses Swift actors for shared state that needs async coordination. `ExecutionEngine` and `EventBus` are actors. `ActionRegistry` and `FeatureSetExecutor` are not — they are `final class` with hand-managed thread safety, and the reason is instructive.

### Why Actors?

Swift 6.3 made data races compile errors. Actors are the answer: the compiler enforces that mutable state is only touched by one task at a time. No manual locking, no `DispatchQueue` gymnastics — the type system does it.

### Why Not Always Actors?

An actor makes every access `await`. That is exactly right for the event bus, whose work is inherently asynchronous. It is exactly wrong for a lookup table consulted once per statement from code paths that include a C bridge which cannot `await` anything. So `ActionRegistry` is a `final class: @unchecked Sendable` — lock-guarded rather than actor-isolated — and `FeatureSetExecutor` is a `final class: Sendable` holding no mutable state of its own.

The rule that emerged: reach for an actor when the state has async coordination to do. Reach for a lock when the state is a table and the callers are synchronous. Choosing the actor anyway pushes `await` into places that then have to bridge back out of it, and the bridge is where the deadlocks live (Chapter 9).

### Actor Isolation in Practice

All actor method calls must be `await`-ed. This propagates up the call stack, making the entire execution path asynchronous — which is exactly what we want for I/O-heavy work.

### EventBus as Actor

EventBus is also an actor, but its `SubscriptionStore` is a lock-backed class so `subscribe()` can register handlers synchronously — an event emitted on the very next instruction is guaranteed to find the new handler. Async coordination (`publishAndWait`, `publishAndTrack`, `awaitPendingEvents`) stays actor-isolated and uses `withTaskGroup` to run handlers concurrently while the bus tracks the in-flight count.

---

## ExecutionContext Protocol

Actions access runtime services through the context. Think of it as the action's window into the world — variables, services, events, metadata.

`ExecutionContext` itself has an empty body. It is a composition of nine narrower protocols, and an action that only needs to read a variable can be written against `VariableBinding` alone:

| Sub-protocol | Methods | Purpose |
|-------------|---------|---------|
| `VariableBinding` | `resolve`, `resolveAny`, `require`, `bind`, `unbind`, `exists`, `variableNames`, `enterMutableScope`, `exitMutableScope`, `resolveTyped`, `bindTyped`, `typeOf` | Read/write the variable space |
| `ServiceRegistryAccess` | `service`, `register`, `registerWithTypeId`, `schemaRegistry` | HTTP, file, socket services; OpenAPI schemas (ARO-0046) |
| `RepositoryAccess` | `repository`, `registerRepository` | CRUD storage access |
| `ResponseManagement` | `setResponse`, `getResponse` | Track the response for short-circuit |
| `EventEmission` | `eventBus`, `emit` | Fire events into the bus |
| `ContextMetadata` | `featureSetName`, `businessActivity`, `executionId`, `parent`, `createChild`, `container`, `isDebugMode`, `isTestMode`, `isCompiled`, `suppressLogPrefix` | Who am I, and how am I running? |
| `WaitStateSignaling` | `enterWaitState`, `waitForShutdown`, `isWaiting`, `signalShutdown` | Keepalive management |
| `OutputFormatting` | `outputContext` | `.human` / `.machine` / `.developer` (ARO-0031) |
| `TemplateBuffering` | `appendToTemplateBuffer`, `flushTemplateBuffer`, `isTemplateContext`, `templateEscaping` | Template rendering (ARO-0050) |

Streaming (`bindLazy`, `resolveAsStream`, `isLazy`, `teeIfNeeded`, ARO-0051) is deliberately *not* in the protocol. Those live on the concrete `RuntimeContext`, so an action reaches them by asking for the concrete type. Lazy streams are an optimization the interpreter can offer, not a promise every context must keep.

---

## FeatureSetExecutor

Each feature set gets an executor that walks its statements in source order. The loop is simple on purpose:

```text
execute:
  for each statement in featureSet:
    executeStatement(statement)
    if getResponse() != nil:
      break  ← short-circuit on Return/Throw
  drainDeferredResults()   ← force anything still outstanding
```

Once a `Return` or `Throw` runs, the response is set and the loop stops. Remaining statements are skipped.

Before each statement runs, the executor opens a fresh statement scope and unbinds twenty-one framework variables — `_literal_`, `_expression_`, `_with_`, `_where_value_` and the rest. These are the channel through which a statement's modifiers reach its action, and they are statement-local by construction. Leaving one bound is how a `with { separator: "-" }` from one statement silently reappears in the next; the compiled path, which clears only fourteen of them and opens no scope, does exactly that (GitLab #552).

That last line of the loop is not bookkeeping. It is the other half of the execution model.

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
  <text x="150" y="55" class="label" text-anchor="middle">Extract the &lt;id&gt; from &lt;request&gt;.</text>

  <rect x="50" y="90" width="200" height="40" rx="5" class="box stmt"/>
  <text x="150" y="115" class="label" text-anchor="middle">Retrieve the &lt;user&gt; from &lt;repo&gt;.</text>

  <rect x="50" y="150" width="200" height="40" rx="5" class="box response"/>
  <text x="150" y="175" class="label" text-anchor="middle">Return an &lt;OK&gt; with &lt;user&gt;.</text>

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

## Statements Start in Order. They Do Not Finish in Order.

The loop above says "execute the statement". What that means changed, and it is the single most consequential thing about ARO's interpreter (ARO-0088).

A statement *starts* where you wrote it. The program waits for it at the **first read of its result** — which may be several statements later, or never. Two independent two-second HTTP requests in one feature set therefore take about two seconds, not four, without anyone writing a single concurrency construct:

```aro
Request the <weather> from "https://api.example.com/weather".
Request the <news> from "https://api.example.com/news".
Log <weather> to the <console>.    (* forces the first *)
Log <news> to the <console>.       (* the second is already in flight *)
```

### Deferral is an allowlist, not a heuristic

The obvious way to build this is to defer everything and force on demand. ARO does the opposite: `LazyActionPolicy` names the thirty value-producing verbs that *may* defer — `retrieve`, `fetch`, `read`, `request`, `compute`, `filter`, `map`, `sort`, `format` and so on — and everything else runs at its own statement.

Two lists, and the second one matters more:

| List | Verbs | Effect |
|------|-------|--------|
| `deferrableVerbs` | 30 value-producers | may return a future |
| `forceAtSiteVerbs` | `return`, `throw`, `log`, `publish`, `emit`, `compare`, `validate`, `accept` | always run here, forcing whatever they read |

Effects never defer. That is what keeps the language honest: `Log` runs at its own statement, so console output stays in source order even though the values it prints were computed out of order. `Sleep` is deliberately *not* deferrable, because for `Sleep` the delay **is** the effect — deferring it would defer nothing.

The allowlist is the conservative choice on purpose. A verb the policy has never heard of runs eagerly, which is always correct and sometimes slow. The reverse default would be sometimes fast and occasionally wrong.

### Mechanics

A deferred action returns an `AROFuture` whose `Task` runs on `ActionTaskExecutor` — a custom `TaskExecutor` over GCD's *elastic* global queue rather than Swift's fixed-size cooperative pool. That choice is load-bearing: a forcer blocks a thread, and if forcers and the work that would unblock them shared a fixed pool, a cascading chain could fill it with threads waiting on each other. GCD spawns more threads instead.

Each statement gets its own scope for those framework variables precisely because of deferral — a deferred action that reads `_with_` when it finally runs must see *its* statement's modifiers, not whatever the loop has moved on to.

Nothing gets lost at the end. `drainDeferredResults` forces everything still outstanding when the feature set exits, so a failure nobody read is still reported, attributed to the statement that caused it rather than to the exit.

### The knobs

| Variable | Default | Does |
|----------|---------|------|
| `ARO_NO_DEFER` | unset | Set to anything: every action runs at its statement |
| `ARO_FORCE_WARN_SECONDS` | `5` | Warn when a force waits this long; `0` disables |
| `ARO_STREAM_PREFETCH` | `2` | How far a stream producer may run ahead of its consumer |
| `ARO_MAX_CALL_DEPTH` | `50000` | Recursion ceiling; `0` disables |

`ARO_NO_DEFER=1` is the debugging tool worth remembering: if a suspected bug disappears under it, the bug is about ordering.

---

## ActionRegistry Design

The registry maps lowercase verb strings to action types. Registration happens at startup; lookup happens for every statement execution.

Actions are not registered one at a time. `createBuiltInActions()` calls eleven **modules** — Request, Own, Response, Server, Socket, File, DataPipeline, Test, Terminal, System, and (off Windows) Git — each handing back an array of action types. Adding an action is one entry in one module array.

That produces **71 built-in actions** on macOS and Linux, claiming about 130 verbs between them; `aro actions` prints the live list and `aro actions <verb>` the details of one. Lookup is a dictionary hit on the lowercase verb string, and a fresh action instance is created per invocation — actions are stateless.

Action methods are `async throws` so every action can do network calls, file reads, or database queries without blocking. Under ARO-0088 most of them are not awaited where they are written; see the deferral section above.

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
  <text x="140" y="55" class="label" text-anchor="middle">Extract the &lt;user&gt; from &lt;request&gt;.</text>

  <!-- Verb lookup -->
  <rect x="30" y="100" width="100" height="30" rx="5" class="box"/>
  <text x="80" y="120" class="label" text-anchor="middle">verb: "extract"</text>

  <!-- Registry -->
  <rect x="170" y="90" width="180" height="110" rx="5" class="box"/>
  <text x="260" y="110" class="title" text-anchor="middle">ActionRegistry</text>
  <text x="180" y="135" class="label">"extract" → ExtractAction</text>
  <text x="180" y="150" class="label">"compute" → ComputeAction</text>
  <text x="180" y="165" class="label">"return" → ReturnAction</text>
  <text x="180" y="180" class="label">... (71 total)</text>

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
for each <item> in <items> {
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

1. **ExecutionEngine** (actor) loads the program and, in a fixed order, registers ten kinds of handler with EventBus before running `Application-Start`
2. **ActionRegistry** (lock-guarded class) maps ~130 verbs to 71 built-in actions, assembled from eleven modules
3. **EventBus** (actor) routes events to matching handlers
4. **FeatureSetExecutor** starts statements in source order and forces them at first read; effects never defer
5. **Descriptors** carry structured information to actions
6. **Context hierarchy** enables scoped variable binding for loops — and per-statement scopes for framework variables, which deferral makes mandatory

Actors are used where state needs async coordination and locks where it does not; that boundary is a design decision, not an oversight. Action methods are `async throws`, which is what lets a statement's work outlive the statement.

The interpreter is the reference implementation. Native compilation (Chapter 8) generates code that calls the same action implementations through a C bridge.

Implementation references:
- `Sources/ARORuntime/Core/ExecutionEngine.swift` (~1,640 lines)
- `Sources/ARORuntime/Core/FeatureSetExecutor.swift` (~2,030 lines)
- `Sources/ARORuntime/Actions/ActionRegistry.swift` (~490 lines)
- `Sources/ARORuntime/Bridge/LazyActionPolicy.swift`, `Bridge/AROFuture.swift` (ARO-0088)

---

*Next: Chapter 7 — Event Architecture*
