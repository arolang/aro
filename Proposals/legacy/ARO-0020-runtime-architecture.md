# ARO-0020: Runtime Architecture

* Proposal: ARO-0020
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0009, ARO-0011

## Abstract

This proposal defines the runtime architecture for executing ARO applications, including multi-file application discovery, event-driven feature set execution, and the single entry point constraint.

## Motivation

ARO applications need:

1. **Multi-File Support**: All `.aro` files in an application folder are automatically parsed
2. **No Imports Required**: All feature sets are globally visible within an application
3. **Single Entry Point**: Exactly one `Application-Start` feature set per application
4. **Event-Driven Execution**: Feature sets are triggered by events, not direct calls

## Proposed Solution

### 1. Application Structure

An ARO application is a **directory** containing one or more `.aro` files:

```
MyApp/
├── main.aro           # Contains Application-Start
├── users.aro          # User-related feature sets
├── orders.aro         # Order-related feature sets
└── notifications.aro  # Notification handlers
```

**All `.aro` files are automatically discovered and parsed.** No import statements are needed.

### 2. Single Entry Point Rule

Every application must have **exactly one** feature set named `Application-Start`:

```aro
(Application-Start: My Application) {
    <Log> "Starting..." to the <console>.
    <Start> the <http-server> on port 8080.
    <Return> an <OK: status> for the <startup>.
}
```

**Validation Rules:**
- If no `Application-Start` is found → Error: "No entry point defined"
- If multiple `Application-Start` found → Error: "Multiple entry points found in: file1.aro, file2.aro"

### 3. Application Exit Points

Applications can define **exit handlers** that execute when the application terminates:

```aro
(* Called on successful shutdown *)
(Application-End: Success) {
    <Log> "Application shutting down gracefully" to the <console>.
    <Close> the <database-connections>.
    <Return> an <OK: status> for the <shutdown>.
}

(* Called on error/crash *)
(Application-End: Error) {
    <Extract> the <error> from the <shutdown: reason>.
    <Log> <error> to the <console>.
    <Send> the <alert> to the <ops-team>.
    <Return> an <OK: status> for the <error-handling>.
}
```

**Exit Handler Rules:**
- `Application-End: Success` - Called when application terminates normally (SIGTERM, graceful shutdown)
- `Application-End: Error` - Called when application terminates due to an error
- Both are **optional** - if not defined, application exits without cleanup
- At most **one of each** per application (error if duplicates found)
- Exit handlers have access to shutdown context via `<shutdown: reason>`, `<shutdown: code>`

**Execution Order:**
1. Shutdown signal received (SIGTERM, SIGINT, or unhandled error)
2. Event loop stops accepting new events
3. Pending events complete (with timeout)
4. Appropriate `Application-End` handler executes
5. Services are stopped
6. Application exits

**Shutdown Context Variables:**
| Variable | Description |
|----------|-------------|
| `<shutdown: reason>` | Human-readable shutdown reason |
| `<shutdown: code>` | Exit code (0 for success, non-zero for error) |
| `<shutdown: signal>` | Signal name if applicable (SIGTERM, SIGINT) |
| `<shutdown: error>` | Error object if shutdown due to error |

### 4. Event-Driven Feature Sets

Feature sets are **not called directly**. They are triggered by events:

```
┌─────────────────────────────────────────────────────────────┐
│                    ARO Runtime                              │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   Event Bus                                                 │
│       │                                                     │
│       ├──► HTTPRequestEvent ──► (GET /users: Handler)       │
│       ├──► FileCreatedEvent ──► (Handle New File: Handler)  │
│       ├──► SocketDataEvent ──► (Handle Data: Handler)       │
│       └──► CustomEvent ──► (Handle Custom: Handler)         │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 4. Feature Set Triggering

Feature sets declare what events they handle via their **business activity**:

| Business Activity Pattern | Triggered By |
|---------------------------|--------------|
| `HTTP Request Handler` | HTTP requests |
| `GET /path`, `POST /path` | HTTP route match |
| `File Event Handler` | File system events |
| `Socket Event Handler` | Socket events |
| `{EventName} Handler` | Custom events |

Example:

```aro
(* Triggered by HTTP GET /users *)
(GET /users: User API) {
    <Retrieve> the <users> from the <user-repository>.
    <Return> an <OK: status> with <users>.
}

(* Triggered by FileCreatedEvent *)
(Handle File Created: File Event Handler) {
    <Extract> the <path> from the <event: path>.
    <Log> <path> to the <console>.
    <Return> an <OK: status> for the <event>.
}

