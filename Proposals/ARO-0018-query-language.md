# ARO-0018: Query Language

* Proposal: ARO-0018
* Author: ARO Language Team
* Status: **Draft**
* Requires: ARO-0001, ARO-0002, ARO-0006

## Abstract

This proposal introduces a built-in query language for filtering, transforming, and aggregating data in ARO.

## Motivation

Data manipulation is central to business logic:

1. **Filtering**: Select subset of data
2. **Transformation**: Reshape data
3. **Aggregation**: Compute summaries
4. **Joining**: Combine data sources

---

### 1. Query Expression

#### 1.1 Basic Syntax

```ebnf
query_expression = "query" , source , { query_clause } ;

query_clause = where_clause 
             | select_clause 
             | order_clause 
             | group_clause 
             | limit_clause
             | join_clause ;
```

**Example:**
```
<Set> the <active-users> to 
    query <users>
    where <status> is "active"
    select { id, email, name }
    order by <created-at> desc
    limit 100.
```

---

### 2. Where Clause (Filtering)

#### 2.1 Basic Conditions

```
query <users>
where <age> >= 18

query <orders>
where <status> is "pending" and <total> > 100

query <products>
where <category> in ["electronics", "computers"]
      and <price> between 100 and 500
      and <name> contains "laptop"
```

#### 2.2 Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `==`, `is` | Equality | `<status> is "active"` |
| `!=`, `is not` | Inequality | `<role> is not "guest"` |
| `<`, `<=`, `>`, `>=` | Comparison | `<age> >= 18` |
| `in` | Set membership | `<status> in ["a", "b"]` |
| `not in` | Not in set | `<status> not in ["x"]` |
| `between` | Range | `<price> between 10 and 100` |
| `contains` | Substring | `<name> contains "test"` |
| `starts with` | Prefix | `<email> starts with "admin"` |
| `ends with` | Suffix | `<file> ends with ".pdf"` |
| `matches` | Regex | `<phone> matches "\\d{10}"` |
| `exists` | Not null | `<email> exists` |
| `is null` | Is null | `<deleted-at> is null` |
| `is empty` | Empty collection | `<items> is empty` |

#### 2.3 Logical Operators

```
query <users>
where (<role> is "admin" or <role> is "moderator")
      and <active> is true
      and not (<banned> is true)
```

---

### 3. Select Clause (Projection)

#### 3.1 Field Selection

```
// Select specific fields
query <users>
select { id, email, name }

// Select all
query <users>
select *

// Exclude fields
query <users>
select * except { password-hash, internal-notes }
```

#### 3.2 Computed Fields

```
query <orders>
select {
    id,
    customer-name: <customer>.name,
    total,
    tax: <total> * 0.08,
    grand-total: <total> * 1.08,
    item-count: <items>.count()
}
```

#### 3.3 Nested Selection

```
query <orders>
select {
    id,
    customer: {
        name: <customer>.name,
        email: <customer>.email
    },
    items: <items>.map(<i> => {
        product: <i>.product-name,
        quantity: <i>.quantity
    })
}
```

---

### 4. Order Clause (Sorting)

```
// Single field
query <users>
order by <name> asc

// Multiple fields
query <products>
order by <category> asc, <price> desc

// Null handling
query <users>
order by <last-login> desc nulls last

// Custom ordering
query <tasks>
order by case <priority> {
    "high" => 1,
    "medium" => 2,
    "low" => 3
}
```

---

### 5. Group Clause (Aggregation)

#### 5.1 Basic Grouping

```
query <orders>
group by <customer-id>
select {
    customer-id,
    order-count: count(),
    total-spent: sum(<total>)
}
```

#### 5.2 Aggregate Functions

| Function | Description |
|----------|-------------|
| `count()` | Number of items |
| `sum(field)` | Sum of values |
| `avg(field)` | Average |
| `min(field)` | Minimum |
| `max(field)` | Maximum |
| `first(field)` | First value |
| `last(field)` | Last value |
| `collect(field)` | Collect into list |
| `distinct(field)` | Unique values |

#### 5.3 Having Clause

```
query <orders>
group by <customer-id>
having count() > 10
select {
    customer-id,
    order-count: count()
}
```

---

### 6. Limit and Offset

```
// Limit
query <users>
limit 10

// Offset (pagination)
query <users>
order by <created-at> desc
limit 20
offset 40

// Or with skip/take
query <users>
skip 40
take 20
```

---

### 7. Joins

#### 7.1 Join Types

