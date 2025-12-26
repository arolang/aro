# The Basics

This chapter introduces the fundamental building blocks of ARO: the syntax, structure, and core concepts you'll use in every program.

## Source Files

ARO source files use the `.aro` extension. An application is a directory containing one or more `.aro` files:

```
MyApp/
├── openapi.yaml   # API contract (required for HTTP)
├── main.aro
├── users.aro
└── events.aro
```

All files in the directory are automatically compiled together. No import statements are needed within an application.

## Importing Other Applications

To use feature sets and types from another ARO application, use `import`:

```aro
import ../user-service
import ../payment-gateway
```

After importing, all feature sets, types, and published variables from the imported application become accessible.

```
workspace/
├── user-service/           # Can import ../payment-service
│   ├── main.aro
│   └── users.aro
├── payment-service/        # Can import ../user-service
│   └── main.aro
└── api-gateway/            # Can import both
    └── main.aro
```

**api-gateway/main.aro:**
```aro
import ../user-service
import ../payment-service

(Application-Start: API Gateway) {
    <Keepalive> the <application> for the <events>.
    <Return> an <OK: status> for the <startup>.
}
```

### No Visibility Modifiers

ARO has no `public`, `private`, or `internal` keywords. Everything is accessible after import. This reflects trust-based composition: if you import an application, you trust it.

## Comments

ARO uses Pascal-style block comments:

```aro
(* This is a comment *)

(*
   Multi-line comments
   are also supported
*)

(* Comments can contain (* nested comments *) *)
```

Comments are ignored by the compiler and are used for documentation.

## Feature Sets

A **feature set** is the primary organizational unit in ARO. It groups related statements that accomplish a business goal:

```aro
(Feature Name: Business Activity) {
    (* statements go here *)
}
```

### Components

1. **Name**: Identifies the feature set (e.g., `User Authentication`)
2. **Business Activity**: Describes the domain context (e.g., `Security`)
3. **Body**: Contains statements enclosed in curly braces

### Example

```aro
(Validate User Credentials: Authentication) {
    <Extract> the <username> from the <request: body.username>.
    <Extract> the <password> from the <request: body.password>.
    <Retrieve> the <user> from the <user-repository> where username = <username>.
    <Compare> the <password> against the <user: passwordHash>.
    <Return> an <OK: status> with <user>.
}
```

## Statements

Every statement in ARO follows the **Action-Result-Object** pattern:

```
<Action> [article] <result> preposition [article] <object> [modifiers].
```

### Components

| Component | Description | Example |
|-----------|-------------|---------|
| Action | The verb/operation | `<Extract>`, `<Create>`, `<Return>` |
| Article | Optional: a, an, the | `the`, `a`, `an` |
| Result | The output variable | `<user>`, `<data: processed>` |
| Preposition | Relationship word | `from`, `to`, `for`, `with` |
| Object | The input/target | `<request: body>`, `<repository>` |
| Modifiers | Additional clauses | `where id = <user-id>` |

### Statement Termination

Every statement ends with a period (`.`):

```aro
<Extract> the <user-id> from the <pathParameters: id>.
<Retrieve> the <user> from the <user-repository>.
<Return> an <OK: status> with <user>.
```

## Variables

Variables are denoted with angle brackets and hold values during execution.

### Simple Variables

```aro
<user>
<order>
<total>
```

### Qualified Variables

Add context with a colon and qualifier:

```aro
<user: id>           (* The id property of user *)
<request: body>      (* The body of the request *)
<order: lineItems>   (* The lineItems of an order *)
```

### Compound Names

Use hyphens for multi-word names:

```aro
<user-id>
<order-total>
<customer-email>
<http-response>
```

### Variable Binding

Variables are bound when they appear as the result of an action:

```aro
<Extract> the <user-name> from the <request: body>.
(* user-name is now bound and can be used *)

<Create> the <greeting> with "Hello, ${user-name}!".
(* greeting is now bound *)
```

## Articles

ARO uses English articles (`a`, `an`, `the`) for readability:

```aro
<Return> an <OK: status> for the <request>.
<Create> a <user> with <user-data>.
<Extract> the <id> from the <pathParameters: id>.
```

Articles are syntactically required but don't affect semantics.

### Usage Rules

- Use `a` before consonant sounds
- Use `an` before vowel sounds
- Use `the` for specific references

## Prepositions

Prepositions define the relationship between result and object:

