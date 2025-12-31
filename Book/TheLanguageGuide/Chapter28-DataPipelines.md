# Chapter 28: Data Pipelines

ARO provides a map/reduce style data pipeline for filtering, transforming, and aggregating collections. All operations are type-safe, with results typed via OpenAPI schemas.

## Pipeline Operations

ARO supports four core data operations:

| Operation | Purpose | Example |
|-----------|---------|---------|
| **Fetch** | Retrieve and filter data | `<Fetch> the <users: List<User>> from the <repository>...` |
| **Filter** | Filter existing collection | `<Filter> the <active: List<User>> from the <users>...` |
| **Map** | Transform to different type | `<Map> the <summaries> as List<UserSummary> from the <users>.` |
| **Reduce** | Aggregate to single value | `<Reduce> the <total> as Float from the <orders> with sum(<amount>).` |

### Type Annotation Syntax

ARO supports two equivalent syntaxes for type annotations:

```aro
(* Colon syntax: type inside angle brackets *)
<Filter> the <active-users: List<User>> from the <users> where <active> is true.

(* As syntax: type follows the result descriptor *)
<Filter> the <active-users> as List<User> from the <users> where <active> is true.
```

Both produce identical results. The `as Type` syntax (ARO-0038) can be more readable when the variable name is long, while the colon syntax keeps everything compact. Type annotations are optional since ARO infers types from the source collection.

---

## Fetch

Retrieves data with optional filtering, sorting, and pagination.

```aro
(* Basic fetch *)
<Fetch> the <users: List<User>> from the <user-repository>.

(* With filter *)
<Fetch> the <active-users: List<User>> from the <users>
    where <status> is "active".

(* With sorting *)
<Fetch> the <recent-users: List<User>> from the <users>
    order by <created-at> desc.

(* With pagination *)
<Fetch> the <page: List<User>> from the <users>
    order by <name> asc
    limit 20
    offset 40.

(* Combined *)
<Fetch> the <top-customers: List<User>> from the <users>
    where <tier> is "premium"
    order by <total-purchases> desc
    limit 10.
```

---

## Filter

Filters an existing collection with a predicate.

```aro
(* Filter by equality *)
<Filter> the <admins: List<User>> from the <users>
    where <role> is "admin".

(* Filter by comparison *)
<Filter> the <high-value: List<Order>> from the <orders>
    where <amount> > 1000.

(* Filter with multiple conditions *)
<Filter> the <active-premium: List<User>> from the <users>
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
| `between` | Range | `<price> between 10 and 100` |
| `contains` | Substring | `<name> contains "test"` |
| `starts with` | Prefix match | `<email> starts with "admin"` |
| `ends with` | Suffix match | `<file> ends with ".pdf"` |
| `matches` | Regex pattern | `<email> matches /^admin@/i` |

### Set Membership with `in` and `not in`

The `in` and `not in` operators test set membership. They accept either a CSV string or an array variable:

```aro
(* Using CSV string *)
<Filter> the <pending: List<Order>> from the <orders>
    where <status> in "pending,processing".

(* Using array variable *)
<Create> the <exclude-statuses> with ["cancelled", "refunded"].
<Filter> the <active: List<Order>> from the <orders>
    where <status> not in <exclude-statuses>.

(* Combining with other conditions *)
<Filter> the <valid-orders: List<Order>> from the <orders>
    where <amount> > 0 and <status> not in <exclude-statuses>.
```

The `matches` operator supports regex literals with flags:

```aro
(* Filter users with admin emails *)
<Filter> the <admins: List<User>> from the <users>
    where <email> matches /^admin@|@admin\./i.

(* Filter valid email addresses *)
<Filter> the <valid-emails: List<User>> from the <users>
    where <email> matches /^[\w.+-]+@[\w.-]+\.[a-zA-Z]{2,}$/i.
```

---

## Map

Transforms a collection to a different OpenAPI-defined type. The runtime automatically maps fields with matching names.

```aro
(* Map User to UserSummary *)
<Map> the <summaries: List<UserSummary>> from the <users>.
```

**Requirements:**
- Target type must be defined in `openapi.yaml` components/schemas
- Fields with matching names are automatically copied
- Missing optional fields are omitted
- Missing required fields cause an error

### Example Types

```yaml
# openapi.yaml
components:
  schemas:
    User:
      type: object
      properties:
        id: { type: string }
        name: { type: string }
        email: { type: string }
        password-hash: { type: string }
        created-at: { type: string }

    UserSummary:
      type: object
      properties:
        id: { type: string }
        name: { type: string }
        email: { type: string }
