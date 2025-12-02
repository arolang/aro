# ARO-0028: Long-Running Applications

* Proposal: ARO-0028
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0020, ARO-0021, ARO-0023, ARO-0024

## Abstract

This proposal introduces the `<Wait>` action for long-running ARO applications. Applications that need to stay alive to process events (HTTP servers, file watchers, socket servers) use `<Wait>` to signal they should not exit after `Application-Start` completes.

## Motivation

ARO applications that start services need to remain running to handle incoming events:

```aro
(Application-Start: File Watcher) {
    <Watch> the <file-monitor> for the <directory> with ".".
    <Return> an <OK: status> for the <startup>.
}
```

Currently, this application starts the file watcher and immediately exits because `Application-Start` completes. Users must use the `--keep-alive` CLI flag, but this is:

1. **Not Declarative**: The application's behavior depends on external flags
2. **Error-Prone**: Users forget to use `--keep-alive`
3. **Not Self-Documenting**: Reading the code doesn't reveal the application is long-running

## Proposed Solution

### The `<Wait>` Action

Introduce a `<Wait>` action that explicitly signals the application should remain running:

```aro
(Application-Start: File Watcher) {
    <Log> the <startup: message> for the <console> with "Starting file watcher".
    <Watch> the <file-monitor> for the <directory> with ".".
    <Log> the <ready: message> for the <console> with "Watching for file changes...".

    (* Keep the application running to process file events *)
    <Wait> for <events>.

    <Return> an <OK: status> for the <startup>.
}
```

### Semantics

The `<Wait>` action:

1. **Blocks Execution**: Pauses the current feature set execution
2. **Enables Event Processing**: Allows the event bus to dispatch events to handlers
3. **Respects Signals**: Terminates on SIGINT/SIGTERM, triggering `Application-End`
4. **Is Cancellable**: Can be programmatically cancelled via events

### Syntax Variants

```aro
(* Wait indefinitely for events *)
<Wait> for <events>.

(* Wait with a timeout (future extension) *)
<Wait> for <events> with 30000.  (* 30 seconds *)

(* Wait for a specific condition (future extension) *)
<Wait> for <shutdown-signal>.
```

### Interaction with Services

When services are started (`<Start>`, `<Watch>`, `<Listen>`), they register with the runtime's service tracker. The `<Wait>` action monitors these services:

| Service | Registration | Auto-Wait Behavior |
|---------|--------------|-------------------|
| HTTP Server | `<Start> the <http-server>` | Keeps alive until stopped |
| File Monitor | `<Watch> the <file-monitor>` | Keeps alive until stopped |
| Socket Server | `<Listen> on <socket>` | Keeps alive until stopped |

### Complete Example

```aro
(* File Watcher Application *)

(Application-Start: File Watcher) {
    <Log> the <startup: message> for the <console> with "Starting file watcher".
    <Watch> the <file-monitor> for the <directory> with ".".
    <Log> the <ready: message> for the <console> with "Watching for changes...".

    (* Block here until shutdown *)
    <Wait> for <events>.

    <Return> an <OK: status> for the <startup>.
}

(* Triggered when files are created *)
(Handle File Created: File Event Handler) {
    <Extract> the <path> from the <event: path>.
    <Log> the <created: notification> for the <console>.
    <Return> an <OK: status> for the <event>.
}

(* Triggered when files are modified *)
(Handle File Modified: File Event Handler) {
    <Extract> the <path> from the <event: path>.
    <Log> the <modified: notification> for the <console>.
    <Return> an <OK: status> for the <event>.
}

(* Graceful shutdown *)
(Application-End: Success) {
    <Log> the <shutdown: message> for the <console> with "Shutting down...".
    <Stop> the <file-monitor>.
    <Return> an <OK: status> for the <shutdown>.
}
```

### HTTP Server Example

```aro
(Application-Start: API Server) {
    <Log> the <startup: message> for the <console> with "Starting API server".
    <Start> the <http-server> on <port> with 8080.
    <Log> the <ready: message> for the <console> with "Server ready on port 8080".

    (* Keep server running *)
    <Wait> for <events>.

    <Return> an <OK: status> for the <startup>.
}
```

## Implementation

### Action Definition

```swift
public struct WaitAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["wait", "await", "block"]
    public static let validPrepositions: Set<Preposition> = [.for]

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        // Signal runtime to enter event loop
        context.enterWaitState()

        // Block until shutdown signal or cancellation
        try await context.waitForShutdown()

        return "completed"
    }
}
```

### Runtime Changes

The `RuntimeContext` gains:

```swift
protocol ExecutionContext {
    // ... existing methods ...

    /// Enter wait state - enables event processing
    func enterWaitState()

    /// Wait for shutdown signal
    func waitForShutdown() async throws

    /// Check if in wait state
    var isWaiting: Bool { get }
}
```

## Backward Compatibility

- Existing applications without `<Wait>` continue to work as before
- The `--keep-alive` CLI flag is deprecated but still functional
- Applications using `--keep-alive` should migrate to explicit `<Wait>`

## Alternatives Considered

### 1. Implicit Wait

Services could automatically keep the application alive. Rejected because:
- Less explicit and harder to reason about
- Doesn't work for applications that start services then exit

### 2. Return Value Based

Using `<Return> a <running: status>` to signal keep-alive. Rejected because:
- Overloads the meaning of Return
- Less clear intent

### 3. Feature Set Annotation

Using `@keepalive` annotation. Rejected because:
- Adds complexity to the language
- Less flexible than an action

## Future Directions

1. **Timeout Support**: `<Wait> for <events> with 30000.`
2. **Conditional Wait**: `<Wait> for <specific-event>.`
3. **Wait Groups**: Waiting for multiple conditions
