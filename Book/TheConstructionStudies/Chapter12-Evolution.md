# Chapter 12: The Evolution of ARO

## How a Language Finds Itself

Languages don't emerge fully formed. They get built, broken, used, debated, fixed, and rebuilt. ARO is no exception. This chapter is the retrospective — the honest account of the back-and-forth that turned a rough concept into a specification worth documenting.

If the earlier chapters read like confident architecture, this one reads like the diary. Same building, different perspective.

---

## The Original Bet

The core hypothesis was simple: business logic is mostly data transformation. You get some data from somewhere, do things to it, put results somewhere else. If you can make that pattern the *only* thing developers write, you get predictability for free.

Early ARO looked something like this:

```aro
(processOrder: Commerce) {
    Extract the <order> from the <request: body>.
    Validate the <order> with <schema>.
    Store the <order> into the <order-repository>.
    Return a <Created: status> with <order>.
}
```

Four statements. One direction of data flow. No branching. That was the vision.

The first thing that happened: everyone wanted branching.

---

## Statement Count: 5 → 9

The original grammar had five statement types: `AROStatement`, `PublishStatement`, `RequireStatement`, `MatchStatement`, and `ForEachLoop`. Five felt clean. Five felt principled.

Then we shipped the first real application and immediately needed to count. Not collection iteration — numeric counting. `for i from 1 to 10` is not the same as `for each item in items`. The grammar was technically expressive enough (you could simulate it with repositories and observers), but it was absurd in practice.

Range loops came first. Then while loops, because there are legitimately cases where you don't know the count upfront. Then `Break`, because without it, while loops have no exit. Finally, the pipeline operator (`|>`) added `PipelineStatement` for chaining multiple actions concisely.

Four new statement types later, the grammar still felt principled — just more honest about what people actually need.

| Added In | Statement | Why |
|----------|-----------|-----|
| ARO 0.7 | `RangeLoop` | Numeric iteration without collection overhead |
| ARO 0.7 | `WhileLoop` | Unknown-count iteration |
| ARO 0.7 | `BreakStatement` | WhileLoop exit |
| ARO 0.7 | `PipelineStatement` | Chained action composition via `\|>` operator (ARO-0067) |

The lesson: you discover the grammar by building with it, not by designing it on paper.

---

## The Verb Classification Problem

Early on, verbs were informal. The parser recognized action brackets, the runtime looked up the verb, and everyone hoped for the best.

The problem showed up when we started writing the compiler. The interpreter (`FeatureSetExecutor`) had developed a set of special-case checks for certain verbs:

- Some verbs needed to run even when their object was a literal (like `Schedule the <tick> with 2.`)
- Some verbs couldn't rebind variables that already existed
- Some verbs should short-circuit the feature set on success

These rules lived in the interpreter's execution logic. When we built the compiler, we duplicated them. When we added new verbs, we'd update one and forget the other. Bugs appeared that were impossible to reproduce in one mode but reliable in the other.

The fix was `VerbSets.swift` — a shared module with ten named sets of verbs:

| Category | Role |
|----------|------|
| `updateVerbs` | Allow rebinding existing variables |
| `createVerbs` | New entity creation |
| `responseVerbs` | Skip the expression shortcut |
| `serverVerbs` | Force execution even with literals |
| `storeVerbs` | Trigger repository observers |
| … | |

Both interpreter and compiler reference the same module. Adding a new verb means touching one file. The parity bugs stopped.

This is a tiny architectural change with outsized impact. Shared canonical vocabulary between two execution modes is not glamorous. It's also exactly right.

---

## From Text IR to Swifty-LLVM

The original compiler generated LLVM IR as strings. It looked like this internally:

```text
emit("define ptr @aro_fs_\(funcName)(ptr %0) {")
emit("entry:")
emit("  %1 = alloca ptr")
// ... hundreds of emit() calls
```

This works. LLVM IR is just text. You can write it character by character.

