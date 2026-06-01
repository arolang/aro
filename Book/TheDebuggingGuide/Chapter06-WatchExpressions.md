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
(aro-dbg) w <users-repository: count>
```

Every pause from then on prints each one.

To list:

```
(aro-dbg) w
  0: <count>
  1: <user>
  2: <users-repository: count>
```

To delete by index:

```
(aro-dbg) dw 1
deleted watch #1
```

## 6.2 What watches are for

Three workflows show up over and over.

**Tracking a value across many statements.** You suspect `<count>` is being mutated unexpectedly. Step through the feature set; if `<count>` ever changes between two pauses, the watch makes it visible without you having to print on every line.

**Confirming an invariant.** A `<user: role>` should always be `"admin"` in this feature set. Watch it; if it ever isn't, you see at a glance.

**Comparing two values over time.** Watch `<users-repository: count>` and `<expected-count>` simultaneously. If they drift, you see the drift.

The watch list is part of the session state — it goes away when you quit. The recording / replay flow in Chapter 9 lets you reproduce a session against an existing trace; the watches you set during replay are independent of the watches you set during the original run.

## 6.3 The current evaluator

Phase 1's watch implementation is intentionally simple. A watch expression of the form `<name>` looks up the binding's *string preview* from the most recent snapshot and prints it. The label can include a qualifier (`<user: id>`) but the resolution does not currently walk through ARO's full expression grammar — that lands when watch expressions adopt the same path as conditional-breakpoint predicates (chapter 5).

Until then:

- `<name>` and `<name: qualifier>` work.
- Arithmetic and comparisons (`<a> == <b>`, `<count> + 1`) do not.
- Repository navigation (`<users-repository: count>`) works because the snapshot captures it as a string already.

When the predicate-evaluator path opens up to watches (issue #230 follow-up), this chapter will gain examples of arbitrary expression watches.

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

When the debugger speaks DAP (chapter 7), watch expressions get their own column in VS Code and IntelliJ's debug pane. The CLI watch and the IDE watch share the same controller state — set a watch in the CLI then connect a DAP client, the watch is there. Set a watch in VS Code then quit and reattach, the watch is *not* preserved (the DAP session is the storage scope, not the project).

This is consistent with the CLI's session-scope rule: watch state lives in the controller, not on disk.

---

**Next:** Chapter 7 walks the DAP bridge — what happens when you launch the debugger from VS Code's Run-and-Debug pane, from IntelliJ's run config, or from `nvim-dap`.
