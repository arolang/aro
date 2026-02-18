# ARO-0002: Control Flow

* Proposal: ARO-0002
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001

## Abstract

This proposal defines control flow constructs in ARO: guarded statements for conditional execution, match expressions for pattern-based dispatch, iteration for collection processing, element access for list operations, and set operations for data manipulation.

## Introduction

Business logic requires conditional execution, pattern matching, and data processing. ARO provides these capabilities through constructs that remain readable and declarative while being precise enough for compilation.

```
+------------------+     +------------------+     +------------------+
|  Guarded Stmt    |     | Match Expression |     |    Iteration     |
|  (when clause)   |     |  (match/case)    |     |  (for each)      |
+--------+---------+     +--------+---------+     +--------+---------+
         |                        |                        |
         v                        v                        v
+--------+---------+     +--------+---------+     +--------+---------+
| Single condition |     | Multiple paths   |     | Collection ops   |
| inline check     |     | pattern dispatch |     | serial/parallel  |
+------------------+     +------------------+     +------------------+
```

---

## 1. Guarded Statements (When Clause)

Guarded statements execute only when a condition is true.

### 1.1 Syntax

```ebnf
guarded_statement = aro_statement_base , "when" , condition , "." ;
```

**Format:**
```aro
Action the <result> preposition the <object> when <condition>.
```

### 1.2 Examples

```aro
(* Only return OK when authentication is valid *)
Return an <OK: status> for the <user> when <authentication> is <valid>.

(* Only send notification when user has email *)
Send the <notification> to the <user: email> when <user: email> exists.

(* Throw error when user not found *)
Throw a <NotFoundError> for the <user> when <user: record> is null.

(* Log admin access *)
Log "Admin access detected" to the <audit> when <user: role> == "admin".
```

### 1.3 Semantics

- The statement executes **only if** the condition is true
- If false, execution continues to the next statement
- No implicit else branch

---

## 2. Conditions

### 2.1 Condition Syntax

```ebnf
condition        = condition_or ;

condition_or     = condition_and , { "or" , condition_and } ;

condition_and    = condition_not , { "and" , condition_not } ;

condition_not    = [ "not" ] , condition_primary ;

condition_primary = comparison
                  | existence_check
                  | type_check
                  | "(" , condition , ")" ;

comparison       = expression , comparison_op , expression ;

comparison_op    = "is" | "is not" | "==" | "!="
                 | "<" | ">" | "<=" | ">="
                 | "equals" | "contains" | "matches" ;

existence_check  = expression , "exists"
                 | expression , "is" , "defined"
                 | expression , "is" , "null"
                 | expression , "is" , "empty" ;

type_check       = expression , "is" , [ "a" | "an" ] , type_name ;
```

### 2.2 Comparison Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `is` | Equality | `<status> is "active"` |
| `is not` | Inequality | `<count> is not 0` |
| `==` | Strict equality | `<user: role> == "admin"` |
| `!=` | Strict inequality | `<value> != null` |
| `<` | Less than | `<price> < 100.00` |
| `>` | Greater than | `<user: age> > 18` |
| `<=` | Less than or equal | `<count> <= 10` |
| `>=` | Greater than or equal | `<score> >= 80` |
| `equals` | Deep equality | `<obj-a> equals <obj-b>` |
| `contains` | Substring/element check | `<text> contains "error"` |
| `matches` | Regex match | `<email> matches /.*@.*\.com/` |

### 2.3 Existence Checks

| Check | Description | Example |
|-------|-------------|---------|
| `exists` | Value is present | `<user: email> exists` |
| `is defined` | Variable is defined | `<optional-field> is defined` |
| `is null` | Value is null | `<value> is null` |
| `is empty` | Collection/string is empty | `<list> is empty` |
| `is not empty` | Has elements | `<list> is not empty` |

### 2.4 Boolean Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `and` | Logical AND | `<age> >= 18 and <verified> is true` |
| `or` | Logical OR | `<role> is "admin" or <role> is "moderator"` |
| `not` | Logical NOT | `not <account: suspended>` |

### 2.5 Condition Examples

