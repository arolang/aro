# FileUpload

Two routes that differ in one line, and that line is the whole difference
(ARO-0090, GitLab #477):

> **Streams don't have a size. Values do.**

| route | what the code does | limit |
|---|---|---|
| `POST /documents/{name}` | writes the body to a file | none — nothing is buffered |
| `POST /archive/{name}` | hands the body to an event handler | none — the runtime anchors it |
| `POST /echo` | returns the body | none — written back chunk by chunk |
| `POST /digest` | folds a SHA-256 over the body | none — folded while it arrives |
| `POST /notes` | reads a field out of the body | `x-aro-max-body: 1KB` |

## Run it

```bash
aro run ./Examples/FileUpload
```

A 4 GB upload costs one chunk of memory:

```bash
curl -X POST localhost:8080/documents/big.bin --data-binary @big.bin
# -> 201, /tmp/aro-uploads/big.bin
```

A JSON body over the route's limit never reaches the feature set:

```bash
curl -X POST localhost:8080/notes -H 'Content-Type: application/json' \
     --data-binary @2kb.json
# -> 413 Cannot read the request body for POST /notes: it is 2.0KB, above this
#    route's 1KB limit. Raise x-aro-max-body for this operation, or stream the
#    body instead of reading it.
```

## See it before you run it

```bash
aro check ./Examples/FileUpload
```

```
Request bodies:
  streams POST /archive/{name} — no limit applies, nothing is buffered
  streams POST /documents/{name} — no limit applies, nothing is buffered
      note: x-aro-max-body is unused here; this route never builds the body
  streams POST /echo — no limit applies, nothing is buffered
  holds  POST /notes — up to 1KB in memory (Extract the <text> from the <note: text>, line 15)
```

## Both modes

`aro run` and `aro build` answer these routes identically — the analysis is
baked into the binary at build time and the compiled server enforces the same
limits (ARO-0090 §10). `test.sh` runs the whole suite twice, once per mode, and
compares the streamed digest against `hashlib`.