(* Triggered by custom UserRegisteredEvent *)
(Send Welcome Email: UserRegistered Handler) {
    <Extract> the <user> from the <event: user>.
    <Extract> the <email> from the <user: email>.
    <Send> the <welcome-email> to the <email>.
    <Return> an <OK: status> for the <notification>.
}
```

### 6. Execution Model

```
┌─────────────────────────────────────────────────────────────┐
│                    Application Lifecycle                    │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  STARTUP:                                                   │
│  1. Discover all .aro files in directory                    │
│  2. Parse and compile all files                             │
│  3. Validate Application-Start (exactly one)                │
│  4. Validate Application-End (at most one of each)          │
│  5. Register all feature sets with EventBus                 │
│  6. Execute Application-Start                               │
│  7. Enter event loop (wait for events)                      │
│                                                             │
│  RUNNING:                                                   │
│  8. Match event to registered feature sets                  │
│  9. Execute matching feature set(s)                         │
│  10. Return to event loop                                   │
│                                                             │
│  SHUTDOWN:                                                  │
│  11. Stop accepting new events                              │
│  12. Wait for pending events (with timeout)                 │
│  13. Execute Application-End: Success or Error              │
│  14. Stop all services                                      │
│  15. Exit                                                   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 7. Application Discovery

```swift
public final class ApplicationLoader {
    public func load(from directory: URL) async throws -> Application {
        // 1. Find all .aro files
        let aroFiles = try findAROFiles(in: directory)

        if aroFiles.isEmpty {
            throw ApplicationError.noSourceFiles(directory)
        }

        // 2. Compile all files
        var allFeatureSets: [AnalyzedFeatureSet] = []
        for file in aroFiles {
            let source = try String(contentsOf: file)
            let result = Compiler.compile(source, filename: file.lastPathComponent)

            if !result.isSuccess {
                throw ApplicationError.compilationFailed(file, result.diagnostics)
            }

            allFeatureSets.append(contentsOf: result.analyzedProgram.featureSets)
        }

        // 3. Validate single Application-Start
        let entryPoints = allFeatureSets.filter { $0.name == "Application-Start" }

        switch entryPoints.count {
        case 0:
            throw ApplicationError.noEntryPoint
        case 1:
            break // Valid
        default:
            let files = entryPoints.map { $0.sourceFile }
            throw ApplicationError.multipleEntryPoints(files)
        }

        // 4. Validate Application-End handlers (at most one of each)
        let successExits = allFeatureSets.filter {
            $0.name == "Application-End" && $0.businessActivity == "Success"
        }
        let errorExits = allFeatureSets.filter {
            $0.name == "Application-End" && $0.businessActivity == "Error"
        }

        if successExits.count > 1 {
            let files = successExits.map { $0.sourceFile }
            throw ApplicationError.multipleExitHandlers("Success", files)
        }
        if errorExits.count > 1 {
            let files = errorExits.map { $0.sourceFile }
            throw ApplicationError.multipleExitHandlers("Error", files)
        }

        // 5. Create application with all feature sets
        return Application(
            featureSets: allFeatureSets,
            exitSuccess: successExits.first,
            exitError: errorExits.first
        )
    }
}
```

### 8. Event Registration

Feature sets are automatically registered with the event bus:

```swift
public final class Application {
    private let eventBus: EventBus
    private var featureSetRegistry: [String: AnalyzedFeatureSet] = [:]

    func registerFeatureSets(_ featureSets: [AnalyzedFeatureSet]) {
        for featureSet in featureSets {
            // Register by name
            featureSetRegistry[featureSet.name] = featureSet

            // Register event handlers based on business activity
            if let eventType = parseEventType(featureSet.businessActivity) {
                eventBus.subscribe(eventType) { [weak self] event in
                    await self?.executeFeatureSet(featureSet, with: event)
                }
            }
        }
    }
}
```

### 9. Cross-File References

All feature sets can reference published variables from any file:

**users.aro:**
```aro
(Load Users: Startup Task) {
    <Retrieve> the <users> from the <database: users>.
    <Publish> as <all-users> <users>.
    <Return> an <OK: status> for the <loading>.
}
```

**reports.aro:**
```aro
(Generate Report: Report Handler) {
    (* Access published variable from users.aro *)
    <Transform> the <report> from the <all-users>.
    <Return> an <OK: status> with <report>.
}
```

---

## Grammar

No grammar changes required - this proposal defines runtime behavior.

---

## Complete Example

### Directory Structure

```
UserService/
├── main.aro
├── users.aro
└── events.aro
```