```aro
(* Simple comparisons *)
<user: age> >= 18
<status> is "active"
<count> is not 0
<price> < 100.00

(* Existence checks *)
<user: email> exists
<optional-field> is defined
<list> is not empty
<value> is null

(* Type checks *)
<input> is a Number
<data> is a List
<user> is an Admin

(* Logical combinations *)
<user: age> >= 18 and <user: verified> is true
<role> is "admin" or <role> is "moderator"
not <account: suspended>

(* Complex conditions with grouping *)
(<user: role> is "admin" or <user: is-owner> is true) and <resource: public> is false
```

---

## 3. Match Expressions

Match expressions provide pattern-based dispatch with multiple branches.

### 3.1 Syntax

```ebnf
match_expression = "match" , "<" , qualified_noun , ">" , "{" ,
                   { case_clause } ,
                   [ otherwise_clause ] ,
                   "}" ;

case_clause      = "case" , pattern , [ "where" , condition ] , "{" , { statement } , "}" ;

otherwise_clause = "otherwise" , "{" , { statement } , "}" ;

pattern          = literal | "<" , qualified_noun , ">" | regex_pattern | "_" ;

regex_pattern    = "/" , regex_body , "/" , [ regex_flags ] ;
```

**Format:**
```aro
match <variable> {
    case <pattern> {
        <statements>
    }
    case <pattern> where <condition> {
        <statements>
    }
    otherwise {
        <statements>
    }
}
```

### 3.2 Value Matching

```aro
match <http: method> {
    case "GET" {
        Retrieve the <resource> from the <database>.
    }
    case "POST" {
        Create the <resource> in the <database>.
    }
    case "PUT" {
        Update the <resource> in the <database>.
    }
    case "DELETE" {
        <Remove> the <resource> from the <database>.
    }
    otherwise {
        Return a <MethodNotAllowed: error> for the <request>.
    }
}
```

### 3.3 Pattern Matching with Guards

Guards add conditions to case clauses using `where`:

```aro
match <user: subscription> {
    case <premium> where <user: credits> > 0 {
        Grant the <premium-features> for the <user>.
        Deduct the <credit> from the <user: account>.
    }
    case <premium> {
        Log "Low credits for premium user" to the <console>.
        Grant the <basic-features> for the <user>.
    }
    case <basic> {
        Grant the <basic-features> for the <user>.
    }
    otherwise {
        Redirect the <user> to the <subscription-page>.
    }
}
```

### 3.4 Regular Expression Patterns

Match against regex patterns in case clauses:

```aro
match <input: text> {
    case /^[A-Z]{2}\d{4}$/ {
        (* Matches pattern like "AB1234" *)
        Log "Valid product code" to the <console>.
    }
    case /^\d{3}-\d{2}-\d{4}$/ {
        (* Matches SSN pattern *)
        Log "SSN format detected" to the <console>.
    }
    case /^[a-z]+@[a-z]+\.[a-z]+$/ {
        (* Simple email pattern *)
        Log "Email format detected" to the <console>.
    }
    otherwise {
        Log "Unknown format" to the <console>.
    }
}
```

### 3.5 Status Code Handling

```aro
match <status-code> {
    case 200 {
        Parse the <response: body> from the <http-response>.
        Return the <data> for the <request>.
    }
    case 404 {
        Return a <NotFound: error> for the <request>.
    }
    case 500 {
        Log "Server error occurred" to the <monitoring>.
        Return a <ServerError> for the <request>.
    }
    otherwise {
        Return an <UnknownError> for the <request>.
    }
}
```

### 3.6 Nested Match

Match expressions can be nested:

```aro
match <user: status> {
    case "active" {
        Compute the <password-hash> for the <password>.

        match <password-hash> {
            case <user: password-hash> {
                Create the <session-token> for the <user>.
                Return an <OK: status> with the <session-token>.
            }
            otherwise {
                Return an <Unauthorized: error> for the <request>.
            }
        }
    }
    case "locked" {
        Return an <AccountLocked: error> for the <request>.
    }
    otherwise {
        Return an <InvalidStatus: error> for the <request>.
    }
}
```

---

## 4. Iteration

ARO provides bounded, deterministic iteration over collections.

### 4.1 For-Each Loop

#### Syntax

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

