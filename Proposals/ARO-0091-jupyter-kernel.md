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
| `complete` | `code`, `cursor` | `matches`, `cursorStart`, `cursorEnd` |
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

## The kernel

`Editor/jupyter-aro` is an `ipykernel` subclass owning one `aro repl --json`
subprocess. `jupyter_client` handles ZMQ, message signing, and heartbeat; the
package translates Jupyter messages to protocol requests and back. It does no
ARO parsing — everything language-shaped stays on the ARO side, so every
client of the protocol behaves identically.

A native Swift kernel would need a libzmq binding, a new C dependency pulling
against the fully-static binary work. The shim reaches notebooks now and can
be replaced later without notebook-visible change.

### Interrupt

A cell blocked inside the runtime cannot be unwound from Python. Interrupt
kills and replaces the process, and says so — the session's variables and
definitions are gone. An honest restart beats a hang or a silent amnesia.

## Limits

- **Event handlers do not fire.** A `… Handler` feature set is registered but
  never dispatched; the kernel runs no event loop. Same as `aro repl` — use
  `aro run` for event-driven applications.
- **One request at a time.** `REPLSession` is not internally synchronised, and
  the protocol is request/response; concurrent requests are not supported.
- **Completion is local.** Actions, qualifiers, session variables, feature
  sets, and meta-commands — not the LSP's full context-aware completion, which
  assumes a document and a compilation a half-typed cell does not have.

## Future directions

- LSP-backed completion and hover, once `AROLSP` is a SwiftPM product.
- Event dispatch in interactive sessions, which would make `Emit` in a cell
  meaningful and benefits `aro repl` equally.
- A native `aro kernel` speaking ZMQ directly, removing the Python dependency.
- `ipywidgets` and the Jupyter debug protocol.
