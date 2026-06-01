# Appendix A: Command Reference

The authoritative source is `aro debug --help`. This appendix is a curated subset, organized for quick lookup. Where the binary disagrees with this text, the binary is right.

---

## A.1 CLI flags

```text
aro debug [<options>] [<path>]
```

| Flag | Meaning |
|---|---|
| `<path>` | Application directory or `.aro` file. Omit only with `--replay`. |
| `--entry-point <name>` | Override the entry feature set (default: `Application-Start`). |
| `--breakpoint <line\|verb>` | Initial breakpoint(s); repeatable. |
| `--dap` | Speak Debug Adapter Protocol over stdio. |
| `--dap-port <port>` | Bind a TCP listener on `127.0.0.1:port` and serve DAP to one client. |
| `--dap-log <path>` | Mirror every DAP message to a file (debugging the bridge itself). |
| `--record <path>` | Append every pause / event / error to a JSONL file. |
| `--replay <path>` | Re-open a recorded session. No project execution. |
| `--sample <N>` | Pause every Nth step-mode checkpoint (production attach). |
| `--verbose`, `-v` | Verbose logging. |

## A.2 TUI commands at a pause prompt

| Command | Aliases | Effect |
|---|---|---|
| `s` | `step` | Advance into the next statement (follow emits / sub-graph calls). |
| `n` | `next` | Advance over the next statement. |
| `f` | `finish`, `stepout` | Run until the current feature set returns. |
| `c` | `continue` | Resume until next breakpoint or program end. |
| `b <line>` | — | Location breakpoint. |
| `b <Verb>` | — | Verb breakpoint. |
| `b <line> if <pred>` | — | Conditional location breakpoint. |
| `be <Event>` | `breakevent` | Event breakpoint. |
| `berror` | — | Error-any breakpoint. |
| `bl` | `list` | List active breakpoints. |
| `d <n>` | `delete` | Delete breakpoint by index. |
| `w <expr>` | `watch` | Add a watch expression. |
| `w` | — | List watches. |
| `dw <n>` | — | Delete watch by index. |
| `p` | `print` | Print all current bindings. |
| `bt` | `where` | Print pause location summary. |
| `h` | `help`, `?` | Show help. |
| `q` | `quit` | Terminate the program (clean unwind via `DebuggerQuit`). |

## A.3 Replay prompt

| Command | Effect |
|---|---|
| `n` / `next` / `↵` | Next pause |
| `p` / `prev` | Previous pause |
| `g` | Last pause |
| `0` | First pause |
| `<number>` | Jump to the Nth pause |
| `q` / `quit` | Exit replay |

## A.4 Breakpoint types (controller-level)

| Variant | Match against |
|---|---|
| `.location(file, line)` | File suffix + line equality |
| `.verb(name)` | `AROStatement.action.verb == name` |
| `.conditionalLocation(file, line, predicate)` | File + line + predicate truthy |
| `.event(name)` | `EventBus.publish`'s event type |
| `.errorAny` | Any runtime error before the message is formatted |

## A.5 Pause reasons

| Reason | When |
|---|---|
| `entry` | First checkpoint of a feature set (unconditional) |
| `step` | Step / next / finish chose to pause |
| `breakpoint(<bp>)` | A registered breakpoint matched |
| `event(<name>)` | An event-name breakpoint matched a `publish` call |
| `error(<msg>)` | An error-any breakpoint matched a pre-error checkpoint |

## A.6 DAP requests handled

| Request | Mapping |
|---|---|
| `initialize` | Reply with capabilities; send `initialized` event. |
| `launch` / `attach` | Reply success; nothing else (CLI already constructed Application). |
| `configurationDone` | Reply; no resume (initial entry hits its own pause). |
| `setBreakpoints` | Replace location breakpoints for the named source. |
| `setFunctionBreakpoints` | Replace verb breakpoints. |
| `setExceptionBreakpoints` | Reply success. |
| `threads` | One thread: `[{id:1, name:"aro"}]`. |
| `stackTrace` | Empty for v1 (causal-stack reporting lands in #230 follow-up). |
| `scopes` | `[{name:"Locals", variablesReference:1}]`. |
| `variables` | The most recent pause's symbol snapshot. |
| `continue`, `next`, `stepIn`, `stepOut` | Resume with the corresponding `StepMode`. |
| `pause` | No-op in v1 (#229 Phase 5 follow-up). |
| `disconnect`, `terminate` | Resume with `.quit`. |

## A.7 DAP events emitted

| Event | When |
|---|---|
| `initialized` | After `initialize` response. |
| `stopped` | At every pause. `reason` is one of `entry`, `step`, `breakpoint`, `event`, `exception`. |
| `output` | Forwarded program stdout (when wired; minimal in v1). |
| `terminated` | At session end. |
| `exited` | (Reserved.) |

## A.8 Recording schema

JSONL format. One JSON object per line. Top-level keys:

```text
t       Float — seconds since recording start
k       String — one of "pause", "event", "error", "end"
```

For `k="pause"`:

```text
reason  String — same set as A.5
fs      String — feature set name
act     String — business activity
file    String — basename of source
line    String — line number (string for flat-record compatibility)
col     String — column
verb    String — action verb (optional)
stmt    String — human-readable statement summary
syms    String — JSON-encoded array of {n, ty, v}
```

For `k="event"`: `name`, `payload`.
For `k="error"`: `msg`.
For `k="end"`: optional `err`.

Full schema lives in `Sources/ARORuntime/Debug/DebugEventLog.swift`. Treat the source as authoritative.
