# Statements Reference

This document provides a complete reference for all statement types in ARO.

## ARO Statement

The fundamental statement type following the Action-Result-Object pattern.

### Syntax

```
<Action> [article] <result> preposition [article] <object> [modifiers].
```

### Components

| Component | Required | Description |
|-----------|----------|-------------|
| Action | Yes | Verb in angle brackets |
| Article | No | a, an, or the |
| Result | Yes | Output variable |
| Preposition | Yes | Relationship word |
| Object | Yes | Input/target |
| Modifiers | No | where, with, on clauses |

### Examples

```aro
<Extract> the <user-id> from the <request: parameters>.
<Create> a <user> with <user-data>.
<Return> an <OK: status> for the <request>.
<Store> the <order> into the <order-repository>.
<Retrieve> the <user> from the <repository> where id = <user-id>.
<Start> the <http-server> on port 8080.
```

## Publish Statement

Makes a variable globally accessible across feature sets.

### Syntax

```
<Publish> as <alias> <variable>.
```

### Components

| Component | Description |
|-----------|-------------|
| alias | Name to publish under |
| variable | Variable to publish |

### Example

```aro
<Read> the <config> from the <file: "./config.json">.
<Publish> as <app-config> <config>.
```

## Conditional Statement (if-then-else)

Executes statements based on a condition.

### Syntax

```
if <condition> then {
    (* statements *)
}

if <condition> then {
    (* statements if true *)
} else {
    (* statements if false *)
}
```

### Conditions

| Condition | Description |
|-----------|-------------|
| `<var> is <value>` | Equality |
| `<var> is not <value>` | Inequality |
| `<var> is empty` | Null/empty check |
| `<var> is not empty` | Has value |
| `<var> > <value>` | Greater than |
| `<var> < <value>` | Less than |
| `<var> >= <value>` | Greater or equal |
| `<var> <= <value>` | Less or equal |
| `<cond1> and <cond2>` | Both true |
| `<cond1> or <cond2>` | Either true |
| `not <cond>` | Negation |

### Examples

```aro
if <user> is empty then {
    <Return> a <NotFound: status> for the <missing: user>.
}

if <user: role> is "admin" then {
    <Return> an <OK: status> with <admin-data>.
} else {
    <Return> an <OK: status> with <user-data>.
}

if <count> > 0 and <count> < 100 then {
    <Process> the <items> for the <batch>.
}
```

## Guard Statement (when)

Provides early exit for preconditions.

### Syntax

```
when <condition> {
    (* exit statements *)
}
```

### Example

```aro
(PUT /users/{id}: User API) {
    <Extract> the <user-id> from the <request: parameters>.
    <Extract> the <updates> from the <request: body>.

    when <user-id> is empty {
        <Return> a <BadRequest: status> for the <missing: id>.
    }

    when <updates> is empty {
        <Return> a <BadRequest: status> for the <missing: data>.
    }

    (* Continue with valid input *)
    <Retrieve> the <user> from the <repository> where id = <user-id>.
    ...
}
```

## Match Statement

Pattern matching for multiple cases.

### Syntax

```
match <variable> {
    case <value1> {
        (* statements *)
    }
    case <value2> {
        (* statements *)
    }
    default {
        (* fallback statements *)
    }
}
```

### Example

```aro
match <status> {
    case "pending" {
        <Log> the <message> for the <console> with "Order is pending".
    }
    case "shipped" {
        <Log> the <message> for the <console> with "Order has shipped".
        <Emit> an <OrderShipped: event> with <order>.
    }
    case "delivered" {
        <Log> the <message> for the <console> with "Order delivered".
        <Emit> an <OrderDelivered: event> with <order>.
    }
    default {
        <Log> the <warning> for the <console> with "Unknown status".
    }
}
```

## Return Statement

Exits the feature set with a response.

### Syntax

```
<Return> [article] <status> [with <data>] [for <context>].
```

### Status Codes

| Status | HTTP Code | Usage |
|--------|-----------|-------|
| `OK` | 200 | Successful request |
| `Created` | 201 | Resource created |
| `Accepted` | 202 | Async operation started |
| `NoContent` | 204 | Success, no body |
| `BadRequest` | 400 | Invalid input |
| `Unauthorized` | 401 | Auth required |
| `Forbidden` | 403 | Access denied |
| `NotFound` | 404 | Not found |
| `Conflict` | 409 | Resource conflict |
| `UnprocessableEntity` | 422 | Validation failed |
| `TooManyRequests` | 429 | Rate limited |
| `InternalError` | 500 | Server error |
| `ServiceUnavailable` | 503 | Service down |

### Examples

```aro
<Return> an <OK: status> with <data>.
<Return> a <Created: status> with <resource>.
<Return> a <NoContent: status> for the <deletion>.
<Return> a <BadRequest: status> with <validation: errors>.
<Return> a <NotFound: status> for the <missing: user>.
<Return> a <Forbidden: status> for the <unauthorized: access>.
```

## Comment

Adds documentation to code.

### Syntax

```
(* comment text *)
```

### Examples

```aro
(* This is a single-line comment *)

(*
   This is a
   multi-line comment
*)

(* Comments can be (* nested *) *)

(Process Order: Order Processing) {
    (* Extract order data from request *)
    <Extract> the <order-data> from the <request: body>.

    (* Validate before processing *)
    <Validate> the <order-data> for the <order-schema>.

    (* Store and return *)
    <Store> the <order> into the <repository>.
    <Return> a <Created: status> with <order>.
}
```

## Where Clause

Filters data in retrieval and deletion.

### Syntax

```
... where <field> = <value>
... where <field> = <value> and <field2> = <value2>
```

### Examples

```aro
<Retrieve> the <user> from the <repository> where id = <user-id>.
<Retrieve> the <orders> from the <repository> where status = "pending".
<Retrieve> the <users> from the <repository> where role = "admin" and active = true.
<Delete> the <sessions> from the <repository> where userId = <user-id>.
```

## With Clause

Provides additional data or parameters.

### Syntax

```
... with <variable>
... with <object-literal>
... with <string-literal>
```

### Examples

```aro
<Create> the <user> with <user-data>.
<Create> the <config> with { debug: true, port: 8080 }.
<Transform> the <updated> from the <user> with <updates>.
<Send> the <message> to the <connection> with "Hello, World!".
<Log> the <message> for the <console> with "Application started".
```

## On Clause

Specifies ports for network operations.

### Syntax

```
... on port <number>
```

### Examples

```aro
<Start> the <http-server> on port 8080.
<Listen> on port 9000 as <socket-server>.
<Connect> to <host: "localhost"> on port 5432 as <database>.
```

## Statement Order

Statements execute sequentially from top to bottom:

```aro
(Process Request: Handler) {
    (* 1. First *)
    <Extract> the <data> from the <request: body>.

    (* 2. Second *)
    <Validate> the <data> for the <schema>.

    (* 3. Third *)
    <Create> the <result> with <data>.

    (* 4. Fourth *)
    <Store> the <result> into the <repository>.

    (* 5. Fifth - ends execution *)
    <Return> a <Created: status> with <result>.

    (* Never executed - after return *)
    <Log> the <message> for the <console> with "This won't run".
}
```

## Statement Termination

All statements end with a period (`.`):

```aro
(* Correct *)
<Extract> the <data> from the <request>.
<Return> an <OK: status> with <data>.

(* Incorrect - missing period *)
<Extract> the <data> from the <request>
```

Control flow blocks use braces without periods:

```aro
if <condition> then {
    <Return> a <NotFound: status>.  (* Period on inner statement *)
}  (* No period on closing brace *)
```