```
// Inner join
query <orders>
join <customers> on <orders>.customer-id == <customers>.id
select {
    order-id: <orders>.id,
    customer-name: <customers>.name,
    total: <orders>.total
}

// Left join
query <users>
left join <orders> on <users>.id == <orders>.user-id
select {
    user: <users>.name,
    order-count: count(<orders>.id)
}
group by <users>.id

// Multiple joins
query <order-items>
join <orders> on <order-items>.order-id == <orders>.id
join <products> on <order-items>.product-id == <products>.id
join <customers> on <orders>.customer-id == <customers>.id
select {
    customer: <customers>.name,
    product: <products>.name,
    quantity: <order-items>.quantity
}
```

---

### 8. Subqueries

```
// In where clause
query <users>
where <id> in (
    query <orders>
    where <total> > 1000
    select <customer-id>
)

// In select clause
query <customers>
select {
    id,
    name,
    total-orders: (
        query <orders>
        where <customer-id> == <customers>.id
        select count()
    )
}

// In from clause
query (
    query <orders>
    group by <customer-id>
    select {
        customer-id,
        order-count: count()
    }
) as <order-stats>
where <order-count> > 5
```

---

### 9. Set Operations

```
// Union
query <active-users>
union
query <premium-users>

// Intersect
query <users-with-orders>
intersect
query <users-with-reviews>

// Except (difference)
query <all-users>
except
query <banned-users>
```

---

### 10. Window Functions

```
query <sales>
select {
    date,
    amount,
    running-total: sum(<amount>) over (order by <date>),
    rank: rank() over (partition by <region> order by <amount> desc),
    moving-avg: avg(<amount>) over (
        order by <date>
        rows between 6 preceding and current row
    )
}
```

---

### 11. Common Table Expressions (CTE)

```
with <high-value-customers> as (
    query <customers>
    where <lifetime-value> > 10000
),
<recent-orders> as (
    query <orders>
    where <created-at> > now().minus(30.days)
)
query <recent-orders>
join <high-value-customers> on <customer-id> == <high-value-customers>.id
select {
    customer: <high-value-customers>.name,
    order-count: count()
}
group by <high-value-customers>.id
```

---

### 12. Query Composition

```
// Define reusable query parts
let <active-users> = query <users> where <status> is "active";

let <recent> = <q> => query <q> where <created-at> > now().minus(7.days);

// Compose
<Set> the <results> to
    query <active-users>
    |> recent
    |> (q => query <q> order by <name>)
    |> (q => query <q> limit 10).
```

---

### 13. Inline Queries in Statements

```
(Report Generation: Analytics) {
    // Direct query in retrieval
    <Retrieve> the <top-customers> from 
        query <customers>
        join <orders> on <customers>.id == <orders>.customer-id
        group by <customers>.id
        select {
            customer: <customers>,
            total-spent: sum(<orders>.total)
        }
        order by <total-spent> desc
        limit 10.
    
    // Query in condition
    if (query <pending-orders> select count()) > 100 then {
        <Alert> the <operations-team>.
    }
    
    // Query in loop
    for each <segment> in 
        (query <customers> 
         group by <region> 
         select { region, customers: collect(<id>) }) {
        <Process> the <segment>.
    }
}
```

---

### 14. Complete Grammar Extension