The problem: text has no type system. You can emit `store i64 %x, ptr %y` when the types don't match, and you won't find out until `llc` tries to compile it and throws a cryptic error pointing at the IR file. Debugging generated code through text diffs is painful.

Swifty-LLVM changed this. It's a Swift wrapper around LLVM's C API that gives you typed objects — `Function`, `BasicBlock`, `IRValue` — that the compiler checks at build time. The same bad store now fails when you write the generation code, not when you run it.

The migration was non-trivial. The entire `LLVMCodeGenerator.swift` was rewritten — 2057 lines from scratch, using the API instead of strings. Worth it.

The cost: LLVM 20 is now a build dependency. The build setup got more complex (`pkg-config`, library paths, platform-specific linkage). CI environments that don't have LLVM installed can't build the native compilation path.

That's the trade-off in one sentence: **better developer experience for the compiler developer, harder deployment for the build environment.**

---

## The Dual-Mode Parity Problem

ARO runs in two modes: interpreted (`aro run`) and compiled (`aro build`). The interpreter runs Swift code directly — actors, async/await, typed events. The binary runs LLVM-generated machine code that calls back into Swift via C-callable functions.

For a long time, these diverged in subtle ways.

### Integer Division

The interpreter's expression evaluator returned `Double` for any division, even when both operands were integers. `80 / 3 = 26.666...`. The binary returned `26` — integer floor division. Same ARO code, different results.

Fix: the interpreter now returns integers when both operands are integers. Simple, but it required noticing the bug and knowing where to look.

### String Repetition in Binary Mode

`" " * 17` should produce 17 spaces. In the interpreter: correct. In binary mode: `"0"`. The binary's expression evaluator handled numeric multiplication but fell through to `0` for string repetition. Nobody tested it because it worked in the interpreter.

Fix: add string repetition handling to the binary expression evaluator.

### Events in Binary Mode

The interpreter uses typed Swift events — `UserCreatedEvent`, `FileModifiedEvent`, `SocketConnectedEvent` — each a distinct protocol conformance. The binary can't use these directly; Swift's type metadata isn't accessible from LLVM-generated code.

The solution: **DomainEvent co-publishing**. Every action that emits a typed event now also emits a generic `DomainEvent` with the same payload, serialized. Binary handlers subscribe to `DomainEvent("UserCreated")` instead of `UserCreatedEvent`. The payload schema is documented and tested.

This is an extra layer, and extra layers add maintenance surface. But the alternative — redesigning events to work in both modes uniformly — was much larger. Pragmatism won.

The co-publishing pattern now covers:
- Domain events (Emit action)
- State transitions (Accept action)
- Notifications (Notify action)
- File events (FileSystemService)
- Socket events (SocketServer)
- Schedule timers

### The `mode: both` Test Directive

Every example has a `test.hint` file. Originally these specified `mode: interpreter` or `mode: binary`. As parity improved, examples were updated to `mode: both` — running the full test in both modes and comparing output.

At the time of writing, 81 of 85 examples pass both modes. The remaining four have known root causes tracked as issues:

| Example | Problem | Issue |
|---------|---------|-------|
| SocketClient | `ManagedAtomic` SIGSEGV in binary | #134 |
| MultiService | Depends on SocketClient | #134 |
| Scoping | AppReady Handler missing in binary | #135 |
| EventReplay | C bridge gap for replay events | #136 |

Four known problems, all tracked. That's actually a reasonable state for a 0.7 release.

---

## The Plugin System Evolution

ARO's plugin system went through two naming schemes.

The original design specified plugin qualifiers with a `handler:` field inside the `provides:` array in `plugin.yaml`:

```yaml
provides:
  - type: swift-plugin
    path: Sources/
    handler: collections   # qualifiers accessed as collections.pick-random
```

This worked, but felt inconsistent — `handler` is also a word used for event handlers in ARO itself. Naming collision in documentation was causing confusion.

The revised design uses a top-level `handle:` field (PascalCase, required):

