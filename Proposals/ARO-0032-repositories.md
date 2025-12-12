# ARO-0032: Repositories

* Proposal: ARO-0032
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0003

## Abstract

This proposal defines repositories in ARO - persistent storage that survives across feature set executions within the same business activity. Repositories provide a mechanism for sharing state between HTTP requests and event handlers without requiring external databases.

## Motivation

ARO applications often need to store and retrieve data across multiple HTTP requests or event handlers. Currently:

1. **Variables are ephemeral**: Each HTTP request creates a new execution context with fresh variables
2. **Published variables don't persist**: Published variables only exist within an event chain, not across independent requests
3. **No simple persistence**: Without repositories, applications must use external databases even for simple state

Consider a chat application:

```aro
(* POST /status - Store a message *)
(postStatus: Simple Chat API) {
    <Extract> the <message> from the <request: body>.
    <Store> the <message> into the <message-repository>.
    <Return> a <Created: status> with <message>.
}

(* GET /status - Retrieve the message *)
(getStatus: Simple Chat API) {
    <Retrieve> the <messages> from the <message-repository>.
    <Return> an <OK: status> with <messages>.
}
```

Without repositories, the `message-repository` doesn't persist between requests, so `getStatus` always returns empty.

## Proposed Solution

### 1. Repository Definition

A **repository** is a named storage container that:

- Persists for the lifetime of the application
- Is scoped to a **business activity** by default
- Can be exported to **application scope** using `<Export>`
- Is identified by names ending with `-repository`

### 2. Repository Naming Convention

Repository names MUST end with `-repository`:

```aro
<message-repository>      (* Valid repository *)
<user-repository>         (* Valid repository *)
<order-repository>        (* Valid repository *)
<messages>                (* NOT a repository - regular variable *)
```

This naming convention:
- Makes repositories visually distinct in code
- Enables the runtime to identify storage targets
- Follows ARO's "code is documentation" philosophy

### 3. Business Activity Scoping

By default, repositories are scoped to their business activity:

```aro
(* Both feature sets share "Chat API" business activity *)
(* They can access the same repositories *)

(postMessage: Chat API) {
    <Store> the <message> into the <message-repository>.
    <Return> a <Created: status>.
}

(getMessages: Chat API) {
    <Retrieve> the <messages> from the <message-repository>.
    <Return> an <OK: status> with <messages>.
}

(* Different business activity - separate repository *)
(storeOrder: Order API) {
    (* This is a DIFFERENT message-repository *)
    <Store> the <order> into the <message-repository>.
}
```

### 4. Repository Operations

#### 4.1 Store Operation

The `<Store>` action persists data to a repository:

```aro
<Store> the <data> into the <name-repository>.
```

**Behavior:**
- If the repository doesn't exist, it's created
- Data is appended to the repository (list semantics)
- Returns a `StoreResult` indicating success

**Syntax Variations:**
```aro
<Store> the <user> into the <user-repository>.
<Store> the <message> in the <message-repository>.
<Store> the <order> to the <order-repository>.
```

#### 4.2 Retrieve Operation

The `<Retrieve>` action fetches data from a repository:

```aro
<Retrieve> the <items> from the <name-repository>.
```

**Behavior:**
- Returns all items stored in the repository
- Returns an empty list if the repository is empty or doesn't exist
- Never throws an error for missing repositories

**Filtering:**
```aro
<Retrieve> the <user> from the <user-repository> where id = <user-id>.
```

#### 4.3 Clear Operation (Future)

```aro
<Clear> the <message-repository>.
```

### 5. Exporting Repositories to Application Scope

Use `<Export>` to make a repository accessible across all business activities:

```aro
(Application-Start: My App) {
    (* Export repository to application scope *)
    <Export> the <shared-repository> as <global-repository>.

    <Return> an <OK: status> for the <startup>.
}

(* Now any business activity can access it *)
(processOrder: Order API) {
    <Retrieve> the <config> from the <global-repository>.
    (* ... *)
}
```

### 6. Repository Scope Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                    Application Scope                             │
│  (Exported repositories available to all business activities)    │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │              Business Activity: "Chat API"                   │ │
│  │                                                              │ │
│  │   <message-repository>  <user-repository>                    │ │
│  │                                                              │ │
│  │   Accessible by: postMessage, getMessages, deleteMessage     │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │              Business Activity: "Order API"                  │ │
│  │                                                              │ │
│  │   <order-repository>  <inventory-repository>                 │ │
│  │                                                              │ │
│  │   Accessible by: createOrder, getOrders, updateOrder         │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                                                                   │
└─────────────────────────────────────────────────────────────────┘
```

### 7. Repository Storage Semantics

#### 7.1 List-Based Storage

Repositories store items as ordered lists:

```aro
(* First store *)
<Store> the <user1> into the <user-repository>.
(* Repository: [user1] *)

