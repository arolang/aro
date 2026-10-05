# Proposal: Jupyter Kernel & Machine-Readable REPL

**Proposal-ID:** ARO-0091
**Author:** ARO Team
**Status:** Implemented
**Created:** 2026-08-17
**Updated:** 2026-10-04
**Requires:** ARO-0001 (Language Fundamentals), ARO-0081 (User-Defined Actions), ARO-0083 (Terminal UI), ARO-0088 (Concurrency Model)

---

## Summary

Two things, one of which exists for the other:

1. **`aro repl --json`** — a line-delimited JSON protocol on stdio that drives a
   REPL session from another program.
2. **A Jupyter kernel** built on it, so ARO runs in notebooks (JupyterLab,
   VS Code, DataSpell).

The protocol is the durable part. A notebook is one client; an editor
scratchpad, a test harness, or a future native kernel are others.

## Motivation

ARO has an interactive evaluator but no way to keep a session, its output, and
the prose explaining it in one document. That costs most where ARO is most
worth showing: collection pipelines (ARO-0018), where seeing the intermediate
list is the whole point, and teaching material, where a runnable chapter beats
a printed transcript.

The REPL was already capable of this. `REPLSession` writes nothing to stdout
and returns every outcome as a value — it is a headless evaluator with a
terminal front-end bolted on. What was missing was a second front-end.

## The protocol

One JSON object per line, both directions. Framing is a newline, as in the MCP
server's `StdioTransport` — not LSP's `Content-Length`.

### Requests

| `type` | Fields | Answer |
|--------|--------|--------|
| `execute` | `code`, optional `cellId`, optional `baseDir`, optional `allowStdin` | `status: ok` with optional `display`, or `status: error` |
| `is_complete` | `code` | `status: complete` / `incomplete` (+`indent`) / `invalid` |
| `complete` | `code`, `cursor` | `matches`, `items`, `cursorStart`, `cursorEnd` |
| `inspect` | `code`, `cursor` | `found`, `text` |
| `info` | — | `info` (version, feature sets, variables) |
| `reset` | — | `status: ok`; session cleared |
| `shutdown` | — | `status: ok`; server exits |
| `input_reply` | `value`, or `status: "error"` | nothing — it answers an `input_request` |

