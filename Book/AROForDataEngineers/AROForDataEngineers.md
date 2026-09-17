# ARO for Data Engineers

**Notebooks, medallion pipelines, and data products**

---

*Language version: 0.12.0 · September 2026*

---

## Abstract

This book is for people who move data for a living. It assumes you know
what a fact table is, why bronze exists, and what happens when a
Tuesday's number changes and nobody can say why. It does not assume you
know ARO.

You will install a Jupyter kernel, open a notebook, and build a medallion
pipeline — landing to bronze to silver to gold — that ingests two CSVs,
drops the rows that are not revenue, joins customers onto orders,
computes line totals once, and writes a data product a business analyst
can open without asking you a question.

Every code block in this book was run before it was written. The finished
project is in `Examples/MedallionPipeline`, and the pipeline's row counts
are asserted in CI, so a change to the language that breaks this book
fails the build rather than aging quietly.

---

## 1. Why a Language for This

Data engineering has two kinds of code. There is the code that expresses
a business rule — *revenue counts confirmed orders only* — and there is
the code that expresses the machinery: session builders, dataframe
plumbing, type coercion, the eight lines that turn a string column into a
number. The first kind is what anyone asks you about. The second is what
fills the file.

ARO is a domain-specific language whose one grammatical form is

> **Action** the **Result** *preposition* the **Object**.

Everything is that sentence. `Read the <orders> from "./landing/orders.csv".`
is a statement. So is `Filter the <confirmed> from the <orders> where
<status> = "confirmed".` There is no framework to configure and no session
to build, because there is no room in the grammar for one.

The trade is real and worth stating plainly. You give up the expressive
range of Python — no arbitrary functions, no library ecosystem, no
notebook full of `df.head()` — in exchange for pipeline code that a
domain expert can read and audit line by line. For transformation logic
that someone will ask questions about a year from now, that is usually
the better side of the trade. For exploratory analysis, it is not, and
this book will tell you where the line is (§9).

### 1.1 What you actually get

- **Statements read as requirements.** The filter that defines revenue is
  one sentence, in the file, in English.
- **Notebook-native.** ARO ships a Jupyter kernel — JupyterLab, VS Code,
  DataSpell — and Solaro, its own notebook editor. Either way the loop is
  the one you already use: run a cell, look at a table, change it, run
  again.
- **One binary.** `aro` is a single executable. No cluster, no JVM, no
  virtualenv for the pipeline itself.
- **Format-aware I/O.** `Read`/`Write` pick their format from the file
  extension — CSV, TSV, JSON, JSONL, YAML, XML, Markdown.

---

## 2. Installing the Kernel

You need one thing: the `aro` binary. It is the kernel as well as the
compiler, so registering it with Jupyter is a command it runs on itself.

### 2.1 The binary

Download the release archive and put `aro` on your `PATH`:

```bash
# Linux
curl -L https://github.com/arolang/aro/releases/latest/download/aro-linux-amd64.tar.gz | tar xz
sudo mv aro /usr/local/bin/

# macOS (Apple silicon)
curl -L https://github.com/arolang/aro/releases/latest/download/aro-macos-arm64.tar.gz | tar xz
sudo mv aro /usr/local/bin/

aro --version
```

Windows builds are on the same page as `aro-windows-amd64.zip`.

### 2.2 The kernel

`aro` is the kernel. It speaks Jupyter's wire protocol over ZeroMQ
directly — no Python, no `ipykernel` — so registering it is one command:

```bash
aro kernel install
```

```
Installed kernelspec: ~/Library/Jupyter/kernels/aro/kernel.json
Pick "ARO" in JupyterLab / VS Code / DataSpell.
```

libzmq is a system dependency, declared the same way libgit2 already is:
`brew install zeromq`, or `apt install libzmq3-dev`.

The kernelspec records the **absolute path of the `aro` that installed
it**, because Jupyter will not inherit your `PATH`. Run
`aro kernel install` from the binary you actually want notebooks to use —
a checkout's `.build/debug/aro` if you are working on the language, the
one on your `PATH` otherwise — and run it again after you move the
binary.

Confirm it registered:

```bash
jupyter kernelspec list
```

You should see `aro` in the list. Then:

```bash
pip install jupyterlab
jupyter lab
```

**New → ARO**, and you have a notebook.

**Windows, and the `pip`-shaped route.** There is a second kernel: an
`ipykernel` subclass that owns one `aro repl --json` subprocess. It
predates the native one and remains the Windows path, because the native
kernel shares the REPL's POSIX output-capture machinery. It ships as a
wheel on the same release page, so installing it does not mean cloning
the repository:

