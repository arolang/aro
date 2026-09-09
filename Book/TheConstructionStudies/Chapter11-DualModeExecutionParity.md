# Chapter 11: Dual-Mode Execution Parity

## What This Chapter Is

ARO programs can run in two modes: interpreted (`aro run`) and compiled (`aro build`). In theory, they should produce identical results. In practice, they share most infrastructure but diverge in subtle ways that are hard to detect until tests fail silently.

This chapter documents the sources of divergence, the systematic fixes applied, and the architectural patterns that prevent future drift.

---

## The Divergence Problem

The interpreter and binary paths share `ActionRegistry.shared`, `RuntimeContext`, and `EventBus.shared`. But two key subsystems have entirely separate implementations:

**Event dispatch**: The interpreter uses Swift typed events (`FileCreatedEvent`, `StateTransitionEvent`, etc.) routed through `EventBus.subscribe(to:)`. The compiled binary uses `DomainEvent` (an event type string plus a `[String: any Sendable]` payload dictionary) routed through `aro_runtime_register_handler` in `RuntimeEventRecordingBridge.swift`.

**Expression evaluation**: The interpreter evaluates expressions in `Core/ExpressionEvaluator.swift`. The compiled binary evaluates them in `evaluateBinaryOp()` in `Bridge/RuntimeExecutionBridge.swift` — whose own doc comment calls it "the compiled-mode sibling of the interpreter's `ExpressionEvaluator`". Two implementations of one semantics, kept in step by hand.

This separation is necessary — the compiled binary cannot execute arbitrary Swift closures — but it creates a gap that widens every time a new feature is added to only one path.

---

## Source of Divergence 1: Verb Sets

### The Problem

`FeatureSetExecutor.executeAROStatement()` classifies verbs into named sets to decide whether a statement needs execution or can be skipped. These sets were defined locally inside the executor function. Any other code needing the same classification had to duplicate them or stay inconsistent.

### The Fix

`Sources/ARORuntime/Core/VerbSets.swift` extracts the eleven sets into a single shared module. The interpreter consults them per statement; binary mode emits direct action calls and has no `needsExecution` decision to make, so for the compiler the module is a canonical vocabulary reference rather than a runtime dependency:

| Set | Sample Verbs | Controls |
|-----|-------------|---------|
| `testVerbs` | then, assert | Test-mode execution |
| `updateVerbs` | update, modify, change, set | Allow rebinding |
| `createVerbs` | create, make, build, construct | Entity creation |
| `responseVerbs` | log, print, send, emit, notify | Skip expression shortcut |
| `serverVerbs` | start, stop, keepalive, schedule | Force execution with literals |
| `requestVerbs` | call, invoke, request, probe, fetch, retrieve | External invocation — always execute |
| … | | (eleven in total; Chapter 5 lists them all) |

There is no `storeVerbs`: `store`, `save` and `persist` live in `responseVerbs`.

Any future code that classifies verbs has one authoritative source — no more duplication. Which makes the *next* section the cautionary tale, because there is a second per-statement list that never got the same treatment.

---

## Source of Divergence 2: The List That Did Not Get Shared

`VerbSets` worked. The lesson did not generalize, and the counter-example is one screen away in the same code.

Between statements, the interpreter unbinds twenty-one framework variables — the `_literal_`, `_expression_`, `_with_`, `_where_value_` channel through which a statement's modifiers reach its action — and opens a fresh statement scope first. The code generator emits `aro_variable_unbind` for fourteen of them and opens no scope. Seven names are never cleared in a compiled binary:

```
_literal_   _expression_   _expression_name_   _result_expression_
_to_        _with_         _against_
```

The comment above the compiler's list says it "mirrors FeatureSetExecutor lines 248-256". It does not mirror it, and the line reference is itself stale — the interpreter's list has since moved. Two hand-maintained lists, one comment asserting a relationship that no code enforces.

It produces a wrong answer, not a crash:

```aro
Compute the <j1: join> from <one> with { separator: "-" }.
Compute the <j2: join> from <two>.
```

```
aro run                 built binary
a-b                     a-b
cd                      c-d      ← the previous statement's separator
```

Filed as GitLab #552. The fix is the `VerbSets` fix again: one constant both paths iterate, plus a test asserting the emitted unbind list equals it. What makes this worth a section rather than a footnote is that the defense described at the end of this chapter did not catch it — no example calls the same qualifier twice, once with `with` and once without, so `mode: both` had nothing to compare.

---

## Source of Divergence 3: Integer Division

### The Problem

Integer division produced different results in the two modes.