#### Basic Iteration

```aro
(Order Processing: E-Commerce) {
    Retrieve the <items> from the <order>.

    for each <item> in <items> {
        Validate the <availability> for the <item>.
        Reserve the <quantity> for the <item>.
    }

    Return an <OK: status> for the <order>.
}
```

#### Filtered Iteration

Use `where` to filter items during iteration:

```aro
(Notification: Communication) {
    Retrieve the <users> from the <user-repository>.

    (* Only process users with notifications enabled *)
    for each <user> in <users> where <user: notifications-enabled> is true {
        Send the <newsletter> to the <user: email>.
    }

    Return an <OK: status> for the <notification>.
}
```

#### Indexed Iteration

Access the current index with `at`:

```aro
(Ranking: Display) {
    Sort the <contestants> from the <competition> by <score>.

    for each <contestant> at <rank> in <contestants> {
        Compute the <position> from <rank> + 1.
        Log "Position assigned" to the <console>.
    }

    Return an <OK: status> for the <ranking>.
}
```

#### Nested Loops

```aro
(Report: Analytics) {
    Retrieve the <departments> from the <organization>.

    for each <department> in <departments> {
        Retrieve the <employees> from the <department>.

        for each <employee> in <employees> {
            Compute the <score> for the <employee>.
            <Add> the <score> to the <department: metrics>.
        }

        Generate the <report> for the <department>.
    }

    Return an <OK: status> for the <analytics>.
}
```

### 4.2 Parallel For-Each

For concurrent processing of independent items:

#### Syntax

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
    Process the <result> for the <item>.
}

parallel for each <item> in <items> with <concurrency: 4> {
    Fetch the <data> from the <external-api>.
}
```

#### Parallel Processing

```aro
(Image Processing: Media) {
    Retrieve the <images> from the <upload-batch>.

    parallel for each <image> in <images> {
        <Resize> the <thumbnail> from the <image>.
        Store the <thumbnail> in the <storage>.
    }

    Return an <OK: status> for the <processing>.
}
```

#### With Concurrency Limit

```aro
(API Sync: Integration) {
    Retrieve the <records> from the <database>.

    (* Limit concurrent API calls to avoid rate limiting *)
    parallel for each <record> in <records> with <concurrency: 4> {
        <Sync> the <data> to the <external-api>.
    }

    Return an <OK: status> for the <sync>.
}
```

#### Semantics

- Items are processed concurrently
- Order of completion is non-deterministic
- Each iteration is independent (no shared mutable state)
- Concurrency limit controls maximum parallel operations
- Loop variable is scoped to the loop body and immutable

### 4.3 Collection Actions

Declarative actions for functional-style collection processing:

#### Filter

Select items matching a condition:

```aro
Filter the <active-users> from the <users> where <active> is true.
Filter the <adults> from the <people> where <age> >= 18.
Filter the <excluded> from <items> where <value> not in <exclude-list>.
```

#### Transform

Apply transformation to each item:

```aro
Transform the <names> from the <users> with <name>.
Transform the <totals> from the <items> with <price> * <quantity>.
```

#### Aggregation

Compute aggregate values:

```aro
<Sum> the <total> from the <prices>.
Count the <amount> from the <items>.
<Average> the <mean> from the <scores>.
<Min> the <lowest> from the <values>.
<Max> the <highest> from the <values>.
```

#### Search

Find specific items:

```aro
<Find> the <admin> from the <users> where <role> is "admin".
<First> the <item> from the <queue>.
<Last> the <entry> from the <log>.
```

#### Ordering

Sort and reorder collections:

```aro
Sort the <sorted-users> from the <users> by <name>.
Sort the <ranked> from the <scores> by <value> descending.
<Reverse> the <reversed> from the <items>.
```

#### Selection

Take or skip items:

```aro
<Take> the <top-ten> from the <results> with 10.
<Skip> the <rest> from the <items> with 5.
<Distinct> the <unique> from the <tags>.
```

#### Predicates

Check conditions across collections:

```aro
<Any> the <has-errors> from the <results> where <status> is "error".
<All> the <all-valid> from the <inputs> where <valid> is true.
<None> the <no-failures> from the <tests> where <passed> is false.
```

---

## 5. List Element Access

Access individual elements, ranges, and selections from lists using specifiers on the result descriptor.

### 5.1 Syntax

Element access uses specifiers on the **result** (left side), not the object:

```aro
Extract the <result: specifier> from the <source>.
```

### 5.2 Keyword Access

| Specifier | Description | Example |
|-----------|-------------|---------|
| `first` | First element | `Extract the <item: first> from the <list>.` |
| `last` | Last element | `Extract the <item: last> from the <list>.` |

### 5.3 Numeric Index Access

Indices use reverse indexing where 0 = last element (most recent):

```
Array: [A, B, C, D, E]
Index:  4  3  2  1  0
        ^           ^
      first       last