```bash
pip install jupyterlab
pip install https://github.com/arolang/aro/releases/latest/download/aro_kernel-py3-none-any.whl
python -m aro_kernel.install --user
```

That one resolves `aro` from `$ARO_KERNEL_ARO`, or from `PATH`, at
install time:

```bash
export ARO_KERNEL_ARO=/opt/aro/bin/aro
python -m aro_kernel.install --user
```

Both kernels run cells through the same engine, so a notebook behaves
identically under either. Both also declare *signal* interrupt: a cell
blocked inside the runtime cannot be unwound, so interrupting kills and
replaces the kernel process, and says so. The session's variables and
definitions are gone. On a long `Read` that is worth knowing before you
reach for the stop button.

### 2.3 VS Code and DataSpell

Registration is per machine, not per editor — every front-end below
reads the same kernelspec that `aro kernel install` wrote.

**VS Code**: install the Jupyter extension, open a `.ipynb`, and pick
**ARO** from the kernel picker. The `Editor/vscode-aro` extension adds
syntax highlighting for ARO cells.

**DataSpell / PyCharm**: these run notebooks through a Jupyter server and
discover kernels from that server's kernelspec directories, so **ARO**
appears in the kernel selector after a restart. If it does not, check
which Jupyter DataSpell is pointed at and run `jupyter kernelspec list`
from *there*; the native kernelspec is interpreter-independent, but the
directory it lives in is not.

There is an ARO plugin on the JetBrains Marketplace, and it does install
in DataSpell, but it carries language support only — highlighting,
diagnostics, navigation. It does not carry the kernel, and it does not
need to: the kernelspec has to name an `aro` binary that exists on this
machine, which is a thing only that binary can know. `aro kernel
install` is the supported route in every front-end.

### 2.4 Solaro: notebooks without Jupyter

Solaro is ARO's own IDE, and it edits notebooks natively. Its `.repl`
files are the same idea as `.ipynb` — markdown cells and code cells with
their captured outputs, JSON on disk — but with ARO's display bundle as
first-class fields instead of a MIME dictionary, so a notebook diffs
like source rather than like a minified blob.

![A `.repl` notebook in Solaro](screenshots/01-solaro-notebook.png){ width=95% }

Cells run against the same session engine the Jupyter kernel drives, so
the same statements behave the same way: definitions accumulate, the
last value is displayed, and a list of records renders as a table.
Above, silver is being built one cell at a time against the landing CSVs
from §4 — the second cell's result is the fact table itself.

Use whichever fits the moment. JupyterLab, VS Code and DataSpell are the
right answer when the notebook sits beside Python work, in a repository
of `.ipynb` files, or on a machine where the whole team already has a
Jupyter install. Solaro is the right answer when the notebook sits
beside the *application* it becomes: the file tree, the LSP diagnostics,
the actions catalogue and the notebook are one window, and §10's
"build in the notebook, ship as a directory" is a scroll rather than a
context switch.

---

## 3. The First Cells

Type this into a cell and run it:

```aro
Create the <numbers> with [3, 1, 4, 1, 5, 9, 2, 6].
Compute the <total: sum> from the <numbers>.
```

```
31
```

Two things are happening that are worth naming immediately.

**The last value is displayed.** You did not write a print. The cell's
final result is what the notebook shows, the way it would in any REPL.

**State persists between cells.** `<numbers>` is still there in the next
cell. So are feature sets you define. A notebook is one session.

Angle brackets mark identifiers. `<numbers>` is a variable; `19.99` and
`"confirmed"` are literals. The colon inside brackets is a *qualifier* —
`<total: sum>` means "a variable called `total`, computed with the `sum`
operation". You will use qualifiers constantly.

### 3.1 Records and collections

Data engineering is mostly collections of records:

```aro
Create the <orders> with [
    {order_id: 1001, sku: "SKU-RED", quantity: 2, unit_price: 19.99},
    {order_id: 1002, sku: "SKU-BLU", quantity: 1, unit_price: 49.50}
].
```

A list of records renders as an HTML table in the notebook, which is the
single most useful thing the kernel does. A one-line dump of a
collection is unreadable, and collections are what notebooks are for.

Reach into a record with a qualifier:

```aro
Extract the <head: first> from the <orders>.
Extract the <sku> from the <head: sku>.
```

```
SKU-RED
```

`<head: first>` is the first element. `<head: sku>` is the `sku` field of
`head`. The same bracket syntax indexes collections and records both.

### 3.2 Immutability, and the habit it forces

A name is bound once. This does not work:

```aro
Create the <total> with 10.
Create the <total> with 20.     (* error: total is already bound *)
```