**Before the fix**: The interpreter's expression evaluator always passed division through a `numericOperation` helper that promoted to `Double`. So `7 / 2 = 3.5`. The binary's evaluator checked for Int/Int first and returned integer floor division. So `7 / 2 = 3`.

**The fix**: The interpreter now matches binary behavior — when both operands are integers, division returns an integer (truncated toward zero). This is a visible behavioral change: ARO integer division now truncates, consistent with most languages.

Result:

| Expression | Before | After |
|-----------|--------|-------|
| `7 / 2` | `3.5` (interp), `3` (binary) | `3` (both) |
| `80 / 3` | `26.666…` (interp), `26` (binary) | `26` (both) |
| `7.0 / 2` | `3.5` (both) | `3.5` (both) |

---

## Source of Divergence 4: Event Handler Registration

### The Architecture

The interpreter registers event handlers during program startup by subscribing Swift closures to typed events — each handler is a block of code that captures the feature set and runs it when the event fires.

The compiled binary cannot use Swift closures at the C ABI boundary. Instead, `LLVMCodeGenerator` emits calls to C-callable registration functions at program startup, passing a function pointer to the compiled feature set:

```
// Generated LLVM IR (pseudocode)
call void @aro_runtime_register_notification_handler(
    runtime_ptr,
    handler_func_ptr,
    when_condition_json_ptr
)
```

### The DomainEvent Co-Publishing Pattern

For the binary path to receive events, every action that fires a typed event must also publish a `DomainEvent` to `EventBus.shared`. The registration functions in `RuntimeEventRecordingBridge.swift` subscribe to these `DomainEvents` and call the compiled handler function.

**Pattern** (applies to all event-generating actions):

```text
1. Publish typed Swift event (for interpreter handlers)
   → eventBus.publishAndTrack(MyTypedEvent(...))

2. Co-publish DomainEvent (for binary mode handlers)
   → EventBus.shared.publish(DomainEvent(
         eventType: "MyEventType",
         payload: { "key1": value1, "key2": value2, ... }
     ))
```

### Payload Schemas

Each event type has a defined payload schema. These are documented in comments at each callsite:

| Event Type | Payload Keys |
|------------|--------------|
| `StateTransition` | `fromState: String`, `toState: String`, `fieldName: String`, `objectName: String`, `entityId: String?` |
| `NotificationSent` | `message: String`, `target: String`, `user: targetObj`, `[targetName]: targetObj`, plus all target object fields spread at top level |
| `file.created` / `file.modified` / `file.deleted` | `path: String` |
| `websocket.connected` | `connectionId: String`, `path: String`, `remoteAddress: String` |
| `websocket.disconnected` | `connectionId: String`, `reason: String` |
| `websocket.message` | `connectionId: String`, `message: String` |
| `socket.connected` | `connection: { id: String, remoteAddress: String }` |
| `socket.data` | `packet: { message: String, buffer: String, data: String, connection: String }` |
| `socket.disconnected` | `event: { connectionId: String, reason: String }` |
| `KeyPress` | `key: String` |

---

## The Handler Registration Pattern

Every new event type requires a corresponding `aro_runtime_register_*` C-callable function. All follow the same template:

```text
@_cdecl("aro_runtime_register_my_event_handler")
  params: runtime handle, optional guard JSON, compiled handler function pointer

Steps inside:
  1. Unwrap handles
  2. Subscribe to DomainEvent("MyEventType") on EventBus.shared
  3. On event received:
     a. Evaluate guard condition JSON (if present)
     b. Create a fresh context, bind event payload
     c. Run the compiled handler off the cooperative pool
     d. Signal completion
```

**Why not the cooperative pool?** Because it has a fixed thread count, and a compiled handler blocks its thread — `@_cdecl` cannot `await`. During intensive event processing, every thread in that pool can end up blocked waiting for a continuation that needs one of those threads to run. Action work therefore goes to `ActionTaskExecutor`, a `TaskExecutor` over GCD's *elastic* global queue, which spawns more threads under load rather than deadlocking; `CompiledExecutionPool.shared` bounds concurrent feature-set entry so "elastic" does not become "unbounded". Chapter 9 has the full mechanism, including why results hand over through a `DispatchGroup` and not a semaphore.

The three-step pattern for every new event handler:

1. **`LLVMExternalDeclEmitter.swift`**: Declare the C function with LLVM types
2. **`LLVMCodeGenerator.registerEventHandlers`**: Detect the business activity pattern and emit the registration call
3. **`Bridge/RuntimeEventRecordingBridge.swift`**: Implement the `@_cdecl` function

---

## The `when` Guard: Interpreter vs Binary

Handler feature sets can have a `when` guard:

