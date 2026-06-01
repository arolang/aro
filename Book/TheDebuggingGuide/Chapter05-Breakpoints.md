# Chapter 5: Breakpoints — All Five Flavors

*"A breakpoint is a question: 'when this happens, stop and let me look.'"*

---

## 5.1 The taxonomy

The debugger ships five breakpoint cases. They share a vocabulary — every breakpoint is a *match rule* that the runtime checks at one of several hook points.

| Case | Match | Hook |
|---|---|---|
| `location` | file + line | every statement |
| `verb` | action verb (e.g. `Emit`) | every statement |
| `conditionalLocation` | file + line + ARO predicate | every statement |
| `event` | event name | every `EventBus.publish` |
| `errorAny` | any runtime error | error checkpoint |

You can have any number of any case bound at once. The runtime evaluates them in registration order; the first match wins.

## 5.2 Location: stop at a specific line

The simplest case. Set inside the debugger:

```
(aro-dbg) b 5
breakpoint set at main.aro:5
```

The current pause's source file is used. To target a different file explicitly, give a relative path:

```
(aro-dbg) b orders.aro:12
```

To pre-set a location breakpoint when launching:

```bash
aro debug --breakpoint 5 ./MyApp
```

The numeric form means "this line in the entry file." For multi-file projects, prefer the interactive `b file:line` form.

To list:

```
(aro-dbg) bl
  0: main.aro:5
  1: orders.aro:12
```

To delete by index:

```
(aro-dbg) d 0
deleted breakpoint #0
```

## 5.3 Verb: stop on every use of an action

Verb breakpoints match the action keyword regardless of file or line. Useful when you want to stop on every `Emit` to trace event flow, or every `Store` to find an unintended write.

```
(aro-dbg) b Emit
breakpoint set on verb Emit
(aro-dbg) c

⏸  paused (breakpoint (verb Emit)) at users.aro:7 — createUser
   <Emit> a <UserCreated: event> with <user>.
```

Verb names are case-sensitive and use the canonical action name from `aro actions`. `Emit`, not `emit`.

Pre-set on launch:

```bash
aro debug --breakpoint Emit ./MyApp
```

The CLI distinguishes line-number from verb breakpoints by parsing the argument: numeric → location; non-numeric → verb.

## 5.4 Conditional location: stop only when a predicate holds

Location breakpoints with a predicate. The predicate is an ARO expression evaluated against the live execution context at every statement boundary that matches the file + line.

```
(aro-dbg) b 5 if <user: id> == 530
conditional breakpoint at main.aro:5 if <user: id> == 530
```

The predicate language is the full ARO expression grammar — comparisons, `&&`, `||`, qualifier navigation, repository counts, anything the runtime can compute. Concretely:

```
b 7 if <count> > 100
b 9 if <user: role> == "admin" && <users-repository: count> < <limit>
b 12 if <event: type> == "purchase"
```

The predicate evaluates *before* the statement runs, against the bindings the previous statement produced. If the predicate raises (e.g. an undefined variable), the runtime treats it as `false` and silently does not pause. This is deliberate: a debugger predicate should never crash the program it is debugging.

## 5.5 Event: stop on every emit of a named event

Set via the `be` (break-event) command:

```
(aro-dbg) be UserCreated
breakpoint set on event UserCreated
```

When any statement publishes a `UserCreated` event, the runtime pauses just before the event-bus fans out to subscribers.

**Ordering caveat.** The event hook fires inside the same Task as `EventBus.publish`'s detached fan-out. In practice the runtime's scheduler runs the checkpoint first, but the strict happens-before relationship between the pause and the first subscriber Task is *not guaranteed*. If you need strict pre-subscriber stop semantics, set a **verb breakpoint on `Emit`** at the source statement instead — that pauses on the statement boundary before any subscriber Task is scheduled.

The strict-gating path is tracked as a follow-up in issue #230; until it lands, the verb-on-Emit workaround is reliable.

## 5.6 Error-any: stop just before any runtime error

```
(aro-dbg) berror
breakpoint set on any error
```

The next time a statement is about to fail, the runtime pauses *before* the error message is formatted. You can read every binding that contributed to the failing call, decide what went wrong, and either continue (the error then propagates normally) or quit.

This is the closest thing the debugger has to "catch on throw." It is the most useful breakpoint for the case where you don't yet know *where* a bug is — set `berror`, run, wait.

The reason it's useful in ARO specifically: error messages in ARO are generated from the failing statement (the "code is the error message" philosophy of #ARO-0006), so an error-any breakpoint pauses you exactly at the statement the error will reference. The relationship between the message and the pause is one-to-one.

## 5.7 Hit count, log breakpoints, and what's *not* here

The five cases above are the entire taxonomy in v1.

The debugger does not yet support:

- **Hit-count breakpoints** (stop only on the Nth hit). The conditional-location form covers most of this — use `if <some-counter> == N` against a binding that increments.
- **Log breakpoints** (print a message without pausing). Use ARO's own `Log` action at the source statement; this is the runtime's idiom and we don't want a debugger-specific log channel competing with it.
- **Function-entry breakpoints in the conventional sense.** Verb breakpoints cover the closest equivalent (`b Application.MyAction` for user-defined actions); event breakpoints cover the event-driven counterpart.

The simpler taxonomy is intentional. The combination of location + verb + conditional + event + error-any reaches every scenario a real debugger user opens an IDE for, with fewer surprises about how each one interacts with the others.

## 5.8 Quick reference

```text
(aro-dbg) b <line>             location bp at this file
(aro-dbg) b <file>:<line>      location bp at another file
(aro-dbg) b <Verb>             verb bp (capital V)
(aro-dbg) b <line> if <pred>   conditional location bp
(aro-dbg) be <Event>           event bp
(aro-dbg) berror               error-any bp
(aro-dbg) bl                   list
(aro-dbg) d <n>                delete by index
```

`--breakpoint` accepts the same syntax on the command line; it can be passed multiple times.

---

**Next:** Chapter 6 introduces watch expressions — predicates that don't trigger a pause but print themselves at every existing pause.