| Preposition | Meaning | Example |
|-------------|---------|---------|
| `from` | Data source | `<Extract> the <id> from the <request>` |
| `to` | Destination | `<Send> the <email> to the <user>` |
| `for` | Purpose/benefit | `<Compute> the <hash> for the <password>` |
| `with` | Accompaniment | `<Create> the <user> with <data>` |
| `into` | Storage target | `<Store> the <user> into the <repository>` |
| `against` | Comparison | `<Compare> the <a> against the <b>` |
| `on` | Location/port | `<Start> the <server> on port 8080` |
| `as` | Alias/role | `<Publish> as <alias> <variable>` |

## Literals

### String Literals

Strings are enclosed in double quotes:

```aro
<Log> the <message> for the <console> with "Hello, World!".
```

### String Interpolation

Use `${}` for variable interpolation:

```aro
<Create> the <greeting> with "Hello, ${user-name}!".
<Log> the <message> for the <console> with "User ${user-id} logged in".
```

### Object Literals

Create structured data with curly braces:

```aro
<Create> the <user> with {
    name: "John Doe",
    email: "john@example.com",
    role: "admin"
}.

<Create> the <config> with {
    port: 8080,
    host: "localhost",
    debug: true
}.
```

### Numeric Literals

Numbers are written directly:

```aro
<Start> the <http-server> on port 8080.
<Set> the <timeout> to 30.
<Configure> the <retry-count> with 3.
```

## Type Hints

Add type hints with a colon in the result:

```aro
<Read> the <config: JSON> from the <file: "./config.json">.
<Read> the <data: bytes> from the <file: "./image.png">.
<Transform> the <users: List> from the <response: body>.
```

## Conditions

### Where Clauses

Filter data with `where`:

```aro
<Retrieve> the <user> from the <user-repository> where id = <user-id>.
<Retrieve> the <orders> from the <order-repository> where status = "pending".
<Delete> the <sessions> from the <session-repository> where userId = <user-id>.
```

### Multiple Conditions

Combine conditions with `and`:

```aro
<Retrieve> the <orders> from the <order-repository>
    where status = "pending" and customerId = <customer-id>.
```

## Special Feature Sets

### Application-Start

The required entry point:

```aro
(Application-Start: My Application) {
    (* Initialization code *)
    <Keepalive> the <application> for the <events>.
    <Return> an <OK: status> for the <startup>.
}
```

### Application-End

Optional exit handlers:

```aro
(Application-End: Success) {
    (* Cleanup on graceful shutdown *)
    <Return> an <OK: status> for the <shutdown>.
}

(Application-End: Error) {
    (* Cleanup on error *)
    <Return> an <OK: status> for the <error-handling>.
}
```

### HTTP Route Handlers (Contract-First)

Feature sets are named after `operationId` values from `openapi.yaml`:

```aro
(* openapi.yaml defines: GET /users -> operationId: listUsers *)
(listUsers: User API) { ... }

(* openapi.yaml defines: POST /users -> operationId: createUser *)
(createUser: User API) { ... }

(* openapi.yaml defines: GET /users/{id} -> operationId: getUser *)
(getUser: User API) { ... }
```

### Event Handlers

Feature sets with "Handler" in the business activity:

```aro
(Process File: FileCreated Handler) { ... }
(Log Connection: ClientConnected Handler) { ... }
(Echo Data: DataReceived Handler) { ... }
```

## Whitespace and Formatting

ARO is whitespace-insensitive. These are equivalent:

```aro
(* Compact *)
(listUsers: API) { <Retrieve> the <users> from the <repository>. <Return> an <OK: status> with <users>. }

(* Expanded *)
(listUsers: API) {
    <Retrieve> the <users> from the <repository>.
    <Return> an <OK: status> with <users>.
}
```

### Style Recommendations

- One statement per line
- Indent statements within feature sets
- Use blank lines to separate logical groups
- Keep feature sets focused on a single responsibility

## Reserved Words

The following words have special meaning in ARO:

**Articles**: `a`, `an`, `the`

**Prepositions**: `from`, `to`, `for`, `with`, `into`, `against`, `on`, `as`

**Control Flow**: `if`, `then`, `else`, `when`, `where`, `and`, `or`, `not`, `is`

**Status**: `OK`, `Created`, `NoContent`, `BadRequest`, `NotFound`, `Forbidden`

## Next Steps

- [Feature Sets](featuresets.html) - Organizing code into feature sets
- [Actions](actions.html) - Complete action reference
- [Variables and Data Flow](variables.html) - Data binding and scoping
