# Chapter 9: Recording and Replay

*"Every session is a file. Every file is a session you can re-open."*

---

## 9.1 Why record

A traditional debugger is a live conversation. The bug has to happen *while* you're paying attention. If it took twenty minutes of HTTP load to trigger, or showed up on Tuesday at 3 a.m. on a production server, you missed it. You repro it, again, this time with the debugger attached.

Recording inverts that. The runtime writes every pause, every published event, every error to a JSONL file. Once the file exists, you can re-open it from anywhere — your laptop, your colleague's laptop, six months later — and step through the session as if it were happening now. The program does not re-execute. Side effects do not re-fire. You scrub through a frozen record.

This is the foundation of two larger workflows. **Time-travel** debugging — stepping forward and backward through a frozen run — is the immediate one. **SOLARO's time-travel scrubber** (issue #228 figure 11) consumes the same JSONL stream live, turning the recording into a UI; chapter 9.5 covers that briefly.

## 9.2 Recording a session

The `--record` flag points the debugger at a JSONL file to write:

```bash
aro debug --record /tmp/session.jsonl ./MyApp
```

Run the session as normal. Every pause appends a `pause` record to the file. Events emitted on the event bus append `event` records. Errors append `error` records. Closure appends a final `end` record.

A single pause looks like this:

```json
{"t":0.015, "k":"pause", "reason":"step",
 "fs":"createUser", "act":"User API",
 "file":"users.aro", "line":5, "col":9,
 "verb":"Create", "stmt":"Create the <user> with <data>.",
 "syms":"[{\"n\":\"user\",\"ty\":\"User\",\"v\":\"{name:Ada,…}\"},{\"n\":\"data\",…}]"}
```

`t` is the wall-clock offset from the start of the recording (seconds). `k` is the kind (`pause`, `event`, `error`, `end`). The rest is self-describing — symbol snapshots are pre-rendered as JSON strings so the line stays flat.

The format is documented in `Sources/ARORuntime/Debug/DebugEventLog.swift`. It is intentionally tiny so the file is streamable, tail-able, diff-able, and trivial to fan out to multiple readers.

## 9.3 Replaying

The `--replay` flag re-opens a recorded file:

```bash
aro debug --replay /tmp/session.jsonl
```

You do not pass a project directory in this mode — the recording is self-contained.

The debugger reports how many pauses it found and drops into a replay-specific prompt:

```text
aro debug · replay (3 pauses)

⏸  [1/3] t=0.015s — Application-Start:4
   <Create> the <greeting: String> with the <_expression_> = "Hello, ARO World!".
     <terminal> : Map<String, Unknown> = ["columns": …]
(replay)
```

The prompt accepts a small command set:

| Command | Effect |
|---|---|
| `n`, `next`, `↵` | next pause |
| `p`, `prev` | previous pause |
| `g` | jump to the last pause |
| `0` | jump to the first pause |
| `<number>` | jump to the Nth pause |
| `q`, `quit` | exit replay |

Every move is instantaneous because nothing executes. You see the symbol snapshot as it was at that pause and the statement that was about to run.

## 9.4 What replay does not do

It does not re-execute. If you step "forward" in replay, the runtime does not actually run the next statement — it shows you the next *recorded* pause. The values you see are the values that were captured at recording time. Nothing in the world changes.

It also does not yet **branch and edit**. Conventional time-travel debuggers let you scrub to a point, mutate a binding, and run forward from there as a new branch. That is not in v1; the architecture supports it (the controller can be re-attached to a forked context) and it is the natural next step, but it has not shipped. Issue #230 tracks it.

What replay is for in v1: post-hoc inspection of a session that already happened. Hand a `.jsonl` file to a colleague; they replay it on their machine; they see exactly what you saw, no environment setup, no shared state. Bug reports become reproducible by attachment.

## 9.5 The SOLARO connection

SOLARO's time-travel scrubber (figure 11 in the wireframes attached to issue #228) consumes the same JSONL format. When SOLARO opens a `.jsonl`, every pause becomes a tick on a timeline. Clicking a tick scrubs to that moment; "follow node" pans the canvas to keep the relevant feature set centered while you scrub.

This is not a coincidence — the format was designed once to serve both the CLI replay command and the SOLARO scrubber. Future SOLARO features (branch-and-edit, mutate-and-replay) will share the same record on disk.

If you are not using SOLARO, the CLI replay is the primary surface. If you are, you'll mostly interact with the scrubber. Both are reading the same file.

## 9.6 What to record

Two practical recipes.

**During an interactive bug hunt:** record every session. The overhead is negligible (a few KB per minute of stepping), and if you find the bug, the file becomes the bug report.

```bash
aro debug --record /tmp/$(date +%s).jsonl ./MyApp
```

The timestamp filename lets you accumulate sessions without overwriting.

**For production:** sample. Chapter 10 describes the `--sample N` flag that pauses every Nth checkpoint. Combined with `--record`, you get a sparse trace of a long-running session that doesn't crater throughput:

```bash
aro debug --dap-port 4711 --sample 1000 --record /var/log/aro/$(date +%s).jsonl ./MyApp
```

The recording is much smaller (one pause per thousand statements) and the program runs near its normal speed.

## 9.7 Limits

The format has a few practical limits worth knowing:

- **Symbol snapshots are previews, not values.** A complex record is rendered as a truncated string. Replay shows you the string, not the structured value. For most diagnostic uses this is fine; if you need to re-instantiate the value, you cannot.
- **External side effects are not captured.** If your session sent an HTTP request, the request happened. Replay does not undo it. (This is also why replay does not re-execute — the original side effects have already left fingerprints in the world.)
- **No backwards compatibility guarantee yet.** The format is small enough that breaking changes are unlikely, but v1 does not pin a version field. Treat `.jsonl` files older than your `aro` binary with caution; either re-record on the new version or open the older one's binary side-by-side.

---

**Next:** Chapter 10 describes production attach — sampling, the TCP DAP listener, and how to keep a debugger session from killing a live server.
