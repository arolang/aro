# Chapter 4: The Statement-Boundary Model

*"The line you read is the unit you step. The line that runs may be somewhere else."*

---

## 4.1 What counts as one step

Every statement in ARO ends with a period:

```aro
Extract the <data> from the <request: body>.
Create the <user> with <data>.
Emit a <UserCreated: event> with <user>.
Return a <Created: status> with <user>.
```

Each period is a checkpoint. `step` moves the cursor from one period to the next. There is no smaller granularity to choose — no expression-level stepping, no operator-level stepping. The unit of code you read is the unit of code you step.

This matters for two reasons. First, the debugger never has to ask "which sub-step did you mean?" Second, the source you read in your editor matches the source the debugger reports — there is no inlined frame, no implicit conversion, no operator-resolution step that surprises you.

## 4.2 Lazy execution: order on the page ≠ order in time

ARO actions are lazy by default. A non-effectful statement like

```aro
Retrieve the <user> from the <users-repository>.
```

doesn't contact the repository when you read the line. It returns a future. The actual repository call runs the first time something reads `<user>` — a `Return`, an `Emit`, a `with` argument, a `when` guard.

The implication for debugging: the line that *triggers* a force is not always the line where the work *originally was*. If you step over a `Retrieve` and the program runs slowly, the slowness will appear on whatever statement happens to read `<user>` — not on the `Retrieve` itself.

The debugger surfaces this in two ways:

- **Source-order stepping** advances by the order of the file. This matches what you read. Default.
- **Force-order stepping** (Phase 6) advances by the order the runtime forces futures. This matches what happens.

For most workflows source-order is enough. When you find yourself confused — "why did the error point at line 7 when the bug is clearly in line 3?" — flip to force-order and the answer becomes obvious.

## 4.3 Effects are sequential anyway

Lazy execution applies to *non-effectful* actions: `Compute`, `Retrieve`, `Extract`, `Validate`, etc. **Effects** — `Log`, `Store`, `Emit`, `Commit`, `Send`, `Push`, `Stage`, etc. — stay in source order. The runtime forces every future an effect depends on *before* the effect runs, exactly as written.

This is why a session like

```aro
Retrieve the <user> from the <users-repository>.
Log <user> to the <console>.
```

prints the user record in source order — the `Log` is an effect, the runtime forces the `Retrieve` future before logging, the print arrives at the moment you'd expect.

For the debugger this means: pauses on effect statements are observationally identical to pauses on lazy statements that have been forced. You won't see the difference until you set a breakpoint on a lazy statement that never gets read — at which point the pause fires and the runtime runs the action right then, just so you can inspect the result.

## 4.4 Step into / step over / step out

Phase 1 of the debugger treats `step` and `step over` (alias `next`) identically because Phase 1 hasn't grown a call stack model yet. The distinction lands in Phase 3:

- **step (`s`)** — into the next emit / sub-graph call if the current statement triggers one.
- **next (`n`)** — over the next emit / sub-graph call.
- **finish (`f`)** — run to the end of the current feature set and pause when the parent caller resumes.

For a `createUser` feature set that emits `UserCreated`:

```aro
Emit a <UserCreated: event> with <user>.   ← paused here, about to fan out
```

`s` follows the emit into the first statement of the `UserCreated Handler` feature set. `n` lets the handler run to completion and pauses on the next statement in `createUser`. `f` runs the rest of `createUser` and pauses where its caller resumes (typically the HTTP framework's per-request driver).

## 4.5 Events as call edges

When a statement publishes an event, every matching handler becomes a new frame on the *causal call stack*. The chain at any pause is:

```
HTTP POST /users  →  createUser  →  Emit UserCreated  →  SendWelcomeEmail
                                                       →  AuditLog
```

`bt` shows the chain. `step` from a paused `Emit` follows the first handler. `step out` returns past the emit.

This is what makes the debugger useful for event-driven systems. A conventional stack-frame debugger has no way to represent "X was caused by Y emitted from Z"; the ARO debugger treats it as the obvious thing it is.

## 4.6 What "before this statement" means

Every pause is *before* the named statement executes. Bindings produced by previous statements are visible; bindings produced by the named statement are not.

So at this pause:

```
⏸  paused (step) at main.aro:5
   <Create> the <user> with <data>.
(aro-dbg) p
  <data> : Map<String, Unknown> = {...}      ← line 4 already ran
  <terminal> : Map<String, Unknown> = {...}
```

`<data>` is visible because the `Extract` on line 4 already ran. `<user>` is *not* visible because the `Create` on line 5 is the next thing to happen.

If you `s` from here, the `Create` runs and the next pause shows `<user>` bound. This is the universal contract of every checkpoint, every breakpoint, every event-checkpoint, every error-checkpoint: pause first, run second.

## 4.7 What it does *not* do

The statement-boundary model is opinionated. It deliberately does not support:

- **Expression-level stepping.** There is no expression-level granularity in the language; there is none in the debugger either.
- **Stepping into action implementations.** Native action code (the Swift / Rust / C / Python that implements `Create`, `Compute`, `Emit`) is opaque from the debugger's perspective. Plugin frames hand off to `lldb` / `debugpy` in a separate follow-up (#230 plugin section).
- **Mutating bindings from the prompt.** You can read with `p`; you cannot write. Mutating-and-replay is the recording / replay workflow in Chapter 9, not an interactive `set` command.

These omissions are deliberate. Each one removes a class of "what did the debugger just do" surprise. The model is small because the language is small.

---

**Next:** Chapter 5 walks the five flavors of breakpoint, from the location bp you already met to event and error-any.
