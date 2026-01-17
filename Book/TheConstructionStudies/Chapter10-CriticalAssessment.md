# Chapter 10: Critical Assessment

## What This Chapter Is

This chapter provides an honest evaluation of ARO's design decisions—what works, what doesn't, and what we'd change with hindsight. Compiler design involves trade-offs; understanding them matters more than celebrating successes.

---

## What Works Well

### Uniform Syntax

ARO's rigid `<Action> the <Result> from the <Object>` structure enables simple tooling:

- **Parsing**: Every statement follows the same pattern
- **Analysis**: Data flow is explicit in the syntax
- **Formatting**: No debates about code style
- **Refactoring**: Find/replace works reliably

The constraint that seemed limiting during design has proven valuable in practice.

### Predictable Execution

Sequential execution with explicit short-circuit points makes debugging straightforward:

```aro
<Extract> the <user> from the <request: body>.    (* 1 *)
<Validate> the <user> with <schema>.              (* 2 - might short-circuit *)
<Store> the <user> into the <user-repository>.   (* 3 *)
<Return> an <OK: status> for the <creation>.     (* 4 *)
```

When something fails, you know exactly which statement failed and why.

### Event-Driven Architecture

The pub-sub model fits naturally with ARO's reactive use cases:

- HTTP routes → feature sets
- Domain events → handlers
- File changes → watchers

No explicit wiring code; the EventBus handles all routing.

### Code-as-Documentation

The verbose syntax reads like prose:

```aro
<Extract> the <email> from the <user: profile: contact: email>.
<Send> the <welcome-message> to the <email>.
```

Even non-programmers can follow the logic.

---

## What Doesn't Work

### HTTP Disabled in Binary Mode

**Problem**: Compiled binaries crash when using SwiftNIO.

**Technical Cause**: SwiftNIO relies on Swift type metadata that isn't properly initialized when the Swift runtime starts from LLVM-compiled code. The crash occurs in `_swift_allocObject_` with a null metadata pointer when NIO tries to create socket channels.

**Impact**: HTTP servers only work in interpreter mode, negating the startup-time benefits of native compilation.

**Workaround**: A native BSD socket HTTP server is used for compiled binaries, but it's less robust than NIO.

**Potential Fix**: Investigate Swift runtime initialization sequence; may require changes to how we link against the Swift stdlib.

---

### No LLVM Type Checking

**Problem**: Type errors in generated LLVM IR are caught at `llc` time, not generation time.

**Technical Cause**: We chose textual LLVM IR over the LLVM C API. Textual IR doesn't provide type checking during generation.

**Impact**: Malformed IR produces cryptic `llc` errors instead of helpful messages pointing to the source.

**Example**:
```
llc: error: program.ll:847:5: use of undefined value '%s0_result_desc'
```

**Potential Fix**: Use the LLVM C API (adds C++ build dependency) or add a verification pass before emitting IR.

---

### Synchronous Action Execution

**Problem**: Actions block their calling thread in compiled binaries.

**Technical Cause**: `@_cdecl` functions cannot be `async`. We use `DispatchSemaphore.wait()` to block until async work completes.

**Impact**: Risk of thread pool exhaustion and deadlocks under load.

**Example deadlock scenario**:
1. Compiled handler starts on thread A
2. Handler action calls async service
3. Async service needs thread A (which is blocked)
4. Deadlock

**Current Mitigation**: Event handlers run on GCD threads, not the Swift cooperative executor.

**Potential Fix**: Design a custom async-compatible C bridge, or use libdispatch more carefully.

---

### Function Pointer Fragility

**Problem**: Handler registration passes function pointers through integer casts.

**Technical Cause**: Swift closures aren't Sendable when they capture pointers. We cast to `Int`, then back to pointer in the callback.

```swift
let handlerAddress = Int(bitPattern: handlerPtr)
// ... later ...
let funcPtr = UnsafeMutableRawPointer(bitPattern: handlerAddress)
let handlerFunc = unsafeBitCast(funcPtr, to: HandlerFunc.self)
```

**Impact**: Works, but undefined behavior if address space assumptions are violated.

**Potential Fix**: Use stable function tables with integer indices instead of raw pointers.

---

### Single Lookahead Limitation

**Problem**: The parser uses single-token lookahead, requiring disambiguation heuristics.

**Technical Cause**: Simplicity choice during initial development.

**Impact Examples**:
- `/` could be division or regex start
- `<` could be generic or less-than
- Article usage affects parsing

**Current Workaround**: Context-dependent heuristics in the lexer/parser.

**Potential Fix**: PEG parser with unlimited lookahead, or packrat parsing.

