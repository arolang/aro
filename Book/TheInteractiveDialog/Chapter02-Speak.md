# Chapter 2: Speak

*"A statement is a complete thought. End it with a period."*

---

## Your First Words

Type this:

```
aro> Set the <greeting> to "Hello, World".
=> OK
```

You've just spoken your first ARO statement. Let's break it down:

- `Set` — The action (what to do)
- `the <greeting>` — The result (what to create)
- `to "Hello, World"` — The object (the value)

The `=> OK` confirms: the statement executed. The variable `greeting` now exists.

The verb is written bare. You may see `<Set>` with angle brackets in older
material — including, for now, the REPL's own `:help` — but that spelling was
removed from the language and fails to parse. Angle brackets are for the
*result* and the *object*, never the action.

## Seeing the Result

Want to see what you created? Log it:

```
aro> Log <greeting> to the <console>.
[_repl_session_] Hello, World
=> OK
```

The string appears — prefixed with the name of the feature set it was logged
from. At the prompt every statement runs inside a synthetic feature set called
`_repl_session_`, so that is the name you see. (Chapter 1's piped-stdin path
drops the prefix; the interactive prompt keeps it.)

Then `=> OK`. Every statement returns something.

## Immediate Feedback

This is the power of the REPL: immediate feedback. No files. No compilation. You speak; ARO responds.

Try some arithmetic:

```
aro> Set the <x> to 10.
=> OK

aro> Set the <y> to 20.
=> OK

aro> Compute the <sum> from <x> + <y>.
=> OK
```

`=> OK` means "that worked," not "that produced nothing." A statement that
binds a result reports `OK` and the value goes into the session; ask for it
with `:vars` (chapter 3) or read it back with a `Log`:

```
aro> Log <sum> to the <console>.
[_repl_session_] 30
=> OK
```

## Quick Expressions

Sometimes you just want to calculate something without binding it:

```
aro> 2 + 2
=> 4

aro> "hello" ++ " " ++ "world"
=> "hello world"
```

The REPL evaluates bare expressions too. No action needed — and *these* are the
lines that come back with a value rather than `OK`, because there is no
binding for the value to go into. `++` concatenates strings.

## Errors as Teachers

Make a mistake. It's safe here.

```
aro> Compute the <result> from <undefined> + 1.
Error: Undefined variable: undefined
```

The REPL doesn't crash. It tells you what went wrong, and you try again. When
the failure happens inside the runtime rather than the parser, you get ARO's
full error block — the feature set, the business activity, and the statement,
in the shape ARO-0006 describes:

```
aro> Flurble the <x> to the <console>.
Error: Runtime Error: Cannot flurble the x to the console.
  Feature: _repl_session_
  Business Activity: Interactive
  Statement: <Flurble> the <x> to the <console>.
```

Note what that second example does *not* say: there is no "unknown action,
did you mean…". ARO's verb vocabulary is open — an unrecognised verb is
carried through to the runtime rather than rejected at parse time — so a
misspelling is caught by the failure it causes, not by the name itself.
Sometimes it is not caught at all: `Compuet the <r2> from 1 + 1.` binds
`r2` to `2` and answers `=> OK`. Read your verbs.

## The Period

Every statement ends with a period. It's ARO's way of knowing you're done:

```
aro> Set the <name> to "Alice".
=> OK
```

Forget it and the statement fails on the spot — the REPL does not wait for a
period on the next line:

```
aro> Set the <name> to "Alice"
Error: Expected '.', but got }
```

What *does* make the REPL wait is an unclosed bracket, brace, parenthesis, or
string. That is what the continuation prompt is for, and chapter 4 uses it for
multi-line objects and feature sets:

```
aro> Create the <config> with {
...>   host: "localhost",
...>   port: 8080
...> }.
=> OK
```

The `...>` prompt means "I'm listening for more." Close the brace and the
statement runs.

---

**Next: Chapter 3 — Remember**
