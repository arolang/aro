# ARO: The Short Studies

## How a Language Gets Built in Ten Pages

*ARO Language Project · March 2026 · ARO 0.8.0*

---

This is the condensed version of *The Construction Studies*. Every major architectural decision, every important data structure, every hard-won lesson — compressed to what you actually need to understand how ARO works. Read the full book for depth. Read this for the map.

---

## 1. The Core Bet

ARO is built on one hypothesis: **expressiveness and predictability are inversely correlated**, and for business-feature code, predictability wins.

The consequence is radical constraint. ARO has exactly **nine statement types**:

| # | Statement | What it does |
|---|-----------|-------------|
| 1 | `AROStatement` | The core action-result-object form |
| 2 | `PublishStatement` | Exports a variable across feature sets |
| 3 | `ForEachLoop` | Iterates a collection |
| 4 | `MatchStatement` | Pattern matching |
| 5 | `RangeLoop` | Numeric range iteration |
| 6 | `WhileLoop` | Condition-based loop |
| 7 | `BreakStatement` | Exits a loop |
| 8 | `RequireStatement` | Declares a dependency |
| 9 | `PipelineStatement` | Chained actions via `\|>` operator |

Nine. That's it. Python's AST has over 40 statement types. Every statement type you don't have is a parser case, a semantic pass, a code generation branch, and a tool integration you don't have to write. The constraint propagates as simplification through the entire stack.

Every action is classified by data flow direction — not as documentation, but as an enforced type:

| Role | Direction | Examples |
|------|-----------|---------|
| `request` | External → Internal | Extract, Retrieve, Fetch, Read |
| `own` | Internal → Internal | Compute, Validate, Compare, Create |
| `response` | Internal → External | Return, Throw |
| `export` | Internal → Global | Store, Emit, Log, Send |

The role determines valid prepositions, what bridge functions the compiler calls, and what optimizations are legal.

**The error philosophy**: ARO code is the error message. When `Retrieve the <user> from the <user-repository>` fails, the runtime reports exactly that sentence back. No stack traces needed — the statement *is* the description of what failed.

---

## 2. Lexical Analysis

The lexer is a single-pass state machine that makes one unusual choice: **articles and prepositions are first-class token types**, not noise to be filtered.

```
"Extract the <user> from the <request: body>."
  ↓
[VERB:"Extract"] [ARTICLE:"the"] [RESULT_START:"<"]
[IDENT:"user"] [RESULT_END:">"] [PREP:"from"]
[ARTICLE:"the"] [OBJECT_START:"<"] [IDENT:"request"]
[COLON:":"] [IDENT:"body"] [OBJECT_END:">"] [DOT:"."]
```

Why keep articles? Because `Extract a <user>` and `Extract the <user>` carry slightly different semantics in English, and stripping them would lose that signal for future tooling. The parser filters them for now; the door stays open.

**The hard problems:**

*String interpolation* — `"Hello, \(name)!"` forces the lexer to recursively lex the embedded expression, yielding a token sequence of string parts and inner tokens that the parser reassembles. It works, but it's the messiest part of the lexer.

*Regex vs. division* — `/pattern/` and `7 / 2` are lexically identical at the `/`. The lexer resolves the ambiguity with context: if the previous token was a value (number, identifier, closing bracket), it's division; otherwise it's a regex. This works for all real-world cases but is technically a heuristic.

*Source locations* — every token carries `(file, line, column, offset)`. This costs memory but pays off when error messages need to point at the right character.

---

## 3. Syntactic Analysis

The parser is a hybrid: **recursive descent for statements, Pratt parsing for expressions**.

Recursive descent is the right choice for statements — each statement type is distinct enough that a top-level `switch` on the first token routes cleanly. The eight statement types map to eight parsing functions.

Pratt parsing handles expressions. The insight is that each token has a *binding power* — how tightly it grabs its neighbors. Addition is weaker than multiplication, which is weaker than unary negation, which is weaker than function call. Parse at the right power level and precedence falls out automatically.

| Precedence Level | Operators |
|-----------------|-----------|
| 1 (lowest) | `or` |
| 2 | `and` |
| 3 | `not` |
| 4 | `==`, `!=`, `<`, `>`, `<=`, `>=` |
| 5 | `+`, `-`, `++` (concat) |
| 6 | `*`, `/`, `%` |
| 7 (highest) | unary `-`, `not` |