In a pipeline this is a feature rather than a nuisance. Every
intermediate result keeps its own name, so a transformation reads as a
chain of stated facts instead of a variable being repeatedly
overwritten — and when a number is wrong, the name of the step that
produced it is right there.

---

## 4. Reading the Source

Our landing zone holds two CSVs. In a real pipeline something else puts
them there — a vendor SFTP, an export job, a Kafka sink. The example
writes them itself in a `SeedLanding` stage so it runs anywhere with
nothing set up first; every stage after that reads files exactly as it
would if upstream had delivered them.

`landing/orders.csv`:

```
order_id,customer_id,sku,quantity,unit_price,status,ordered_at
1001,C001,SKU-RED,2,19.99,confirmed,2026-08-01
1002,C002,SKU-BLU,1,49.50,confirmed,2026-08-01
1003,C001,SKU-GRN,5,4.25,cancelled,2026-08-02
1004,C003,SKU-RED,3,19.99,confirmed,2026-08-02
1005,C002,SKU-GRN,10,4.25,confirmed,2026-08-03
1006,C004,SKU-BLU,2,49.50,pending,2026-08-03
```

And `landing/customers.csv`:

```
customer_id,name,region,tier
C001,Ada Lovelace,EMEA,gold
C002,Grace Hopper,AMER,silver
C003,Alan Turing,EMEA,silver
C004,Katherine Johnson,AMER,gold
```

Reading is one statement:

```aro
Read the <orders> from "./landing/orders.csv".
Compute the <n: length> from the <orders>.
```

```
6
```

`Read` picks its parser from the extension. The same statement against
`orders.jsonl` reads JSON Lines, against `orders.yaml` reads YAML. There
is no reader to configure because the file already said what it is.

Numeric columns arrive usable:

```aro
Extract the <head: first> from the <orders>.
Extract the <qty> from the <head: quantity>.
Extract the <price> from the <head: unit_price>.
Compute the <line-total> from <qty> * <price>.
```

```
39.98
```

No cast, no schema declaration. `2` and `19.99` came out of a text file
and multiplied.

---

## 5. Bronze: The Source, Reproduced

The bronze layer has exactly one job: make the source reproducible. It
does not clean, join, or filter. If the upstream CSV is wrong, bronze is
wrong in the same way — which is precisely what makes it useful when
someone asks why last Tuesday's number changed.

What bronze *adds* is provenance: where the row came from, and when it
was read.

```aro
(IngestOrders: Action) {
    Read the <rows> from "./landing/orders.csv".
    Create the <stamp> with now.

    for each <row> in <rows> {
        Create the <record> with {
            order_id: <row: order_id>,
            customer_id: <row: customer_id>,
            sku: <row: sku>,
            quantity: <row: quantity>,
            unit_price: <row: unit_price>,
            status: <row: status>,
            ordered_at: <row: ordered_at>,
            _source: "landing/orders.csv",
            _ingested: <stamp>
        }.
        Store the <record> into the <bronze-orders-repository>.
    }

    Retrieve the <bronze> from the <bronze-orders-repository>.
    Compute the <count: length> from the <bronze>.
    Log "  bronze/orders.jsonl — " ++ <count> ++ " rows" to the <console>.
    Write the <bronze> to "./bronze/orders.jsonl".
    Return an <OK: status> with <bronze>.
}
```

Four things in that block are worth stopping on.

**`(IngestOrders: Action)`** declares a *user-defined action*. A feature
set whose business activity is `Action` becomes callable as
`Application.IngestOrders`. This is how a pipeline gets named stages
instead of one long procedure.

**`for each <row> in <rows>`** is the loop. Per-record work goes here.

**Repositories are the accumulator.** `Store … into the
<bronze-orders-repository>` appends; `Retrieve … from` reads the lot back.
The `-repository` suffix is not decoration — it is how the runtime knows
the name refers to a repository rather than an ordinary variable.

**`Write … to "./bronze/orders.jsonl"`** writes JSON Lines, chosen from
the extension. JSONL is the right bronze format: append-friendly,
diffable, and readable by everything.

Running it:

```
bronze/orders.jsonl — 6 rows
bronze/customers.jsonl — 4 rows
```

Six rows in, six rows out. Bronze filtered nothing, which is the point.

### 5.1 A note on names

Two naming rules will bite you once each, and then never again.

Identifiers cannot contain a preposition as a hyphenated segment.
`<ingested-at>` fails to parse, because `at` is a preposition and the
parser reaches it expecting a clause. `<stamp>` is fine, and so is
`<ingested-stamp>`. The same applies to `-by`, `-to`, `-with`, `-from`.

