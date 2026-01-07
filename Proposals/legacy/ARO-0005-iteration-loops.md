# ARO-0005: Iteration and Loops

* Proposal: ARO-0005
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0002, ARO-0003, ARO-0004

## Abstract

This proposal introduces iteration constructs to ARO, enabling specifications to process collections in a deterministic, bounded manner.

## Motivation

Many business operations involve:

- Processing each item in a collection
- Filtering collections based on conditions
- Aggregating results from multiple items
- Transforming lists of data

ARO provides iteration constructs that are:
- **Deterministic**: Predictable execution order
- **Bounded**: Always terminate (no infinite loops)
- **Declarative**: Express intent, not control flow

## Proposed Solution

Two iteration constructs:

1. **For-Each**: Iterate over collections (serial)
2. **Parallel For-Each**: Iterate over collections (concurrent)

Plus collection actions for functional-style processing.

---

### 1. For-Each Loop

#### 1.1 Syntax

```ebnf
foreach_loop = "for" , "each" , "<" , item_name , ">" ,
               [ "at" , "<" , index_name , ">" ] ,
               "in" , "<" , collection , ">" ,
               [ "where" , condition ] ,
               block ;

item_name    = compound_identifier ;
index_name   = compound_identifier ;
collection   = qualified_noun ;
```

**Format:**
```aro
for each <item> in <collection> {
    <statements using item>
}

for each <item> in <collection> where <condition> {
    <statements>
}

for each <item> at <index> in <collection> {
    <statements>
}
```

#### 1.2 Examples

##### Basic Iteration

```aro
(Order Processing: E-Commerce) {
    <Retrieve> the <items> from the <order>.

    for each <item> in <items> {
        <Validate> the <availability> for the <item>.
        <Reserve> the <quantity> for the <item>.
    }

    <Return> an <OK: status> for the <order>.
}
```

##### With Filter (replaces Break/Continue)

```aro
(Notification: Communication) {
    <Retrieve> the <users> from the <user-repository>.

    (* Only process users with notifications enabled *)
    for each <user> in <users> where <user: notifications-enabled> is true {
        <Send> the <newsletter> to the <user: email>.
    }

    <Return> an <OK: status> for the <notification>.
}
```

##### Indexed Iteration

```aro
(Ranking: Display) {
    <Sort> the <contestants> from the <competition> by <score>.

    for each <contestant> at <rank> in <contestants> {
        <Compute> the <position> from <rank> + 1.
        <Display> the <result> for the <contestant> with <position>.
    }

    <Return> an <OK: status> for the <ranking>.
}
```

##### Nested Loops

```aro
(Report: Analytics) {
    <Retrieve> the <departments> from the <organization>.

    for each <department> in <departments> {
        <Retrieve> the <employees> from the <department>.

        for each <employee> in <employees> {
            <Compute> the <score> for the <employee>.
            <Add> the <score> to the <department: metrics>.
        }

        <Generate> the <report> for the <department>.
    }

    <Return> an <OK: status> for the <analytics>.
}
```

#### 1.3 Loop Variable Scoping

- The loop variable (`<item>`) is scoped to the loop body
- It shadows any outer variable with the same name
- It is immutable within the loop

---

### 2. Parallel For-Each

For concurrent processing of independent items:

#### 2.1 Syntax

```ebnf
parallel_foreach = "parallel" , "for" , "each" , "<" , item_name , ">" ,
                   "in" , "<" , collection , ">" ,
                   [ "with" , "<" , "concurrency" , ":" , number , ">" ] ,
                   [ "where" , condition ] ,
                   block ;
```

**Format:**
```aro
parallel for each <item> in <items> {
    <Process> the <result> for the <item>.
}

parallel for each <item> in <items> with <concurrency: 4> {
    <Fetch> the <data> from the <external-api>.
}
```

#### 2.2 Examples

##### Parallel Processing

```aro
(Image Processing: Media) {
    <Retrieve> the <images> from the <upload-batch>.

    parallel for each <image> in <images> {
        <Resize> the <thumbnail> from the <image>.
        <Store> the <thumbnail> in the <storage>.
    }

    <Return> an <OK: status> for the <processing>.
}
```

##### With Concurrency Limit

```aro
(API Sync: Integration) {
    <Retrieve> the <records> from the <database>.

    (* Limit concurrent API calls to avoid rate limiting *)
    parallel for each <record> in <records> with <concurrency: 4> {
        <Sync> the <data> to the <external-api>.
    }

    <Return> an <OK: status> for the <sync>.
}
```

#### 2.3 Semantics

- Items are processed concurrently
- Order of completion is non-deterministic
- Each iteration is independent (no shared state)
- Concurrency limit controls max parallel operations

