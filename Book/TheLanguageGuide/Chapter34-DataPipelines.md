# Chapter 34: Data Pipelines

ARO provides a map/reduce style data pipeline for filtering, transforming, and aggregating collections. Results can carry a type annotation drawn from your OpenAPI schemas; the annotation documents intent and is not enforced, so treat it as a comment the tooling can read rather than a guarantee.

## Pipeline Operations

ARO supports five core data operations:

| Operation | Purpose | Example |
|-----------|---------|---------|
| **Retrieve** | Retrieve and filter data | `Retrieve the <users: List<User>> from the <repository>...` |
| **Filter** | Filter existing collection | `Filter the <active: List<User>> from the <users>...` |
| **Map** | Extract one field from every element | `Map the <names: name> from the <users>.` |
| **Reduce** | Aggregate to single value | `Reduce the <total> as Float from the <orders> with sum(<amount>).` |
| **Group** | Partition by field value | `Group the <status-groups> from the <orders> by "status".` |

### Type Annotation Syntax

ARO supports two equivalent syntaxes for type annotations:

```aro
(* Colon syntax: type inside angle brackets *)
Filter the <active-users: List<User>> from the <users> where <active> is true.

(* As syntax: type follows the result descriptor *)
Filter the <active-users> as List<User> from the <users> where <active> is true.
```

Both produce identical results. The `as Type` syntax (ARO-0003) can be more readable when the variable name is long, while the colon syntax keeps everything compact. Type annotations are optional since ARO infers types from the source collection.

---

## Retrieve

Retrieves data with optional filtering, sorting, and pagination.

```aro
(* Basic retrieve *)
Retrieve the <users: List<User>> from the <user-repository>.

(* With filter *)
Retrieve the <active-users: List<User>> from the <users>
    where <status> is "active".

(* Ordering is a separate Sort step *)
Retrieve the <all-users: List<User>> from the <users>.
Sort the <recent-users: List<User>> from the <all-users> by "created-at".
```

> **Note:** SQL-style `order by ... asc/desc`, `limit`, and `offset` clauses are
> not part of the current parser. Order a collection with the `Sort` action (see
> **Sorting** below).

---

## Filter

Filters an existing collection with a predicate.

```aro
(* Filter by equality *)
Filter the <admins: List<User>> from the <users>
    where <role> is "admin".

(* Filter by comparison *)
Filter the <high-value: List<Order>> from the <orders>
    where <amount> > 1000.

(* Filter with multiple conditions — one where clause *)
Filter the <active-premium: List<User>> from the <users>
    where <status> is "active" and <tier> is "premium".
```

### Comparison Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `is`, `=` | Equality | `<status> is "active"` |
| `is not`, `!=` | Inequality | `<role> is not "guest"` |
| `>`, `>=`, `<`, `<=` | Comparison | `<age> >= 18` |
| `in` | Set membership | `<status> in ["a", "b"]` |
| `not in` | Set exclusion | `<status> not in <excluded>` |
| `contains` | Substring | `<name> contains "test"` |
| `matches` | Regex pattern | `<email> matches /^admin@/i` |

A `where` clause combines predicates with `and` and `or`:

```aro
Filter the <closed: List<Order>> from the <orders>
    where <status> = "delivered" or <status> = "cancelled".
```

Chaining `Filter` statements is the other way to write an `and`, and it is
sometimes the clearer one, because each stage gets a name you can log:

```aro
Filter the <active> from the <users> where <status> is "active".
Filter the <active-premium> from the <active> where <tier> is "premium".
```

`Delete` is the exception: it takes exactly one predicate, and a compound
`where` on a repository delete is refused at check time (Chapter 36).

### Set Membership with `in` and `not in`

The `in` and `not in` operators test set membership. They accept either a CSV string or an array variable:

