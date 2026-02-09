# Chapter 30: Repositories

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

### Automatic Deduplication

When `<Store>` is called, the runtime automatically deduplicates plain values (strings, numbers, booleans). If the value already exists in the repository, it is not stored again and **no observer event fires**. This means repository observers naturally handle deduplication — they only trigger for genuinely new entries.

**Preferred pattern — use observers:**

```aro
(Queue URL: QueueUrl Handler) {
    (* Just store — observer handles the rest *)
    <Store> the <url> into the <crawled-repository>.
    <Return> an <OK: status>.
}

(Process New URLs: crawled-repository Observer) {
    (* Only fires for new entries, not duplicates *)
    <Extract> the <url> from the <event: newValue>.
    <Log> "Processing: ${<url>}" to the <console>.
    <Emit> a <ProcessUrl: event> with { url: <url> }.
    <Return> an <OK: status>.
}
```

This follows ARO's philosophy: **Store OR Emit, not both**. Handlers that store data shouldn't also emit events for the same logical action — that's what observers are for.

### The `new-entry` Variable (Legacy)

For backward compatibility, `<Store>` also binds a `new-entry` variable:

- `new-entry = 1` — The value was newly stored
- `new-entry = 0` — The value already existed (duplicate)

This can be used with `when` guards, but **observers are preferred**:

```aro
(* Works, but consider using an observer instead *)
<Store> the <url> into the <crawled-repository>.
<Log> "New: ${<url>}" to the <console> when <new-entry> > 0.
```