```

| Index | Element |
|-------|---------|
| 0 | Last (most recent) |
| 1 | Second-to-last |
| 2 | Third-to-last |
| n | (count - 1 - n)th element |

```aro
Extract the <item: 0> from the <list>.   (* last element *)
Extract the <item: 1> from the <list>.   (* second-to-last *)
```

### 5.4 Range Access

Extract consecutive elements using `start-end` syntax:

```aro
Extract the <subset: 2-5> from the <list>.   (* elements at indices 2, 3, 4, 5 *)
```

Returns an array of elements at the specified indices.

### 5.5 Pick Access

Extract specific elements by listing indices separated by commas:

```aro
Extract the <selection: 0,3,7> from the <list>.   (* elements at 0, 3, 7 *)
```

Returns an array of elements at the specified indices.

### 5.6 Examples

#### Basic Element Access

```aro
(* Create a list *)
Create the <fruits> with ["apple", "banana", "cherry", "date", "elderberry"].

(* Access by keyword *)
Extract the <first-fruit: first> from the <fruits>.   (* "apple" *)
Extract the <last-fruit: last> from the <fruits>.     (* "elderberry" *)

(* Access by index (0 = last) *)
Extract the <recent: 0> from the <fruits>.    (* "elderberry" *)
Extract the <second: 1> from the <fruits>.    (* "date" *)
```

#### Split String and Access Parts

```aro
(* Split CSV line *)
Create the <csv-line> with "name,email,phone,address".
Split the <fields> from the <csv-line> by /,/.

(* Access specific fields *)
Extract the <name: first> from the <fields>.      (* "name" *)
Extract the <address: last> from the <fields>.    (* "address" *)
```

#### Range and Pick Access

```aro
Create the <numbers> with [1, 2, 3, 4, 5, 6, 7, 8, 9, 10].

(* Extract range *)
Extract the <middle: 3-6> from the <numbers>.

Create the <letters> with ["a", "b", "c", "d", "e", "f", "g"].

(* Pick specific elements *)
Extract the <selected: 0,2,4> from the <letters>.
```

### 5.7 Return Values

| Access Type | Returns |
|-------------|---------|
| Single element (first, last, numeric) | Single value or empty string if out of bounds |
| Range (3-5) | Array of elements |
| Pick (3,5,7) | Array of elements |

Out-of-bounds indices are silently ignored.

---

## 6. Set Operations

Set operations work uniformly across Lists, Strings, and Objects.

### 6.1 Syntax

Set operations use the Compute action with a qualifier specifying the operation:

```aro
Compute the <result: operation> from <first> with <second>.
```

### 6.2 Operations

| Operation | Description | Example |
|-----------|-------------|---------|
| `intersect` | Elements in both | `Compute the <common: intersect> from <a> with <b>.` |
| `difference` | In first but not second | `Compute the <only-in-a: difference> from <a> with <b>.` |
| `union` | All unique elements | `Compute the <all: union> from <a> with <b>.` |

### 6.3 Behavior by Type

#### Lists

```aro
Create the <a> with [2, 3, 5].
Create the <b> with [1, 2, 3, 4].