The core statement shape that nearly everything reduces to:

```
Action [article] <Result[:qualifier]> preposition [article] <Object[:qualifier]>.
```

`<Result:qualifier>` is a `QualifiedNoun` — the most important structural unit in ARO. It shows up everywhere:

| Field | Type | Example |
|-------|------|---------|
| `base` | String | `"user"` |
| `qualifier` | String? | `"email"` |
| `specifiers` | [String] | `["profile", "contact"]` |

`<user: profile: contact: email>` resolves to base `user`, qualifier `email`, specifiers `["profile", "contact"]`. At runtime this navigates into nested objects.

**Error recovery**: when the parser hits something unexpected, it scans forward to the next `.` (statement terminator) and continues. This means a single syntax error doesn't abort the whole file — you get all the errors in one pass.

---

## 4. Semantic Analysis

The semantic analyzer makes four passes over the AST:

1. **Symbol collection** — build a symbol table per feature set, tracking every variable name and its visibility level
2. **Data flow analysis** — classify each binding as `request`, `own`, `response`, or `export`
3. **Immutability enforcement** — flag any variable bound twice in the same scope
4. **Cross-feature validation** — detect circular event loops, orphaned handlers, undefined variables

**VerbSets** are the semantic analyzer's classification tool. Every verb gets assigned to exactly one set, and that set determines how the executor treats it:

| Set | Verbs (examples) | Effect |
|-----|-----------------|--------|
| `testVerbs` | then, assert | Only runs in test mode |
| `updateVerbs` | update, modify, set | Allows rebinding an existing variable |
| `createVerbs` | create, make, build | Entity creation path |
| `responseVerbs` | log, print, send, emit | Skip the expression shortcut |
| `serverVerbs` | start, stop, keepalive, schedule | Force execution even with literal object |
| `storeVerbs` | store, save, persist | Trigger repository observers |

These sets live in `VerbSets.swift`, shared by both the interpreter and the compiler. One authoritative source — no duplication, no drift.

**Immutability** is the rule with the most impact on users: once a variable is bound in a feature set, it can't be rebound. The only escape is renaming — compute a new name. This feels annoying until you debug a feature set and realize you always know exactly what a variable contains at any point.

---

## 5. Interpreted Execution

The interpreter is built around three collaborating components:

```
ExecutionEngine  →  EventBus  →  FeatureSetExecutor (×N)
                        ↓
                   ActionRegistry
```

**ExecutionEngine** is a Swift actor. It loads the program, registers all event handlers with the event bus, and fires `Application-Start`. After that it steps back and lets events drive everything.

**FeatureSetExecutor** runs one feature set. For each statement it:
1. Builds a `ResultDescriptor` and `ObjectDescriptor` from the AST node
2. Looks up the verb in `ActionRegistry`
3. Calls `action.execute(result:object:context:)`
4. Checks if the action set a response (short-circuit) or threw

**ActionRegistry** maps verb strings to action implementations. 61 built-in actions, registered at startup. Adding a new action is implementing one protocol method and registering the type.

**ExecutionContext** is what actions see. A flat protocol that hides whether you're running in the interpreter, a compiled binary, or a test:

| Method group | What it does |
|---|---|
| `resolve`, `require`, `bind` | Variable read/write |
| `service` | Access HTTP, file, socket services |
| `repository` | CRUD storage |
| `setResponse`, `getResponse` | Track the short-circuit response |
| `emit` | Fire events |

**The short-circuit pattern**: as soon as a `Return` or `Throw` action runs, it sets the response on the context. The executor checks after every statement and stops early. This is how `Validate the <user>` can abort the rest of the feature set — no exceptions, no special control flow.

---

## 6. Event Architecture

Everything in ARO is event-driven. HTTP requests arrive as events. File changes arrive as events. Domain events travel between feature sets as events. The `EventBus` is the central router.

Seven handler types, registered by naming convention:

| Pattern | Triggered by |
|---------|-------------|
| `operationId` (e.g., `listUsers`) | HTTP route match |
| `{Name} Handler` | Custom domain event |
| `{repo-name} Observer` | Repository store/update/delete |
| `File Event Handler` | File system changes |
| `Socket Event Handler` | TCP socket events |
| `KeyPress Handler` | Keyboard input (with `where` guards) |
| `WebSocket Event Handler` | WebSocket lifecycle |