Because repository operations are serialized by the runtime's Actor model, both patterns are **race-condition-free** even under `parallel for each`.

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
    <Log> "Starting Simple Chat..." to the <console>.
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

    <Log> <changeType> to the <console>.
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

    <Compute> the <message> from "User " + <entityId> + " renamed from " + <oldName> + " to " + <newName>.
    <Log> <message> to the <console>.

    <Return> an <OK: status> for the <tracking>.
}
```

### Multiple Observers

You can have multiple observers for the same repository:

```aro
(* Audit logging observer *)
(Log All Changes: user-repository Observer) {
    <Extract> the <changeType> from the <event: changeType>.
    <Log> <changeType> to the <console>.
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

### Conditional Observers with `when` Guard

Add a `when` clause to trigger observers only when a condition is met. This is useful for implementing cleanup logic, rate limiting, or threshold-based actions.

```aro
(* Only triggers when message count exceeds 100 *)
(Cleanup Messages: message-repository Observer) when <message-repository: count> > 100 {
    <Retrieve> the <all-messages> from the <message-repository>.
    <Extract> the <keep-messages: 0-49> from the <all-messages>.
    <Clear> the <all> from the <message-repository>.
    <Store> the <keep-messages> into the <message-repository>.
    <Log> "Cleaned up messages, kept last 50" to the <console>.
    <Return> an <OK: status> for the <cleanup>.
}
```

The `when` guard is evaluated before the observer executes. If the condition is false, the observer is silently skipped. This prevents infinite loops when the observer modifies the same repository it observes.

**Repository Count Expression**: Use `<repository-name: count>` to get the current number of items in a repository:

```aro
(* Trigger alert when queue grows too large *)
(Queue Alert: task-repository Observer) when <task-repository: count> > 1000 {
    <Log> "Warning: Task queue exceeds 1000 items" to the <console>.
    <Emit> a <QueueOverflow: event>.
    <Return> an <OK: status>.
}
```

## Case Study: Directory Replicator

Let's examine two implementations of the same application: a directory replicator that scans a source directory and recreates its structure in a target location. This comparison illustrates the power of repository observers and event-driven architecture in ARO.

### Imperative Approach: DirectoryReplicator

The straightforward implementation uses sequential processing:

```aro
(Application-Start: Directory Replicator) {
    <Create> the <template-path> with "../template".
    <Log> "Scanning template directory..." to the <console>.

    <List> the <all-entries: recursively> from the <directory: template-path>.
    <Filter> the <directories: List> from the <all-entries> where <isDirectory> is true.

    <Compute> the <count: length> from the <directories>.
    <Log> "Found ${count} directories" to the <console>.

    <Log> "Creating directory structure..." to the <console>.

    (* Process each directory sequentially *)
    <Create> the <index> with 0.
    (For Each: <entry> in <directories>) {
        <Extract> the <fullpath> from the <entry: path>.

        (* Remove template/ prefix *)
        <Split> the <pathparts> from the <fullpath> by /template\//.
        <Extract> the <relpath: last> from the <pathparts>.

        (* Create the directory *)
        <Make> the <dir> to the <path: relpath>.
        <Log> "Created: ${relpath}" to the <console>.

        <Compute> the <index> from <index> + 1.
    }

    <Log> "Replication complete!" to the <console>.
    <Return> an <OK: status> for the <replication>.
}
```

**How it works**:
1. List all directories recursively
2. Filter to get only directories
3. Loop through each directory
4. Create each directory in sequence
5. Log progress

**Characteristics**:
- ✅ Simple and straightforward
- ✅ Easy to understand control flow
- ❌ Sequential execution (slow for large directory trees)
- ❌ All logic in one place (harder to extend)
- ❌ No separation of concerns
- ❌ Cannot handle concurrent operations

### Event-Driven Approach: DirectoryReplicatorEvents

The reactive implementation uses repository observers:

**main.aro**:
```aro
(Application-Start: Directory Replicator Events) {
    <Create> the <template-path> with "../template".
    <Log> "Scanning template directory..." to the <console>.

    <List> the <all-entries: recursively> from the <directory: template-path>.
    <Filter> the <directories: List> from the <all-entries> where <isDirectory> is true.

    <Compute> the <count: length> from the <directories>.
    <Log> "Found ${count} directories" to the <console>.

    <Log> "Storing directories to repository..." to the <console>.

    (* Store directories - triggers observers for each item *)
    <Store> the <directories> into the <directory-repository>.

    <Return> an <OK: status> for the <replication>.
}
```

**observers.aro**:
```aro
(* Main observer: Creates each directory when stored *)
(Process Directory Entry: directory-repository Observer) {
    (* Extract the directory entry from the event *)
    <Extract> the <entry> from the <event: newValue>.
    <Extract> the <fullpath> from the <entry: path>.

    (* Split to remove template/ prefix from absolute path *)
    <Split> the <pathparts> from the <fullpath> by /template\//.

    (* Get the last element (relative path) *)
    <Extract> the <relpath: last> from the <pathparts>.

    (* Create the directory in current location *)
    <Make> the <dir> to the <path: relpath>.

    (* Log the created directory *)
    <Log> "Created: ${relpath}" to the <console>.

    <Return> an <OK: status> for the <processing>.
}

(* Audit observer: Tracks all repository changes *)
(Audit Directory Changes: directory-repository Observer) {
    <Extract> the <changeType> from the <event: changeType>.
    <Extract> the <repositoryName> from the <event: repositoryName>.

    <Log> "[AUDIT] ${repositoryName}: ${changeType}" to the <console>.

    <Return> an <OK: status> for the <audit>.
}
```

**How it works**:
1. List all directories recursively
2. Filter to get only directories
3. **Store array to repository** (triggers per-item events)
4. **Observers execute concurrently** for each directory
5. Each observer processes one directory entry

**Characteristics**:
- ✅ **Concurrent execution** (all directories created simultaneously)
- ✅ **Separation of concerns** (scanning vs. processing vs. auditing)
- ✅ **Easily extensible** (add more observers without changing main code)
- ✅ **Reactive architecture** (responds to data changes)
- ✅ **Composable** (multiple observers can react to same events)
- ❌ Slightly more files (but better organized)

### Why the Events Version is Better

#### 1. **Performance: Concurrent Execution**

**Imperative** (sequential):
```
Directory 1: [====] 100ms
Directory 2:          [====] 100ms
Directory 3:                   [====] 100ms
Total: 300ms
```

**Events** (concurrent):
```
Directory 1: [====] 100ms
Directory 2: [====] 100ms
Directory 3: [====] 100ms
Total: 100ms (3x faster!)
```

For 100 directories, the events version can be **100x faster** on multi-core systems.

#### 2. **Separation of Concerns**

**Imperative**: All logic mixed together
```aro
(Application-Start) {
    (* Scanning logic *)
    (* Processing logic *)
    (* Logging logic *)
    (* Error handling *)
    (* Progress tracking *)
    (* All in one place! *)
}
```

**Events**: Clear separation
```aro
(* main.aro: Scanning and storage *)
(Application-Start) {
    (* Just scan and store *)
}

(* observers.aro: Processing *)
(Process Directory Entry: Observer) {
    (* Just create directories *)
}

(* observers.aro: Auditing *)
(Audit Changes: Observer) {
    (* Just log changes *)
}
```

Each feature set has **one clear responsibility**.

#### 3. **Extensibility Without Modification**

To add new functionality:

**Imperative**: Must modify main code
```aro
(Application-Start) {
    (* Existing code... *)

    (* NEW: Calculate total size? Must add here! *)
    <Compute> the <total-size>...

    (* NEW: Send notification? Must add here! *)
    <Send> the <notification>...

    (* NEW: Validate permissions? Must add here! *)
    <Validate> the <permissions>...
}
```

**Events**: Just add new observers
```aro
(* NEW: Calculate total size *)
(Track Size: directory-repository Observer) {
    <Extract> the <entry> from the <event: newValue>.
    (* Calculate and track size *)
}

(* NEW: Send notification *)
(Notify Completion: directory-repository Observer) {
    (* Send notification when done *)
}

(* NEW: Validate permissions *)
(Check Permissions: directory-repository Observer) {
    <Extract> the <entry> from the <event: newValue>.
    (* Validate permissions *)
}
```

**No changes to existing code!** This follows the Open/Closed Principle.

#### 4. **Composability and Reusability**

**Events version** allows mix-and-match:

```aro
(* Reusable observers *)
(Process Directory Entry: directory-repository Observer) { ... }
(Audit Changes: directory-repository Observer) { ... }
(Calculate Statistics: directory-repository Observer) { ... }
(Send Notifications: directory-repository Observer) { ... }

(* Use all of them *)
(* Or just some *)
(* Or add new ones *)
(* Without changing anything else! *)
```

Each observer is **independent and reusable**.

#### 5. **Real-World Scalability**

Consider processing 10,000 directories:

**Imperative**:
- Sequential: ~16 minutes (100ms each)
- Single-threaded
- One failure stops everything
- Hard to parallelize

**Events**:
- Concurrent: ~10 seconds (with 100 cores)
- Naturally parallelized
- One failure doesn't affect others
- Scales with available CPU cores

#### 6. **Testing and Debugging**

**Imperative**: Must test entire flow
```bash
# Test everything at once
aro run DirectoryReplicator
```

**Events**: Can test components independently
```bash
# Test just the scanning
aro run main.aro

# Test just the observers
# (trigger events manually in test)

# Test individual observers in isolation
```

### Per-Item Event Semantics

A critical feature: when you store an **array** to a repository, ARO emits **per-item events**:

```aro
<Store> the <directories> into the <directory-repository>.
(* If directories = [dir1, dir2, dir3] *)
(* Emits 3 separate events: *)
(*   - event { newValue: dir1, changeType: "created" } *)
(*   - event { newValue: dir2, changeType: "created" } *)
(*   - event { newValue: dir3, changeType: "created" } *)
```

This enables:
- **Concurrent processing** of array items
- **Independent failure handling** per item
- **Progress tracking** for long operations
- **Reactive data pipelines**

### When to Use Each Approach

**Use Imperative** when:
- ❌ Simple, one-off scripts
- ❌ Learning ARO basics
- ❌ Very small datasets (< 10 items)
- ❌ No need for extensibility

**Use Events** when:
- ✅ Processing large datasets
- ✅ Need concurrent execution
- ✅ Want extensibility
- ✅ Building production systems
- ✅ Multiple independent operations
- ✅ Separation of concerns matters

### Best Practice Recommendation

**Prefer the Events version** for any non-trivial application. The benefits of concurrency, extensibility, and separation of concerns far outweigh the slight increase in code organization.

The imperative style is fine for learning and quick scripts, but the event-driven architecture is the **ARO way** for building robust, scalable applications.

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

---

*Next: Chapter 30 — System Commands*
