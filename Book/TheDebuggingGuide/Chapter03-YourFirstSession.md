# Chapter 3: Your First Session

*"If you can pause it, print it, and let it run, you can debug it."*

---

## 3.1 The four moves

A real debug session is a sequence of four moves repeated as often as needed: **pause**, **inspect**, **decide**, **resume**. Everything else this book teaches is a refinement of one of those four.

Open `Examples/HelloWorld` under the debugger:

```bash
aro debug ./Examples/HelloWorld
```

The debugger pauses at the entry — before any of your statements has run. This is *pause* number one, the easiest kind: every program pauses here.

## 3.2 Inspect: where am I, what's bound?

The prompt:

```
⏸  paused (entry) at main.aro:2 — Application-Start
   <Create> the <greeting: String> with the <_expression_> = "Hello, ARO World!".
(aro-dbg)
```

tells you the file, the line, the feature set, and the statement about to execute. Type `bt` (for "backtrace") to see the same information laid out:

```
(aro-dbg) bt
  Application-Start · Entry Point
  at main.aro:2
  <Create> the <greeting: String> with "Hello, ARO World!".
```

Right now, no user bindings exist. Type `p` (for "print") to confirm:

```
(aro-dbg) p
  <terminal> : Map<String, Unknown> = ["columns": 120, "rows": 36, …]
```

The `<terminal>` you see is a framework-supplied dict the runtime binds for every feature set; the user-visible bindings start empty. Underscore-prefixed bookkeeping names (`<_expression_>`, `<_with_>`, etc.) are filtered out of `p` output by default — they exist but they are not interesting to a debugger user.

## 3.3 Decide: step or continue?

`s` (step) advances one statement. `c` (continue) resumes until the next breakpoint or program end. There are also `n` (next, alias of step in Phase 1) and `f` (finish — run to end of feature set, used in Phase 3+ once call stacks land).

For HelloWorld, type `s`:

```
(aro-dbg) s

⏸  paused (step) at main.aro:3 — Application-Start
   <Log> <greeting> to the <console>.
(aro-dbg)
```

You moved one line. The `Create` ran. Print the bindings again:

```
(aro-dbg) p
  <greeting> : String = Hello, ARO World!
  <terminal> : Map<String, Unknown> = ["columns": 120, …]
```

`<greeting>` is now bound. The value is the literal string the `Create` produced. The line we are paused on (`Log <greeting>`) has not run — that is the convention: a checkpoint fires *before* the statement it points at executes.

## 3.4 Resume: run to the end

Type `c`:

```
(aro-dbg) c
[Application-Start] Hello, ARO World!

Program ended cleanly.
```

You wrote "Hello, ARO World!" to the console, returned an OK, and let the program exit. The session is over.

That is the full loop. The rest of this chapter walks the same loop with a breakpoint added, to show that *pause* doesn't have to be the entry.

## 3.5 Same session, with a breakpoint

Quit the debugger if you are still in it (`q`) and restart with a pre-set breakpoint:

```bash
aro debug --breakpoint 3 ./Examples/HelloWorld
```

This sets a location breakpoint on line 3 before execution begins. You can also set the same breakpoint interactively from inside the debugger — see Chapter 5 for the syntax.

Run it:

```
aro debug · 1.0.0 · HelloWorld
Use 'h' for help, 'q' to quit, 's' to step.

⏸  paused (entry) at main.aro:2 — Application-Start
   <Create> the <greeting: String> with "Hello, ARO World!".
(aro-dbg) c
```

The entry pause still fires — that one is unconditional. Type `c` and we go to the breakpoint:

```
⏸  paused (breakpoint (main.aro:3)) at main.aro:3 — Application-Start
   <Log> <greeting> to the <console>.
(aro-dbg) p
  <greeting> : String = Hello, ARO World!
(aro-dbg) c
[Application-Start] Hello, ARO World!

Program ended cleanly.
```

Notice the pause reason — `(main.aro:3)`. The debugger tells you *why* it paused. This matters more when you have several breakpoints and want to know which one matched.

## 3.6 The shape of every session ahead

Every session in this book — and almost every real one you will run on your own code — is the same loop:

1. Start the debugger pointed at a project.
2. Pause at the entry (or set a breakpoint and `c` to it).
3. Print to see the current bindings.
4. Step or continue based on what you learned.
5. Exit, either by hitting the program's natural end or by typing `q`.

You now have all four moves. The chapters that follow extend each one — Chapter 4 explains what a statement boundary really is, Chapter 5 walks the five kinds of breakpoint, Chapter 6 adds watch expressions. By Chapter 7 you are doing the same loop through an IDE; by Chapter 9 you are scrubbing through a recording of a session that already finished.

---

**Next:** Chapter 4 unpacks "statement boundary" — what counts as one step, what happens with lazy futures, and why the line you are paused on isn't always where the work happens.