**`cellId` — re-running a cell.** A front-end that has stable cell
identity sends it with `execute`. Re-running a cell then releases the
bindings *that cell* made before running it again, so the ordinary
notebook loop — fix a typo, run again — works instead of failing as a
rebind (GitLab #544).

Immutability is unchanged everywhere else. A *different* cell binding a
name an earlier cell bound is still refused, and a client that sends no
`cellId` (a terminal REPL line, where each line is a new statement in
the session's program) keeps the session-wide rule. A cell that binds
fewer names on its second run leaves nothing behind: the names it no
longer binds are released with it, so the session reflects the cells as
they are now.

**`baseDir` — where a relative path points.** A front-end sends the directory
the cell's relative paths resolve against, and it is the *notebook's own
folder*, not the session's.

The two are not the same thing, and the gap is what made this a field rather
than a working directory. A kernel process has one working directory for its
whole life, chosen when it starts — Solaro launches it in the project root — but
a project holds notebooks in several folders, and a reader looking at
`Learning/22-git-and-devops.repl` means that file's folder when the cell says
`<git: "..">`. Without the field that cell discovered whatever repository sits
above the project root, or none, and answered `Cannot retrieve the status from
the git: ..` — while the same notebook passed under `Learning/validate.py`,
which runs with `cwd=Learning/` (GitLab #915).

So the directory travels per request. The server applies it for that cell and
restores the previous default afterwards, which also means a front-end may run
cells from notebooks in different folders against one session.

Absent means the session's own default: the project directory for
`aro repl <dir>`, otherwise the process's working directory. A client that does
not know where its cell came from therefore behaves exactly as before.

Every request carries an `id`. Every request gets exactly one `result` message
with the same `id` — `input_reply` excepted, because it is an answer rather than
a question (see *Interactive input*).

### Messages from the server

```jsonc
{"type":"ready","version":"0.11.1","protocol":1}          // once, at startup
{"type":"stream","id":1,"name":"stdout","text":"hi\n"}    // output, as it happens
{"type":"result","id":1,"status":"ok","display":{…},"durationMs":3.0}
{"type":"result","id":1,"status":"error","error":{"ename":…,"evalue":…,"traceback":[…]}}
{"type":"input_request","id":1,"prompt":"Your name: ","password":false}  // mid-execute
```

**Ordering is guaranteed**: every `stream` for a request precedes that
request's `result`. Clients never have to guess when a cell's output is done.
An `input_request` obeys the same rule from the other side: everything the
question is printed under — a `Select` menu, the `Log` lines above it — is on
the wire before the question.

### Display bundles

`display` is a MIME bundle. `text/plain` is always present, rendered by
`ResponseFormatter` in `.human` — the same renderer the runtime uses for
console output. `application/json` appears when the value encodes.
`text/html` appears for tabular values only: a list of records becomes a
table, a single record becomes key/value rows, a list of scalars gets nothing
because a one-column table is noise.

### Errors

ARO's error text is already the message (ARO-0006): a block naming the
feature, the statement, and the trace. It is split, not rewritten — first line
as `evalue`, whole block as `traceback`.

Because the first line is the headline, compile diagnostics arrive **ranked**
(GitLab #509): errors before warnings before notes, and within a severity,
root-cause findings before consequential ones — hygiene fallout of a failed
statement, such as `Variable 'x' is defined but never used` or
`Feature set '…' has no Return or Throw statement`. Emission order is
preserved within each class and nothing is dropped or reworded, so `evalue`
names the diagnostic worth acting on (e.g. `Unknown Compute qualifier
'sparkle'`) and the fallout stays visible in `traceback`.

## Cell semantics

A terminal REPL reads one input at a time. A cell arrives whole and may mix
kinds, so it is split into units in source order:

| Unit | Recognised by | Effect |
|------|---------------|--------|
| Meta-command | line starts with `:` | Dispatched through `MetaCommandRegistry` |
| Feature set | `(Name: Activity) {` … `}` | Compiled and registered in the session |
| Statements | anything else | Executed as one feature-set body |

Consecutive statements stay **one** unit. Splitting them would serialise work
the language is allowed to overlap: statements in a feature set defer and
force independently (ARO-0088), and two 2-second requests in one cell should
take ~2s, not 4s.

### Definitions accumulate

Each statement unit is compiled together with the source of every feature set
defined earlier in the session. This is what makes cell-to-cell composition
work: semantic analysis resolves `Application.<Name>` (ARO-0081) against the
program it is given, and a lone wrapped statement is a program of one.

Companion sources are appended *after* the wrapper, never prepended, so
diagnostics keep the line numbers of the code the user typed.

### Automatic display

A cell whose last statement produces a value displays it, without an explicit
`Return`. "Produces a value" means the statement's action role is `own` or
`request`; showing something after `Log`, `Store`, or `Publish` would either
duplicate output or invent a result the statement never had.

### Blocking statements

`Keepalive` (and its aliases `Wait`, `Block`) are rejected with an
explanation. They block until the process is signalled, which in a cell is a
spinner that never stops. Services started by an earlier statement keep
running without them. `ARO_REPL_ALLOW_BLOCKING=1` overrides.

### Event dispatch

A `{EventName} Handler` feature set defined in the session is live: an
`Emit` in a later input dispatches to it, with the same routing an
application gets — event type from the business activity, state guards
(ARO-0022), payload bound as `event` / `event:key`. The session's own
`EventBus` carries the dispatch; no event loop is required, because
domain events have no external source to wait on.

Ordering holds. After each executed input the session waits for every
handler it triggered — cascades included, where a handler emits an event
of its own — so handler output lands with the input that caused it, and
a cell's `stream` messages still all precede its `result`. A handler
that outlives the wait (the runtime's handler timeout) is reported as a
warning on stderr rather than an error: the emitting statement itself
succeeded. Handler errors likewise arrive on stderr in ARO's own error
text (ARO-0006) — they never retroactively fail the emitting cell.

Redefining a handler replaces its subscription, and `reset` (or `:clear`)
drops it — a cleared definition must not keep answering events. Both
front-ends behave identically because the dispatch lives in
`REPLSession`; the terminal REPL benefits equally.

### Handler families

A business activity says how a feature set is triggered, and a session can
deliver some of those triggers and not others. The dividing line is **where
the events come from**:

- An **ARO statement** produces them — `Emit`, `Store`/`Update`/`Delete`,
  `Accept`, `Notify`, or a file monitor this session started. The session
  subscribes the handler, and dispatch at the prompt works the way it does
  under `aro run`.
- They arrive over a **transport the session does not own** — a TCP server,
  an HTTP contract, the keyboard. No subscription would make one arrive.

```
                         +---------------------------+
   Emit / Store /        |                           |
   Accept / Notify /     |   the session's EventBus  |-----> handler runs
   file monitor   ------>|                           |
                         +---------------------------+
   TCP peer / WebSocket          (nothing publishes here
   frame / key press      --X     in a session)        -----> never arrives
```

| Business activity | In a session |
|-------------------|--------------|
| `{EventName} Handler` | dispatched — fires on `Emit` |
| `{repository} Observer` | dispatched — fires on `Store`, `Update`, `Delete` |
| `File Event Handler` | dispatched — fires on a change under a path `Start the <file-monitor>` is watching |
| `StateTransition Handler` / `… StateObserver` | dispatched — fires on `Accept` |
| `NotificationSent Handler` | dispatched — fires on `Notify` |
| `Socket Event Handler` | **undelivered** — a session starts no TCP server |
| `WebSocket Event Handler` | **undelivered** — a session serves no HTTP contract |
| `KeyPress Handler` | **undelivered** — nothing here reads a raw keyboard (`Prompt`, `Select` and `Ask` do work — see *Interactive input*) |
| `{repository} Evicted Handler` | **undelivered** — the eviction is published on the runtime's shared bus, not the session's |
| `… Watch: …` | **undelivered** — a session refreshes no watches (ARO-0083) |
| `Application-End` | **undelivered** — a session has no shutdown to run it on |

**An undelivered family is named at definition time, not silently accepted.**
The definition is still kept — it compiles, it is listed by `:fs`, and it can
be copied into an application unchanged — but the front-end says what will not
happen and where it will:

```
Defined (Echo Input: Socket Event Handler) — this session delivers no socket
events — nothing in a session starts a TCP server; put it in an application
and `aro run` it
```

A dispatched family says what makes it fire, for the same reason: "Defined"
alone reads as "parked". The classification is one function
(`REPLSession.handlerFamily`), read by `aro repl`, `aro repl --json`,
`aro kernel`, piped stdin and Solaro alike, so no two front-ends can disagree
about which family is which.

## Interactive input

`Prompt`, `Select` and `Ask` (ARO-0083 §5.2–5.3) read an answer from the user.
They used to read it from the process's own terminal and nothing else, so in a
notebook — where there is no terminal — the statement failed with
`Service not registered: 'TerminalService'`, which names a Swift type and tells
the reader nothing they can act on (GitLab #690).

**The terminal is one answerer, not the only possible one.** A front-end driving
a session already has a channel to its user; a question travels over it the same
way output does.

```
   Prompt / Select / Ask
            |
            v
   +--------------------+     no answerer registered
   | who can answer?    |---------------------------> statement FAILS,
   +--------------------+                             naming the reason
      |             |
      | terminal    | front-end channel
      v             v
   the TTY     input_request  -------->  front-end asks its user
   (aro run,   <--------------  input_reply  (or refuses, or never answers:
    aro repl)                                the wait is bounded)
```

### The message pair

Jupyter already has this: `input_request` / `input_reply` on the **stdin
channel**, which is how `input()` works in IPython. The native kernel bound that
socket and never used it; it now serves it. The JSON protocol gains the same pair
of messages, deliberately the same shape — `prompt` and `password` out, `value`
back — so a kernel sitting between the two is a relay rather than a translator,
and a reader of one protocol already knows the other.

```jsonc
// server → client, between an execute request and its result
{"type":"input_request","id":1,"prompt":"Your name: ","password":false}
// client → server
{"id":1,"type":"input_reply","value":"Ada Lovelace"}
// …or: the user dismissed the prompt and will not answer
{"id":1,"type":"input_reply","status":"error"}
```

The `id` is the id of the `execute` that asked, which is what lets a client
attribute the question to a cell.

### Who may be asked

A client declares it per request, as Jupyter does:

| Front-end | Declares | Default when absent |
|-----------|----------|---------------------|
| `aro kernel` (native) | `allow_stdin` on `execute_request` | **false** — ipykernel's own default |
| `aro repl --json` | `"allowStdin": true` on `execute` | **false** |

False in both cases, and the reason is the same: a client that has never heard of
`input_request` would be sent one, never reply, and the cell would sit out the
whole timeout before failing. Opting in costs one field; refusing honestly is the
default. "Run All Cells" and `nbconvert` send false themselves — there is nobody
at the keyboard — and get the failure rather than a hang.

### Nobody can answer

The statement **fails**, with a sentence saying which front-end could have
answered and how to get one:

```
Runtime Error: Cannot prompt the name with the _expression_. Interactive input is
not available in this cell: the front-end ran this cell with allow_stdin: false,
so `Prompt` has nobody to ask. Allow input for the cell and run it again.
```

Failing is the design, not a shortcut. A cell waiting forever on a question
nobody will answer cannot be told from a slow one, and interrupting a notebook
costs the whole session (see *Interrupt*). Every wait therefore has a way out:

- **the reply**, or an `input_reply` that refuses;
- **the channel closing** — stdin at EOF, a `shutdown` arriving instead of an
  answer, the kernel's context shutting down;
- **the timeout**, `ARO_INPUT_TIMEOUT_SECONDS`, 300s by default. `0` waits
  indefinitely, for a front-end whose user may legitimately take an hour.

A request arriving while a question is open is **refused by name** rather than
run: the session is one request at a time (see *Limits*), and the refusal says
to answer the `input_request` first.

### Select without a picker

Neither front-end has a menu widget, so `Select` renders the numbered menu it
has always rendered — to the cell's output — and asks for a number:

```
Pick a colour:
  1. Red
  2. Green
  3. Blue
Enter selection (number): ▁
```

An out-of-range number selects nothing, as it always has. A front-end that grows
a real picker overrides one method (`requestChoice`) and keeps `Prompt`
unchanged.

### What answers today

| Front-end | Interactive input |
|-----------|-------------------|
| `aro run`, `aro repl` on a TTY | the terminal, unchanged |
| `aro kernel` (native) | `input_request` on the stdin channel |
| `Editor/jupyter-aro` (Python shim) | relayed onto ipykernel's `raw_input` / `getpass` |
| SOLARO notebooks | not yet — it does not opt in, so a cell gets the explanation (GitLab #912) |

A `KeyPress Handler` stays **undelivered** in a session (see *Handler
families*), and this is where the line falls: this channel answers a question
the program asked — one line, on request — while a `KeyPress` handler wants
unsolicited keystrokes from a raw keyboard, which no front-end offers.
## The project a session stands in

A session takes an optional project directory, and wires in what `aro run`
discovers for it:

```
aro repl ./MyApp
aro repl --json ./MyApp
aro kernel --connection-file … --project ./MyApp
```

| What | Effect in a cell |
|---|---|
| `openapi.yaml` | the contract is registered, so route-shaped work and status names behave as they do under `aro run` |
| `*.store` | seed rows are in the repositories a cell `Retrieve`s from |
| `templates/` | `Transform the <page> from the <template: hi.tpl>.` finds the file — with a template executor set, since a service without one answers "Template executor not configured" |
| `Plugins/` | the project's plugin actions and qualifiers resolve (`Greeting.Hello the <h> with …`) |
| the project's `.aro` files | its feature sets are added through the same `addFeatureSet` a `:load` or a cell definition uses, so handler families register through the one classifier above and `Application.<Name>` calls resolve |

**`Application-Start` and `Application-End` are discovered and not executed.** A
session is a place to try statements, not a process that boots an application:
binding ports and starting watchers because a notebook window opened would be a
surprise, and Solaro opens a project as soon as one does. The count of skipped
lifecycle feature sets is reported, so it is visible rather than silent.

Each item is wired in independently and a failure in one is a warning, not a
refusal: a project with a malformed contract still gives you its templates. A
session is a tool for finding out why something is broken, which it cannot be if
the breakage stops it from starting.

Without a directory nothing changes — a bare `aro repl` is the session it always
was (GitLab #691).

## Output with no cell

A handler runs when something outside the notebook says so. A `File Event
Handler` woken by a file dropped into a watched directory may fire between two
cells, or while nobody is typing — and its output belongs to no cell at all.

Such output is sent as a `stream` message carrying **no `id`** and an
`origin`:

```json
{"type":"stream","origin":"background","name":"stdout","text":"New export landed: harbor.csv\n"}
```

The alternative — stamping it with whichever request was last seen — says
something false about causation, and a front-end that has already finalised
that cell either renders the line under a finished cell or drops it. Neither is
visible to the user as a mistake, which is what makes it worth a distinct
message rather than a best guess (GitLab #913).

A front-end should render background output somewhere of its own: a log pane, a
status area, or appended to the notebook with its origin shown. What it must
not do is attribute it to a cell.

Output produced *while* a cell is executing still carries that cell's `id`,
including a handler the cell itself woke — the cell is running, so it is the
honest owner even when it is not the cause.

## Output capture

`Log` writes to stdout directly, as do assorted warnings and `print`s in the
runtime — on the same descriptor the protocol uses. Two mechanisms, layered:

1. **`ConsoleObject.sink`**, a `@TaskLocal` the runtime already consults
   before falling back to a descriptor write. Installed around every
   execution, so console output becomes a protocol message at the moment it
   happens. Exact ordering, and it works on every platform.
2. **Descriptor redirection** (POSIX only). The real stdout is duplicated for
   protocol use, then fd 1 and fd 2 are replaced with pipes that are drained
   into `stream` messages. This catches everything the sink cannot see: stray
   `print`s, plugin output, deferred-failure warnings on stderr.

Draining uses a sentinel: before answering, the server writes a marker into
the pipe and waits for the reader to reach it. That is what makes the ordering
guarantee true across a real pipe rather than merely likely.

On Windows only (1) is available; `Log` is captured, stray `print`s are not.

## The kernels

Two kernels reach notebooks; both run cells through the same
`REPLCellEngine`, so a cell behaves identically under either.

### `aro kernel` — native (the default)

`aro kernel` speaks Jupyter's wire protocol (5.3) over ZeroMQ directly —
no Python anywhere. `aro kernel install` writes the kernelspec into the
user's Jupyter data dir; the front-end then launches
`aro kernel --connection-file …` itself. libzmq is a system dependency
(`brew install zeromq` / `libzmq3-dev`), declared the same way libgit2
already is; message signing is HMAC-SHA256 via swift-crypto, and a
message whose signature does not verify is dropped, not answered.

Threading follows libzmq's one-socket-one-thread rule: heartbeat echoes
on its own thread, control has its own so shutdown stays answerable
mid-cell, shell recv/handle/reply sequentially (one request at a time
*is* the protocol), and iopub — written by both the shell thread and the
output-capture readers — is serialized by a lock. Stdin is confined to a
serial queue of its own, because an `input_request` is raised *by* the
cell the shell thread is blocked on. Output capture is the same
descriptor-redirection machinery the JSON server uses, sentinel drain
included, so every `stream` for a cell is on iopub before that cell's
reply.

Windows is excluded — the kernel shares the REPL's POSIX capture
machinery. Use the Python shim there.

### `Editor/jupyter-aro` — the Python shim

An `ipykernel` subclass owning one `aro repl --json` subprocess;
`jupyter_client` handles ZMQ, signing, heartbeat. It predates the native
kernel and remains the Windows path and the reference client for the
JSON protocol. It does no ARO parsing — everything language-shaped stays
on the ARO side. An `input_request` is relayed onto ipykernel's own
`raw_input` / `getpass`, which is the same stdin channel the native
kernel speaks directly.

### Interrupt

A cell blocked inside the runtime cannot be unwound — from Python or
in-process. Both kernels declare signal interrupt: the process is killed
and replaced, and says so — the session's variables and definitions are
gone. An honest restart beats a hang or a silent amnesia.

### Widgets (comms)

The native kernel implements Jupyter's comm protocol — `comm_open` /
`comm_msg` / `comm_close` / `comm_info_request` — and on it, an
`ipywidgets` subset: **controls bound to session variables**.

```
:widget slider <volume> 0 11      IntSlider bound to <volume>
:widget text <name>               Text field bound to <name>
:widget list                      what's bound in this session
```

Creating a control opens the ipywidgets-8 model comms (a LayoutModel, a
style model, the control referencing both) and publishes a
`display_data` carrying `application/vnd.jupyter.widget-view+json`.
Dragging the slider sends the standard `update` — the kernel writes the
session variable, so the next cell computes with the new value. The
binding is the *only* writer a session variable has: ARO's immutability
still holds for code, which is exactly what makes a slider-fed variable
coherent.

`:widget` exists only under `aro kernel` — the widget lives in the comm
layer only that transport has. In `aro repl` it reports itself as
unavailable, like any unknown meta-command.

### Debug protocol

`debug_request` on the control channel tunnels DAP. The kernel serves
the subset that is true for ARO today: `inspectVariables` /
`richInspectVariables` / `variables` (JupyterLab's variable inspector),
`evaluate` against the live session, `dumpCell` with Murmur2 path
naming (`debugInfo` publishes prefix/suffix/seed), and the lifecycle
handshake. Breakpoints answer `verified: false` with the reason in the
message: ARO cells run to completion, and pausing mid-cell needs the
runtime's pause engine wired into the kernel — promising a stop that
never comes would be worse than the hollow dot JupyterLab renders for
the honest answer.

### Rebinding across cells

The semantic analyzer catches duplicate bindings within one program; a
cell compiled alone cannot see that an earlier cell bound the name, and
the runtime treats that miss as a fatal compiler bug — which killed the
kernel. The cell engine now answers with ARO's own immutability message
(bind a new name, or reset the session) before execution, on every
front-end.

## Limits

- **Transport-bound handlers do not fire.** `Socket`, `WebSocket` and
  `KeyPress` handlers — plus repository evictions, watches and
  `Application-End` — need something a session does not own, so they are
  reported as undelivered when defined rather than waited for (see *Handler
  families* above). Everything an ARO statement can trigger dispatches.
- **One request at a time.** `REPLSession` is not internally synchronised, and
  the protocol is request/response; concurrent requests are not supported. An
  open `input_request` is part of its cell's request, so a second request sent
  before the answer is refused rather than queued (see *Interactive input*).
- **No input widget.** `Select` renders a numbered menu and reads a number;
  neither front-end offers a real picker, and SOLARO does not opt into input at
  all yet.

## Completion & inspection

`complete` and `inspect` are LSP-backed. The input is framed exactly the
way `execute` frames it — wrapped in a temporary feature set unless it
already defines one, the session's definitions appended after — compiled,
and handed to the same `CompletionHandler` / `HoverHandler` that
`aro lsp` serves. A cell therefore completes the way a document does, by
construction: context classification (statement opener, `<identifier`,
qualifier slot, feature-set header) and compilation-derived symbols
included.

What the LSP cannot know is merged in from the session: its live
variables — whose current *values* answer `inspect`, ahead of static
hover — its defined feature sets, and the `:` meta-commands. On Windows,
where `AROLSP` does not build, this session-local layer answers alone.

The `complete` result carries two shapes: `matches`, a flat name list
that replaces `[cursorStart, cursorEnd)` verbatim (what Jupyter's
`complete_reply` wants), and `items`, richer `label` / `kind` / `detail`
entries in the LSP's kind vocabulary for clients that can render them.
Snippet items appear only in `items` — their placeholder syntax is not a
verbatim replacement.

The terminal REPL's Tab key routes through the same engine, so Tab in
`aro repl` and Tab in a notebook agree.

## Future directions

- Pausing cells: wiring the runtime's pause engine (`aro debug`) into the
  kernel's debug adapter, so breakpoints verify and `stopped` events fire.
- More widget controls (dropdowns, buttons wired to feature-set
  invocations) on the same comm layer.
