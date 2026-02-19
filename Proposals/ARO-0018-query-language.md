# ARO-0018: Data Pipelines

* Proposal: ARO-0018
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0002, ARO-0006

## Abstract

This proposal defines ARO's data pipeline operations for filtering, transforming, and aggregating collections using a map/reduce style approach. All results are typed via OpenAPI schemas.

## Motivation

Data manipulation is central to business logic:

1. **Filtering**: Select subset of data
2. **Transformation**: Map to different types
3. **Aggregation**: Compute summaries (sum, avg, count)
4. **Sorting**: Order results

## Design Principles

1. **Type-First**: All results typed via OpenAPI schemas (`<users: List<User>>`)
2. **Pipeline Style**: Chain operations: `fetch → filter → map → reduce`
3. **No SQL Complexity**: No JOINs, subqueries, or CTEs
4. **Simple & Fast**: Elegant implementation, predictable performance

---

## 1. Pipeline Operations

### 1.1 Fetch

Retrieves and filters data into a typed collection.

```aro
Fetch the <active-users: List<User>> from the <users>
    where <status> is "active"
    order by <name> asc
    limit 100.
```

**Syntax:**
```ebnf
fetch_statement = "<Fetch>" , "the" , typed_result , "from" , "the" , source ,
                  [ where_clause ] , [ order_clause ] , [ limit_clause ] , "." ;
```

### 1.2 Filter

Filters an existing collection with a predicate.

```aro
Filter the <premium-users: List<User>> from the <users>
    where <tier> is "premium".
```

**Syntax:**
```ebnf
filter_statement = "<Filter>" , "the" , typed_result , "from" , "the" , source ,
                   "where" , predicate , "." ;
```

### 1.3 Map

Transforms a collection to a different OpenAPI-defined type. The runtime automatically maps matching field names.

```aro
(* Map List<User> to List<UserSummary> *)
Map the <summaries: List<UserSummary>> from the <users>.
```

**Requirements:**
- Target type must be defined in `openapi.yaml` components/schemas
- Runtime maps fields with matching names from source to target
- Missing fields in target are omitted (if optional) or error (if required)

**Syntax:**
```ebnf
map_statement = "<Map>" , "the" , typed_result , "from" , "the" , source , "." ;
```

### 1.4 Reduce

Aggregates a collection to a single value.

```aro
Reduce the <total: Float> from the <orders>
    with sum(<amount>).

Reduce the <order-count: Integer> from the <orders>
    with count().

Reduce the <avg-price: Float> from the <products>
    where <category> is "electronics"
    with avg(<price>).
```

**Syntax:**
```ebnf
reduce_statement = "<Reduce>" , "the" , typed_result , "from" , "the" , source ,
                   [ where_clause ] , "with" , aggregate_function , "." ;
```

---

## 2. Where Clause (Filtering)

### 2.1 Comparison Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `is`, `==` | Equality | `<status> is "active"` |
| `is not`, `!=` | Inequality | `<role> is not "guest"` |
| `<`, `<=`, `>`, `>=` | Comparison | `<age> >= 18` |
| `in` | Set membership | `<status> in ["a", "b"]` |
| `between` | Range | `<price> between 10 and 100` |
| `contains` | Substring | `<name> contains "test"` |
| `starts with` | Prefix | `<email> starts with "admin"` |
| `ends with` | Suffix | `<file> ends with ".pdf"` |

### 2.2 Logical Operators

```aro
Fetch the <users: List<User>> from the <all-users>
    where (<role> is "admin" or <role> is "moderator")
          and <active> is true.
```

---

## 3. Order Clause (Sorting)

```aro
(* Single field *)
Fetch the <users: List<User>> from the <all-users>
    order by <name> asc.

(* Multiple fields *)
Fetch the <products: List<Product>> from the <all-products>
    order by <category> asc, <price> desc.
```

**Syntax:**
```ebnf
order_clause = "order" , "by" , order_item , { "," , order_item } ;
order_item = field_reference , [ "asc" | "desc" ] ;
```

---

## 4. Limit and Offset

```aro
(* Limit results *)
Fetch the <top-users: List<User>> from the <users>
    order by <score> desc
    limit 10.

(* Pagination with offset *)
Fetch the <page: List<User>> from the <users>
    order by <created-at> desc
    limit 20
    offset 40.
```

---

## 5. Aggregation Functions

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

