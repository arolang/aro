# Chapter 5: Breakpoints — All Six Flavors

*"A breakpoint is a question: 'when this happens, stop and let me look.'"*

---

## 5.1 The taxonomy

The debugger ships six breakpoint cases. They share a vocabulary — every breakpoint is a *match rule* that the runtime checks at one of several hook points.

| Case | Match | Hook |
|---|---|---|
| `location` | file + line | every statement |
| `verb` | action verb (e.g. `Emit`) | every statement |
| `conditionalLocation` | file + line + ARO predicate | every statement |
| `logpoint` | file + line — traces, never pauses | every statement |
| `event` | event name | every `EventBus.publish` — but see §5.5 |
| `errorAny` | any thrown runtime error | error checkpoint — see §5.6 |

You can have any number of any case bound at once. The runtime evaluates them in registration order; the first match wins. Logpoints are the exception to "first match wins": they do not compete for the pause, so a logpoint and a location breakpoint on the same line both fire — the message prints, then the pause happens.

## 5.2 Location: stop at a specific line

The simplest case. Set inside the debugger:

```
(aro-dbg) b 5
breakpoint set at main.aro:5
```

The current pause's source file comes with it, so `b 5` means "line 5 of the file I am looking at."

To pre-set a location breakpoint when launching:

```bash
aro debug ./MyApp --breakpoint 5
```

A launch-time breakpoint carries no file, and an empty file matches every one — so the numeric form means "line 5 in *any* source file in the project," not "line 5 in the entry file." In a single-file example that is the same thing; in a multi-file application it is usually more stops than you wanted.

**Targeting another file.** `b orders.aro:12` scopes the breakpoint to that file, whichever file you happen to be paused in:

```
(aro-dbg) b orders.aro:12
breakpoint set at orders.aro:12
```

The file is matched on basename suffix, so `orders.aro:12` and `sources/orders/orders.aro:12` both reach the same statement. Leave the file half empty — `b :12` — to match line 12 of *every* file, which is what a launch-time `--breakpoint 12` does. The conditional form takes a file too: `b orders.aro:12 if <qty> > 5`.

A verb never contains a colon, so there is nothing to disambiguate; an argument with a colon whose tail is not a number is reported as a typo rather than quietly registered as a verb nothing can match:

```
(aro-dbg) b orders.aro:x
not a line number: orders.aro:x — use `b <file>:<line>`
```

To list:

```
(aro-dbg) bl
  0: main.aro:5
  1: verb Emit
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
aro debug ./MyApp --breakpoint Emit
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

To pre-set one on the command line, use `--break-condition` with a `LINE=EXPRESSION` pair. It is repeatable, and — like `--breakpoint` — it carries no file, so it matches that line in every source file:

```bash
aro debug ./MyApp --break-condition "5=<user: id> == 530"
```

`--breakpoint` cannot carry a predicate — it parses its argument as a line number or a verb and nothing else — which is why the conditional form gets a flag of its own.

## 5.5 Event: stop on every emit of a named event

Set via the `be` (break-event) command:

```
(aro-dbg) be UserCreated
breakpoint set on event UserCreated
```

The intent is that when any statement publishes a `UserCreated` event, the runtime pauses just before the event bus fans out to subscribers.

That is what happens, and the pause is a strict happens-before: on the `Emit` path the event bus already awaits its handlers, so the program stops before any subscriber runs (GitLab #557).

```
(aro-dbg) be NumberTriggered
breakpoint set on event NumberTriggered
(aro-dbg) c

⏸  paused (event NumberTriggered) at main.aro:7 — Application-Start
```

The pause names the feature set and line that emitted, not just the event.

A **verb breakpoint on `Emit`** remains useful, and it is the better tool when you want the statement's own bindings rather than the event:

```
(aro-dbg) b Emit
breakpoint set on verb Emit
(aro-dbg) c

⏸  paused (breakpoint (verb Emit)) at main.aro:7 — Application-Start
   <Emit> the <NumberTriggered: event> with the <_expression_> = "Event triggered!".
