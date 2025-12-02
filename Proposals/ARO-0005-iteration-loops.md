# ARO-0005: Iteration and Loops

* Proposal: ARO-0005
* Author: ARO Language Team
* Status: **Draft**
* Requires: ARO-0001, ARO-0002, ARO-0003, ARO-0004

## Abstract

This proposal introduces iteration constructs to ARO, enabling specifications to process collections, repeat operations, and handle sequences of data.

## Motivation

Many business operations involve:

- Processing each item in a collection
- Repeating until a condition is met
- Aggregating results from multiple items
- Transforming lists of data

## Proposed Solution

Three iteration constructs:

1. **For-Each**: Iterate over collections
2. **While**: Repeat while condition holds
3. **Repeat-Until**: Repeat until condition becomes true

Plus collection operations for functional-style processing.

---

### 1. For-Each Loop

#### 1.1 Syntax

```ebnf
foreach_loop = "for" , "each" , "<" , item_name , ">" , 
               "in" , "<" , collection , ">" ,
               [ "where" , condition ] ,
               block ;

item_name    = compound_identifier ;
collection   = qualified_noun ;
```

**Format:**
```
for each <item> in <collection> {
    <statements using item>
}

for each <item> in <collection> where <condition> {
    <statements>
}
```

#### 1.2 Examples

##### Basic Iteration

```
(Order Processing: E-Commerce) {
    <Retrieve> the <order: items> from the <order>.
    
    for each <item> in <order: items> {
        <Validate> the <stock: availability> for the <item>.
        <Reserve> the <quantity> for the <item>.
    }
}
```

##### With Filter

```
(Notification: Communication) {
    <Retrieve> the <users> from the <user-repository>.
    
    for each <user> in <users> where <user: notifications-enabled> is true {
        <Send> the <newsletter> to the <user: email>.
    }
}
```

##### Nested Loops

```
(Report: Analytics) {
    <Retrieve> the <departments> from the <organization>.
    
    for each <department> in <departments> {
        <Retrieve> the <employees> from the <department>.
        
        for each <employee> in <employees> {
            <Compute> the <performance: score> for the <employee>.
            <Add> the <score> to the <department: metrics>.
        }
        
        <Generate> the <department: report> for the <department>.
    }
}
```

#### 1.3 Loop Variable Scoping

- The loop variable (`<item>`) is scoped to the loop body
- It shadows any outer variable with the same name
- It is immutable within the loop

```
(Example: Scoping) {
    <Set> the <item> to "outer".
    
    for each <item> in <items> {
        // <item> refers to current collection element
        <Process> the <item>.
    }
    
    // <item> is "outer" again
}
```

---

### 2. Indexed For-Each

#### 2.1 Syntax

```ebnf
indexed_foreach = "for" , "each" , "<" , item_name , ">" , 
                  "at" , "<" , index_name , ">" ,
                  "in" , "<" , collection , ">" ,
                  block ;
```

**Format:**
```
for each <item> at <index> in <collection> {
    <statements>
}
```

#### 2.2 Example

```
(Ranking: Display) {
    <Sort> the <contestants> by the <score: descending>.
    
    for each <contestant> at <rank> in <contestants> {
        <Set> the <position> to <rank> + 1.
        <Display> the <position> with the <contestant: name>.
    }
}
```

---

### 3. While Loop

#### 3.1 Syntax

```ebnf
while_loop = "while" , condition , block ;
```

**Format:**
```
while <condition> {
    <statements>
}
```

#### 3.2 Examples

##### Retry Logic

```
(API Client: Integration) {
    <Set> the <attempts> to 0.
    <Set> the <max-attempts> to 3.
    <Set> the <success> to false.
    
    while <attempts> < <max-attempts> and <success> is false {
        <Increment> the <attempts>.
        <Call> the <external-api> for the <request>.
        
        if <response: status> is 200 then {
            <Set> the <success> to true.
            <Parse> the <data> from the <response>.
        } else {
            <Wait> for <retry-delay: seconds>.
        }
    }
    
    if <success> is false then {
        <Throw> a <ServiceUnavailable: error> for the <request>.
    }
}
```

##### Processing Queue

```
(Queue Processor: Background) {
    while <queue> is not empty {
        <Dequeue> the <task> from the <queue>.
        <Process> the <result> for the <task>.
        <Mark> the <task> as <completed>.
    }
}
```

---

### 4. Repeat-Until Loop

#### 4.1 Syntax

```ebnf
repeat_until = "repeat" , block , "until" , condition ;
```

**Format:**
```
repeat {
    <statements>
} until <condition>
```

#### 4.2 Semantics

