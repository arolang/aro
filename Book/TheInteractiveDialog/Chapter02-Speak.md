# Chapter 2: Speak

*"A statement is a complete thought. End it with a period."*

---

## Your First Words

Type this:

```
aro> <Set> the <greeting> to "Hello, World".
=> OK
```

You've just spoken your first ARO statement. Let's break it down:

- `<Set>` — The action (what to do)
- `the <greeting>` — The result (what to create)
- `to "Hello, World"` — The object (the value)

The `=> OK` confirms: the statement executed. The variable `greeting` now exists.

## Seeing the Result

Want to see what you created? Log it:

```
aro> <Log> <greeting> to the <console>.
Hello, World
=> OK
```

The string appears. Then `=> OK`. Every statement returns something.

## Immediate Feedback

This is the power of the REPL: immediate feedback. No files. No compilation. You speak; ARO responds.

Try some arithmetic:

```
aro> <Set> the <x> to 10.
=> OK

aro> <Set> the <y> to 20.
=> OK

aro> <Compute> the <sum> from <x> + <y>.
=> 30
```

Notice that `<Compute>` returns the computed value directly. When an action produces a meaningful result, you see it.

## Quick Expressions

Sometimes you just want to calculate something without binding it:

```
aro> 2 + 2
=> 4

aro> "hello" ++ " " ++ "world"
=> "hello world"
```

The REPL can evaluate bare expressions too. No action needed.

## Errors as Teachers

Make a mistake. It's safe here.

```
aro> <Compute> the <result> from <undefined> + 1.
Error: Undefined variable 'undefined'

  Suggestion: Use :vars to see available variables
```

The REPL doesn't crash. It teaches. It tells you what went wrong and how to fix it.

Try misspelling an action:

```
aro> <Compuet> the <result> from 1 + 1.
Error: Unknown action 'Compuet'

  Did you mean: <Compute>?
```

The REPL is patient. It corrects. It waits for you to try again.

## The Period

Every statement ends with a period. It's ARO's way of knowing you're done:

```
aro> <Set> the <name> to "Alice".
=> OK
```

Forget the period and press Enter? The REPL waits for more:

```
aro> <Set> the <name> to "Alice"
...> .
=> OK
```

The `...>` prompt means "I'm listening for more." Type the period to complete your thought.

---

**Next: Chapter 3 — Remember**
