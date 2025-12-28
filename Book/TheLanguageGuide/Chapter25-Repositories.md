# Chapter 25: Repositories

Repositories provide persistent in-memory storage that survives across HTTP requests and event handlers. Unlike regular variables which are scoped to a single feature set execution, repositories maintain state for the lifetime of the application.

## Overview

In ARO, each HTTP request creates a fresh execution context. Variables defined in one request aren't available in another:

```aro
(* This won't work - count resets on each request *)
(GET /count: Counter API) {
    <Create> the <count> with 0.
    <Compute> the <new-count> from <count> + 1.
    <Return> an <OK: status> with <new-count>.
}
```

Repositories solve this by providing shared storage:

```aro
(POST /increment: Counter API) {
    <Retrieve> the <counts> from the <counter-repository>.
    <Compute> the <current> from <counts: length>.
    <Store> the <current> into the <counter-repository>.
    <Return> an <OK: status> with <current>.
}

(GET /count: Counter API) {
    <Retrieve> the <counts> from the <counter-repository>.
    <Compute> the <total> from <counts: length>.
    <Return> an <OK: status> with { count: <total> }.
}
```

## Repository Naming Convention

Repository names **must** end with `-repository`. This is how ARO distinguishes repositories from regular variables:

```aro
(* These are repositories *)
<user-repository>
<message-repository>
<order-repository>
<session-repository>

(* These are NOT repositories - just regular variables *)
<users>
<messages>
<user-data>
```

The naming convention:
- Makes repositories visually distinct in code
- Enables automatic persistence by the runtime
- Follows ARO's self-documenting code philosophy

## Storing Data

Use the `<Store>` action to save data to a repository:

```aro
<Store> the <data> into the <name-repository>.
```

### Preposition Variants

All of these are equivalent:

```aro
<Store> the <user> into the <user-repository>.
<Store> the <user> in the <user-repository>.
<Store> the <user> to the <user-repository>.
```

### Storage Semantics

Repositories use **list-based storage**. Each store operation appends to the list:

```aro
(* First request *)
<Store> the <user1> into the <user-repository>.
(* Repository: [user1] *)

(* Second request *)
<Store> the <user2> into the <user-repository>.
(* Repository: [user1, user2] *)

(* Third request *)
<Store> the <user3> into the <user-repository>.
(* Repository: [user1, user2, user3] *)
```

### Example: Storing Messages

```aro
(postMessage: Chat API) {
    <Extract> the <data> from the <request: body>.
    <Extract> the <text> from the <data: message>.
    <Extract> the <author> from the <data: author>.

    <Create> the <message> with {
        text: <text>,
        author: <author>,
        timestamp: now
    }.

    <Store> the <message> into the <message-repository>.

    <Return> a <Created: status> with <message>.
}
```

## Retrieving Data

Use the `<Retrieve>` action to fetch data from a repository:

```aro
<Retrieve> the <items> from the <name-repository>.
```

### Return Value

- Returns a **list** of all stored items
- Returns an **empty list** `[]` if the repository is empty or doesn't exist
- Never throws an error for missing repositories

### Example: Retrieving All Messages

```aro
(getMessages: Chat API) {
    <Retrieve> the <messages> from the <message-repository>.
    <Return> an <OK: status> with { messages: <messages> }.
}
```

### Filtered Retrieval

Use `where` to filter results:

```aro
(getUserById: User API) {
    <Extract> the <id> from the <pathParameters: id>.
    <Retrieve> the <user> from the <user-repository> where id = <id>.
    <Return> an <OK: status> with <user>.
}
```

### Single Item Retrieval

Use specifiers to retrieve a single item from a repository:

```aro
(* Get the most recently stored item *)
<Retrieve> the <message> from the <message-repository: last>.

(* Get the first stored item *)
<Retrieve> the <message> from the <message-repository: first>.

(* Get by numeric index - 0 = most recent *)
<Retrieve> the <latest> from the <message-repository: 0>.
<Retrieve> the <second-latest> from the <message-repository: 1>.
```

Numeric indices count from most recently added (0 = newest, 1 = second newest, etc.).

This is useful when you only need one item, like the latest message in a chat:

```aro
(getLatestMessage: Chat API) {
    <Retrieve> the <message> from the <message-repository: last>.
    <Return> an <OK: status> with { message: <message> }.
}
```

If the repository is empty, an empty string is returned.

## Business Activity Scoping

Repositories are scoped to their **business activity**. Feature sets with the same business activity share repositories:

```aro
(* Same business activity: "Chat API" *)
(* These share the same <message-repository> *)

(postMessage: Chat API) {
    <Store> the <message> into the <message-repository>.
    <Return> a <Created: status>.
}

(getMessages: Chat API) {
    <Retrieve> the <messages> from the <message-repository>.
    <Return> an <OK: status> with <messages>.
}

(deleteMessage: Chat API) {
    (* Same repository as above *)
    <Retrieve> the <messages> from the <message-repository>.
    (* ... *)
}
```

### Different Business Activities = Different Repositories

```aro
(* Business activity: "Chat API" *)
(postMessage: Chat API) {
    <Store> the <msg> into the <message-repository>.
}

(* Business activity: "Admin API" - DIFFERENT repository! *)
(postAuditLog: Admin API) {
    (* This <message-repository> is separate from Chat API's *)
    <Store> the <log> into the <message-repository>.
}
```

This scoping:
- Prevents accidental data leakage between domains
- Allows reuse of generic repository names
- Enforces domain boundaries