```aro
(* Using CSV string *)
Filter the <pending: List<Order>> from the <orders>
    where <status> in "pending,processing".

(* Using array variable *)
Create the <exclude-statuses> with ["cancelled", "refunded"].
Filter the <active: List<Order>> from the <orders>
    where <status> not in <exclude-statuses>.

(* Combining with other conditions *)
Filter the <valid-orders: List<Order>> from the <orders>
    where <amount> > 0 and <status> not in <exclude-statuses>.
```

The `matches` operator supports regex literals with flags:

```aro
(* Filter users with admin emails *)
Filter the <admins: List<User>> from the <users>
    where <email> matches /^admin@|@admin\./i.

(* Filter valid email addresses *)
Filter the <valid-emails: List<User>> from the <users>
    where <email> matches /^[\w.+-]+@[\w.-]+\.[a-zA-Z]{2,}$/i.
```

---

## Map

`Map` pulls one field out of every element of a collection. The qualifier names
the field, and the result is the list of that field's values:

```aro
Create the <users> with [
    { id: "1", name: "Alice" },
    { id: "2", name: "Bob" }
].

Map the <names: name> from the <users>.
(* ["Alice", "Bob"] *)
```

The `with` spelling is the same statement written the other way round, and the
two are interchangeable:

```aro
Map the <names> from the <users> with name.
```

**The qualifier is a field name, never a value or an expression.** There is no
per-element binding, so `with <user> * 0.9` has nothing to range over and
`with 3` has nothing to mean; both are check-time errors. To compute something
per element, use `for each` (Chapter 33) and accumulate.

### Map projects onto a schema

Naming a schema from `components/schemas` turns a `List<User>` into a
`List<UserSummary>`, copying **only** the fields the target declares:

```yaml
# openapi.yaml
components:
  schemas:
    UserSummary:
      type: object
      properties:
        id: {type: string}
        name: {type: string}
        email: {type: string}
```

```aro
Map the <summaries: List<UserSummary>> from the <users>.
(* [{ id: "1", name: "a", email: "a@x" }] — password-hash is gone *)
```

Both spellings do the same thing, so use whichever reads better:

```aro
Map the <summaries: List<UserSummary>> from the <users>.
Map the <summaries> as List<UserSummary> from the <users>.
```

`List<X>`, `Array<X>`, `Set<X>` and a bare `X` all name the schema `X`.

**Nested records are projected too.** A declared property that is itself an
object is projected onto its own schema, so a field one level down is dropped
as surely as one at the top:

```aro
(* Deep declares id and address; Address declares city *)
Map the <safe: List<Deep>> from the <records>.
(* address.zip and the top-level secret are both gone *)
```

**An annotation that names no schema is an error**, not an empty list:

```aro
Map the <summaries: List<NoSuchSchema>> from the <users>.
(* Runtime Error: Cannot map the summaries: List<NoSuchSchema> from the users. *)
```