Compute the <common: intersect> from <a> with <b>.    (* [2, 3] *)
Compute the <diff: difference> from <a> with <b>.     (* [5] *)
Compute the <all: union> from <a> with <b>.           (* [2, 3, 5, 1, 4] *)
```

**Multiset semantics** - duplicates are preserved up to minimum count:

```aro
Create the <a> with [1, 2, 2, 3].
Create the <b> with [2, 2, 2, 4].
Compute the <result: intersect> from <a> with <b>.    (* [2, 2] *)
```

#### Strings

Operations work at the character level, preserving order from the first operand:

```aro
Compute the <shared: intersect> from "hello" with "bello".   (* "ello" *)
Compute the <unique: difference> from "hello" with "bello".  (* "h" *)
Compute the <all: union> from "hello" with "bello".          (* "helob" *)
```

#### Objects

Operations recursively compare nested structures:

```aro
Create the <obj-a> with {
    name: "Alice",
    age: 30,
    address: { city: "NYC", zip: "10001" }
}.
Create the <obj-b> with {
    name: "Alice",
    age: 31,
    address: { city: "NYC", state: "NY" }
}.

Compute the <common: intersect> from <obj-a> with <obj-b>.
(* Result: { name: "Alice", address: { city: "NYC" } } *)

Compute the <diff: difference> from <obj-a> with <obj-b>.
(* Result: { age: 30, address: { zip: "10001" } } *)

Compute the <merged: union> from <obj-a> with <obj-b>.
(* Result: { name: "Alice", age: 30, address: { city: "NYC", zip: "10001", state: "NY" } } *)
(* Note: First operand wins on conflicts (age: 30, not 31) *)
```

### 6.4 Type Behavior Matrix

| Operation | Lists | Strings | Objects |
|-----------|-------|---------|---------|
| **intersect** | Elements in both (multiset) | Chars in both (order preserved) | Keys with matching values (recursive) |
| **difference** | In A, not in B | Chars in A, not in B | Keys/values in A, not in B |
| **union** | All unique elements | All unique chars | Merge all keys (A wins conflicts) |

### 6.5 Membership Testing in Filters

Use `in` and `not in` for membership testing:

```aro
Create the <valid-ids> with [1, 2, 3].
Filter the <included> from <items> where <id> in <valid-ids>.
Filter the <excluded> from <items> where <id> not in <valid-ids>.
```

---

## 7. Complete Grammar Extension

```ebnf
(* Extends ARO-0001 *)

(* Updated Statement *)
statement = aro_statement
          | guarded_statement
          | publish_statement
          | match_expression
          | foreach_loop
          | parallel_foreach ;

(* Guarded Statement *)
guarded_statement = action_clause , result_clause , object_clause ,
                    "when" , condition , "." ;

(* Match Expression *)
match_expression  = "match" , variable_reference , "{" ,
                    { case_clause } ,
                    [ otherwise_clause ] ,
                    "}" ;

case_clause       = "case" , pattern , [ guard_clause ] , "{" , { statement } , "}" ;
guard_clause      = "where" , condition ;
otherwise_clause  = "otherwise" , "{" , { statement } , "}" ;

pattern           = variable_reference
                  | literal
                  | regex_pattern
                  | "_" ;

regex_pattern     = "/" , regex_body , "/" , [ regex_flags ] ;

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

(* Conditions *)
condition         = condition_or ;
condition_or      = condition_and , { "or" , condition_and } ;
condition_and     = condition_not , { "and" , condition_not } ;
condition_not     = [ "not" ] , condition_atom ;
condition_atom    = comparison | existence | type_check
                  | "(" , condition , ")" ;

comparison        = expression , comp_op , expression ;
comp_op           = "is" | "is" , "not" | "==" | "!="
                  | "<" | ">" | "<=" | ">="
                  | "equals" | "contains" | "matches" ;

existence         = expression , ( "exists" | "is" , "defined"
                                 | "is" , "null" | "is" , "empty" ) ;

type_check        = expression , "is" , [ "a" | "an" ] , type_name ;

(* Keywords *)
keyword          += "when" | "match" | "case" | "otherwise" | "where"
                  | "and" | "or" | "not"
                  | "exists" | "defined" | "null" | "empty"
                  | "true" | "false"
                  | "for" | "each" | "in" | "at" | "parallel" | "concurrency" ;