### main.aro
```aro
(* Application entry point - only one allowed *)
(Application-Start: User Service) {
    <Log> "Starting User Service" to the <console>.

    (* Start HTTP server *)
    <Start> the <http-server> on port 8080.

    (* Start file watcher *)
    <Watch> the <directory: "./uploads"> as <file-monitor>.

    <Log> "Service ready" to the <console>.
    <Return> an <OK: status> for the <startup>.
}

(* Called on graceful shutdown (SIGTERM, SIGINT) *)
(Application-End: Success) {
    <Log> "Shutting down gracefully..." to the <console>.
    <Stop> the <http-server>.
    <Close> the <database-connections>.
    <Log> "Goodbye!" to the <console>.
    <Return> an <OK: status> for the <shutdown>.
}

(* Called when application crashes or encounters fatal error *)
(Application-End: Error) {
    <Extract> the <error> from the <shutdown: error>.
    <Extract> the <code> from the <shutdown: code>.
    <Log> "Fatal error: ${error}" to the <console>.
    <Send> the <alert> to the <ops-webhook> with {
        message: "User Service crashed",
        error: <error>,
        code: <code>
    }.
    <Return> an <OK: status> for the <error-handling>.
}
```

### users.aro
```aro
(* HTTP route handlers - triggered by HTTP events *)

(GET /users: User API) {
    <Retrieve> the <users> from the <user-repository>.
    <Return> an <OK: status> with <users>.
}

(GET /users/{id}: User API) {
    <Extract> the <user-id> from the <request: parameters>.
    <Retrieve> the <user> from the <user-repository> where id = <user-id>.
    <Return> an <OK: status> with <user>.
}

(POST /users: User API) {
    <Extract> the <user-data> from the <request: body>.
    <Validate> the <user-data> for the <user-schema>.
    <Create> the <user> with <user-data>.
    <Store> the <user> into the <user-repository>.

    (* Emit event for other handlers *)
    <Emit> a <UserCreated: event> with <user>.

    <Return> a <Created: status> with <user>.
}
```

### events.aro
```aro
(* Event handlers - triggered by events from other feature sets *)

(Send Welcome Email: UserCreated Handler) {
    <Extract> the <user> from the <event: user>.
    <Extract> the <email> from the <user: email>.
    <Create> the <welcome-message> with {
        subject: "Welcome to our service!",
        body: "Thanks for signing up..."
    }.
    <Send> the <welcome-message> to the <email>.
    <Log> "Welcome email sent" to the <console>.
    <Return> an <OK: status> for the <notification>.
}

(Process Upload: FileCreated Handler) {
    <Extract> the <path> from the <event: path>.
    <Read> the <content> from the <file: path>.
    <Transform> the <processed> from the <content>.
    <Store> the <processed> into the <processed-files>.
    <Return> an <OK: status> for the <processing>.
}
```

---

## Error Messages

```
Error: No entry point defined
  No 'Application-Start' feature set found in application.

  Hint: Add a feature set named 'Application-Start':

    (Application-Start: My App) {
        <Return> an <OK: status> for the <startup>.
    }
```

```
Error: Multiple entry points found
  Found 'Application-Start' in multiple files:
    - main.aro:1
    - startup.aro:5

  An application can only have one entry point.
  Remove the duplicate 'Application-Start' feature set.
```

```
Error: Multiple exit handlers found
  Found 'Application-End: Success' in multiple files:
    - main.aro:15
    - cleanup.aro:1

  An application can only have one 'Application-End: Success' handler.
  Remove the duplicate handler.
```

```
Error: Multiple error handlers found
  Found 'Application-End: Error' in multiple files:
    - main.aro:25
    - errors.aro:1

  An application can only have one 'Application-End: Error' handler.
  Remove the duplicate handler.
```

---

## Implementation Notes

### Runtime Components

1. **ApplicationLoader**: Discovers and compiles all `.aro` files
2. **ExecutionEngine**: Orchestrates program execution
3. **FeatureSetExecutor**: Executes individual feature sets
4. **EventBus**: Routes events to feature sets
5. **RuntimeContext**: Variable binding and service access

### CLI Integration

```bash
aro run ./UserService           # Run application directory
aro run ./UserService --keep-alive  # Keep alive for servers
aro compile ./UserService       # Compile all files
aro check ./UserService         # Validate all files
```

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-12 | Initial specification |
| 1.1 | 2024-12 | Multi-file support, event-driven execution |
| 1.2 | 2024-12 | Application-End: Success and Error exit handlers |