```yaml
name: plugin-collections
version: 1.0.0
handle: Collections

provides:
  - type: swift-plugin
    path: Sources/
```

Qualifiers are now accessed as `<value: Collections.pick-random>` — the namespace comes from the canonical `handle`, not from a buried field inside `provides`. The old `handler:` field is still accepted with a deprecation warning.

The migration was two-line per plugin. The naming improvement was worth it.

---

## HTTP in Binary Mode: The Ongoing Gap

SwiftNIO, the async networking library used for ARO's HTTP server, relies on Swift type metadata that isn't properly initialized when the Swift runtime starts from LLVM-generated code. The crash happens in `_swift_allocObject_` when NIO tries to create socket channels.

The workaround: compiled binaries use a native BSD socket HTTP server instead of NIO. It works for basic cases but lacks NIO's performance and robustness.

The root cause isn't fully understood. It's somewhere in the Swift runtime initialization sequence — the order in which Swift's reflection metadata gets set up relative to when LLVM-generated main runs. Fixing it would require:

1. Understanding exactly which metadata NIO requires at initialization
2. Finding where that initialization happens in the Swift runtime startup
3. Either triggering it earlier, or restructuring the binary's entry point to guarantee order

This is not a quick fix. It's in the known limitations section, not the roadmap.

---

## The KeyboardService Pattern

Building terminal applications with ARO revealed a gap in the binary mode event system. Keyboard input requires:

1. A service that reads raw keystrokes in a background loop
2. Publishing a `DomainEvent("KeyPress")` for each keystroke
3. Registering that event in the binary's handler registration table

