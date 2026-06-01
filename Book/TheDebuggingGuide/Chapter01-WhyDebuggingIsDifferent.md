# Chapter 1: Why ARO Debugging Is Different

*"In a language with one sentence shape, the debugger knows where to pause without asking."*

---

## 1.1 One verb, one step

Open `gdb` on a C program and the question "where do I pause?" gets a complicated answer. The compiler emitted instructions for declarations, expressions, sub-expressions, temporaries, loop edges, and inlined frames; the debugger has to map every one of those back to a source line, sometimes well, sometimes badly. Step over `int x = foo(a, b) + bar(c);` and you may step into `foo`, into `bar`, into a `+` operator, or directly to the next line — depending on which file, which optimization level, and which year you compiled in.

ARO has none of that. Every executable construct is a statement:

```aro
Action the <Result> preposition the <Object>.
```

There is no nested expression to step into. There is no operator to land on. There is no implicit conversion. The unit of execution is the same as the unit you read on the page. That is the entire reason `aro debug` works the way it does, and why this book is shorter than a comparable book about, say, debugging Java.

When you type `step` in `aro debug`, the runtime advances exactly one statement. When you type `step` again, exactly one more. There is no expression-level granularity to choose because there is no expression-level granularity to express.

## 1.2 Lazy execution makes the debugger interesting

The simple grammar would be reason enough on its own, but ARO has a second design choice that makes the debugger genuinely useful: **actions are lazy**. A statement like

```aro
Retrieve the <user> from the <users-repository>.
```

does not, in general, contact the repository the moment you read it. It returns a future. The repository call happens the first time something *reads* `<user>` — typically a `Return`, an `Emit`, a `with` expression, or a guard.

This means the line you are paused on is not always where the work happens. The debugger lets you see this in two complementary ways:

1. **Source-order stepping** — advance by the order of the file. This matches what you read.
2. **Force-order stepping** — advance by the order the runtime actually forces futures. This matches what happens.

A bug that points an error message at line 3 might really be the fault of line 7, because line 7 was the first read that forced the future created on line 3. Source-order stepping shows you the file; force-order stepping shows you the execution. You will use both.

## 1.3 The event bus is part of the call stack

Conventional debuggers show a stack of function frames. ARO has feature sets that are triggered by events: HTTP requests, repository writes, custom emits, file watcher notifications. A call from `createUser` to a `UserCreated Handler` does not look like a function call in the language, but it is one in the causal sense.

The ARO debugger treats events as call edges. When `createUser` emits `UserCreated`, **step into** follows that emit into the handler's first statement. **Step over** continues `createUser` to its next statement, leaving the handler to run on its own. The "call stack" you see in a paused session is a chain of *(statement, feature set, triggering event)* tuples — a causal history, not a function stack.

This is what lets you debug an event-driven system the same way you debug a synchronous one.

## 1.4 Two runtimes, one debugger

ARO compiles two ways: an interpreter (`aro run`) and a native binary (`aro build`). The debugger drives the interpreter directly — every Phase 1–5 feature works there. Native binaries get function-level DWARF (so `lldb` can name your feature sets in a backtrace) but not per-line breakpoints yet. Chapter 8 covers what `lldb` can and cannot see and when each path is the right tool.

The practical implication: **debug from source, ship the compile**. The same `.aro` files run both ways.

## 1.5 What this book covers

- **Part I (you are here)**: foundations. Why the debugger looks the way it does, getting it installed, and walking your first session.
- **Part II**: driving the debugger. The five kinds of breakpoint, watches, and the statement-boundary model in detail.
- **Part III**: editor integration. VS Code, IntelliJ, Neovim — what works, what doesn't.
- **Part IV**: time and distance. Recording sessions, replaying them, attaching to running programs.

Two appendices follow with the full command reference and a small glossary. The book runs from page one to the appendix in about a long afternoon's reading.

## 1.6 What this book does not cover

It does not teach ARO. If you have never written a feature set or do not know what a preposition pin is, read `TheLanguageGuide` first — the foundations chapter assumes you have. It does not teach SOLARO either; the canvas IDE consumes the same debug event stream this book describes, but the canvas itself has its own documentation under issue #228's ADRs.

It also does not cover *fixing* bugs, in any language-specific sense. Once you can step, watch, and replay, the fix is the same conversation you have had on every other project: read the failing case, find the wrong assumption, change the code. The debugger gets you to the conversation faster. That's the entire pitch.

---

**Next:** Chapter 2 walks through getting `aro debug` running on your machine and verifying the binary against a known-good help text.