## Complete Example: Simple Chat Application

### main.aro

```aro
(Application-Start: Simple Chat) {
    <Log> the <startup: message> for the <console> with "Starting Simple Chat...".
    <Start> the <http-server> for the <contract>.
    <Keepalive> the <application> for the <events>.
    <Return> an <OK: status> for the <startup>.
}
```

### api.aro

```aro
(* GET /status - Return the last message *)
(getStatus: Simple Chat API) {
    <Retrieve> the <message> from the <message-repository: last>.
    <Return> an <OK: status> with { message: <message> }.
}

(* POST /status - Store a new message *)
(postStatus: Simple Chat API) {
    <Extract> the <message> from the <body: message>.

    <Store> the <message> into the <message-repository>.

    <Return> a <Created: status> with { message: <message> }.
}
```

### Testing

```bash
# Post a message
curl -X POST http://localhost:8080/status \
  -H 'Content-Type: application/json' \
  -d '{"message":"Hello!"}'
# Response: {"message":"Hello!"}

# Post another message
curl -X POST http://localhost:8080/status \
  -H 'Content-Type: application/json' \
  -d '{"message":"World!"}'
# Response: {"message":"World!"}

# Get the last message
curl http://localhost:8080/status
# Response: {"message":"World!"}
```

## Deleting from Repositories

Use the `<Delete>` action with a `where` clause to remove items from a repository:

```aro
<Delete> the <user> from the <user-repository> where id = <userId>.
```

### Example: Deleting a User

```aro
(deleteUser: User API) {
    <Extract> the <userId> from the <pathParameters: id>.
    <Delete> the <user> from the <user-repository> where id = <userId>.
    <Return> an <OK: status> with { deleted: <userId> }.
}
```

The deleted item(s) are bound to the result variable (`user` in this example).

## Repository Observers

Repository observers are feature sets that automatically react to repository changes. They receive access to both old and new values, enabling audit logging, synchronization, and reactive patterns.

### Observer Syntax

Create an observer by naming your feature set's business activity as `{repository-name} Observer`:

```aro
(Audit Changes: user-repository Observer) {
    <Extract> the <changeType> from the <event: changeType>.
    <Extract> the <newValue> from the <event: newValue>.
    <Extract> the <oldValue> from the <event: oldValue>.

    <Log> the <audit: message> for the <console> with <changeType>.
    <Return> an <OK: status> for the <audit>.
}
```

### Event Payload

Observers receive an event with the following fields:

| Field | Type | Description |
|-------|------|-------------|
| `repositoryName` | String | The repository name (e.g., "user-repository") |
| `changeType` | String | "created", "updated", or "deleted" |
| `entityId` | String? | ID of the changed entity (if available) |
| `newValue` | Any? | The new value (nil for deletes) |
| `oldValue` | Any? | The previous value (nil for creates) |
| `timestamp` | Date | When the change occurred |

### Change Types

Observers are triggered for three types of changes:

- **created**: New item stored (no previous value existed with matching ID)
- **updated**: Existing item modified (matched by ID)
- **deleted**: Item removed using `<Delete>` action

### Example: Tracking User Changes

```aro
(Track User Changes: user-repository Observer) {
    <Extract> the <changeType> from the <event: changeType>.
    <Extract> the <entityId> from the <event: entityId>.

    <Compare> the <changeType> equals "updated".

    <Extract> the <oldName> from the <event: oldValue: name>.
    <Extract> the <newName> from the <event: newValue: name>.

    <Log> the <change: message> for the <console>
        with "User " + <entityId> + " renamed from " + <oldName> + " to " + <newName>.

    <Return> an <OK: status> for the <tracking>.
}
```

### Multiple Observers

You can have multiple observers for the same repository:

```aro
(* Audit logging observer *)
(Log All Changes: user-repository Observer) {
    <Extract> the <changeType> from the <event: changeType>.
    <Log> the <audit: message> for the <console> with <changeType>.
    <Return> an <OK: status>.
}

(* Email notification observer *)
(Notify Admin: user-repository Observer) {
    <Extract> the <changeType> from the <event: changeType>.
    <Compare> the <changeType> equals "deleted".
    <Send> the <notification> to the <admin-email>.
    <Return> an <OK: status>.
}
```

## Lifetime and Persistence

### Application Lifetime

Repositories persist for the **lifetime of the application**:

- Created when first accessed
- Survive across all HTTP requests
- Cleared when application restarts

### No Disk Persistence

Repositories are **in-memory only**:

- Data is lost when the application stops
- No external database required
- Fast and simple for prototyping

For persistent storage, use a database integration (future ARO feature).

## Best Practices

### Use Descriptive Repository Names

```aro
(* Good - clear what's stored *)
<user-repository>
<pending-order-repository>
<session-token-repository>

(* Avoid - too generic *)
<data-repository>
<stuff-repository>
```

### One Repository Per Domain Concept

```aro
(* Good - separate repositories for different concepts *)
<user-repository>
<order-repository>
<product-repository>

(* Avoid - mixing concepts *)
<everything-repository>
```

### Keep Repository Data Simple

Store simple, serializable data:

```aro
(* Good - simple object *)
<Create> the <user> with {
    id: <id>,
    name: <name>,
    email: <email>
}.
<Store> the <user> into the <user-repository>.

(* Avoid - complex nested structures *)
<Store> the <entire-request-context> into the <debug-repository>.
```