```ebnf
(* Query Language Grammar *)

query_expression = "query" , query_source , { query_clause } ;

query_source = variable_reference 
             | "(" , query_expression , ")" , [ "as" , identifier ] ;

query_clause = where_clause
             | select_clause
             | order_clause
             | group_clause
             | having_clause
             | limit_clause
             | offset_clause
             | join_clause ;

(* Where *)
where_clause = "where" , predicate ;

predicate = predicate_or ;
predicate_or = predicate_and , { "or" , predicate_and } ;
predicate_and = predicate_not , { "and" , predicate_not } ;
predicate_not = [ "not" ] , predicate_atom ;
predicate_atom = comparison | membership | existence | "(" , predicate , ")" ;

comparison = expression , comp_op , expression ;
comp_op = "==" | "!=" | "is" | "is" , "not" 
        | "<" | "<=" | ">" | ">=" 
        | "between" , expression , "and"
        | "contains" | "starts" , "with" | "ends" , "with" | "matches" ;

membership = expression , [ "not" ] , "in" , ( list_literal | subquery ) ;
existence = expression , ( "exists" | "is" , "null" | "is" , "empty" ) ;

(* Select *)
select_clause = "select" , ( "*" | select_list | select_except ) ;
select_list = "{" , select_item , { "," , select_item } , "}" ;
select_item = [ identifier , ":" ] , expression ;
select_except = "*" , "except" , "{" , identifier_list , "}" ;

(* Order *)
order_clause = "order" , "by" , order_item , { "," , order_item } ;
order_item = expression , [ "asc" | "desc" ] , [ "nulls" , ( "first" | "last" ) ] ;

(* Group *)
group_clause = "group" , "by" , expression_list ;
having_clause = "having" , predicate ;

(* Limit/Offset *)
limit_clause = "limit" , expression ;
offset_clause = "offset" , expression | "skip" , expression ;

(* Join *)
join_clause = [ join_type ] , "join" , query_source , 
              "on" , predicate ;
join_type = "left" | "right" | "inner" | "outer" | "cross" ;

(* Aggregates *)
aggregate_func = ( "count" | "sum" | "avg" | "min" | "max" 
                 | "first" | "last" | "collect" | "distinct" ) ,
                 "(" , [ expression ] , ")" ;

(* Window *)
window_func = aggregate_func , "over" , "(" , window_spec , ")" ;
window_spec = [ "partition" , "by" , expression_list ] ,
              [ "order" , "by" , order_item , { "," , order_item } ] ,
              [ frame_clause ] ;
frame_clause = ( "rows" | "range" ) , "between" , frame_bound , 
               "and" , frame_bound ;
frame_bound = "unbounded" , ( "preceding" | "following" )
            | "current" , "row"
            | expression , ( "preceding" | "following" ) ;

(* CTE *)
with_clause = "with" , cte_def , { "," , cte_def } ;
cte_def = identifier , "as" , "(" , query_expression , ")" ;

(* Set Operations *)
set_operation = query_expression , set_op , query_expression ;
set_op = "union" , [ "all" ] | "intersect" | "except" ;

(* Subquery *)
subquery = "(" , query_expression , ")" ;
```

---

### 15. Complete Example

```
(Sales Analytics: Reporting) {
    // Complex analytical query
    with <customer-metrics> as (
        query <orders>
        join <customers> on <orders>.customer-id == <customers>.id
        where <orders>.created-at > now().minus(365.days)
        group by <customers>.id
        select {
            customer-id: <customers>.id,
            customer-name: <customers>.name,
            region: <customers>.region,
            order-count: count(),
            total-revenue: sum(<orders>.total),
            avg-order-value: avg(<orders>.total),
            first-order: min(<orders>.created-at),
            last-order: max(<orders>.created-at)
        }
    ),
    <product-performance> as (
        query <order-items>
        join <products> on <order-items>.product-id == <products>.id
        group by <products>.id
        select {
            product-id: <products>.id,
            product-name: <products>.name,
            category: <products>.category,
            units-sold: sum(<order-items>.quantity),
            revenue: sum(<order-items>.quantity * <order-items>.unit-price)
        }
    )
    
    // Top customers by region
    <Compute> the <top-customers-by-region> from
        query <customer-metrics>
        select {
            region,
            customer-name,
            total-revenue,
            rank: rank() over (
                partition by <region> 
                order by <total-revenue> desc
            )
        }
        where <rank> <= 5.
    
    // Monthly trends
    <Compute> the <monthly-trends> from
        query <orders>
        where <created-at> > now().minus(12.months)
        group by month(<created-at>)
        select {
            month: month(<created-at>),
            orders: count(),
            revenue: sum(<total>),
            running-revenue: sum(sum(<total>)) over (order by month(<created-at>))
        }
        order by <month>.
    
    // Cohort analysis
    <Compute> the <cohort-retention> from
        query <customers>
        join <orders> on <customers>.id == <orders>.customer-id
        select {
            cohort-month: month(<customers>.created-at),
            order-month: month(<orders>.created-at),
            months-since-signup: months-between(
                <customers>.created-at, 
                <orders>.created-at
            ),
            customer-count: count(distinct <customers>.id)
        }
        group by <cohort-month>, <order-month>.
    
    // Generate report
    <Create> the <report: SalesReport> with {
        generated-at: now(),
        top-customers: <top-customers-by-region>,
        trends: <monthly-trends>,
        cohort: <cohort-retention>,
        top-products: (
            query <product-performance>
            order by <revenue> desc
            limit 20
        )
    }.
    
    <Return> the <report>.
}
```

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-01 | Initial specification |