Some words are qualifiers with meaning of their own — `matches` is one —
and using them as a plain variable name confuses the parse. When a name
produces a syntax error that seems to point at the wrong place, rename it
before you debug it.

---

## 6. Silver: The Source, Made Trustworthy

Silver is where opinions are allowed. Three of them here:

1. **Only confirmed orders are revenue.** Cancelled and pending rows stay
   in bronze, where they can still be counted if someone asks how many
   orders were abandoned.
2. **Customers are joined on.** Downstream should never have to know that
   region lives in a different file.
3. **Money is computed once, and rounded once.** `line_total` is
   calculated here so every consumer computes it the same way — which is
   to say, so no two dashboards disagree.

```aro
(BuildSilver: Action) {
    Read the <orders> from "./bronze/orders.jsonl".
    Read the <customers> from "./bronze/customers.jsonl".

    Filter the <confirmed> from the <orders> where <status> = "confirmed".

    for each <order> in <confirmed> {
        Extract the <cid> from the <order: customer_id>.
        Filter the <candidates> from the <customers> where <customer_id> = <cid>.
        Extract the <customer: first> from the <candidates>.

        Compute the <raw-total> from <order: quantity> * <order: unit_price>.
        Compute the <line-total: fixed> from the <raw-total>.

        Create the <fact> with {
            order_id: <order: order_id>,
            ordered_on: <order: ordered_at>,
            customer_id: <cid>,
            customer_name: <customer: name>,
            region: <customer: region>,
            tier: <customer: tier>,
            sku: <order: sku>,
            quantity: <order: quantity>,
            unit_price: <order: unit_price>,
            line_total: <line-total>
        }.
        Store the <fact> into the <silver-orders-repository>.
    }

    Retrieve the <silver> from the <silver-orders-repository>.
    Compute the <count: length> from the <silver>.
    Log "  silver/order_facts.jsonl — " ++ <count> ++ " rows" to the <console>.
    Write the <silver> to "./silver/order_facts.jsonl".
    Return an <OK: status> with <silver>.
}
```

```
silver/order_facts.jsonl — 4 rows
```

Six orders in; four facts out. The two that vanished are order 1003
(cancelled) and 1006 (pending), and the statement that dropped them is
one line you can point a finance person at.

Two smaller things in that block. `<order: quantity>` is usable directly
in an expression — the `Extract` per operand that §4 showed is only
needed when you want the value under a name of its own. And
`<line-total: fixed>` is money: `2 × 19.99` in binary floating point is
not `39.98`, and `fixed` makes the stored value the one a person would
write. §7 has the full story, because gold is where it shows.

### 6.1 The join

ARO has no `JOIN`. The join here is a filter inside a loop:

```aro
Extract the <cid> from the <order: customer_id>.
Filter the <candidates> from the <customers> where <customer_id> = <cid>.
Extract the <customer: first> from the <candidates>.
```

Read it as a sentence and it is exactly what a join *is*: for this
order's customer id, find the customer rows that match, take the one.
It is a nested-loop join, and for dimension tables — regions, customers,
product catalogues, the things you actually join to — that is fine. For
joining two large fact tables it is the wrong shape, and §9 says so.

The `where` clause takes the usual comparisons: `=`, `!=`, `<`, `>`,
`<=`, `>=`, plus `contains`, `starts with`, `in`, and `between`.

### 6.2 One row of silver

```json
{"customer_id":"C001","customer_name":"Ada Lovelace",
 "id":"A5862C4B-C30E-49C9-BF81-449DC3FD74C0","line_total":39.979999999999997,
 "order_id":1001,"ordered_on":"2026-08-01","quantity":2,"region":"EMEA",
 "sku":"SKU-RED","tier":"gold","unit_price":19.989999999999998}
```

Note `id`. Storing a record into a repository gives it a key. You can
supply your own — and in the gold layer we will, because a data product
with a random UUID in it is a data product with a question in it.

---

## 7. Gold: A Data Product

Gold is not "the aggregated tables". Gold is *the answer to one
question*, shaped for whoever asked it. Ours: **revenue by region.**

