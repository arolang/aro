# Proposal: Jupyter Kernel & Machine-Readable REPL

**Proposal-ID:** ARO-0091
**Author:** ARO Team
**Status:** Implemented
**Created:** 2026-08-17
**Updated:** 2026-08-17
**Requires:** ARO-0001 (Language Fundamentals), ARO-0081 (User-Defined Actions), ARO-0088 (Concurrency Model)

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
| `execute` | `code` | `status: ok` with optional `display`, or `status: error` |
| `is_complete` | `code` | `status: complete` / `incomplete` (+`indent`) / `invalid` |
| `complete` | `code`, `cursor` | `matches`, `items`, `cursorStart`, `cursorEnd` |
| `inspect` | `code`, `cursor` | `found`, `text` |
| `info` | — | `info` (version, feature sets, variables) |
| `reset` | — | `status: ok`; session cleared |
| `shutdown` | — | `status: ok`; server exits |

Every request carries an `id`. Every request gets exactly one `result` message
with the same `id`.

### Messages from the server

```jsonc
{"type":"ready","version":"0.11.1","protocol":1}          // once, at startup
{"type":"stream","id":1,"name":"stdout","text":"hi\n"}    // output, as it happens
{"type":"result","id":1,"status":"ok","display":{…},"durationMs":3.0}
{"type":"result","id":1,"status":"error","error":{"ename":…,"evalue":…,"traceback":[…]}}
```

**Ordering is guaranteed**: every `stream` for a request precedes that
request's `result`. Clients never have to guess when a cell's output is done.

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

Service-bound handler families — `Socket Event Handler`,
`WebSocket Event Handler`, `File Event Handler`, `KeyPress Handler` —
are *not* subscribed. Their events come from a server the session never
runs; subscribing them would promise dispatch that cannot arrive. Use
`aro run` for those.

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
output-capture readers — is serialized by a lock. Output capture is the
same descriptor-redirection machinery the JSON server uses, sentinel
drain included, so every `stream` for a cell is on iopub before that
cell's reply.

Windows is excluded — the kernel shares the REPL's POSIX capture
machinery. Use the Python shim there.

### `Editor/jupyter-aro` — the Python shim

An `ipykernel` subclass owning one `aro repl --json` subprocess;
`jupyter_client` handles ZMQ, signing, heartbeat. It predates the native
kernel and remains the Windows path and the reference client for the
JSON protocol. It does no ARO parsing — everything language-shaped stays
on the ARO side.

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

- **Service-bound handlers do not fire.** Domain event handlers dispatch
  (see *Event dispatch* above), but `Socket` / `WebSocket` / `File` /
  `KeyPress` handler families need a running service the session never
  starts — use `aro run` for those.
- **One request at a time.** `REPLSession` is not internally synchronised, and
  the protocol is request/response; concurrent requests are not supported.

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
