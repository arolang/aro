# Variables and Data Flow

Variables in ARO hold values during execution. This chapter explains how variables are created, scoped, and how data flows through your application.

## Variable Basics

### Declaring Variables

Variables are implicitly declared when they appear as the result of an action:

```aro
<Extract> the <user-id> from the <request: parameters>.
(* user-id is now declared and bound *)

<Create> the <user> with <user-data>.
(* user is now declared and bound *)
```

There's no separate declaration step - variables come into existence when first assigned.

### Variable Syntax

Variables use angle brackets:

```aro
<user>                (* Simple variable *)
<user-id>             (* Hyphenated name *)
<orderTotal>          (* Camel case - works but not recommended *)
```

**Naming Conventions:**
- Use lowercase with hyphens: `<user-id>`, `<order-total>`
- Be descriptive: `<customer-email>` not `<ce>`
- Use nouns: `<user>`, `<order>`, `<payment>`

### Qualified Variables

Add qualifiers to access properties:

```aro
<user: id>            (* The id property of user *)
<user: email>         (* The email property *)
<order: lineItems>    (* The lineItems property *)
<request: body>       (* The body of request *)
```

Qualifiers can be chained conceptually, but typically you extract step by step:

```aro
<Extract> the <order> from the <request: body>.
<Extract> the <items> from the <order: lineItems>.
<Extract> the <first-item> from the <items: first>.
```

## Variable Scoping

### Feature Set Scope

Variables are scoped to their feature set:

```aro
(GET /users/{id}: User API) {
    <Extract> the <user-id> from the <request: parameters>.
    (* user-id is available here *)

    <Retrieve> the <user> from the <repository> where id = <user-id>.
    (* user is available here *)

    <Return> an <OK: status> with <user>.
}
(* user-id and user are NOT available outside this feature set *)
```

### No Global Variables

Variables don't persist across feature set executions:

```aro
(GET /count: Counter API) {
    (* This won't work - count doesn't persist *)
    <Set> the <count> to <count> + 1.
    <Return> an <OK: status> with <count>.
}
```

Use repositories for persistence:

```aro
(GET /count: Counter API) {
    <Retrieve> the <counter> from the <counter-repository>.
    <Compute> the <new-count> from <counter: value> + 1.
    <Store> the <counter> with { value: <new-count> } into the <counter-repository>.
    <Return> an <OK: status> with <new-count>.
}
```

## Publishing Variables

### Cross-Feature-Set Access

Use `<Publish>` to make variables available across feature sets:

```aro
(* In config.aro *)
(Load Config: Initialization) {
    <Read> the <config: JSON> from the <file: "./config.json">.
    <Publish> as <app-config> <config>.
    <Return> an <OK: status> for the <loading>.
}

(* In any other file *)
(GET /settings: Settings API) {
    (* Access the published variable *)
    <Extract> the <port> from the <app-config: port>.
    <Return> an <OK: status> with <port>.
}
```

### Publishing Guidelines

- Publish configuration, not request-specific data
- Use descriptive aliases: `<app-config>`, `<database-pool>`
- Publish during initialization, not during request handling

```aro
(* Good - publish configuration once *)
(Application-Start: My App) {
    <Read> the <config> from the <file: "./config.json">.
    <Publish> as <app-config> <config>.
    <Return> an <OK: status> for the <startup>.
}

(* Avoid - don't publish request data *)
(POST /users: User API) {
    <Create> the <user> with <data>.
    (* Don't do this - user is request-specific *)
    <Publish> as <current-user> <user>.
}
```

## Data Flow Patterns

### Linear Flow

Data flows through statements sequentially:

```aro
(Process Order: Order Management) {
    (* Input *)
    <Extract> the <order-data> from the <request: body>.

    (* Validation *)
    <Validate> the <order-data> for the <order-schema>.

    (* Transformation *)
    <Transform> the <order> from the <order-data>.

    (* Enrichment *)
    <Compute> the <total> for the <order: items>.
    <Transform> the <enriched-order> from the <order> with { total: <total> }.

    (* Persistence *)
    <Store> the <enriched-order> into the <order-repository>.

    (* Output *)
    <Return> a <Created: status> with <enriched-order>.
}
```

### Branching Flow

Data can flow through different paths:

```aro
(GET /users/{id}: User API) {
    <Extract> the <user-id> from the <request: parameters>.
    <Retrieve> the <user> from the <repository> where id = <user-id>.

    if <user> is empty then {
        (* Error path *)
        <Return> a <NotFound: status> for the <missing: user>.
    }

    (* Success path *)
    <Transform> the <user-response> from the <user>.
    <Return> an <OK: status> with <user-response>.
}
```

### Event-Driven Flow

Data flows between feature sets via events:

```aro
(* Source - emits event with data *)
(POST /orders: Order API) {
    <Create> the <order> with <order-data>.
    <Store> the <order> into the <order-repository>.
    <Emit> an <OrderCreated: event> with <order>.
    <Return> a <Created: status> with <order>.
}

(* Target - receives data from event *)
(Send Confirmation: OrderCreated Handler) {
    <Extract> the <order> from the <event: order>.
    <Extract> the <email> from the <order: customerEmail>.
    <Send> the <confirmation> to the <email>.
    <Return> an <OK: status> for the <notification>.
}
```