```aro
(BuildRegionRevenue: Action) {
    Read the <facts> from "./silver/order_facts.jsonl".

    Map the <all-regions> from the <facts> with region.
    Compute the <regions: unique> from the <all-regions>.

    for each <region-name> in <regions> {
        Filter the <rows> from the <facts> where <region> = <region-name>.
        Reduce the <raw-revenue> from the <rows> with sum(<line_total>).
        Reduce the <order-count> from the <rows> with count().
        Compute the <revenue: fixed> from the <raw-revenue>.
        Compute the <raw-avg> from <revenue> / <order-count>.
        Compute the <avg-order: fixed> from the <raw-avg>.

        Create the <row> with {
            id: <region-name>,
            region: <region-name>,
            orders: <order-count>,
            revenue: <revenue>,
            avg_order_value: <avg-order>
        }.
        Store the <row> into the <gold-region-repository>.
    }

    Retrieve the <product> from the <gold-region-repository>.
    Compute the <count: length> from the <product>.
    Log "  gold/revenue_by_region.csv — " ++ <count> ++ " rows" to the <console>.
    Write the <product> to "./gold/revenue_by_region.csv".
    Return an <OK: status> with <product>.
}
```

And the product:

```
avg_order_value,id,orders,region,revenue
49.98,EMEA,2,EMEA,99.95
46.0,AMER,2,AMER,92.0
```

CSV, because the person who asked for it opens things in a spreadsheet.
Had they asked for JSON, the only change is the extension.

### 7.1 Money, and the digits you would otherwise ship

Without those two `fixed` statements, the same file reads:

```
avg_order_value,id,orders,region,revenue
49.974999999999994,EMEA,2,EMEA,99.94999999999999
46.0,AMER,2,AMER,92.0
```

That is not an ARO quirk. `19.99` is not representable in binary
floating point, so two of them plus three more land on the `Double` next
door, and the same sum in Python or Java prints the same thing. What
makes it a problem here is where it surfaces: the *console* absorbs it —
human-facing output is rendered at 15 significant digits, so a `Log` of
that revenue prints `99.95` — but a **file does not, and must not**.
`Write` serializes at full precision, and a data product is a file
someone opens.

`fixed` moves the correction from the renderer to the value. It rounds
through the decimal spelling, so what is stored is the `Double` nearest
to `99.95` — the number a person would have written, which the CSV, the
console, and anything that reads the file back then agree about:

```aro
Reduce the <raw-revenue> from the <rows> with sum(<line_total>).
Compute the <revenue: fixed> from the <raw-revenue>.
```

Two decimal places by default; `with { places: 4 }` for a rate. The
result stays a number — a rendered string would print correctly and then
quote itself into a JSON data product, which is a different wrong
answer. There is no `round` qualifier, and no `money` one; both
diagnostics point at `fixed`.

![The same revenue, before and after `fixed`](screenshots/02-solaro-money.png){ width=95% }

The discipline around it matters more than the spelling. **Round each
amount once, where it is produced, to the precision that amount actually
has.** `line_total` is rounded in silver because a line total *is* money
to the cent; the `fixed` in gold is not a second rounding of that number
but the cleanup after summing, because floating-point addition of
exact-to-the-cent values still drifts. What you must not do is round the
same quantity twice at different precisions — that is how two dashboards
come to disagree by a penny, and exercise 4 in Appendix D makes it happen
on purpose so you can see the size of it.

Where a ledger has to balance to the cent rather than merely display
well, the stricter option is still the old one: hold money in integer
minor units through the pipeline and divide once at the end.

One caveat, so the JSONL in §6.2 is not a surprise: ARO's JSON writer
renders every `Double` at 17 significant digits, so a silver row shows
`39.979999999999997` even after `fixed` has made the value the nearest
one to `39.98`. The number is right, the rendering is not, and it is the
CSV data product — the file with a reader — where the difference shows.

### 7.2 Getting the distinct values

```aro
Map the <all-regions> from the <facts> with region.
Compute the <regions: unique> from the <all-regions>.
```

`Map … with region` projects one column out of a collection — a list of
region strings, one per fact. `unique` removes duplicates and **keeps
first-seen order**, which matters more than it sounds: the gold file is
something people diff, and a product whose row order changes run to run
generates questions that have nothing to do with the data.

`Map` takes a *field name*, not an expression. `Map the <totals> from the
<facts> with <line_total> * 0.9.` looks reasonable and fails —

```
Undefined variable: line_total
```

— because `Map` has no per-element binding for the expression to range
over. Per-element arithmetic goes in a `for each` loop, which is what the
silver layer does.

### 7.3 Aggregating

```aro
Reduce the <revenue> from the <rows> with sum(<line_total>).
Reduce the <order-count> from the <rows> with count().
```

`Reduce` aggregates a collection to one value: `sum`, `count`, `avg`,
`min`, `max`, `first`, `last`. Field aggregates name their field;
`count()` takes none.

### 7.4 The `id` column

The gold rows set `id` explicitly:

```aro
Create the <row> with {
    id: <region-name>,
    region: <region-name>,
    ...
```