---

## Design Decisions We'd Reconsider

### Preposition-Based Semantics

The idea: prepositions carry semantic meaning (from = source, to = destination, with = modification).

```aro
<Extract> the <data> from the <request>.   (* from = source *)
<Send> the <message> to the <user>.        (* to = destination *)
<Update> the <user> with <changes>.        (* with = modification *)
```

**The Problem**: Too subtle. Developers don't intuitively distinguish between:
- `<Store> the <user> into the <repository>.`
- `<Store> the <user> to the <repository>.`

Both seem valid, but only one is correct.

**What We'd Change**: Fewer prepositions with clearer rules, or remove semantic distinction entirely.

---

### No Explicit Type Annotations

The idea: Types are inferred from usage and OpenAPI schemas.

```aro
<Extract> the <user> from the <request: body>.  (* user type comes from OpenAPI *)
```

**The Problem**: Tooling becomes harder:
- IDE completion doesn't know types without analyzing the whole program
- Error messages can't reference expected types
- Documentation generators can't show types

**What We'd Change**: Optional type annotations with inference as fallback:
```aro
<Extract> the <user: User> from the <request: body>.
```

---

### Business Activity Isolation

The idea: Variables are only visible within the same "business activity" scope.

**The Problem**: Confusing mental model. Developers expect either:
- Global scope (everything visible everywhere)
- Lexical scope (visible in nested blocks)

Business activity scope is neither.

**What We'd Change**: Explicit visibility keywords or simpler scoping rules.

---

## Limitations Table

| Limitation | Technical Cause | Impact | Difficulty to Fix |
|------------|-----------------|--------|-------------------|
| HTTP in binary | SwiftNIO metadata | No compiled HTTP servers | Hard |
| No IR type checking | Textual LLVM IR | Runtime-only errors | Medium |
| Sync action execution | @_cdecl constraint | Potential deadlocks | Hard |
| Function pointer fragility | Sendable constraints | Undefined behavior risk | Medium |
| Single lookahead | Parser simplicity | Disambiguation heuristics | Medium |
| Platform type handling | Darwin vs Linux differences | Boolean representation bugs | Easy |
| No stack traces in binary | LLVM generates minimal debug info | Hard debugging | Medium |

---

## What Students Should Learn

### Simple Designs Have Hidden Complexity

ARO's "simple" Action-Result-Object syntax seemed easy to implement. But:
- Articles (`a`/`an`/`the`) created parsing ambiguity
- Prepositions required semantic classification
- Qualifier syntax (`<user: email>`) needed special handling
- String interpolation required multi-token emission

The simplicity of the surface syntax hides significant implementation complexity.

### Interop Layers Multiply Problems

Every language boundary creates friction:
- **Swift → C**: Manual memory management, no async
- **C → LLVM**: Manual struct layout, no type safety
- **LLVM → native**: Platform-specific linking

A bug at any layer is hard to diagnose because you lose language guarantees.

### "Code is Documentation" Requires Discipline

ARO's verbose syntax aims to be self-documenting. But:
- Bad variable names still make bad code
- Complex logic still needs comments
- The syntax enforces structure, not clarity

The language can encourage good practices; it can't enforce them.

### Trade-offs Are Real

Every design choice has costs:

| We chose | We got | We lost |
|----------|--------|---------|
| Textual LLVM IR | Simpler build, readable output | Type checking, performance |
| Immutable variables | Predictable data flow | Flexibility |
| Rigid syntax | Uniform tooling | Expressiveness |
| Event-driven model | Loose coupling | Explicit flow |
| @_cdecl bridge | C interop | Async support |

There are no free lunches in language design.

---

## Honest Assessment

ARO achieves its goals for a narrow use case: declarative, auditable business features with predictable execution. It's not a general-purpose language and shouldn't try to be.

The native compilation path works for some scenarios but has significant limitations. The interpreter is more reliable and should be the default choice.

The language design is opinionated—some developers will find it liberating, others constraining. That's intentional; ARO prioritizes team legibility over individual expressiveness.

For students: ARO is an example of what a constrained DSL looks like in practice. Study the trade-offs, not just the implementation.

---

## Future Directions

If we were to continue development:

1. **Fix NIO in binary**: Investigate Swift runtime initialization deeply
2. **Add optional types**: `<user: User>` syntax for explicit typing
3. **Improve error messages**: Source-mapped errors from LLVM failures
4. **Reduce prepositions**: Simplify to 3-4 with clear semantics
5. **Add debugging support**: Better stack traces in compiled mode

These are not planned—they're lessons for future DSL designers.

---

*Next: Appendix — Source Map*