**StateGuards** let handlers filter on event payload fields:

```aro
(Send Welcome: NotificationSent Handler) when <age> >= 18 {
    (* only fires when the notified user is 18+ *)
}
```

The guard is evaluated before the handler body runs. If it fails, the handler is silently skipped.

**publishAndTrack** is how the event bus ensures handlers complete before the program moves on. Every `emit` increments an in-flight counter. `awaitPendingEvents()` spins until the counter hits zero. This prevents race conditions between `Application-Start` and its handlers — a real bug we hit early.

**DomainEvent co-publishing** is the bridge between interpreter and binary mode. Typed Swift events (like `FileCreatedEvent`) work for the interpreter. Compiled binaries can't receive those — they need C-callable registration functions. The solution: every action that fires a typed event *also* publishes a `DomainEvent` (a plain string type + `[String: Sendable]` dictionary) to the same bus. Binary handlers register via C functions that subscribe to these DomainEvents.

---

## 7. Native Compilation

The compiled path takes the same AST and turns it into a native binary instead of interpreting it.

```
.aro files → Parser → AnalyzedProgram → LLVMCodeGenerator → LLVM IR → llc → .o → Linker → binary
```

**Swifty-LLVM**: ARO uses the [Swifty-LLVM](https://github.com/hylo-lang/Swifty-LLVM) wrapper around LLVM's C API. The original implementation used textual LLVM IR — strings concatenated together. The problem: type errors were only caught when `llc` tried to compile the output. With Swifty-LLVM, IR is built from typed Swift objects (`Function`, `BasicBlock`, `GlobalVariable`), and `verifyModule()` catches structural errors before any text is emitted. The cost: LLVM 20 as a build dependency.

**What gets generated**: each feature set becomes an LLVM function. The function:
1. Allocates a context handle (opaque pointer to a `RuntimeContext`)
2. Allocates descriptor structs for each statement's result and object
3. Calls the appropriate `aro_action_*` C function
4. Checks the return value and jumps to `error_exit` on failure
5. Frees the context and returns

String constants are collected in a first pass and emitted as global LLVM constants. The code generator then references them by pointer — no string allocation at runtime.

**Control flow** maps directly to LLVM basic blocks:
- `when` guard → branch instruction to skip block
- `match` → chain of comparisons, each branching to its case block
- `for-each` → loop with `gep` to advance through the array
- `while` → back-edge to the condition block

**Event handler registration** happens at program startup: `LLVMCodeGenerator` emits calls to C-callable registration functions (`aro_runtime_register_notification_handler`, `aro_runtime_register_state_transition_handler`, etc.) that subscribe to DomainEvents and call the compiled function pointer when the event fires.

---

## 8. The Runtime Bridge

The compiled binary can't call Swift directly — the C ABI boundary forbids it. Everything flows through `RuntimeBridge.swift`, which exposes 61 `@_cdecl` functions:

```
LLVM Binary  →  @_cdecl functions  →  Swift runtime
(C types)         (C ABI boundary)      (async, actors, closures)
```

Three handle types cross the boundary as opaque `UnsafeMutableRawPointer`:

| Handle | What it wraps | Used for |
|--------|--------------|---------|
| `AROCContextHandle` | `RuntimeContext` | Per-execution variable space |
| `AROCRuntimeHandle` | `RuntimeBridge` instance | Shared runtime state |
| `AROCDescriptorHandle` | `ResultDescriptor`/`ObjectDescriptor` | Statement metadata |

**The synchronous bridge problem (and how it was solved)**: `@_cdecl` functions can't be `async`, but Swift runtime actions are async. ARO solves this with an `AROFuture` — `aro_action_*` returns immediately with a future handle, and force points (the value-accessors, the effectful verbs) block the C-bridge pthread on the future's `DispatchGroup` until the result is ready. The futures' tasks run on a custom `TaskExecutor` over GCD's elastic global queue, *not* the cooperative pool, so a blocked pthread cannot starve the work that would unblock it. Cascading event chains that previously risked deadlock now finish in milliseconds.

**Platform types**: `Bool` is not the same on macOS and Linux at the C boundary. macOS passes it as 1 byte; Linux sometimes expects 4 bytes. All boolean results cross the bridge as `Int32` and are converted at each side.

---

## 9. Dual-Mode Parity

Running `aro run` and running the compiled binary should produce identical results. In practice, two subsystems diverge:

**Expression evaluation** has two implementations — `ExpressionEvaluator.swift` for the interpreter and `evaluateBinaryOp()` in `RuntimeBridge.swift` for the binary. They have to be kept in sync manually. The most common drift: integer division.

| Expression | Interpreter (before fix) | Binary | After fix |
|-----------|--------------------------|--------|-----------|
| `7 / 2` | `3.5` (promoted to Double) | `3` (truncated) | `3` (both) |
| `80 / 3` | `26.666…` | `26` | `26` (both) |
| `7.0 / 2` | `3.5` | `3.5` | `3.5` (both) |

The fix: interpreter integer division now truncates, matching the binary. Visible behavior change, but consistent.

**Event dispatch** is architecturally different between modes. The checklist for adding any new event type:

1. Add DomainEvent co-publish after the typed event publish
2. Document the payload schema in a `// DomainEvent payload:` comment
3. Add the `@_cdecl` registration function in `RuntimeBridge.swift`
4. Declare the extern in `LLVMExternalDeclEmitter.swift`
5. Detect the business activity in `LLVMCodeGenerator.registerEventHandlers`
6. Spread guard fields into the payload if the handler has a `when` condition
7. Add an example with `mode: both` in the test suite

The `mode: both` test directive is the defense mechanism. Every example runs in both modes and compares output. Any divergence becomes a test failure immediately.

---

## 10. What We Learned

**The things that worked:**

- Uniform syntax makes tooling cheap. One statement shape means one parser, one formatter, one AST walker.
- Nine statement types kept every backend small. Every new execution target (interpreter, LLVM, future transpiler) starts with nine cases.
- `mode: both` testing caught divergence that would otherwise be invisible for months.
- VerbSets as a shared module eliminated the drift between interpreter and compiler verb classification.

**The things that didn't:**

- HTTP doesn't work in compiled binaries. SwiftNIO relies on Swift type metadata that isn't properly initialized when the runtime starts from LLVM-compiled code. The crash is in `_swift_allocObject_` with a null metadata pointer. The workaround is a native BSD socket server — less robust but functional.
- `@_cdecl` can't be `async`. The semaphore bridge works but is fragile under load.
- Business activity scope confused everyone. Variables visible only within the same activity string is neither global scope nor lexical scope. Users expected one or the other.
- Prepositions carry semantic meaning (`from` = source, `into` = destination, `with` = modification) but the distinctions are too subtle. Developers guess wrong and get cryptic errors.

**The evolution in one table:**

| Version | What changed |
|---------|-------------|
| 0.1 | 5 statement types, text-based LLVM IR, no binary mode |
| 0.3 | Added RangeLoop, WhileLoop, BreakStatement → 8 types |
| 0.5 | VerbSets extracted as shared module; dual-mode parity project starts |
| 0.6 | Swifty-LLVM replaces text IR; `verifyModule()` catches IR errors early |
| 0.7 | DomainEvent co-publishing; 81/85 examples run `mode: both` |
| 0.7.1 | Integer division parity; KeyboardService binary mode; SocketClient (#134 open) |
| 0.8.0 | PipelineStatement (9 types); KeyPress/WebSocket handlers (7 handler types); package manager (`aro add`/`aro remove`); LSP server; terminal UI subsystem |

**For the next implementer:**

Keep the statement count small. It's the most impactful architectural decision and the hardest to change later. Every statement type you add is a permanent tax on every future pass, every future tool, every future backend.

Test both execution paths from day one. Divergence accumulates silently. By the time you notice, it's deep in the codebase.

Co-publishing is not elegant, but it works. A unified event system would be cleaner. In practice, unifying deeply integrated subsystems mid-project costs more than bridging them.

The constraint is the feature. ARO programs are predictable and auditable because the language doesn't let you write anything else. That's not a limitation — it's the entire point.

---

*For the complete treatment — all diagrams, all implementation details, all appendices — see* The Construction Studies.