A repository assigns a UUID key when you do not supply one. In bronze and
silver that is harmless — nobody reads those files by hand. In a data
product it is a column an analyst has to ask about, so we give the row a
key that means something. `id` and `region` carrying the same value is
the familiar surrogate-key-equals-natural-key case, and it is the honest
version: the row's identity *is* its region.

---

## 8. Running the Pipeline

The notebook is where you build it. It is not where you run it at 6am.

The finished project is a single file:

```
MedallionPipeline/
└── main.aro          # seed, the three stages, and the orchestration
```

and it writes `landing/`, `bronze/`, `silver/` and `gold/` as it runs.

`main.aro` ends with the entry point:

```aro
(Application-Start: Medallion Pipeline) {
    Application.SeedLanding the <seeded> with { }.

    Log "== bronze ==" to the <console>.
    Application.IngestOrders the <bronze-orders> with { }.
    Application.IngestCustomers the <bronze-customers> with { }.

    Log "== silver ==" to the <console>.
    Application.BuildSilver the <silver> with { }.

    Log "== gold ==" to the <console>.
    Application.BuildRegionRevenue the <gold> with { }.

    Return an <OK: status> for the <pipeline>.
}
```

Run it:

```bash
$ aro run ./MedallionPipeline
== bronze ==
  bronze/orders.jsonl — 6 rows
  bronze/customers.jsonl — 4 rows
== silver ==
  silver/order_facts.jsonl — 4 rows
== gold ==
  gold/revenue_by_region.csv — 2 rows
[OK] pipeline
```

That is a cron line. There is no scheduler, no orchestrator, no DAG
definition — one command that exits zero or does not.

Two flags matter for operating it:

```bash
aro check ./MedallionPipeline    # syntax and semantics, runs nothing
aro build ./MedallionPipeline    # compile to a native binary
```

`aro check` in CI catches a broken pipeline before it runs against real
data. `aro build` produces a standalone executable, which is the shape
you want inside a container.

### 8.1 Calling a stage from another file

The three stages live in one file here, but they do not have to. A
user-defined action is visible application-wide: put `IngestOrders` in
`bronze.aro` and call it from `main.aro` and it resolves, the same way a
handler in one file receives an event emitted from another. There are no
imports to write — every `.aro` file under the application directory is
discovered and its actions join one flat `Application.` namespace, so a
name may be declared only once across the whole application.