---

### 3. Collection Actions

ARO provides declarative actions for collection operations, replacing lambda-based functional methods:

#### 3.1 Filter

Select items matching a condition:

```aro
<Filter> the <active-users> from the <users> where <active> is true.
<Filter> the <adults> from the <people> where <age> >= 18.
```

#### 3.2 Transform

Apply transformation to each item:

```aro
<Transform> the <names> from the <users> with <name>.
<Transform> the <totals> from the <items> with <price> * <quantity>.
```

#### 3.3 Aggregation

Compute aggregate values:

```aro
<Sum> the <total> from the <prices>.
<Count> the <amount> from the <items>.
<Average> the <mean> from the <scores>.
<Min> the <lowest> from the <values>.
<Max> the <highest> from the <values>.
```

#### 3.4 Search

Find specific items:

```aro
<Find> the <admin> from the <users> where <role> is "admin".
<First> the <item> from the <queue>.
<Last> the <entry> from the <log>.
```

#### 3.5 Ordering

Sort and reorder collections:

```aro
<Sort> the <sorted-users> from the <users> by <name>.
<Sort> the <ranked> from the <scores> by <value> descending.
<Reverse> the <reversed> from the <items>.
```

#### 3.6 Selection

Take or skip items:

```aro
<Take> the <top-ten> from the <results> with 10.
<Skip> the <rest> from the <items> with 5.
<Distinct> the <unique> from the <tags>.
```

#### 3.7 Predicates

Check conditions across collections:

```aro
<Any> the <has-errors> from the <results> where <status> is "error".
<All> the <all-valid> from the <inputs> where <valid> is true.
<None> the <no-failures> from the <tests> where <passed> is false.
```

---

### 4. Complete Grammar Extension

```ebnf
(* Extends ARO-0004 *)

(* Updated Statement *)
statement = aro_statement
          | guarded_statement
          | publish_statement
          | require_statement
          | match_expression
          | foreach_loop
          | parallel_foreach ;

(* For-Each Loop *)
foreach_loop = "for" , "each" , variable_reference ,
               [ "at" , variable_reference ] ,
               "in" , variable_reference ,
               [ "where" , condition ] ,
               block ;

(* Parallel For-Each *)
parallel_foreach = "parallel" , "for" , "each" , variable_reference ,
                   "in" , variable_reference ,
                   [ "with" , "<" , "concurrency" , ":" , integer , ">" ] ,
                   [ "where" , condition ] ,
                   block ;

(* Keywords *)
keyword += "for" | "each" | "in" | "at" | "parallel" | "concurrency" ;
```

---

### 5. Complete Example

```aro
(Order Fulfillment: E-Commerce) {
    <Require> the <order-repository> from the <framework>.
    <Require> the <inventory> from the <framework>.

    (* Get pending orders *)
    <Retrieve> the <orders> from the <order-repository>.
    <Filter> the <pending-orders> from the <orders> where <status> is "pending".

    (* Process each order *)
    for each <order> in <pending-orders> {
        <Retrieve> the <items> from the <order>.

        (* Check all items are in stock *)
        <All> the <in-stock> from the <items> where <inventory: available> > 0.

        match <in-stock> {
            case true {
                (* Reserve inventory for all items *)
                for each <item> in <items> {
                    <Reserve> the <quantity> from the <inventory> for the <item>.
                }

                (* Update order status *)
                <Update> the <order: status> to "processing".

                (* Send confirmation in parallel *)
                <Send> the <confirmation> to the <order: customer-email>.
            }
            case false {
                <Update> the <order: status> to "backordered".
                <Send> the <backorder-notice> to the <order: customer-email>.
            }
        }
    }

    (* Calculate summary *)
    <Count> the <processed-count> from the <pending-orders>.
    <Log> <processed-count> to the <console>.

    <Return> an <OK: status> for the <fulfillment>.
}
```

---

## Implementation Notes

### AST Node

```swift
public struct ForEachLoop: Statement {
    let itemVariable: String
    let indexVariable: String?
    let collection: QualifiedNoun
    let filter: (any Expression)?
    let isParallel: Bool
    let concurrency: Int?
    let body: [Statement]
    let span: SourceSpan
}
```

### Semantic Checks

1. **Collection Type Check**: Iteration target must be iterable
2. **Variable Shadowing**: Warn if loop variable shadows outer scope
3. **Parallel Safety**: Warn if parallel loop body has side effects on shared state

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-01 | Initial specification |
| 2.0 | 2025-12 | Simplified: removed while, repeat-until, break, continue, labeled loops. Added collection actions. |