- Body executes **at least once**
- Condition checked **after** each iteration
- Loop exits when condition becomes true

#### 4.3 Example

```
(Validation: Input) {
    repeat {
        <Prompt> the <user> for the <input>.
        <Read> the <value> from the <user-input>.
        <Validate> the <result> for the <value>.
    } until <result> is <valid>
    
    <Process> the <value> for the <operation>.
}
```

---

### 5. Loop Control

#### 5.1 Break Statement

Exit the innermost loop immediately:

```ebnf
break_statement = "<Break>" , "." ;
```

**Example:**
```
for each <item> in <items> {
    if <item> is <target> then {
        <Set> the <found> to <item>.
        <Break>.
    }
}
```

#### 5.2 Continue Statement

Skip to next iteration:

```ebnf
continue_statement = "<Continue>" , "." ;
```

**Example:**
```
for each <order> in <orders> {
    if <order: status> is "cancelled" then {
        <Continue>.
    }
    <Process> the <order>.
}
```

#### 5.3 Labeled Loops

For nested loop control:

```ebnf
labeled_loop = label , ":" , ( foreach_loop | while_loop | repeat_until ) ;
break_to     = "<Break>" , "to" , label , "." ;
continue_to  = "<Continue>" , "to" , label , "." ;
label        = identifier ;
```

**Example:**
```
outer: for each <category> in <categories> {
    for each <product> in <category: products> {
        if <product> is <target> then {
            <Set> the <result> to <product>.
            <Break> to outer.
        }
    }
}
```

---

### 6. Collection Operations

Functional-style operations on collections:

#### 6.1 Map

```ebnf
map_expression = "<" , collection , ">" , ".map(" , 
                 "<" , item , ">" , "=>" , expression , ")" ;
```

**Example:**
```
<Compute> the <prices> from <items>.map(<item> => <item>.price * <item>.quantity).
```

#### 6.2 Filter

```ebnf
filter_expression = "<" , collection , ">" , ".filter(" , 
                    "<" , item , ">" , "=>" , condition , ")" ;
```

**Example:**
```
<Compute> the <active-users> from <users>.filter(<user> => <user>.isActive is true).
```

#### 6.3 Reduce

```ebnf
reduce_expression = "<" , collection , ">" , ".reduce(" ,
                    "<" , accumulator , ">" , "," , "<" , item , ">" ,
                    "=>" , expression , "," , initial_value , ")" ;
```

**Example:**
```
<Compute> the <total> from <prices>.reduce(<sum>, <price> => <sum> + <price>, 0).
```

#### 6.4 Other Operations

| Operation | Description | Example |
|-----------|-------------|---------|
| `.first()` | First element | `<items>.first()` |
| `.last()` | Last element | `<items>.last()` |
| `.count()` | Number of elements | `<items>.count()` |
| `.sum()` | Sum of numbers | `<prices>.sum()` |
| `.avg()` | Average | `<scores>.avg()` |
| `.min()` | Minimum | `<values>.min()` |
| `.max()` | Maximum | `<values>.max()` |
| `.sort()` | Sort ascending | `<items>.sort()` |
| `.reverse()` | Reverse order | `<items>.reverse()` |
| `.distinct()` | Unique elements | `<items>.distinct()` |
| `.take(n)` | First n elements | `<items>.take(10)` |
| `.skip(n)` | Skip n elements | `<items>.skip(5)` |
| `.any(cond)` | Any match condition | `<items>.any(<i> => <i> > 0)` |
| `.all(cond)` | All match condition | `<items>.all(<i> => <i> > 0)` |
| `.none(cond)` | None match condition | `<items>.none(<i> => <i> < 0)` |
| `.find(cond)` | First matching | `<items>.find(<i> => <i>.id == 5)` |

---

### 7. Parallel Iteration (Future)

For concurrent processing:

```
parallel for each <item> in <items> with <concurrency: 4> {
    <Process> the <item>.
}
```

---

### 8. Complete Grammar Extension