All three pieces had to be added together. The keyboard service had to be registered in `AROCContextHandle` (the binary's context object). The `readLoop` had to publish `DomainEvent` alongside any Swift events. The `LLVMCodeGenerator` had to learn to detect `KeyPress Handler` feature sets.

The pattern that emerged: **when adding any new event source, touch four places**:

1. The Swift-side service (publish DomainEvent)
2. RuntimeBridge (register a `@_cdecl` handler registration function)
3. LLVMExternalDeclEmitter (declare the new C function)
4. LLVMCodeGenerator (detect the handler pattern and call the registration function)

Chapter 11 documents this pattern formally. It was learned by adding socket events, file events, state transitions, and keyboard events — each time discovering a piece that was missing.

---

## Streaming Wasn't Streaming

ARO-0051 introduced `listStream` as the O(1)-memory answer to `List the <entries: recursively>`. The claim was true in the spec and false in the code. On a 200k-file home directory the process peaked at 1.7 GB RSS and then settled back to 192 MB when the scan completed. Not a leak — a buffering mistake.

The implementation looked right at a glance:

```swift
AsyncThrowingStream { continuation in
    Task {
        while let url = enumerator.nextObject() as? URL {
            continuation.yield(entry)
        }
        continuation.finish()
    }
}
```

A producer Task walks the tree; each entry is yielded to the consumer. What's wrong with that?

`AsyncThrowingStream` defaults to an **unbounded** buffering policy. `yield` never blocks. The producer Task ran flat out through the entire tree, pushing hundreds of thousands of `[String: any Sendable]` dicts into the stream's internal buffer, while the for-each consumer drained them at actor-hop speed. Peak memory was proportional to tree size, not to iteration depth.

The fix was small and the lesson is not. The replacement uses the pull-based initializer:

```swift
AsyncThrowingStream { () async throws -> Entry? in
    lazyList.next()   // advances the enumerator on demand
}
```

The closure runs **exactly once per consumer `next()` call**. No producer task, no buffer, no race between enumeration speed and consumption speed. Peak memory drops from O(tree) back to the O(1) that the proposal described.

The lesson: **"streaming" is a promise about memory, not about API shape**. Wrapping something in `AsyncSequence` doesn't make it lazy — you have to verify that pull pressure actually reaches the source. Every `AsyncThrowingStream` initializer in the codebase is now a thing to audit: if it spawns a Task that loops and yields, it has an unbounded buffer unless you prove otherwise.

---

## The Convenience-by-Default Trap

Two smaller bugs in the same release had the same shape: a feature was convenient when it worked and silent when it didn't.

**Format-aware `Read`.** ARO-0040 let you write `Read the <users> from "./users.json"` and get parsed JSON back. The file extension determined the format. This is lovely when the file contains JSON — and a silent failure when `./bigfile.txt` contains a million integers. The `.txt` extension triggers the key=value parser, no valid pairs are found, and the variable is bound to `[:]`. The next statement fails on the empty dict with a message that never mentions the extension.

The fix added a `:raw` opt-out (plus explicit format qualifiers that also solve the inverse case). The prior legacy `as String` hatch existed but wasn't discoverable — developers renamed files to `.dat` instead. The lesson: **any convenience that is silent when wrong needs a visible opt-out, and the opt-out name should be the first thing someone Googles**.

**REPL terminal.** `aro run` registers `TerminalService` at startup if stdout is a TTY. The REPL session never registered it. The REPL is always interactive, so `<terminal>` reported `is_tty: false`, 80×24, no color — and there was nothing in the error path to notice, because reading a hardcoded default is not an error. The fix was one TTY-gated `context.register(TerminalService())` in `REPLSession.init()`, mirroring the production path byte for byte.

Neither of these was hard to fix. Both were hard to *notice*. The common thread: a feature that degrades quietly to a plausible-looking default is worse than a feature that throws. The graceful fallback is load-bearing for exactly the people who didn't want it.

---

## What We'd Design Differently

Looking back with honest eyes:

**Prepositions were too subtle.** The idea that `from` means "source" and `to` means "destination" and `with` means "modification" — this was elegant in the spec and confusing in practice. Developers guessed prepositions by feel and were often wrong. We'd reduce to three prepositions with clear, unambiguous rules.

**Business activity scope was too clever.** Variables published in "Security" being visible to other "Security" feature sets but not to "Commerce" — it sounds principled. In practice, developers expected either global scope or lexical scope. Neither is what they got. A simpler visibility model would reduce cognitive load.

**No explicit types cost us.** When variables have no declared type, IDE tooling can't complete them, error messages can't reference expected types, and documentation generators can't show types. The OpenAPI contract provides types for HTTP inputs, but only for inputs. Everything else is inferred by human readers.

**Text-based LLVM IR was always wrong.** Starting with text IR saved a few days of understanding the C API. It cost weeks of debugging opaque `llc` errors. The right starting point was the typed API.

---

## The Arc

ARO 0.1 was a proof of concept that could parse and execute five statement types.

ARO 0.7 is a system with:
- Nine statement types
- 61 built-in actions
- A plugin system supporting four languages
- Dual-mode execution (interpreter and native binary)
- A native BSD HTTP server for binary mode
- Streaming execution for large datasets
- Regex, dates, templates, WebSockets, metrics, CLI parameters

The gap between those two states is not clever design. It's iteration. Each use case revealed something missing. Each bug revealed an assumption. Each platform difference revealed something taken for granted.

The spec in `Proposals/` is not prescient — it's documentation that followed what worked. The language found itself through use.

That's how languages actually happen.

---

## For the Next Implementer

If you're building on ARO, or building something like it:

**Start with the interpreter.** It's slower, but you can fix it. The compilation path multiplies every design mistake.

**Test dual-mode from day one.** If you build two execution modes, they will diverge. The longer you wait to test both, the more they diverge.

**Name things carefully.** `handler:` vs `handle:`, `activity` vs `business-activity` — naming is the cheapest design decision with the longest reach.

**Make the verb list canonical.** Implicit verb classification in multiple places will bite you every time you add a verb.

**Write the happy path; let the runtime write the errors.** It sounds risky. It's actually liberating.

---

*End of The Construction Studies*