## Type Hints

### Adding Type Information

Provide type hints for clarity:

```aro
<Read> the <config: JSON> from the <file: "./config.json">.
<Read> the <image: bytes> from the <file: "./logo.png">.
<Transform> the <users: List> from the <response: data>.
```

### Common Type Hints

| Type | Usage |
|------|-------|
| `JSON` | JSON data |
| `bytes` | Binary data |
| `List` | Array/collection |
| `String` | Text data |
| `Number` | Numeric data |
| `Boolean` | True/false |
| `Date` | Date/time |

## Special Variables

### Request Variables

Available in HTTP handlers:

```aro
<request: method>      (* HTTP method: GET, POST, etc. *)
<request: path>        (* Request path *)
<request: parameters>  (* Path parameters *)
<request: query>       (* Query string parameters *)
<request: headers>     (* HTTP headers *)
<request: body>        (* Request body *)
```

### Event Variables

Available in event handlers:

```aro
<event: type>          (* Event type name *)
<event: timestamp>     (* When event occurred *)
<event: ...>           (* Event-specific data *)
```

### Shutdown Variables

Available in Application-End:

```aro
<shutdown: reason>     (* Why shutting down *)
<shutdown: code>       (* Exit code *)
<shutdown: signal>     (* Signal name if applicable *)
<shutdown: error>      (* Error if error shutdown *)
```

## Immutability

### Variables are Immutable

Once bound, a variable's value doesn't change:

```aro
<Extract> the <user-id> from the <request>.
(* user-id is now "123" - it won't change *)

(* To "modify", create a new variable *)
<Transform> the <new-value> from the <user-id>.
```

### Creating Modified Copies

Use `<Transform>` with `with` to create modified copies:

```aro
<Retrieve> the <user> from the <repository> where id = <id>.
(* user is { name: "John", status: "pending" } *)

<Transform> the <active-user> from the <user> with { status: "active" }.
(* active-user is { name: "John", status: "active" } *)
(* user is still { name: "John", status: "pending" } *)
```

## Repositories

Repositories are special variables that persist across HTTP requests and event handlers within the same business activity. They provide in-memory storage for application state.

### Repository Naming

Repository names must end with `-repository`:

```aro
<message-repository>      (* Valid repository *)
<user-repository>         (* Valid repository *)
<order-repository>        (* Valid repository *)
<messages>                (* NOT a repository - regular variable *)
```

### Storing Data

Use `<Store>` to save data to a repository:

```aro
(POST /messages: Chat API) {
    <Extract> the <message> from the <request: body>.
    <Store> the <message> into the <message-repository>.
    <Return> a <Created: status> with <message>.
}
```

Data is appended to the repository as a list.

### Retrieving Data

Use `<Retrieve>` to fetch data from a repository:

```aro
(GET /messages: Chat API) {
    <Retrieve> the <messages> from the <message-repository>.
    <Return> an <OK: status> with <messages>.
}
```

Returns all items in the repository, or an empty list if empty.

### Business Activity Scoping

Repositories are scoped to their business activity:

```aro
(* Both share "Chat API" - same repository *)
(postMessage: Chat API) {
    <Store> the <msg> into the <message-repository>.
}

(getMessages: Chat API) {
    <Retrieve> the <msgs> from the <message-repository>.
}

(* Different activity - different repository! *)
(logError: Logging API) {
    (* This is a separate message-repository *)
    <Store> the <error> into the <message-repository>.
}
```

For more details, see [Repositories](repositories.html).

## Best Practices

### Descriptive Names

```aro
(* Good *)
<Extract> the <customer-email> from the <order: customerEmail>.
<Retrieve> the <pending-orders> from the <repository> where status = "pending".

(* Avoid *)
<Extract> the <e> from the <o: customerEmail>.
<Retrieve> the <x> from the <repository> where status = "pending".
```

### Single Purpose

Each variable should have one purpose:

```aro
(* Good - clear purpose *)
<Retrieve> the <user> from the <repository>.
<Transform> the <user-dto> from the <user>.
<Return> an <OK: status> with <user-dto>.

(* Avoid - reusing variable name *)
<Retrieve> the <data> from the <repository>.
<Transform> the <data> from the <data>.  (* Confusing *)
```

### Minimize Scope

Only create variables you need:

```aro
(* Good - minimal variables *)
(GET /users/{id}: User API) {
    <Extract> the <id> from the <request: parameters>.
    <Retrieve> the <user> from the <repository> where id = <id>.
    <Return> an <OK: status> with <user>.
}

(* Avoid - unnecessary intermediate variables *)
(GET /users/{id}: User API) {
    <Extract> the <params> from the <request: parameters>.
    <Extract> the <id> from the <params: id>.
    <Retrieve> the <result> from the <repository> where id = <id>.
    <Extract> the <user> from the <result>.
    <Return> an <OK: status> with <user>.
}
```

## Next Steps

- [Control Flow](controlflow.html) - Conditional logic
- [Events](events.html) - Event-driven data flow
- [Feature Sets](featuresets.html) - Organizing code