## 6. Window Functions

Basic window functions for ranking and running totals.

```aro
(* Rank within partition *)
Compute the <ranked: List<SalesRank>> from the <sales>
    with rank() over (partition by <region> order by <amount> desc).

(* Running total *)
Compute the <running: List<RunningTotal>> from the <transactions>
    with sum(<amount>) over (order by <date>).
```

**Supported Window Functions:**
- `rank()` - Rank within partition
- `row_number()` - Sequential number
- `sum(field) over (...)` - Running sum
- `avg(field) over (...)` - Running average

---

## 7. Grammar

```ebnf
(* Data Pipeline Grammar *)

(* Fetch *)
fetch_statement = "<Fetch>" , "the" , typed_result , "from" , "the" , source ,
                  [ where_clause ] , [ order_clause ] , [ limit_clause ] , "." ;

(* Filter *)
filter_statement = "<Filter>" , "the" , typed_result , "from" , "the" , source ,
                   where_clause , "." ;

(* Map *)
map_statement = "<Map>" , "the" , typed_result , "from" , "the" , source , "." ;

(* Reduce *)
reduce_statement = "<Reduce>" , "the" , typed_result , "from" , "the" , source ,
                   [ where_clause ] , "with" , aggregate_function , "." ;

(* Clauses *)
where_clause = "where" , predicate ;
order_clause = "order" , "by" , order_item , { "," , order_item } ;
limit_clause = "limit" , integer , [ "offset" , integer ] ;

(* Predicate *)
predicate = predicate_or ;
predicate_or = predicate_and , { "or" , predicate_and } ;
predicate_and = predicate_atom , { "and" , predicate_atom } ;
predicate_atom = comparison | "(" , predicate , ")" ;

comparison = field_reference , operator , value ;
operator = "is" | "is" , "not" | "==" | "!="
         | "<" | "<=" | ">" | ">="
         | "in" | "between" | "contains" | "starts" , "with" | "ends" , "with" ;

(* Order *)
order_item = field_reference , [ "asc" | "desc" ] ;

(* Aggregates *)
aggregate_function = ( "count" | "sum" | "avg" | "min" | "max" | "first" | "last" ) ,
                     "(" , [ field_reference ] , ")" ;

(* Window *)
window_function = aggregate_function , "over" , "(" , window_spec , ")" ;
window_spec = [ "partition" , "by" , field_list ] , [ "order" , "by" , order_item ] ;

(* Types *)
typed_result = "<" , identifier , ":" , type_annotation , ">" ;
```

---

## 8. Complete Example

### openapi.yaml

```yaml
openapi: 3.0.3
info:
  title: Sales Analytics
  version: 1.0.0

components:
  schemas:
    Order:
      type: object
      properties:
        id:
          type: string
        customer-name:
          type: string
        amount:
          type: number
        status:
          type: string
        region:
          type: string
        created-at:
          type: string
          format: date-time
      required: [id, customer-name, amount, status]

    OrderSummary:
      type: object
      properties:
        id:
          type: string
        customer-name:
          type: string
        amount:
          type: number
      required: [id, customer-name, amount]

    RegionStats:
      type: object
      properties:
        region:
          type: string
        total:
          type: number
        count:
          type: integer
      required: [region, total, count]
```

### analytics.aro

```aro
(Sales Report: Analytics) {
    (* Fetch recent orders *)
    Fetch the <recent-orders: List<Order>> from the <orders>
        where <created-at> > now().minus(30.days)
        order by <created-at> desc.

    (* Get total revenue *)
    Reduce the <total-revenue: Float> from the <recent-orders>
        with sum(<amount>).

    (* Count pending orders *)
    Reduce the <pending-count: Integer> from the <recent-orders>
        where <status> is "pending"
        with count().

    (* Map to summaries *)
    Map the <summaries: List<OrderSummary>> from the <recent-orders>.

    (* Filter high-value orders *)
    Filter the <high-value: List<Order>> from the <recent-orders>
        where <amount> > 1000.

    Return an <OK: status> with {
        orders: <summaries>,
        total: <total-revenue>,
        pending: <pending-count>,
        high-value-count: <high-value>.count()
    }.
}
```

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-01 | Initial specification (SQL-like) |
| 2.0 | 2025-12 | Simplified to map/reduce style. Removed JOINs, subqueries, CTEs, set operations. Results typed via OpenAPI. |
