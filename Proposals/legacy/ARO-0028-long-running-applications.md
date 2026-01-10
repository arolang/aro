# ARO-0028: Long-Running Applications

* Proposal: ARO-0028
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0020, ARO-0021, ARO-0023, ARO-0024

## Abstract

This proposal introduces the `<Wait>` action for long-running ARO applications. Applications that need to stay alive to process events (HTTP servers, file watchers, socket servers) use `<Wait>` to block execution until a specific event occurs.

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

Introduce a `<Wait>` action that blocks until a specific event occurs:

```aro
(Application-Start: File Watcher) {
    <Log> "Starting file watcher" to the <console>.
    <Watch> the <file-monitor> for the <directory> with ".".
    <Log> "Watching for file changes..." to the <console>.

    (* Block until Ctrl+C or SIGTERM *)
    <Wait> for <shutdown-signal>.

    <Return> an <OK: status> for the <startup>.
}
```

### Syntax

The `<Wait>` action takes a specific event name:

| Syntax | Behavior |
|--------|----------|
| `<Wait> for <shutdown-signal>.` | Waits for SIGINT (Ctrl+C) or SIGTERM |
| `<Wait> for <EventName>.` | Waits for a specific event to be emitted |

### Semantics

#### Shutdown Signal

`<Wait> for <shutdown-signal>.` is the standard way to keep an application running:

1. **Blocks Execution**: Pauses the current feature set until signal received
2. **Enables Event Processing**: Allows the event bus to dispatch events to handlers
3. **Respects OS Signals**: Unblocks on SIGINT (Ctrl+C) or SIGTERM
4. **Triggers Cleanup**: After unblocking, executes `Application-End: Success`

```aro
(Application-Start: API Server) {
    <Start> the <http-server> on <port> with 8080.
    <Log> "Server ready" to the <console>.

    (* Wait for Ctrl+C *)
    <Wait> for <shutdown-signal>.

    <Return> an <OK: status> for the <startup>.
}

(Application-End: Success) {
    <Log> "Shutting down..." to the <console>.
    <Stop> the <http-server>.
    <Return> an <OK: status> for the <shutdown>.
}
```

#### Specific Events

`<Wait> for <EventName>.` waits for a specific event:

1. **Blocks Until Event**: Pauses until the named event is emitted
2. **Executes Handler**: When event triggers, the matching handler executes
3. **Waits for Completion**: Blocks until handler completes
4. **Resumes/Ends**: After handler completes, execution resumes (program may end)

```aro
(Application-Start: One-Shot Processor) {
    <Start> the <file-monitor> for the <directory> with "/incoming".
    <Log> "Waiting for file..." to the <console>.

    (* Wait for a file to be created, then exit *)
    <Wait> for <FileCreatedEvent>.

    <Log> "File processed, exiting" to the <console>.
    <Return> an <OK: status> for the <startup>.
}

(Handle File Created: File Event Handler) {
    <Extract> the <path> from the <event: path>.
    <Log> <path> to the <console>.
    (* Process the file... *)
    <Return> an <OK: status> for the <event>.
}
```

---

## Complete Examples

### HTTP Server (Long-Running)

```aro
(Application-Start: API Server) {
    <Log> "Starting API server" to the <console>.
    <Start> the <http-server> on <port> with 8080.
    <Log> "Server ready on port 8080" to the <console>.

    (* Keep server running until Ctrl+C *)
    <Wait> for <shutdown-signal>.

    <Return> an <OK: status> for the <startup>.
}

(Application-End: Success) {
    <Log> "Shutting down..." to the <console>.
    <Stop> the <http-server>.
    <Return> an <OK: status> for the <shutdown>.
}
```

### File Watcher (Long-Running)

```aro
(Application-Start: File Watcher) {
    <Log> "Starting file watcher" to the <console>.
    <Watch> the <file-monitor> for the <directory> with ".".
    <Log> "Watching for changes..." to the <console>.

    (* Block until shutdown *)
    <Wait> for <shutdown-signal>.

    <Return> an <OK: status> for the <startup>.
}

(Handle File Created: File Event Handler) {
    <Extract> the <path> from the <event: path>.
    <Log> <path> to the <console>.
    <Return> an <OK: status> for the <event>.
}

(Handle File Modified: File Event Handler) {
    <Extract> the <path> from the <event: path>.
    <Log> <path> to the <console>.
    <Return> an <OK: status> for the <event>.
}

(Application-End: Success) {
    <Log> "Shutting down..." to the <console>.
    <Stop> the <file-monitor>.
    <Return> an <OK: status> for the <shutdown>.
}
```

### Socket Server (Long-Running)

```aro
(Application-Start: Echo Socket) {
    <Log> "Starting echo socket on port 9000" to the <console>.
    <Start> the <socket-server> on <port> with 9000.
    <Log> "Socket server listening" to the <console>.

    <Wait> for <shutdown-signal>.

    <Return> an <OK: status> for the <startup>.
}

(Handle Data Received: Socket Event Handler) {
    <Extract> the <data> from the <packet: buffer>.
    <Extract> the <client> from the <packet: connection>.
    <Send> the <data> to the <client>.
    <Return> an <OK: status> for the <packet>.
}
```

---

## Implementation

### Action Definition

```swift
public struct WaitAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["wait"]
    public static let validPrepositions: Set<Preposition> = [.for]

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        let eventName = object.base.lowercased()

        if eventName == "shutdown-signal" {
            // Wait for SIGINT/SIGTERM
            SignalHandler.shared.setup()
            context.enterWaitState()
            await ShutdownCoordinator.shared.waitForShutdown()
            return WaitResult(completed: true, event: "shutdown-signal")
        } else {
            // Wait for specific event
            await context.waitForEvent(named: eventName)
            return WaitResult(completed: true, event: eventName)
        }
    }
}
```

### Runtime Changes

The `ExecutionContext` protocol includes:

```swift
protocol ExecutionContext {
    /// Enter wait state - enables event processing
    func enterWaitState()

    /// Wait for shutdown signal
    func waitForShutdown() async throws

    /// Wait for a specific event
    func waitForEvent(named: String) async

    /// Check if in wait state
    var isWaiting: Bool { get }
}
```

---

## Backward Compatibility

- The `<Keepalive>` verb is a synonym for `<Wait>` for backward compatibility
- Existing applications using `<Keepalive> the <application> for the <events>.` continue to work
- New applications should prefer the explicit `<Wait> for <shutdown-signal>.` syntax

---

## Implementation Location

The Wait action is implemented in:

- `Sources/ARORuntime/Actions/BuiltIn/ServerActions.swift` - `WaitForEventsAction` (verbs: "wait", "keepalive")
- `Sources/ARORuntime/Actions/BuiltIn/ServerActions.swift` - `ShutdownCoordinator` for signal handling
- `Sources/ARORuntime/Actions/BuiltIn/ServerActions.swift` - `KeepaliveSignalHandler` for SIGINT/SIGTERM

Examples:
- `Examples/HTTPServer/` - HTTP server with wait for shutdown
- `Examples/FileWatcher/` - File monitor with wait for shutdown
- `Examples/EchoSocket/` - Socket server with wait for shutdown

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-12 | Initial specification |
| 1.1 | 2024-12 | Implemented with shutdown-signal and event-specific wait |
