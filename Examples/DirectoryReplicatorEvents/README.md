# DirectoryReplicatorEvents

Demonstrates **List Storage with Per-Item Observer Events**, a powerful ARO runtime feature that enables event-driven processing without iteration.

## The Feature

When you store a **List** to a repository, the Store action automatically emits **one repository observer event for each item** in the list, instead of a single event for the entire list.

**This completely eliminates the need for iteration** in your application code while maintaining per-item processing and concurrent execution.

## How It Works

### Traditional Approach (DirectoryReplicator)

```aro
(* Iterate and process each entry directly *)
for each <entry> in <entries> where <entry: isDirectory> is true {
    <Extract> the <path> from the <entry: path>.
    (* ...process the directory... *)
    <Make> the <created> to the <path: path>.
}
```

### Event-Driven Approach (DirectoryReplicatorEvents)

```aro
(* Store the entire list - NO iteration needed! *)
<Store> the <directory-list> into the <directory-repository>.

(* Runtime automatically waits for all observers to complete *)
<Return> an <OK: status> for the <replication>.

(* Observer automatically triggered for EACH directory *)
(Process Directory: directory-repository Observer) {
    <Extract> the <dir-path> from the <event: newValue>.
    (* Process individual directory here *)
}
```

## Runtime Behavior

When this code executes:

```aro
<List> the <all-entries: recursively> from the <directory: template-path>.
<Filter> the <directories: List> from the <all-entries> where <isDirectory> is true.
<Store> the <directories> into the <directory-repository>.
```

The runtime **automatically**:
1. Lists all entries from the template directory recursively
2. Filters to only directories (e.g., foo, foo/bar, baz)
3. Stores the filtered list
4. Emits one RepositoryChangedEvent per directory:
   - Event 1: `newValue = {path: ".../foo", name: "foo", isDirectory: true, ...}`
   - Event 2: `newValue = {path: ".../foo/bar", name: "bar", isDirectory: true, ...}`
   - Event 3: `newValue = {path: ".../baz", name: "baz", isDirectory: true, ...}`

All matching observers are triggered once per item and execute **concurrently**.

## Key Benefits

1. **No Iteration Required**: Store the list once - runtime handles the rest
2. **Concurrent Processing**: Each observer invocation runs in parallel
3. **Event-Driven Architecture**: Decouples data preparation from processing
4. **Declarative Style**: Focus on what to do with each item, not how to iterate
5. **Extensible**: Multiple observers can react to the same events

## Running the Example

```bash
aro run Examples/DirectoryReplicatorEvents
```

**Output:**
```
[Application-Start] Scanning template directory...
[Application-Start] Found 3 directories
[Application-Start] Storing directories to repository...
[Audit Directory Changes] [AUDIT] directory-repository: created
[Process Directory Entry] Created: foo
[Audit Directory Changes] [AUDIT] directory-repository: created
[Process Directory Entry] Created: foo/bar
[Audit Directory Changes] [AUDIT] directory-repository: created
[Process Directory Entry] Created: baz
[OK] replication
```

Notice that:
- **Filter** found 3 directories (foo, foo/bar, baz)
- **Three events emitted** - one per directory in the list
- **Both observers triggered** - `Process Directory Entry` and `Audit Directory Changes` fire for each item
- **Concurrent execution** - output is interleaved because observers run in parallel
- **Automatic event completion** - runtime waits for all observers to finish before exiting (no Keepalive needed)

## Comparison with DirectoryReplicator

| Aspect | DirectoryReplicator | DirectoryReplicatorEvents |
|--------|-------------------|---------------------------|
| **Iteration** | `for each` loop with processing | **NONE** - eliminated entirely |
| **Store calls** | One per item (in loop) | **One** call for entire List |
| **Observer events** | N/A | One per item (automatic) |
| **Processing pattern** | Sequential | **Concurrent** (observers in parallel) |
| **Separation of concerns** | Low (all in one place) | **High** (data prep vs processing) |
| **Extensibility** | Hard to add logic | **Easy** (add more observers) |

## Architecture Pattern

This example demonstrates the **Repository-Driven Event Pattern**:

```
List Data → Filter/Transform → Store List → Per-Item Events → Concurrent Observers
```

This pattern is ideal for:
- Batch processing
- Data pipelines
- Queue-based systems
- Event-driven microservices
- Concurrent task execution

## Implementation Notes

The feature is implemented in `StoreAction.execute()` at:
`Sources/ARORuntime/Actions/BuiltIn/ResponseActions.swift`

When `storedValue` is detected as an Array, the action:
1. Iterates through each item internally
2. Emits a `RepositoryChangedEvent` for each item
3. Observers receive individual items, not the entire list

**Backward Compatibility**: Single-value storage continues to emit one event as before.

## See Also

- **Proposal ARO-0007** (Events & Reactive) - Section 6.6: List Storage with Per-Item Events
- **Wiki**: Reference-Actions.md - Store action documentation
- **Example**: DirectoryReplicator - Traditional iteration approach for comparison
- **Example**: RepositoryObserver - Repository observer pattern basics