```aro
(Greet User: NotificationSent Handler) when <age> >= 16 {
    (* ... *)
}
```

**Interpreter**: `ExecutionEngine` evaluates this expression inline using `ExpressionEvaluator` with the target object's fields bound to context.

**Binary**: `LLVMCodeGenerator` serializes the `whenCondition` AST node to JSON using `serializeExpression()`:

```json
{"$binary":{"op":">=","left":{"$var":"age"},"right":{"$literal":16}}}
```

This JSON is passed as a string constant to the registration function. At runtime, `evaluateExpressionJSON()` in `Bridge/RuntimeExecutionBridge.swift` deserializes and evaluates it against a `RuntimeContext` populated with the event payload.

The serializer handles more forms than the evaluator does. `ExpressionSerializer` emits `$lit`, `$var`, `$binary`, `$interpolated` **and `$unary`**; `evaluateExpressionJSON` knows the first four. `ConstantFolder` runs first and folds constant unaries away, so the gap only opens for a non-constant `not <flag>` in a compiled guard — which is precisely the kind of edge that stays hidden until someone writes it.

This means the binary `when` guard evaluates against a flat payload dictionary, so the payload must spread the target object's fields at top level.

---

## Test Coverage: The mode: both Directive

A `test.hint` file may carry a `mode` field:

| Value | Meaning |
|-------|---------|
| `both` | Run in interpreter and compiled binary modes, compare output |
| `interpreter` | Run interpreter only |
| `compiled` | Run the built binary only |
| `test` | `aro test`, interpreter leg only |

**`both` is the default**, which is the design decision that matters: an example opts *out* of parity testing, never in. `AROTest::Hint` validates the field against exactly those four values and silently resets anything else to `both`, so a typo cannot quietly disable the check.

Of 109 examples, 102 carry a `test.hint`; 66 name `mode: both` explicitly and the rest inherit it. Four opt out, and it is worth reading why, because none of the four reasons is "binary mode cannot do this":

| Example | Why interpreter-only |
|---------|----------------------|
| `FileUpload` | Its own `test.sh` builds the binary and repeats every check against it, so the harness would build twice (ARO-0090 §10) |
| `MultiService` | Real parity gaps: socket welcome lines arrive before the harness subscribes at compiled speed, and file events emit `FILE MODIFIED` where the interpreter emits `CREATED`/`DELETED` |
| `EventReplay` | Its `test-script` drives `--record` / `--replay` as a shell pipeline |
| `RepoBackup` | Clones live remotes; unsafe under CI regardless of mode |

The harness is Perl — `Tests/IntegrationTestsRunner/run-tests.pl`, with `Runner.pm` dispatching the two legs and `Normalize.pm` massaging output so one `expected.txt` can match both. Windows skips the compiled leg entirely; `skip-compiled-on-linux` skips it there per example, while both legs still run on macOS.

The `occurrence-check: true` hint enables order-independent output comparison, which is essential for event handlers that fire asynchronously in binary mode.

---

## Verification Checklist for New Event Types

When adding a new action that fires events:

1. **Add DomainEvent co-publish** after the typed event publish
2. **Document the payload schema** with a `// DomainEvent eventType:  payload:` comment
3. **Add `@_cdecl` registration function** in `Bridge/RuntimeEventRecordingBridge.swift`
4. **Declare the extern** in `LLVMExternalDeclEmitter.swift`
5. **Detect the business activity** in `LLVMCodeGenerator.registerEventHandlers` (before generic `hasSuffix(" Handler")`)
6. **Spread guard fields** into the DomainEvent payload if the handler has a `when` condition
7. **Add or update an example** with `mode: both` and `occurrence-check: true`
8. **Run** `swift build -c release && ./Tests/IntegrationTestsRunner/run-tests.pl`

---

## Lessons

**Silent divergence is the worst kind of bug.** A binary that produces wrong results without crashing is harder to diagnose than one that crashes immediately. The `mode: both` test directive is the primary defense: any behavioral difference between interpreter and binary becomes a test failure.

**Co-publishing is cheaper than unification.** A clean architectural solution would use a single event system for both modes. In practice, the typed event system is deeply integrated with the interpreter (closures, `async/await`, `publishAndTrack`), while the binary needs C-callable, pthread-compatible registration. DomainEvent co-publishing bridges the two worlds with minimal coupling and no breaking changes.

**Payload schemas are contracts.** The `// DomainEvent payload:` comments are not just documentation — they define the interface between the action that fires the event and the `RuntimeBridge` function that receives it. When the payload changes, both sides must be updated atomically.

---

*Next: Chapter 12 — The Evolution of ARO*