```ebnf
(* Extends ARO-0004 *)

(* Updated Statement *)
statement = aro_statement 
          | guarded_statement
          | publish_statement 
          | require_statement
          | conditional_block
          | match_expression
          | foreach_loop
          | indexed_foreach
          | while_loop
          | repeat_until
          | break_statement
          | continue_statement ;

(* For-Each Loop *)
foreach_loop = "for" , "each" , variable_reference ,
               [ "at" , variable_reference ] ,
               "in" , variable_reference ,
               [ "where" , condition ] ,
               block ;

(* While Loop *)
while_loop = "while" , condition , block ;

(* Repeat-Until *)
repeat_until = "repeat" , block , "until" , condition ;

(* Loop Control *)
break_statement    = "<Break>" , [ "to" , identifier ] , "." ;
continue_statement = "<Continue>" , [ "to" , identifier ] , "." ;

(* Labeled Loop *)
labeled_loop = identifier , ":" , 
               ( foreach_loop | while_loop | repeat_until ) ;

(* Collection Operations *)
collection_op = variable_reference , "." , operation_name , 
                "(" , [ lambda_or_args ] , ")" ;

operation_name = "map" | "filter" | "reduce" | "first" | "last" 
               | "count" | "sum" | "avg" | "min" | "max"
               | "sort" | "reverse" | "distinct" 
               | "take" | "skip" | "any" | "all" | "none" | "find" ;

lambda_or_args = lambda_expression | expression_list ;

lambda_expression = variable_reference , "=>" , expression
                  | variable_reference , "," , variable_reference , 
                    "=>" , expression ;

expression_list = expression , { "," , expression } ;

(* New Keywords *)
keyword += "for" | "each" | "in" | "at" | "while" | "repeat" | "until" ;
```

---

### 9. Complete Examples

#### Batch Processing

```
(Batch Processing: Data Pipeline) {
    <Retrieve> the <pending-jobs> from the <job-queue>.
    
    for each <job> in <pending-jobs> {
        <Mark> the <job> as <processing>.
        
        match <job: type> {
            case "import" {
                <Import> the <data> from the <job: source>.
            }
            case "export" {
                <Export> the <data> to the <job: destination>.
            }
            case "transform" {
                <Transform> the <data> with the <job: rules>.
            }
            otherwise {
                <Log> the <unknown-job-type: warning> for the <job>.
                <Continue>.
            }
        }
        
        <Mark> the <job> as <completed>.
    }
}
```

#### Shopping Cart Calculation

```
(Shopping Cart: E-Commerce) {
    <Retrieve> the <cart: items> from the <session>.
    
    // Calculate subtotal using map/reduce
    <Compute> the <subtotal> from 
        <cart: items>
            .map(<item> => <item>.price * <item>.quantity)
            .sum().
    
    // Apply discounts
    <Set> the <discount> to 0.
    
    for each <item> in <cart: items> where <item: has-discount> is true {
        <Compute> the <item-discount> for the <item>.
        <Add> the <item-discount> to the <discount>.
    }
    
    // Calculate tax
    <Compute> the <taxable-amount> from <subtotal> - <discount>.
    <Compute> the <tax> from <taxable-amount> * 0.08.
    
    // Final total
    <Compute> the <total> from <taxable-amount> + <tax>.
    
    <Return> the <cart: summary> with {
        subtotal: <subtotal>,
        discount: <discount>,
        tax: <tax>,
        total: <total>
    }.
}
```

#### Pagination

```
(Data Export: Reporting) {
    <Set> the <page> to 1.
    <Set> the <page-size> to 100.
    <Set> the <has-more> to true.
    
    while <has-more> is true {
        <Retrieve> the <records> from the <database> 
            with { page: <page>, size: <page-size> }.
        
        if <records> is empty then {
            <Set> the <has-more> to false.
        } else {
            for each <record> in <records> {
                <Transform> the <row> from the <record>.
                <Write> the <row> to the <export-file>.
            }
            <Increment> the <page>.
        }
    }
    
    <Close> the <export-file>.
}
```

---

## Implementation Notes

### AST Nodes

```swift
public struct ForEachLoop: Statement {
    let itemVariable: String
    let indexVariable: String?
    let collection: QualifiedNoun
    let filter: Condition?
    let body: [Statement]
    let label: String?
    let span: SourceSpan
}

public struct WhileLoop: Statement {
    let condition: Condition
    let body: [Statement]
    let label: String?
    let span: SourceSpan
}

public struct RepeatUntil: Statement {
    let body: [Statement]
    let condition: Condition
    let label: String?
    let span: SourceSpan
}

public struct BreakStatement: Statement {
    let targetLabel: String?
    let span: SourceSpan
}

public struct ContinueStatement: Statement {
    let targetLabel: String?
    let span: SourceSpan
}

public struct CollectionOperation: Expression {
    let collection: Expression
    let operation: String
    let arguments: [Expression]
    let lambda: LambdaExpression?
    let span: SourceSpan
}

public struct LambdaExpression {
    let parameters: [String]
    let body: Expression
    let span: SourceSpan
}
```

### Semantic Checks

1. **Infinite Loop Detection**: Warn if condition never changes
2. **Break/Continue Validation**: Must be inside a loop
3. **Label Resolution**: Labeled break/continue must match existing label
4. **Collection Type Check**: Iteration target must be iterable

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-01 | Initial specification |
