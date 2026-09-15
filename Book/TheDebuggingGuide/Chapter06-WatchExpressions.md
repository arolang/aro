# Chapter 6: Watch Expressions

*"A watch is a question you ask every time you pause, automatically."*

---

## 6.1 What a watch does

A watch expression is a short label for a binding (or, in a future iteration, an ARO expression) whose current value is printed at every pause without you having to type `p`. It does not trigger a pause; it merely *surfaces* a value while you are paused for another reason.

Set one with `w`:

```
(aro-dbg) w <count>
watching: <count>
```

The next pause prints it:

```
⏸  paused (step) at main.aro:7 — Application-Start
   <Log> <count> to the <console>.
   watch <count> = 42
(aro-dbg)
```

You can have several:

```
(aro-dbg) w <count>
(aro-dbg) w <user>
(aro-dbg) w <total>
```

Every pause from then on prints each one, in the order you added them:

```
   watch <count> = 42
   watch <user> = ["id": 530, "name": "Ada"]
   watch <total> = 99.95
```

To list:

```
(aro-dbg) w
  0: <count>
  1: <user>
  2: <total>
```

To delete by index:

```
(aro-dbg) dw 1
deleted watch #1
```

## 6.2 What watches are for

Three workflows show up over and over.

**Tracking a value across many statements.** You suspect `<count>` is being mutated unexpectedly. Step through the feature set; if `<count>` ever changes between two pauses, the watch makes it visible without you having to print on every line.

**Confirming an invariant.** A `<role>` should always be `"admin"` in this feature set. Watch it; if it ever isn't, you see at a glance.

**Comparing two values over time.** Watch `<actual-count>` and `<expected-count>` simultaneously. If they drift, you see the drift.

The watch list is part of the session state — it goes away when you quit. The recording / replay flow in Chapter 9 lets you reproduce a session against an existing trace; the watches you set during replay are independent of the watches you set during the original run.

## 6.3 What a watch may be

A watch is an **ARO expression**, evaluated against the live context at every
pause — the same `Lexer → Parser → ExpressionEvaluator` pipeline a conditional
breakpoint uses (chapter 5.4). So a watch accepts whatever `b 5 if …` accepts:

```
(aro-dbg) w <user>
(aro-dbg) w <user: id>
(aro-dbg) w <users-repository: count>
(aro-dbg) w <limit> > 50
...
   watch <user> = ["id": 530, "name": "Ada"]
   watch <user: id> = 530
   watch <users-repository: count> = 1
   watch <limit> > 50 = true
```

- **`<name>`** — the binding.
- **`<name: qualifier>`** — a field, a date part, a repository's `count`.
- **Arithmetic and comparisons** — `<a> == <b>`, `<count> + 1`.

An expression that cannot be evaluated at this pause prints `(unresolved)`
rather than stopping the program: a name not yet bound reads as unresolved
early in a feature set and resolves once the binding exists, which is often
exactly what you want to watch for.

Until GitLab #567 the evaluator was a string match against the pause snapshot —
it compared the bare binding name, so `<user: id>` matched nothing and printed
`(unresolved)` forever, accepted at `w` time without complaint. Only `<name>`
worked. If you remember working around that by binding a `Compute` just to
watch it, you no longer need to.

## 6.4 What watches do not do

A watch never causes a pause. It is a passive printer. If you want to stop *when* a value reaches a state, you need a conditional location breakpoint (Chapter 5.4), not a watch.

A watch also doesn't change the bindings it references. There is no "watch and mutate" idiom in the prompt; bindings stay read-only until you re-run the program with edits.

## 6.5 When to use which

The decision matrix between watches and conditional breakpoints is short:

- **You want to see the value but keep moving:** watch.
- **You want to stop when the value reaches a condition:** conditional breakpoint.
- **You want to see *all* the bindings, not just one:** `p`. Don't watch everything; the prompt becomes noisy.

The print command `p` is the third member of the family. It is a one-shot, all-bindings snapshot. The watch is the ongoing, named-bindings projection of that snapshot.

## 6.6 Watches across DAP

They don't, yet. Watches live on the controller, and the controller is shared between the CLI and DAP frontends — but the bridge has no `evaluate` handler, so nothing pushes them to the editor's Watch pane, and the editor has no way to add one (chapter 7.7). A watch you set at the CLI prompt prints at CLI pauses only.

What an editor does get is the full `variables` response: every binding at the pause, which for most sessions is the same information less selectively. Wiring `evaluate` through to the watch list is part of the DAP-parity follow-up in issue #230.

Either way the CLI's session-scope rule holds: watch state lives in the controller, not on disk. Quit the debugger and the watches are gone.

---

**Next:** Chapter 7 walks the DAP bridge — what happens when you launch the debugger from VS Code's Run-and-Debug pane, from IntelliJ's run config, or from `nvim-dap`.