```

When mapping `List<User>` to `List<UserSummary>`, only `id`, `name`, and `email` are copied. Sensitive fields like `password-hash` are excluded.

---

## Reduce

Aggregates a collection to a single value using aggregation functions.

```aro
(* Count items *)
<Reduce> the <user-count: Integer> from the <users>
    with count().

(* Sum numeric field *)
<Reduce> the <total-revenue: Float> from the <orders>
    with sum(<amount>).

(* Average *)
<Reduce> the <avg-price: Float> from the <products>
    with avg(<price>).

(* Min/Max *)
<Reduce> the <highest-score: Float> from the <scores>
    with max(<value>).

(* With filter *)
<Reduce> the <pending-count: Integer> from the <orders>
    where <status> is "pending"
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

---

## Pipeline Composition

Chain operations to build complex data transformations:

```aro
(Generate Report: Analytics) {
    (* Step 1: Fetch recent orders *)
    <Fetch> the <recent-orders: List<Order>> from the <orders>
        where <created-at> > now().minus(30.days)
        order by <created-at> desc.

    (* Step 2: Filter high-value orders *)
    <Filter> the <high-value: List<Order>> from the <recent-orders>
        where <amount> > 1000.

    (* Step 3: Map to summaries *)
    <Map> the <summaries: List<OrderSummary>> from the <high-value>.

    (* Step 4: Calculate total *)
    <Reduce> the <total: Float> from the <high-value>
        with sum(<amount>).

    <Return> an <OK: status> with {
        orders: <summaries>,
        total: <total>,
        count: <high-value>.count()
    }.
}
```

---

## Sorting

Sort results by one or more fields:

```aro
(* Single field, ascending *)
<Fetch> the <users: List<User>> from the <repository>
    order by <name> asc.

(* Single field, descending *)
<Fetch> the <recent: List<Order>> from the <orders>
    order by <created-at> desc.

(* Multiple fields *)
<Fetch> the <products: List<Product>> from the <catalog>
    order by <category> asc, <price> desc.
```

---

## Pagination

Limit results with offset for pagination:

```aro
(* First page: items 1-20 *)
<Fetch> the <page1: List<User>> from the <users>
    order by <name> asc
    limit 20.

(* Second page: items 21-40 *)
<Fetch> the <page2: List<User>> from the <users>
    order by <name> asc
    limit 20
    offset 20.

(* Third page: items 41-60 *)
<Fetch> the <page3: List<User>> from the <users>
    order by <name> asc
    limit 20
    offset 40.
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
    <Log> "Order Analytics ready" to the <console>.
    <Return> an <OK: status> for the <startup>.
}

(* Analytics report generation *)
(Generate Report: Order Analytics) {
    (* Fetch recent orders *)
    <Fetch> the <recent: List<Order>> from the <orders>
        where <created-at> > now().minus(30.days)
        order by <created-at> desc.

    (* Calculate metrics *)
    <Reduce> the <total-revenue: Float> from the <recent>
        with sum(<amount>).

    <Reduce> the <order-count: Integer> from the <recent>
        with count().

    <Reduce> the <avg-order: Float> from the <recent>
        with avg(<amount>).

    (* Filter pending orders *)
    <Filter> the <pending: List<Order>> from the <recent>
        where <status> is "pending".

    <Reduce> the <pending-count: Integer> from the <pending>
        with count().

    (* Map to summaries for response *)
    <Map> the <summaries: List<OrderSummary>> from the <recent>.

    <Return> an <OK: status> with {
        orders: <summaries>,
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

## Design Philosophy

ARO's data pipelines follow these principles:

1. **Type-First**: All results are typed via OpenAPI schemas
2. **No SQL Complexity**: No JOINs, subqueries, or CTEs
3. **Pipeline Style**: Chain simple operations for complex transformations
4. **Predictable Performance**: Simple operations with clear cost

For complex data needs, use multiple feature sets and compose results in your business logic.

---

*Next: Chapter 29 — Repositories*