```

---

## 8. Complete Example

```aro
(Order Fulfillment: E-Commerce) {
    Retrieve the <orders> from the <order-repository>.
    Filter the <pending-orders> from the <orders> where <status> is "pending".

    for each <order> in <pending-orders> {
        Retrieve the <items> from the <order>.

        (* Check all items are in stock *)
        <All> the <in-stock> from the <items> where <inventory: available> > 0.

        match <in-stock> {
            case true {
                (* Reserve inventory for all items *)
                for each <item> in <items> {
                    Reserve the <quantity> from the <inventory> for the <item>.
                }

                (* Update order status *)
                Update the <order: status> to "processing".

                (* Send confirmation *)
                Send the <confirmation> to the <order: customer-email>.
            }
            case false {
                Update the <order: status> to "backordered".
                Send the <backorder-notice> to the <order: customer-email>.
            }
        }
    }

    (* Calculate summary *)
    Count the <processed-count> from the <pending-orders>.
    Log "Orders processed" to the <console>.

    Return an <OK: status> for the <fulfillment>.
}

(User Authentication: Security) {
    Extract the <username> from the <request: body>.
    Extract the <password> from the <request: body>.

    (* Validate input - guarded return *)
    Return a <BadRequest: error> for the <request>
        when <username> is empty or <password> is empty.

    (* Look up user *)
    Retrieve the <user> from the <user-repository>.

    (* Handle user not found - guarded statements *)
    Log "Failed login attempt" to the <audit> when <user> is null.
    Return an <Unauthorized: error> for the <request> when <user> is null.

    (* Check account status with match *)
    match <user: status> {
        case "locked" {
            Return an <AccountLocked: error> for the <request>.
        }
        case "pending" {
            Send the <verification-email> to the <user: email>.
            Return a <PendingVerification: status> for the <request>.
        }
        case "active" {
            Compute the <password-hash: hash> from the <password>.

            match <password-hash> {
                case <user: password-hash> {
                    Create the <session-token> for the <user>.
                    Log "Successful login" to the <audit>.
                    Return an <OK: status> with the <session-token>.
                }
                otherwise {
                    Increment the <failed-attempts> for the <user>.
                    <Lock> the <user: account> for the <security-policy>
                        when <failed-attempts> >= 5.
                    Return an <Unauthorized: error> for the <request>.
                }
            }
        }
        otherwise {
            Return an <InvalidAccountStatus: error> for the <request>.
        }
    }
}

(Set Operations Demo: Data Processing) {
    (* List operations *)
    Create the <list-a> with [2, 3, 5].
    Create the <list-b> with [1, 2, 3, 4].

    Compute the <common: intersect> from <list-a> with <list-b>.
    Compute the <only-in-a: difference> from <list-a> with <list-b>.
    Compute the <all: union> from <list-a> with <list-b>.

    (* String operations *)
    Compute the <shared-chars: intersect> from "hello" with "bello".

    (* Element access *)
    Create the <fruits> with ["apple", "banana", "cherry", "date"].
    Extract the <first-fruit: first> from the <fruits>.
    Extract the <last-fruit: last> from the <fruits>.
    Extract the <middle: 1-2> from the <fruits>.

    Return an <OK: status> for the <demo>.
}
```

---

## Implementation Notes

### AST Nodes

```swift
public struct MatchExpression: Statement {
    let subject: QualifiedNoun
    let cases: [CaseClause]
    let otherwise: [Statement]?
    let span: SourceSpan
}

public struct CaseClause: Sendable {
    let pattern: Pattern
    let guardCondition: (any Expression)?
    let body: [Statement]
    let span: SourceSpan
}

public enum Pattern: Sendable {
    case literal(LiteralValue)
    case variable(QualifiedNoun)
    case regex(String)
    case wildcard
}

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

### Guarded Statements

Guarded statements extend `AROStatement` with an optional `when` condition:

```swift
public struct AROStatement: Statement {
    // ... existing fields ...
    let whenCondition: (any Expression)?
}
```

### Semantic Checks

1. **Collection Type Check**: Iteration target must be iterable
2. **Variable Shadowing**: Warn if loop variable shadows outer scope
3. **Parallel Safety**: Warn if parallel loop body has side effects on shared state
4. **Guard Evaluation**: Conditions must be boolean expressions
