# Chapter 7: Depart

*"Take your conversation with you."*

---

## Nothing Is Lost

Every statement you've typed and every feature set you've defined can leave the
session as ordinary ARO source. The variables cannot — they are session state,
and the session ends when you do. What survives is the *code that produced*
them, which is the part worth keeping.

## Export Your Session

The `:export` command captures your session as a proper `.aro` file:

```
aro> Set the <base-price> to 100.
=> OK

aro> Compute the <tax> from <base-price> * 0.2.
=> OK

aro> Compute the <total> from <base-price> + <tax>.
=> OK

aro> :export
(* Generated from ARO REPL session *)
(* Date: 2026-09-07T20:19:28Z *)

(REPL Session: Interactive) {
    Set the <base-price> to 100.
    Compute the <tax> from <base-price> * 0.2.
    Compute the <total> from <base-price> + <tax>.
}
```

Your exploration becomes code. Feature sets you defined are emitted first, in
their own right; the loose statements are gathered into one `REPL Session`
feature set after them. Only statements that succeeded are included, so a
session full of typos exports clean.

## Save to File

```
aro> :export ./pricing.aro
Exported to ./pricing.aro
```

The file is nearly ready. Two edits stand between it and `aro run`: it has no
`Application-Start`, and the generated feature set has no `Return`. Rename the
header to `(Application-Start: Pricing)`, add a `Return an <OK: status> for the
<pricing>.` at the end, and it runs.

## Export as Test

`--test` writes the same statements into a `Test`-activity feature set:

```
aro> :export --test ./pricing-test.aro
Exported to ./pricing-test.aro
```

```aro
(* Generated test from ARO REPL session *)
(* Date: 2026-09-07T20:19:34Z *)

(REPL Test: Test) {
    Set the <base-price> to 100.
    Compute the <tax> from <base-price> * 0.2.
    Compute the <total> from <base-price> + <tax>.
}
```

The exporter can also emit an assertion after a statement, in the ARO-0015
shape — `Assert the <total> with 120.` — but only for statements whose result
came back as a *value*, and at the prompt a binding statement comes back as
`OK` (chapter 2). In practice that means the assertions are yours to add:

```aro
    Compute the <total> from <base-price> + <tax>.
    Assert the <total> with 120.
```

`aro test ./pricing-test.aro` then runs it.

## Loading a File Back

`:load` reads a `.aro` file and executes it into the current session — the
counterpart to `:export`, and the way to start a session from a prepared
setup:

```
aro> :load ./pricing.aro
```

There is no `:save`/`:load` pair for session *state*; `:load` takes ARO source,
not a session snapshot. Re-running the exported statements is how you get back
to where you were, which is also why the export is worth taking.

## The Goodbye

When you're ready:

```
aro> :quit
Goodbye!
```

Or press `Ctrl+D` on an empty line.

The prompt disappears. You return to your shell. But everything you learned stays with you.

---

## The End of the Beginning

You've learned to:

- **Enter** the REPL
- **Speak** in statements
- **Remember** with variables
- **Define** feature sets
- **Command** the REPL
- **Extend** with events and plugins
- **Depart** with your work saved

This is just the beginning. The REPL is your laboratory. Use it to explore ARO's full power—actions, events, HTTP, files, sockets, and more.

The prompt awaits.

```
aro> _
```

---

*"The Dialog is how I learned ARO. Not from documentation—from conversation."*
