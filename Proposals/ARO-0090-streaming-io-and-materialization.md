# ARO-0090: Streaming I/O and Materialization Limits

- **Status:** Accepted (describes the implemented runtime — [Issue #477](https://git.ausdertechnik.de/arolang/aro/-/issues/477))
- **Author:** ARO Language Team
- **Created:** 2026-08-18
- **Related:** ARO-0051 (Streaming Execution), ARO-0088 (Concurrency Model), ARO-0008 (I/O Services), ARO-0005 (Application Architecture), ARO-0035 (Configurable Runtime), ARO-0006 (Error Philosophy)

## Abstract

> **Streams don't have a size. Values do.**
> Moving data doesn't read it. Using data reads it. Only reading has a limit.

This proposal specifies what happens to a request body between the socket and
the feature set: when it becomes a value in memory, what bounds that, and what
a program has to say to get either behaviour.

The answer is that a program says nothing. A feature set that moves its body —
to a file, a socket, the response, an event — never builds it, so its size is
bounded by the sink rather than by memory. A feature set that reads it turns it
into a value, and *that* is what `x-aro-max-body` bounds. Which of the two a
route is, is a property of its source, computed before the server binds a port.

## Motivation

The HTTP server accumulated every request body in memory with no ceiling. One
connection could exhaust the process — no authentication needed, and it took
down every other service sharing it (#477).

The obvious fix is a cap, and every framework ships one (Express 100 KB, Spring
2 MB, nginx 1 MB). A cap alone, though, makes uploads impossible: the first
route that legitimately accepts a 500 MB file forces the global limit up, and
the exposure comes back for every other route at once.

The two requirements only look contradictory while *size* and *memory* are the
same question. They stop being the same question the moment the body is allowed
to flow through the process instead of collecting in it.

## 1. The Rule

A body is not bytes the program holds. It is bytes on their way somewhere.

```
    moving it                              reading it
    ---------                              ----------
    Write the <upload> to the <file: p>.   Extract the <n> from the <note: name>.
    Send the <upload> to the <upstream>.   Compute the <total: sum> from <rows>.
    Return an <OK: status> with <upload>.  Store the <note> to the <notes>.
    Emit a <Received: event> with <it>.    Log <upload> to the <console>.
    for each <chunk> in <upload> { … }     … when <upload> is not empty.

    no limit — the sink bounds it          bounded by the route's limit
```

Nothing in either column is written differently from the way it would be
written for a small body. The difference between them is what the statement
does with the data, which is the difference the programmer already meant.

## 2. Where the limit is declared

In the contract, with the route it protects:

```yaml
paths:
  /documents/{name}:
    post:
      operationId: uploadDocument     # streams — no limit applies
  /notes:
    post:
      operationId: createNote
      x-aro-max-body: 256KB           # reads the body — this is the ceiling
```

`x-aro-max-body` accepts `256KB`, `10MB`, `1.5GB`, `1MiB`, or a plain byte
count. Decimal suffixes are powers of 1000, binary suffixes powers of 1024.

A route that declares nothing gets the runtime default, which is 1 MB and can
be changed globally:

```aro
Configure the <http-server: max-body> with "1MB".
```

or with `ARO_MAX_BODY=512KB` in the environment. A route's own declaration
always wins over the default: the limit belongs with the route it protects.

Declaring a limit on a route that streams is not an error — the value is simply
unused, and `aro check` says so.

## 3. What the runtime does

The materialization analysis (§4) classifies each route once, at startup. Two
paths follow from it, and nothing else does:

```
      POST /notes                          POST /documents/{name}
      (the code reads the body)            (the code only moves it)
              |                                        |
   +----------v-----------+                 +----------v-----------+
   | Content-Length > lim?|--- yes --> 413  | no buffer allocated  |
   +----------+-----------+                 +----------+-----------+
              | no                                     |
   +----------v-----------+                 +----------v-----------+
   | accumulate, checking |                 | socket -> sink, two  |
   | before every append  |--- over --> 413 | chunks in flight     |
   +----------+-----------+                 | (ARO_STREAM_PREFETCH)|
              |                             +----------+-----------+
   +----------v-----------+                            |
   | parse per Content-   |                 +----------v-----------+
   | Type, run feature set|                 | feature set runs     |
   +----------------------+                 | while it arrives     |
                                            +----------------------+
```

**On the reading path** the ceiling is enforced twice: an oversized
`Content-Length` is refused at the request head, before a byte is read — with
`Expect: 100-continue` the client never sends the body at all — and a chunked
body is checked before each append, so the memory over the limit is never
allocated. Both answer `413` and close the connection.

**On the moving path** nothing accumulates. Reads are demand-driven
(`autoRead` off, one read issued per hand-off), so a slow sink throttles the
client through TCP rather than through the heap. Memory is
`ARO_STREAM_PREFETCH × chunk` — two 64 KB buffers by default — regardless of
body size.

**A body nobody reads is drained and discarded.** Before this proposal every
byte was buffered even for a handler that never touched it.

### Response bodies

`Return` of an unread body writes it back out chunk by chunk, with chunked
transfer encoding and no `Content-Length`. An echo or a proxy costs one chunk
of memory rather than the size of the payload.

### Single consumption

A body arrives once and is not retained, so it can be consumed once. A second
consumer is a program error, reported as one (§6).

## 4. The materialization analysis

`BodyMaterializationAnalyzer` (AROParser) answers, per feature set: *does any
statement need the body as a value?*

It is a taint analysis. `<request: body>` and `<body>` are the source;
pass-through verbs propagate the taint to their result; the first whole-value
read of a tainted binding is the answer. Verbs are classified by
`StreamConsumptionPolicy`, an allowlist with reasons in the shape of
ARO-0088's `LazyActionPolicy.deferrableVerbs`:

| class | verbs | why |
|---|---|---|
| `elementWise` | `write`, `append`, `send`, `return`, `broadcast`, `respond`, `emit`, `publish` | consume a chunk at a time and never hold the whole |
| `passThrough` | `extract` (naming no field) | moves the binding without reading it |
| `wholeValue` | everything else | looks inside |
| `elementWise` | `compute` with a folding qualifier (§8) | answers while the bytes go past |

Deliberately `wholeValue`, with reasons:

- **`log`** renders a value for a human. A four-gigabyte render is not a log
  line; `for each` is the streaming spelling.
- **`store`** puts a value in a repository to be queried later. A stream cannot
  be queried and is gone once read.
- **`validate`, `compare`, `transform`** look inside, always.
- **`compute`** looks inside *unless its qualifier folds* — `sha256`, `length`
  and `lines` answer their question while the bytes go past, so a statement
  carrying one of them is element-wise. See §8.

Three further rules:

1. **A guard reads.** `… when <upload> is not empty` asks a question about the
   body, and a question needs an answer — even when the statement it guards
   would only have moved it.
2. **Calls propagate.** `Application.<Name>` (ARO-0081) resolves to the
   callee's own summary, computed to a fixpoint so mutual recursion
   terminates. `takes <field>` unwrapping is not a read.
3. **Unknown is reading.** A plugin action, an unrecognised verb, a route
   whose source is unavailable: all count as reading. Assuming the opposite is
   the assumption that loses memory.

`aro check` reports the result per route, and the language server puts the same
fact at the statement that causes it — an inlay hint reading `reads body ≤ 256KB`
where the body becomes a value, so the cost is visible while the line is being
written rather than after it ships (ARO-0034).

```
Request bodies:
  streams POST /documents/{name} — no limit applies, nothing is buffered
      note: x-aro-max-body is unused here; this route never builds the body
  holds  POST /notes — up to 1KB in memory (Extract the <text> from the <note: text>, line 15)
```

## 5. Crossing a lifetime boundary

`Emit`, `Publish as` and a repository `Store` hand a value to something that
outlives the statement that produced it. A live body cannot go through as it
is: it is tied to a connection that will close, and an event may have many
handlers while a body can be read once.

Such a body is **anchored** — drained to a temporary file one chunk at a time
and passed on as a value any number of readers can open independently. Memory
stays at one chunk; the file is deleted when the last reference to it goes
away, which is ordinary reference counting rather than a lifetime rule anyone
has to remember.

Anchoring is the one place spooling survives in this design, and it is the
exception with a reason — crossing a lifetime boundary, not the default path.

## 6. Diagnostics

Both messages name the fix rather than the failure (ARO-0006).

A body read past its limit:

```
Cannot Extract the <text> from the <note: text>: reading the request body needs
240MB, above POST /notes's 1MB limit. Stream it (Write the <body> to the
<file: …>), or raise x-aro-max-body for POST /notes.
```

A body read twice:

```
Cannot Return an <OK: status> with <upload>: the request body of POST /documents
was already consumed by Write the <upload> to the <file: target>. A body arrives
once and is not kept. Use the earlier result, or raise x-aro-max-body to hold
the body in memory.
```

Refused on the wire, before the feature set runs:

```
413  Cannot read the request body for POST /notes: it is 2.0MB, above this
     route's 1KB limit. Raise x-aro-max-body for this operation, or stream the
     body instead of reading it.
```

## 7. Metrics

ARO-0044 counters distinguish the two paths, which is the question a limit
raises and nothing else answers: how much of the traffic becomes a value, and
how much only passes through.

- `materializedBytes` — request-body bytes that became values
- `streamedBytes` — request-body bytes that flowed through
- `responseStreamedBytes` — response bytes written chunk by chunk
- `rejectedCount` / `rejectedRoutes` — 413s, and which routes produced them

A route expected to stream that shows up in `materializedBytes` is a route
whose code reads its body — worth noticing before it is a memory incident.

## 8. Folding without building

Some questions about a body do not need the body. The qualifier namespace is
closed (#486), so the runtime knows which ones:

| qualifier | what it folds to | over |
|---|---|---|
| `sha256`, `hash` | hex digest | the raw bytes |
| `length`, `count`, `size` | byte count | the raw bytes |
| `lines` | a lazy sequence of lines | the raw bytes, split across chunks |

```aro
(digestBody: Files API) {
    Extract the <payload> from the <request: body>.
    Compute the <digest: sha256> from <payload>.     (* folds — no limit applies *)
    Return an <OK: status> with <digest>.
}
```

A fold makes `Compute` element-wise, so the analysis classifies the route as
streaming and the digest of a four-gigabyte upload costs a chunk. A fold sees
the **raw bytes**, which on a route that never reads its body is all there is —
hashing an upload hashes the upload rather than a rendering of its parsed form.

`sum`, `avg` and `join` are deliberately absent: they are questions about
records, and a body is bytes until something parses it. A chain folds only if
every step does (`lines|length` folds; `lines|uppercase` does not).

## 9. Interaction with ARO-0088

Deferral and materialization are different axes and must not be conflated:

- **Deferral** is *when* a statement runs. A deferrable action starts at its
  statement and is waited for at the first read of its result.
- **Materialization** is *whether* a value is built at all.

A body binding is not a deferred future: it is a value that happens not to have
been read yet. Reading it forces nothing except the bytes themselves.

## 10. Compiled binaries

`aro run` and `aro build` answer the same upload the same way, because both
decide it from the same analysis.

Values do **not** cross the C ABI as serialized strings: `executeAction` takes a
context pointer and the statement's descriptors, and the action resolves its
operands from that context on the Swift side. A body can therefore live in a
compiled binary's context exactly as it does in the interpreter's — nothing
about it has to be flattened to reach an action.

What differs is the server. A compiled binary serves HTTP from
`NativeHTTPServer` (BSD sockets, thread per connection) rather than from NIO, so
that server enforces the policy itself:

- The declared `Content-Length` is checked before the body is read, and the
  accumulated size before each append. Both answer the same `413` with the same
  message, so a client cannot tell which server refused it. (Before this, a
  compiled binary had no limit at all — the same exposure as the interpreter,
  in a build nobody was checking.)
- A streaming route reads on a **separate thread** and hands chunks over a
  bounded channel. That is not an optimisation: the connection thread runs the
  feature set, and a consumer waiting on its own producer never finishes.
- A streamed response is written chunked from the same thread that owns the
  connection.

The policy itself is baked in at build time. A compiled binary has no AST to
analyse at startup, so `LLVMCodeGenerator` runs `BodyMaterializationAnalyzer`
during code generation and emits one `aro_http_set_body_policy(operationId,
streams, limit)` call per route into `main`, carrying `x-aro-max-body` through
as written so the size is parsed in exactly one place at runtime.

## 11. Limits of the implementation

- **Windows.** The FlyingFox path enforces the declared `Content-Length` and
  the post-read size, but hands the body over as one `Data`, so a chunked body
  is bounded by FlyingFox rather than by ARO, and streaming is unavailable.
  Recorded in the README's Platform Support table.
- **Plugins.** A plugin action receives serialized input, so passing a body to
  one materializes it. ARO-0087 may add a declared streaming capability later.
- **Element-wise formats.** `for each` over a body yields byte chunks. Yielding
  NDJSON or CSV *records* straight off the wire is a natural next step
  (ARO-0051 already has the parsers).
- **Chunked request bodies in compiled mode.** `NativeHTTPServer` frames
  requests by `Content-Length` and does not implement
  `Transfer-Encoding: chunked` at all — a pre-existing gap this proposal does
  not close. The interpreter handles both.

## 12. Summary

| | reads the body | only moves it |
|---|---|---|
| buffer | bounded by `x-aro-max-body`, default 1 MB | none |
| oversized `Content-Length` | `413` at the request head | accepted |
| memory | at most the limit | two chunks, whatever the size |
| `aro build` | supported | supported (§10) |
| what the program writes | nothing special | nothing special |