(* Second store *)
<Store> the <user2> into the <user-repository>.
(* Repository: [user1, user2] *)

(* Retrieve returns all *)
<Retrieve> the <users> from the <user-repository>.
(* users = [user1, user2] *)
```

#### 7.2 Single-Value Retrieval

Use specifiers or filtering for single items:

```aro
(* Last stored value *)
<Retrieve> the <latest> from the <user-repository: last>.

(* First stored value *)
<Retrieve> the <oldest> from the <user-repository: first>.

(* By numeric index (0-based) *)
<Retrieve> the <second> from the <user-repository: 1>.

(* By predicate *)
<Retrieve> the <user> from the <user-repository> where id = "123".
```

Returns an empty string if the repository is empty or index is out of bounds.

### 8. Complete Example

```aro
(* main.aro *)
(Application-Start: Simple Chat) {
    <Log> the <startup: message> for the <console> with "Starting...".
    <Start> the <http-server> for the <contract>.
    <Keepalive> the <application> for the <events>.
    <Return> an <OK: status> for the <startup>.
}

(* api.aro *)

(* POST /messages - Store a new message *)
(postMessage: Chat API) {
    <Extract> the <data> from the <request: body>.
    <Extract> the <text> from the <data: message>.
    <Extract> the <author> from the <data: author>.

    <Create> the <message> with {
        id: <generated-id>,
        text: <text>,
        author: <author>,
        timestamp: now
    }.

    <Store> the <message> into the <message-repository>.

    <Return> a <Created: status> with <message>.
}

(* GET /messages - Retrieve all messages *)
(getMessages: Chat API) {
    <Retrieve> the <messages> from the <message-repository>.
    <Return> an <OK: status> with { messages: <messages> }.
}

(* GET /messages/{id} - Retrieve single message *)
(getMessage: Chat API) {
    <Extract> the <id> from the <pathParameters: id>.
    <Retrieve> the <message> from the <message-repository> where id = <id>.
    <Return> an <OK: status> with <message>.
}
```

## Implementation

### Runtime Architecture

```swift
/// Service for managing repository storage
public protocol RepositoryStorageService: Sendable {
    /// Store a value in a repository
    func store(value: any Sendable, in repository: String, businessActivity: String) async

    /// Retrieve all values from a repository
    func retrieve(from repository: String, businessActivity: String) async -> [any Sendable]

    /// Retrieve values matching a predicate
    func retrieve(from repository: String, businessActivity: String,
                  where predicate: String, equals value: any Sendable) async -> [any Sendable]

    /// Export a repository to application scope
    func export(repository: String, from businessActivity: String, as name: String) async

    /// Check if a repository exists
    func exists(repository: String, businessActivity: String) async -> Bool
}
```

### StoreAction Changes

```swift
public func execute(...) async throws -> any Sendable {
    let repoName = object.base

    // Check if this is a repository (ends with -repository)
    if repoName.hasSuffix("-repository") {
        // Store in repository storage
        if let storage = context.service(RepositoryStorageService.self) {
            await storage.store(
                value: data,
                in: repoName,
                businessActivity: context.businessActivity
            )
        }
    }

    return StoreResult(repository: repoName, success: true)
}
```

### RetrieveAction Changes

```swift
public func execute(...) async throws -> any Sendable {
    let repoName = object.base

    // Check if this is a repository
    if repoName.hasSuffix("-repository") {
        if let storage = context.service(RepositoryStorageService.self) {
            let values = await storage.retrieve(
                from: repoName,
                businessActivity: context.businessActivity
            )
            return values
        }
        return [] // Empty list if no storage service
    }

    // Fall back to variable resolution
    if let source = context.resolveAny(repoName) {
        return source
    }

    throw ActionError.undefinedVariable(repoName)
}
```

## Compatibility

This proposal is **backwards compatible**:

- Existing code continues to work unchanged
- Repository semantics only apply to names ending with `-repository`
- Non-repository Store/Retrieve behavior is preserved

## Security Considerations

- Repositories are in-memory and not persisted across application restarts
- Business activity scoping prevents accidental data leakage between domains
- No external network access required

## Future Directions

1. **Persistent Repositories**: Optional persistence to disk/database
2. **Repository Schemas**: Type validation for stored data
3. **Repository Events**: Emit events on store/retrieve operations
4. **Repository Limits**: Maximum size and TTL for cached data

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2025-12 | Initial specification |
