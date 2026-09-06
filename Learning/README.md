# Learning ARO — the notebook course

A step-by-step ARO course as runnable `.repl` notebooks: markdown prose
between live code cells, executed against a real ARO REPL session
(ARO-0091). Open them in SOLARO (a `.repl` file opens as a notebook), or
in JupyterLab / VS Code / DataSpell after `aro kernel install`.

## The story arc

You have just joined **Brew & Bytes**, a small café going digital. Every
notebook ships one capability of its ordering system — and one piece of
the language. By the end you have touched everything the café's real
service needs, and notebook 14 shows how the pieces become an actual
`aro run` application with an HTTP API.

The arc is deliberate: values before computations, computations before
collections, collections before events, events before actions — each
notebook uses only what earlier ones taught, and ends by naming where
its ideas continue.

## The notebooks

| # | Notebook | Teaches | Café capability |
|---|----------|---------|-----------------|
| 01 | [Hello, ARO](01-hello-aro.repl) | Statements: Action–Result–Object, the console | The shop says hello |
| 02 | [Values & Literals](02-values-and-literals.repl) | Strings, numbers, booleans, records, lists | The menu as data |
| 03 | [Compute & Qualifiers](03-compute-and-qualifiers.repl) | The Compute action, qualifier-as-name, the closed qualifier namespace | Pricing an order |
| 04 | [Immutability](04-immutability.repl) | One name, one binding; the new-name pattern | Receipts that can't be forged |
| 05 | [Expressions & Conditionals](05-expressions-and-conditionals.repl) | Arithmetic, comparison, logic, `when` guards | Order rules (discounts, minimums) |
| 06 | [Collections & Pipelines](06-collections-and-pipelines.repl) | Filter, Sort, Group, Map, `for each`, aggregation | Analyzing a day of orders |
| 07 | [Text Processing](07-text-processing.repl) | Split, regex, lines/join, encodings, escaping | Cleaning customer feedback |
| 08 | [Dates & Times and Intervals](08-dates-and-times.repl) | Date arithmetic, ranges, formatting, sleep intervals | Opening hours & schedules |
| 09 | [Feature Sets & Events](09-feature-sets-and-events.repl) | Feature sets, business activities, Emit, handlers, state guards | Order events through the shop |
| 10 | [User-Defined Actions](10-user-defined-actions.repl) | `Application.<Name>`, `takes`, recursion | Reusable pricing logic |
| 11 | [Set Operations & Merging](11-set-operations-and-merging.repl) | Union, intersect, difference, merge | Loyalty audiences |
| 12 | [Templates & Output](12-templates-and-output.repl) | Render (mustache), escaping, context-aware output | Printable receipts |
| 13 | [Repositories & State](13-repositories-and-state.repl) | Store/Retrieve, `where`, observers, store files | Keeping inventory |
| 14 | [Building Applications](14-building-applications.repl) | App structure, contract-first HTTP, services, concurrency, testing, native builds | From notebook to running café service |

## The advanced track

The café grew — it's franchising. The second track takes the same
story into production territory: concurrency, streaming, a real data
platform, operations. These notebooks may **read** the fixtures shipped
under [`data/`](data/) and **write only** into a `.scratch/` directory
they clean up; anything that needs a running server, the network, or a
mutable git repository is taught with annotated code blocks and links
rather than live cells, so the validator stays deterministic.

| # | Notebook | Teaches | Franchise capability |
|---|----------|---------|----------------------|
| 15 | [Concurrency & Deferral](15-concurrency-and-deferral.repl) | The ARO-0088 model: deferral, forcing, `parallel for each`, ordered effects | Serving the morning rush |
| 16 | [Streaming Execution](16-streaming-execution.repl) | Streams, pipelining, bounded prefetch, bodies that stay streams (ARO-0090) | Receipts that never fit in memory |
| 17 | [Data Engineering](17-data-engineering-medallion.repl) | Bronze/silver/gold, ingestion, joins, data products | The franchise data platform |
| 18 | [Format-Aware I/O](18-format-aware-io.repl) | JSON/JSONL/YAML/CSV/TSV by extension (ARO-0040) | One dataset, every consumer |
| 19 | [HTTP Services & Clients](19-http-services-and-clients.repl) | Contract-first serving, the Request action, timeouts | The online ordering API |
| 20 | [WebSockets & Real-Time](20-websockets-and-realtime.repl) | WebSocket serving, live updates, socket services (ARO-0048) | The kitchen display |
| 21 | [Files & Watching](21-files-and-watching.repl) | Extended file ops (ARO-0036), monitoring, file events | The nightly export drop |
| 22 | [Git & DevOps](22-git-and-devops.repl) | Native git actions (ARO-0080), CI thinking, releases | Shipping the menu as code |
| 23 | [Toolsmith: CLI & Config](23-toolsmith-cli-and-config.repl) | Parameters (ARO-0047), Configure (ARO-0035), exec, plugins as tools | Internal tooling |
| 24 | [State Machines & Domain Modeling](24-state-machines-and-domain-modeling.repl) | Accept transitions, guards (ARO-0022), DDD (ARO-0014) | The order lifecycle |
| 25 | [Testing & Quality](25-testing-and-quality.repl) | Colocated tests, Given/When/Then (ARO-0015), `aro check`/`diff` | Trusting every branch |
| 26 | [Observability & Deployment](26-observability-and-deployment.repl) | Metrics (ARO-0044), logging, time travel, native builds, Linux/Docker | Running 40 shops |

## How to run

**SOLARO**: open this repository (or copy `Learning/` into any project)
and click a `.repl` file — it opens as a notebook; ⇧⏎ runs a cell.

**Jupyter**: `aro kernel install`, then open the files' cells in a
JupyterLab session with the ARO kernel (or drive them from the
`Editor/jupyter-aro` shim).

Cells are **non-destructive**: they compute, define, and store in the
session's memory only — no files are written, nothing leaves the
machine. Each notebook is self-contained: run it top to bottom in a
fresh session. One notebook (04) contains a cell that is *supposed* to
fail — it is marked in the text and carries `(* expect-error *)` so the
validator expects the error too.

## Validating

Every code cell of every notebook runs in CI-style through the real
REPL:

```bash
swift build --product aro
ARO_BIN=.build/debug/aro python3 Learning/validate.py
```

A cell that stops compiling — because the language moved — fails the
validator, so the course cannot silently rot.

## Where the depth lives

Notebooks explain precisely but briefly; when a topic deepens, they
link instead of sprawling:

- **The Language Guide** (`Book/TheLanguageGuide/`) — the 50-chapter
  reference companion; every notebook names its chapters.
- **The wiki** — task-oriented guides:
  <https://github.com/arolang/aro/wiki>.
- **Proposals** (`Proposals/`) — the authoritative specifications
  (`ARO-0001` fundamentals through `ARO-0091` notebooks themselves).