That matters, because both spellings used to fail quietly
(GitLab #559): the
qualifier form read `UserSummary` as a *field name* and returned `[]`, and the
`as` form passed every row through untouched — `password-hash` and all —
which looked like it had worked.

Without an annotation, `Map` still passes rows through unchanged. Projection is
something you ask for.

---

## Reduce

Aggregates a collection to a single value using aggregation functions.

```aro
(* Count items *)
Reduce the <user-count: Integer> from the <users>
    with count().

(* Sum numeric field *)
Reduce the <total-revenue: Float> from the <orders>
    with sum(<amount>).

(* Average *)
Reduce the <avg-price: Float> from the <products>
    with avg(<price>).

(* Min/Max *)
Reduce the <highest-score: Float> from the <scores>
    with max(<value>).

(* With filter — filter first, then reduce *)
Filter the <pending: List<Order>> from the <orders>
    where <status> is "pending".
Reduce the <pending-count: Integer> from the <pending>
    with count().
```

### Aggregation Functions

| Function | Description | Example |
|----------|-------------|---------|
| `count()` | Number of items | `with count()` |
| `sum(field)` | Sum of numeric field | `with sum(<amount>)` |
| `avg(field)` | Average of numeric field | `with avg(<price>)` |
| `min(field)` | Minimum value | `with min(<date>)` |
| `max(field)` | Maximum value | `with max(<score>)` |
| `first()` | First element | `with first()` |
| `last()` | Last element | `with last()` |

### `count()` vs `Compute length` — Choosing the Right Tool

`Reduce … with count()` is not the only way to count a collection. The `Compute` action with a `length` or `count` qualifier does the same thing in one line:

```aro
Create the <all-files> with ["report.pdf", "notes.txt", "data.csv"].

(* Pipeline style — explicit type, composes with Filter/Map/Retrieve *)
Reduce the <file-count: Integer> from the <all-files> with count().

(* OWN style — concise, works on lists and strings *)
Compute the <file-count: length> from the <all-files>.
```

Both statements bind `file-count` to `3`. The difference is in role and context:

| | `Reduce … with count()` | `Compute <n: length>` |
|---|---|---|
| **Role** | Aggregate (data pipeline) | OWN (pure transformation) |
| **Type annotation** | Explicit (`: Integer`) | Inferred |
| **Works on** | Collections | Collections and strings |
| **Pipeline fit** | Natural (pairs with Filter/Map) | Standalone |
| **Best for** | Aggregation inside a pipeline | Quick size check of any value |

As a guideline: use `Reduce` when you are already in a pipeline (after a `Filter`, `Map`, or `Retrieve`) or when the explicit type annotation adds clarity. Use `Compute` for a quick, self-contained count.

See **Chapter 9 — Computations** for the full `Compute` reference.

---

## Group

Partitions a collection into sub-collections based on a field value. Returns a dictionary mapping each unique field value to an array of matching items.

```aro
(* Group by a field *)
Group the <result> from the <collection> by "fieldName".
```

### Examples

```aro
(* Group orders by status *)
Create the <orders> with [
    { id: 1, status: "active", amount: 100 },
    { id: 2, status: "pending", amount: 250 },
    { id: 3, status: "active", amount: 500 }
].
Group the <status-groups> from the <orders> by "status".
(* Result: { "active": [{id:1,...}, {id:3,...}], "pending": [{id:2,...}] } *)

(* Group users by role *)
Group the <role-groups> from the <users> by "role".
(* Result: { "admin": [...], "editor": [...], "viewer": [...] } *)
```

### Using Grouped Results

The grouped result is a dictionary, so you can extract individual groups or iterate over them:

```aro
Group the <region-groups> from the <orders> by "region".

(* Extract a specific group *)
Extract the <eu-orders> from the <region-groups: EU>.

(* Aggregate within a group *)
Reduce the <eu-total: Float> from the <eu-orders>
    with sum(<amount>).
```

### Relationship to Filter

`Group` is the multi-bucket equivalent of `Filter`. Where `Filter` selects items matching a single predicate, `Group` partitions the entire collection at once:

```aro
(* Using Filter — one bucket at a time *)
Filter the <active> from the <orders> where <status> is "active".
Filter the <pending> from the <orders> where <status> is "pending".

(* Using Group — all buckets in one pass *)
Group the <status-groups> from the <orders> by "status".
```

---

## Pipeline Composition

Chain operations to build complex data transformations:

<div style="text-align: center; margin: 2em 0;">
<svg width="560" height="130" viewBox="0 0 560 130" xmlns="http://www.w3.org/2000/svg" font-family="sans-serif">
  <!-- Source collection (dark) -->
  <rect x="10" y="40" width="90" height="50" rx="4" fill="#1f2937" stroke="#1f2937" stroke-width="2"/>
  <text x="55" y="61" text-anchor="middle" font-size="10" fill="#ffffff">Source</text>
  <text x="55" y="77" text-anchor="middle" font-size="10" fill="#ffffff">[items]</text>

  <!-- Arrow + label -->
  <line x1="100" y1="65" x2="128" y2="65" stroke="#1f2937" stroke-width="2"/>
  <polygon points="128,65 118,60 118,70" fill="#1f2937"/>
  <text x="114" y="58" text-anchor="middle" font-size="8" fill="#374151">all items</text>

  <!-- Filter stage (red) -->
  <rect x="130" y="40" width="100" height="50" rx="4" fill="#fee2e2" stroke="#ef4444" stroke-width="2"/>
  <text x="180" y="61" text-anchor="middle" font-size="10" fill="#991b1b">Filter</text>
  <text x="180" y="77" text-anchor="middle" font-size="9" fill="#991b1b">predicate: active</text>

  <!-- Arrow + label -->
  <line x1="230" y1="65" x2="258" y2="65" stroke="#1f2937" stroke-width="2"/>
  <polygon points="258,65 248,60 248,70" fill="#1f2937"/>
  <text x="244" y="58" text-anchor="middle" font-size="8" fill="#374151">active items</text>

  <!-- Transform stage (amber) -->
  <rect x="260" y="40" width="100" height="50" rx="4" fill="#fef3c7" stroke="#f59e0b" stroke-width="2"/>
  <text x="310" y="61" text-anchor="middle" font-size="10" fill="#92400e">Transform</text>
  <text x="310" y="77" text-anchor="middle" font-size="9" fill="#92400e">map: name</text>

  <!-- Arrow + label -->
  <line x1="360" y1="65" x2="388" y2="65" stroke="#1f2937" stroke-width="2"/>
  <polygon points="388,65 378,60 378,70" fill="#1f2937"/>
  <text x="374" y="58" text-anchor="middle" font-size="8" fill="#374151">name list</text>

  <!-- Aggregate stage (green) -->
  <rect x="390" y="40" width="100" height="50" rx="4" fill="#d1fae5" stroke="#22c55e" stroke-width="2"/>
  <text x="440" y="61" text-anchor="middle" font-size="10" fill="#166534">Aggregate</text>
  <text x="440" y="77" text-anchor="middle" font-size="9" fill="#166534">reduce: count</text>

  <!-- Arrow + label -->
  <line x1="490" y1="65" x2="518" y2="65" stroke="#1f2937" stroke-width="2"/>
  <polygon points="518,65 508,60 508,70" fill="#1f2937"/>
  <text x="504" y="58" text-anchor="middle" font-size="8" fill="#374151">result</text>

  <!-- Result (indigo) -->
  <rect x="520" y="47" width="36" height="36" rx="4" fill="#e0e7ff" stroke="#6366f1" stroke-width="2"/>
  <text x="538" y="70" text-anchor="middle" font-size="12" fill="#4338ca">42</text>
</svg>
</div>

```aro
(Generate Report: Analytics) {
    Retrieve the <orders: List<Order>> from the <order-repository>.

    (* Step 1: Filter high-value orders *)
    Filter the <high-value: List<Order>> from the <orders>
        where <amount> > 1000.

    (* Step 2: Sort by amount, largest first *)
    Sort the <ranked: descending> from the <high-value> by "amount".

    (* Step 3: Pull out the customer names, largest order first *)
    Map the <customer-names: customer-name> from the <ranked>.

    (* Step 4: Aggregate *)
    Reduce the <total: Float> from the <high-value>
        with sum(<amount>).
    Reduce the <count: Integer> from the <high-value>
        with count().

    Return an <OK: status> with {
        customers: <customer-names>,
        total: <total>,
        count: <count>
    }.
}
```

---

## Automatic Pipeline Detection

ARO automatically detects pipeline patterns **without requiring explicit operators** like `|>`. The runtime recognizes data flow chains through immutable variable dependencies, providing all the benefits of pipeline operators without new syntax.

### How It Works

Because ARO variables are immutable, each statement creates a new binding that later statements can reference. This creates an explicit data flow graph:

```aro
(* ARO automatically detects this as a 4-stage pipeline *)
Filter the <current-year> from <transactions> where <year> = "2024".
Filter the <high-value> from <current-year> where <amount> > 500.
Filter the <completed> from <high-value> where <status> = "completed".
Filter the <electronics> from <completed> where <category> = "electronics".
```

The runtime automatically recognizes the dependency chain:
```
transactions → current-year → high-value → completed → electronics
```

### Why Not Use `|>` Operator?

Many languages provide explicit pipeline operators. ARO takes a different approach:

| Aspect | Explicit `|>` Operator | ARO Automatic Detection |
|--------|----------------------|-------------------------|
| **Syntax** | New operator to learn | Natural language (no change) |
| **Debugging** | Hard (no variable names) | Easy (named variables) |
| **Error messages** | "Pipeline failed at step 3" | "Cannot filter <completed> from <high-value>" |
| **Backward compat** | Breaking change | Transparent |
| **Intermediate inspection** | Requires special syntax | `Log <current-year> to <console>.` |

### Benefits of Named Pipelines

With named intermediate values, you can:

1. **Inspect each stage** during debugging:
```aro
Filter the <current-year> from <transactions> where <year> = "2024".
Log <current-year> to the <console>.  (* Debug: see year-filtered data *)

Filter the <high-value> from <current-year> where <amount> > 500.
Log <high-value> to the <console>.  (* Debug: see high-value data *)
```

2. **Get clear error messages** that reference specific variables:
```
Error: Cannot filter the completed from the high-value where status = "completed"
  Variable: <high-value>
  Location: analytics.aro:15
```

3. **Reuse intermediate results** for multiple operations:
```aro
Filter the <active-orders> from <orders> where <status> = "active".

(* Reuse active-orders for multiple aggregations *)
Reduce the <total> from <active-orders> with sum(<amount>).
Reduce the <count> from <active-orders> with count().
Reduce the <average> from <active-orders> with avg(<amount>).
```

### Optimization Strategies

The runtime applies several optimizations based on detected patterns:

| Pattern | Optimization | Memory |
|---------|--------------|--------|
| **Linear chain** | Streaming pipeline | O(1) |
| **Multiple aggregations** | Aggregation fusion (single pass) | O(k accumulators) |
| **Fan-out** | Stream tee with bounded buffer | O(buffer size) |

See **Chapter 46: Streaming Execution** for complete details on how ARO optimizes pipelines.

### Complete Specification

For the complete design and implementation of automatic pipeline detection, see:
- **Proposal**: `Proposals/ARO-0086-automatic-pipeline-detection.md`
- **Related**: ARO-0051 (Streaming Execution)
- **Examples**: `Examples/DataPipeline/`, `Examples/StreamingPipeline/`

---

## Sorting

The `Sort` action orders a collection. Verbs `Sort`, `Order`, and `Arrange` are
equivalent. Sort ascending by default; descending is selected with the
`descending` qualifier on the result.

```aro
(* Sort a list of objects by a field, ascending *)
Sort the <users: List<User>> from the <all-users> by "name".

(* Sort descending by a field *)
Sort the <recent: descending> from the <orders> by "created-at".

(* Sort a list of plain numbers ascending *)
Sort the <sorted-scores> for the <scores>.
```

---

## Pagination

There is no SQL-style `limit`/`offset` clause. Sort the collection first, then
slice a page out of it with an `Extract` range specifier (see **Appendix A**).

**Indices count backwards.** `0` is the *last* element, not the first (ARO-0038
§2.2), and a range walks from there towards the front — so on
`["a","b","c","d","e"]`, `<page: 0-2>` binds `["e", "d", "c"]`. Ranges are a
"most recent N" tool, which is what repositories want, and it means a page one
of `0-19` is the *end* of the list in reverse.

So sort into the order you want the last page to be in, and read the pages
backwards:

```aro
(* Ascending by name; index 0 is therefore the last name alphabetically *)
Sort the <ordered: List<User>> from the <users> by "name".

(* The 20 names closest to the end of the alphabet, Z-first *)
Extract the <page1: 0-19> from the <ordered>.
Extract the <page2: 20-39> from the <ordered>.
```

If you want page one to be A-first, sort descending instead, so that the
reverse index and the reading order agree:

```aro
Sort the <ordered: descending> from the <users> by "name".
Extract the <page1: 0-19> from the <ordered>.   (* A … T, in order *)
```

---

## Complete Example

### openapi.yaml

```yaml
openapi: 3.0.3
info:
  title: Order Analytics
  version: 1.0.0

components:
  schemas:
    Order:
      type: object
      properties:
        id: { type: string }
        customer-id: { type: string }
        customer-name: { type: string }
        amount: { type: number }
        status: { type: string }
        region: { type: string }
        created-at: { type: string, format: date-time }
      required: [id, customer-id, amount, status]

    # `created-at` can be both sorted by and read with `<order: created-at>`.
    # It used to be unreadable — a hyphenated name whose tail is a preposition
    # did not lex as an identifier (GitLab #579, #583) — so fields like this
    # had to be renamed `createdAt` even when the payload called them
    # `created-at`.

    OrderSummary:
      type: object
      properties:
        id: { type: string }
        customer-name: { type: string }
        amount: { type: number }
      required: [id, customer-name, amount]
```

### analytics.aro

```aro
(* Application entry point *)
(Application-Start: Order Analytics) {
    Log "Order Analytics ready" to the <console>.
    Return an <OK: status> for the <startup>.
}

(* Analytics report generation *)
(Generate Report: Order Analytics) {
    (* Retrieve orders, then order newest-first *)
    Retrieve the <all-orders: List<Order>> from the <order-repository>.
    Sort the <recent: descending> from the <all-orders> by "created-at".

    (* Calculate metrics *)
    Reduce the <total-revenue: Float> from the <recent>
        with sum(<amount>).

    Reduce the <order-count: Integer> from the <recent>
        with count().

    Reduce the <avg-order: Float> from the <recent>
        with avg(<amount>).

    (* Filter pending orders *)
    Filter the <pending: List<Order>> from the <recent>
        where <status> is "pending".

    Reduce the <pending-count: Integer> from the <pending>
        with count().

    (* Pull out the customer names for the response *)
    Map the <customer-names: customer-name> from the <recent>.

    Return an <OK: status> with {
        customers: <customer-names>,
        metrics: {
            total-revenue: <total-revenue>,
            order-count: <order-count>,
            avg-order-value: <avg-order>,
            pending-count: <pending-count>
        }
    }.
}
```

---

## Performance Considerations

When working with data pipelines, keep these performance guidelines in mind:

### Operation Costs

| Operation | Time Complexity | Notes |
|-----------|-----------------|-------|
| Filter | O(n) | Scans entire collection once |
| Map | O(n) | Transforms each element |
| Reduce | O(n) | Single pass aggregation |
| Group | O(n) | Single pass partitioning |
| Retrieve | O(n) + sort | Filtering and optional sorting |
| Sort | O(n log n) | Standard comparison sort |

### Best Practices

1. **Filter Early**: Apply filters before map operations to reduce the working set.

```aro
(* Good: Filter first, then transform *)
Filter the <active: List<User>> from the <users>
    where <status> is "active".
Map the <active-names: name> from the <active>.

(* Less efficient: extract the field from every user, then discard most *)
Map the <all-names: name> from the <users>.
```

2. **Slice After Sorting**: Sort, then take only the elements you need with an `Extract` range instead of materialising and scanning the whole collection downstream.

Remember that the range counts backwards, so "the ten largest" is an
*ascending* sort read from index 0:

```aro
(* Good: sort ascending, then take indices 0-9 — the ten largest, largest first *)
Sort the <ranked> from the <orders> by "amount".
Extract the <top-orders: 0-9> from the <ranked>.
```

3. **Most-Selective Filter First**: when you do split a compound condition into a chain of `Filter` statements — for the named intermediate values, or to log a stage — apply the most selective predicate first, so later stages scan a smaller collection.

```aro
(* Good: the rarer predicate (premium) runs first *)
Filter the <premium: List<User>> from the <users>
    where <tier> is "premium".
Filter the <premium-active: List<User>> from the <premium>
    where <status> is "active".

(* Less efficient: the broad predicate (active) runs first *)
Filter the <active: List<User>> from the <users>
    where <status> is "active".
Filter the <active-premium: List<User>> from the <active>
    where <tier> is "premium".
```

4. **Use Reduce for Counts in Pipelines**: When you are already in a pipeline, prefer `Reduce … with count()` over retrieving everything just to measure it.

```aro
(* Good: Aggregate directly inside the pipeline *)
Reduce the <user-count: Integer> from the <users>
    with count().

(* Expensive: Retrieve all items just to count them *)
Retrieve the <all-users: List<User>> from the <users>.
Compute the <count: length> from <all-users>.
```

Note that `Compute <n: length>` is perfectly appropriate when the collection is already bound as a local variable—for example, after a `Filter`. The expensive anti-pattern above is the unnecessary `Retrieve`, not the `Compute` itself.

### Memory Considerations

- For collections under 10,000 elements, each pipeline operation creates a new collection (immutability)
- For collections of 10,000+ elements, `Filter` and `Map` return lazy streams — chained operations execute in O(1) memory per stage without materialising intermediate arrays (see Chapter 46)
- For pagination, sort and then slice with an `Extract` range — there is no `limit`/`offset`
- Intermediate results are garbage-collected when no longer referenced
- Map operations to smaller types reduce memory usage

### When to Split Feature Sets

For very complex data transformations, consider splitting into multiple feature sets:

```aro
(* Feature set 1: Heavy data processing *)
(Process Orders: Order Handler) {
    Retrieve the <orders: List<Order>> from the <order-repository>
        where <status> is "pending".
    Reduce the <order-count: Integer> from the <orders>
        with count().
    Store the <orders> into the <pending-cache>.
    Emit a <OrdersProcessed: event> with { count: <order-count> }.
    Return an <OK: status> for the <processing>.
}

(* Feature set 2: Analytics on cached data *)
(Generate Report: OrdersProcessed Handler) {
    Retrieve the <orders: List<Order>> from the <pending-cache>.
    Reduce the <total: Float> from the <orders>
        with sum(<amount>).
    (* ... additional analytics ... *)
    Return an <OK: status> with { total: <total> }.
}
```

This approach keeps each feature set focused and allows the event bus to manage execution flow.

---

## Join

The `Join` action concatenates a collection of values into a single string using a separator. It is the complement of `Split`:

```aro
Split the <words> from <sentence> by /\s+/.

(* ... transform words ... *)

Join the <result> from <words> with " ".
```

### Syntax

```aro
Join the <result> from <collection> with "separator".
```

The separator can be any string — empty string for no separator, `"\n"` for newlines, `", "` for comma-separated values:

```aro
(* Comma-separated list *)
Join the <csv-line> from <fields> with ",".

(* Space-joined words *)
Join the <sentence> from <words> with " ".

(* Newline-joined lines *)
Join the <document> from <lines> with "\n".

(* No separator *)
Join the <compact> from <parts> with "".
```

### Relationship to Split

`Split` and `Join` are inverses:

```aro
Split the <parts> from <text> by /,/.
(* ... modify parts ... *)
Join the <rejoined> from <parts> with ",".
```

---

## Design Philosophy

ARO's data pipelines follow these principles:

1. **Type-First**: All results are typed via OpenAPI schemas
2. **No SQL Complexity**: No JOINs, subqueries, or CTEs
3. **Pipeline Style**: Chain simple operations for complex transformations
4. **Predictable Performance**: Simple operations with clear cost

For complex data needs, use multiple feature sets and compose results in your business logic.

---

*Next: Chapter 35 — Set Operations*
