# Chapter 50: Request Bodies

A web application receives two kinds of request body, and they want opposite
things. A JSON document of a few hundred bytes wants to be a value: you read a
field out of it and carry on. A file upload of four gigabytes wants never to be
a value at all: you put it somewhere and forget about it.

Most frameworks make you choose in advance, with a different API for each. ARO
does not, because there is nothing to choose. You write what you mean, and the
statement you write decides.

## The rule

> **Streams don't have a size. Values do.**
>
> Moving data doesn't read it. Using data reads it. Only reading has a limit.

<div style="text-align: center; margin: 2em 0;">
<svg width="560" height="230" viewBox="0 0 560 230" xmlns="http://www.w3.org/2000/svg" font-family="sans-serif">
  <!-- Left: moving -->
  <text x="140" y="20" text-anchor="middle" font-size="12" font-weight="bold" fill="#166534">Moving it</text>
  <rect x="20" y="34" width="240" height="150" rx="6" fill="#f0fdf4" stroke="#22c55e" stroke-width="1.5"/>

  <!-- socket -->
  <rect x="36" y="54" width="60" height="34" rx="4" fill="#dcfce7" stroke="#16a34a" stroke-width="1"/>
  <text x="66" y="75" text-anchor="middle" font-size="9" fill="#166534">socket</text>
  <!-- arrow -->
  <line x1="98" y1="71" x2="130" y2="71" stroke="#16a34a" stroke-width="1.5"/>
  <polygon points="136 71, 128 67, 128 75" fill="#16a34a"/>
  <!-- chunk -->
  <rect x="138" y="54" width="42" height="34" rx="4" fill="#dcfce7" stroke="#16a34a" stroke-width="1"/>
  <text x="159" y="75" text-anchor="middle" font-size="9" fill="#166534">chunk</text>
  <line x1="182" y1="71" x2="212" y2="71" stroke="#16a34a" stroke-width="1.5"/>
  <polygon points="218 71, 210 67, 210 75" fill="#16a34a"/>
  <!-- sink -->
  <rect x="200" y="54" width="46" height="34" rx="4" fill="#dcfce7" stroke="#16a34a" stroke-width="1"/>
  <text x="223" y="75" text-anchor="middle" font-size="9" fill="#166534">file</text>

  <text x="140" y="112" text-anchor="middle" font-size="10" fill="#166534">Write the &lt;upload&gt; to the &lt;file: target&gt;.</text>
  <text x="140" y="134" text-anchor="middle" font-size="10" fill="#166534">memory: two chunks, whatever the size</text>
  <text x="140" y="156" text-anchor="middle" font-size="10" font-weight="bold" fill="#166534">no limit applies</text>
  <text x="140" y="174" text-anchor="middle" font-size="9" fill="#166534">the sink bounds it</text>

  <!-- Right: reading -->
  <text x="420" y="20" text-anchor="middle" font-size="12" font-weight="bold" fill="#991b1b">Reading it</text>
  <rect x="300" y="34" width="240" height="150" rx="6" fill="#fef2f2" stroke="#ef4444" stroke-width="1.5"/>

  <rect x="316" y="54" width="60" height="34" rx="4" fill="#fee2e2" stroke="#dc2626" stroke-width="1"/>
  <text x="346" y="75" text-anchor="middle" font-size="9" fill="#991b1b">socket</text>
  <line x1="378" y1="71" x2="408" y2="71" stroke="#dc2626" stroke-width="1.5"/>
  <polygon points="414 71, 406 67, 406 75" fill="#dc2626"/>
  <rect x="416" y="46" width="106" height="50" rx="4" fill="#fee2e2" stroke="#dc2626" stroke-width="1"/>
  <text x="469" y="66" text-anchor="middle" font-size="9" fill="#991b1b">value in memory</text>
  <text x="469" y="82" text-anchor="middle" font-size="9" fill="#991b1b">bounded</text>

  <text x="420" y="112" text-anchor="middle" font-size="10" fill="#991b1b">Extract the &lt;text&gt; from the &lt;note: text&gt;.</text>
  <text x="420" y="134" text-anchor="middle" font-size="10" fill="#991b1b">memory: up to the route's limit</text>
  <text x="420" y="156" text-anchor="middle" font-size="10" font-weight="bold" fill="#991b1b">x-aro-max-body, default 1MB</text>
  <text x="420" y="174" text-anchor="middle" font-size="9" fill="#991b1b">over it: 413, before it is read</text>

  <text x="280" y="212" text-anchor="middle" font-size="10" fill="#374151">The program says nothing about which is which — the statement decides.</text>
