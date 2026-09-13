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

> **Scope note.** A deferred action still *starts* at its own statement — only
> the wait moves to the first read. So the divergence below is about where a slow
> statement's cost lands, not about work happening out of order. Effects never
> defer. ARO-0088 §2 and §3 are the specification.

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

`s`, `n` and `f` are all accepted at the prompt, and they map to distinct step modes on the controller — `.stepIn`, `.stepOver`, `.stepOut`. But the checkpoint does not yet act on the distinction: any of the three pauses at the next statement boundary the runtime reaches, wherever it is. In practice `s`, `n` and `f` are three spellings of "advance one statement."

The intended distinction, when the controller grows a frame model:

- **step (`s`)** — into the next emit / sub-graph call if the current statement triggers one.
- **next (`n`)** — over it.
- **finish (`f`)** — run to the end of the current feature set and pause when the parent resumes.

Today all three follow the emit. Pause on an `Emit` and press `n` expecting to stay in the emitting feature set and you land in a handler instead — which is a surprise worth knowing before it happens to you mid-session.

## 4.5 Events as call edges

Stepping does cross the event boundary. Pause on an `Emit` and step, and the next pause is inside a handler:

```
⏸  paused (breakpoint (verb Emit)) at main.aro:7 — Application-Start
   <Emit> the <NumberTriggered: event> with the <_expression_> = "Event triggered!".
(aro-dbg) s

⏸  paused (step) at main.aro:4 — Handler One
   <Log> "Handler #1 executed" to the <console>.
```

That is the useful half. Two things about it are not what a stack-frame debugger would give you, and the chapter would be lying if it left them out.

**Handlers run concurrently, so the pauses interleave.** The event bus gives each subscriber its own Task. The controller is an actor, so only one checkpoint is *served* at a time, but they queue in whatever order the scheduler produced — five handlers on one event pause in a different order on different runs, and the prompt for one can be printed while another's banner is still arriving. Read the feature-set name on each banner rather than assuming you are still where you were.

**There is no causal backtrace.** `bt` prints the current pause and nothing else — feature set, business activity, file, line, statement:

```
(aro-dbg) bt
  Handler One · NumberTriggered Handler
  at main.aro:4
  <Log> "Handler #1 executed" to the <console>.
```

It does not print the chain that led there. The `PauseInfo` the controller hands the frontend carries one location, not a stack; DAP's `stackTrace` request answers with an empty frame list for the same reason (appendix A.6). Reconstructing "X was caused by Y emitted from Z" is the natural shape for an event-driven debugger and is what the causal call stack in the glossary describes — it is a design the runtime is built toward, not a thing you can read off the prompt today. Until it lands, the `--record` JSONL from chapter 9 is the honest way to see the whole cascade: every pause in order, with its feature set, in one file.

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

**Next:** Chapter 5 walks the six flavors of breakpoint, from the location bp you already met to logpoints, event and error-any.