One place still sees a single file at a time: `aro check bronze.aro`
naming the file rather than the directory. There a call into a sibling
file is reported unknown, and the diagnostic says so. Point it at the
directory and it resolves. The REPL is not such a place — every
definition in the session is compiled alongside the statement that calls
it, so an action defined at the prompt is callable from the next line
(GitLab #576).

### 8.2 Passing arguments

`with { }` passes an empty input. To parameterise a stage, declare what
it takes:

```aro
(IngestFile: Action takes <path>) {
    Extract the <p> from the <input: path>.
    Read the <rows> from <p>.
    ...
}
```

and call it positionally:

```aro
Application.IngestFile the <bronze> from "./landing/orders.csv".
```

Without `takes`, callers pass an object with `with { … }`. With it, one
positional argument is extracted as `input.<name>`.

### 8.3 What a stage returns

`Return an <OK: status> with <silver>.` hands back a record with
`status`, `reason`, and `data`. The payload arrives at the caller
serialized, so counting it there counts characters, not rows — which is
why each stage in this pipeline logs its own count, where the collection
is still a collection. Treat a stage's return value as a signal that it
finished, and let the stage report its own numbers.

---

## 9. Where the Line Is

An honest book names the cases where its subject is the wrong tool.

**Data that does not fit in memory.** Every collection here is
materialised. ARO has streaming support for I/O, but the transformation
model in this book reads a file into a list. If your fact table is
100 GB, this is not the tool for that layer.

**Large fact-to-fact joins.** The nested-loop join of §6.1 is fine
against dimension tables and quadratic against another fact table. Join
to dimensions in ARO; do fact-to-fact work in an engine built for it.

**Exploration.** Notebooks are also for poking at data — five variations
of a histogram, a quick correlation. ARO has no plotting and no
statistical library. Use Python for the looking, ARO for the pipeline
that results from it. A notebook can hold both, in different files.

**Anything needing the Python ecosystem.** No pandas, no scikit-learn, no
pyarrow. ARO's plugin system can call out to native code, but if the job
*is* the library, use the library.

Where it fits: transformation logic that a domain expert should be able
to read, in pipelines whose data fits in memory, where the ability to
point at the line that defines revenue is worth more than the ability to
express anything at all.

**And the parts of the job this book does not cover at all.** One
pipeline is not the discipline. Around it sit data platforms, orchestration,
dashboards and the decisions they drive, access and discoverability,
privacy, streaming, and the ownership questions data mesh asks — which
team owns this product, and who do you page when it is wrong. If you
want that map, [Data Derp](https://data-derp.github.io/docs/2.0/intro) is
an open-source curriculum that walks it step by step, vendor-neutral and
exercise-driven. It teaches in Python and SQL on Databricks notebooks;
the vocabulary it establishes — bronze/silver/gold, data product, data
mesh — is the vocabulary this book has been using, so the two read well
together.

---

## 10. A Working Method

What has held up in practice:

**Build in the notebook, ship as a directory.** Prototype each stage in
cells against a slice of data. When the shape is right, move it into
`main.aro` as an action. The code does not change on the way — a cell and
a feature-set body are the same statements.

**Keep bronze stupid.** Every filter you are tempted to add to bronze is
a question you cannot answer later. Land the source; be opinionated in
silver.

**Log row counts at every boundary.** `6 → 4 → 2` is the cheapest
pipeline monitoring there is, and it turns "the numbers look wrong" into
"silver dropped more than it should have".

**Put `aro check` in CI, and assert the counts.** A pipeline that runs
green and writes the wrong number of rows is the failure worth catching.
`Examples/MedallionPipeline` asserts `6 / 4 / 2` in this repository's CI
for exactly that reason.

**Name intermediates for what they are.** Immutability forces a name per
step. Use it: `<confirmed>`, `<candidates>`, `<line-total>` are a
narrative. `<tmp2>` is not.

---

## Appendix A: Operation Reference

Verified against the language version on the cover.

### Reading and writing

| Statement | Effect |
|---|---|
| `Read the <x> from "f.csv".` | Parse by extension: csv, tsv, json, jsonl, yaml, xml |
| `Write the <x> to "f.jsonl".` | Serialize by extension |

### Collections

| Statement | Effect |
|---|---|
| `Filter the <r> from the <xs> where <f> = v.` | Rows matching a predicate |
| `Map the <r> from the <xs> with field.` | Project one column |
| `Group the <r> from the <xs> by "field".` | Partition into a keyed record |
| `Reduce the <r> from the <xs> with sum(<f>).` | `sum`, `count`, `avg`, `min`, `max`, `first`, `last` |
| `Sort the <r> for the <xs>.` | Sorted collection (an action, not a qualifier) |
| `Reverse the <r> for the <xs>.` | Reversed collection (an action) |
| `for each <x> in <xs> { … }` | Per-element work |

### Compute qualifiers

| Qualifier | Effect |
|---|---|
| `length` / `count` | Element or character count |
| `sum`, `avg` / `average` | Numeric aggregate over a collection |
| `unique` | Drop duplicates, first-seen order kept |
| `uppercase`, `lowercase`, `trim`, `replace` | Text |
| `lines`, `join` | Text ↔ collection |
| `hash` / `sha256` | Digest |
| `fixed` | Round to N decimal places, 2 by default — money (§7.1) |
| `-7d`, `+24h`, `+1M` | Date offsets |

The qualifier set is **closed**. An unrecognised one is a check-time
error naming the closest match, not a silent pass-through. Notably
`sort`, `reverse`, `first` and `last` are *not* Compute qualifiers:
sorting and reversing are actions, and element access is an Extract
qualifier (`Extract the <head: first> from the <xs>.`). Nor is `round`
or `money` — both diagnostics point at `fixed`.

Run `aro actions --qualifiers` for the live set.

### Records and repositories

| Statement | Effect |
|---|---|
| `Create the <r> with { a: 1 }.` | Record literal |
| `Extract the <v> from the <r: field>.` | Field access |
| `Extract the <v: first> from the <xs>.` | First element |
| `Store the <r> into the <x-repository>.` | Append; assigns `id` if absent |
| `Retrieve the <all> from the <x-repository>.` | Read everything back |

---

## Appendix B: Troubleshooting

**"Expected identifier, but got preposition(at)"** — an identifier
contains a preposition segment. Rename `<ingested-at>` to `<stamp>`.

**"Unknown user-defined action"** — the action is declared in a different
file. Move it into the calling file (§8.1).

**"Unknown Compute qualifier 'sort'"** — sorting is an action:
`Sort the <sorted> for the <numbers>.` The diagnostic names the
replacement for the common cases.

**`Map … with <expr>` says "Undefined variable"** — you gave `Map` an
expression. It takes a field name, and has no per-element binding for an
expression to range over; per-element arithmetic goes in a `for each`
(§7.2).

**A count is implausibly large** — you counted a stage's return payload
rather than a collection, and got its serialized length (§8.3).

**The output is not where you expected** — `aro run ./MyPipeline` does
not change into the application directory, so relative paths resolve
against *your* current directory. Run it from where you want the layers
written (§8).

**A price ends in `…9999` in the output file** — the console renders at
15 significant digits and hides it; the file does not. Round the value
once, at the layer that publishes: `Compute the <revenue: fixed> from the
<raw-revenue>.` (§7.1).

**"Unknown Compute qualifier 'round'"** — the qualifier is `fixed`, and
the diagnostic says so (§7.1).

**The kernel does not appear in DataSpell** — the kernelspec is in a
Jupyter data directory that DataSpell's server does not read. Find out
which Jupyter it launches, run `jupyter kernelspec list` from there, and
re-run `aro kernel install` under that `JUPYTER_DATA_DIR` if the entry is
missing (§2.3).

**A notebook cell hangs and the stop button restarts everything** — that
is the documented interrupt: a cell blocked inside the runtime cannot be
unwound, so both kernels kill and replace the process. Bindings and
definitions from earlier cells are gone; re-run from the top (§2.2).

---

## Appendix C: The Complete Project

`Examples/MedallionPipeline` in the ARO repository. It runs with:

```bash
aro run ./Examples/MedallionPipeline
```

and writes `landing/`, `bronze/`, `silver/` and `gold/` **relative to
your current directory** — `aro run` does not change into the application
directory, which is worth knowing before you wonder where the output
went. Its row counts are asserted in CI, which is the only reason this
book is allowed to claim they are right.

---

## Appendix D: Exercises

Reading a pipeline is not the same as having built one. Run the project
once (Appendix C) so `bronze/`, `silver/` and `gold/` exist, then work
these in a notebook against those files — a cell and a feature-set body
are the same statements, so anything that works here moves into
`main.aro` unchanged.

**1. Count what bronze kept.** Silver dropped two orders. Prove bronze
still has them, and say how many there are, without re-reading the
landing CSV.

> Answer: `2`.
> ```aro
> Read the <orders> from "./bronze/orders.jsonl".
> Filter the <rejected> from the <orders> where <status> != "confirmed".
> Compute the <n: length> from the <rejected>.
> ```
> This is the bronze promise paying for itself: the rows are still
> countable because nobody was clever in the ingest.

**2. Ship a second data product.** The head of sales wants revenue by
customer *tier*, not by region. Write `gold/revenue_by_tier.csv`.

> Answer: §7's loop with `tier` where `region` was —
> `Map … with tier`, `Compute the <tiers: unique> …`, filter, reduce,
> `fixed`, store, write. Two rows: `gold,39.98` and `silver,151.97`.
> Note what you did *not* have to do: no re-derivation of `line_total`.
> Silver computed money once, so the second product agrees with the
> first by construction.

**3. Break the rounding on purpose.** Delete the two `fixed` statements
from `BuildRegionRevenue`, re-run, and open the CSV. Put them back.

> The point is to see `99.94999999999999` land in a file a person opens,
> once, deliberately — so you recognise it the next time it happens by
> accident (§7.1).

**4. Round the same quantity twice, and watch it drift.** Round
`line_total` in silver to whole units — `Compute the <line-total: fixed>
from the <raw-total> with { places: 0 }.` — leave gold as it is, re-run,
and compare EMEA's revenue against §7's `99.95`.

> You get `100.0`. Nothing errored, no count changed, and the number is
> wrong by five cents — which is exactly why a rounding decision belongs
> in one place, at the precision the amount actually has.

**5. Break the join.** Change the silver join to match on `sku` instead
of `customer_id` and re-run.

> No customer matches an SKU, so the join finds nothing and the stage
> stops on the first order rather than quietly writing four facts with
> empty customer columns. A pipeline that fails is cheaper than one that
> succeeds with the wrong answer — §6's whole argument for putting the
> opinions in silver where they can be pointed at.

**6. Assert the counts.** Add a check that silver has exactly four rows,
so a future change that drops a filter fails loudly instead of shipping.

> ```aro
> Compute the <silver-count: length> from the <silver>.
> Assert the <silver-count> with 4.
> ```
> A wrong count reports `Assertion failed: silver-count is 3, expected 4`
> and stops. `Examples/MedallionPipeline` gets the same guarantee from
> CI, which compares its logged `6 / 4 / 2` against a recorded expectation
> — §10 argues this is the single highest-value check in a pipeline,
> however you spell it.