</svg>
</div>

## Two feature sets

They differ in one line, and that line is the whole difference:

```aro
(* Moves the body. Four gigabytes is fine: nothing is ever built. *)
(uploadDocument: Files API) {
    Extract the <name> from the <pathParameters: name>.
    Extract the <upload> from the <request: body>.
    Compute the <target> from "/var/uploads/" ++ <name>.
    Write the <upload> to the <file: target>.
    Return a <Created: status> with <name>.
}

(* Reads the body. It becomes a value, so the route's limit applies. *)
(createNote: Notes API) {
    Extract the <note> from the <request: body>.
    Extract the <text> from the <note: text>.
    Return a <Created: status> with <text>.
}
```

Notice what `Extract the <upload> from the <request: body>.` does in the first
one: nothing. It moves a name onto the body. The bytes have not arrived yet and
may never be in memory at all. The `Write` on the next line is what pulls them,
one chunk at a time, straight out to the file.

## Declaring the limit

The limit lives with the route, in the contract, next to everything else about
that route's shape:

```yaml
paths:
  /documents/{name}:
    post:
      operationId: uploadDocument      # streams — no limit applies
  /notes:
    post:
      operationId: createNote
      x-aro-max-body: 256KB            # reads the body — this is the ceiling
```

Sizes are written the way people write them: `256KB`, `10MB`, `1.5GB`, `1MiB`,
or a plain byte count. A route that declares nothing gets 1 MB. To change that
default for a whole application:

```aro
Configure the <http-server: max-body> with "1MB".
```

The route's own declaration always wins. A limit belongs with the thing it
protects.

## What you see when it doesn't fit

Nothing about this model is hidden until it goes wrong, and when it goes wrong
the message names the fix rather than the failure:

```
Cannot Extract the <text> from the <note: text>: reading the request body needs
240MB, above POST /notes's 1MB limit. Stream it (Write the <body> to the
<file: …>), or raise x-aro-max-body for POST /notes.
```

And a body sent to a route that reads it never reaches the feature set at all:

```
413  Cannot read the request body for POST /notes: it is 2.0MB, above this
     route's 1KB limit. Raise x-aro-max-body for this operation, or stream the
     body instead of reading it.
```

## Reading the body once

A body arrives from the network exactly once and is not kept. That is a
property of HTTP, not of ARO, and it shows up in the one place where it can
surprise you:

```aro
Write the <upload> to the <file: target>.
Return an <OK: status> with <upload>.     (* the bytes are already gone *)
```

The second statement is refused, with a message naming the first. Return
`<name>` instead — or, if you genuinely want the body in memory, raise
`x-aro-max-body` and read it.

## Handing the body to an event

An event handler outlives the request that emitted the event, so a body handed
to one cannot stay tied to a connection that is about to close. The runtime
*anchors* it: drains it to a temporary file a chunk at a time, and passes on
something every handler can read independently. The file disappears when the
last handler is done with it.

```aro
(archiveDocument: Files API) {
    Extract the <upload> from the <request: body>.
    Emit a <DocumentReceived: event> with <upload>.
    Return an <Accepted: status> for the <archive>.
}

(Archive Upload: DocumentReceived Handler) {
    Extract the <document> from the <event: upload>.
    Write the <document> to the <file: "/var/archive/latest.bin">.
    Return an <OK: status> for the <archive>.
}
```

Still nothing accumulates in memory, and still no size limit applies — the
disk is the sink now, and the sink is what bounds it.

## Knowing before you run

Because the difference is a property of your source, `aro check` can tell you
which routes are which before anything runs:

```
Request bodies:
  streams POST /documents/{name} — no limit applies, nothing is buffered
      note: x-aro-max-body is unused here; this route never builds the body
  holds  POST /notes — up to 256KB in memory (Extract the <text> from the <note: text>, line 15)
```

That is the part worth remembering. The limit is not a runtime surprise waiting
for a large request — it is something you can read off your own program.

---

## Related Proposals

- **ARO-0090**: Streaming I/O and Materialization Limits (this chapter)
- **ARO-0051**: Streaming Execution Engine
- **ARO-0088**: Concurrency Model — deferral is *when*, materialization is *whether*
- **ARO-0035**: Configurable Runtime — `Configure the <http-server: max-body>`

---

*Next: Appendix A — Action Reference*