```

That pauses on the statement boundary — before any subscriber Task is even scheduled — so it also gives you the strict pre-handler ordering the event hook was never able to promise. Its one weakness is that it stops on *every* `Emit`, not just the one event you care about; in a feature set that emits several, pair it with `bl` and a conditional breakpoint on the line instead.

## 5.6 Error-any: stop just before any runtime error

```
(aro-dbg) berror
breakpoint set on any error
```

The next time a statement throws, the runtime pauses *before* the error message is formatted. You can read every binding that contributed to the failing call, decide what went wrong, and either continue (the error then propagates normally) or quit.

This is the closest thing the debugger has to "catch on throw." It is the most useful breakpoint for the case where you don't yet know *where* a bug is — set `berror`, run, wait.

The reason it's useful in ARO specifically: error messages in ARO are generated from the failing statement (the "code is the error message" philosophy of ARO-0006), so an error-any breakpoint pauses you exactly at the statement the error will reference. The relationship between the message and the pause is one-to-one:

```
⏸  paused (error: Runtime Error: Cannot read the data from the _expression_.
   File not found: /nonexistent/definitely-not-here.json
     Feature: Application-Start
     Business Activity: Error Demo
     Statement: <Read> the <data> from the <_expression_>.) at main.aro:3 — Application-Start
   [error] Runtime Error: Cannot read the data from the _expression_. …
```

It catches deferred failures too. A *deferred* action doesn't throw at its own statement — its failure rides in the future and surfaces when the feature set drains it — and the checkpoint fires there as well, attributed to the statement that **created** the future rather than the one that read the empty value (GitLab #561). So the pause points at the cause:

```
(aro-dbg) berror
breakpoint set on any error
(aro-dbg) c

⏸  paused (error: Runtime Error: Cannot read the data …) at main.aro:3 — Application-Start
```

`ARO_NO_DEFER=1` is still worth reaching for while error-hunting, for the reason chapter 4.2 gives — it removes the gap between the line you read and the line that ran — but `berror` no longer needs it.

```bash
ARO_NO_DEFER=1 aro debug ./MyApp
```

## 5.7 Logpoints, hit counts, and what's *not* here

The sixth case is the **logpoint**: a breakpoint that traces instead of stopping. It is set on the command line as a `LINE=MESSAGE` pair, repeatable:

```bash
aro debug ./MyApp --logpoint "7=count is {count}, user is {user}"
```

Every time line 7 is reached — in any file, since a launch flag carries no file — the runtime interpolates `{name}` tokens against the bindings visible at that statement and prints one line:

```
[logpoint] users.aro:7 count is 42, user is {name:Ada,…}
```

Then execution continues — a logpoint never pauses. A `{name}` that matches nothing is left verbatim in the output, so a typo shows up in the trace rather than silently vanishing; `\{` and `\}` escape a literal brace. When a `--record` file is open, each hit lands in it as an `event` record tagged `logpoint`, so a traced run replays as a trace.

The point of having this at all, in a language whose own `Log` action is one statement away, is that a logpoint costs no edit: you can trace a line in a file you don't want to touch, or in a checkout you don't want to dirty, and take it back off by not passing the flag.

The debugger still does not support:

- **Hit-count breakpoints** (stop only on the Nth hit). The conditional-location form covers most of this — use `if <some-counter> == N` against a binding that increments.
- **Interactive logpoints.** `--logpoint` is a launch flag; there is no `b 7 log …` command at the pause prompt. Set them when you start the session.
- **Function-entry breakpoints in the conventional sense.** Verb breakpoints cover the closest equivalent (`b Application.MyAction` for user-defined actions); event breakpoints cover the event-driven counterpart.

The taxonomy stays small on purpose. Location + verb + conditional + logpoint + event + error-any reaches every scenario a real debugger user opens an IDE for, with fewer surprises about how each one interacts with the others.

## 5.8 Quick reference

```text
(aro-dbg) b <line>             location bp at this file
(aro-dbg) b <file>:<line>      location bp at that file (empty file ⇒ any)
(aro-dbg) b <Verb>             verb bp (capital V)
(aro-dbg) b <line> if <pred>   conditional location bp
(aro-dbg) b <file>:<l> if <p>  conditional, scoped to a file
(aro-dbg) be <Event>           event bp
(aro-dbg) berror               error-any bp
(aro-dbg) bl                   list
(aro-dbg) d <n>                delete by index
```

On the command line, `--breakpoint <line|Verb>` sets the location and verb forms, `--break-condition "LINE=EXPR"` the conditional form, and `--logpoint "LINE=MESSAGE"` a logpoint. All three are repeatable. Event and error-any breakpoints have no launch flag — set them from the entry pause before you continue.

---

**Next:** Chapter 6 introduces watch expressions — predicates that don't trigger a pause but print themselves at every existing pause.
