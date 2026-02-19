# ARO-0005: Application Architecture

* Proposal: ARO-0005
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001

## Abstract

This proposal defines the ARO application model: directory-based applications, automatic file discovery, application lifecycle, cross-application imports, and the concurrency model. ARO applications are directories containing `.aro` files that respond to events.

## Philosophy

ARO's application model matches how project managers think:

- **"An application is a folder"** - No package manifests, no build files
- **"When X happens, do Y"** - Feature sets respond to events
- **"Do this, then this, then this"** - Steps happen in order

Project managers don't think about modules, visibility modifiers, threads, or async/await. They think about applications that do things in response to events.

---

## 1. Directory-Based Applications

An ARO application is a **directory** containing one or more `.aro` files:

```
MyApp/
+-- main.aro           # Contains Application-Start (required)
+-- users.aro          # User-related feature sets
+-- orders.aro         # Order-related feature sets
+-- events.aro         # Event handlers
+-- openapi.yaml       # API contract (optional, for HTTP)
```

### Automatic Discovery

All `.aro` files in the directory are **automatically discovered and parsed**:

```
+---------------------------+
|    Application Loader     |
+---------------------------+
            |
            v
+---------------------------+
|  Scan directory for *.aro |
|                           |
|  main.aro    --> parse    |
|  users.aro   --> parse    |
|  orders.aro  --> parse    |
|  events.aro  --> parse    |
+---------------------------+
            |
            v
+---------------------------+
|  Build unified symbol     |
|  table from all files     |
+---------------------------+
            |
            v
+---------------------------+
|  Register all feature     |
|  sets with EventBus       |
+---------------------------+
```

### Global Visibility Within Application

Within an application:

- All feature sets are globally visible
- All published variables are accessible from any file
- No import statements needed between files in the same directory

**users.aro:**
```aro
(Load User Config: Startup) {
    Read the <config> from the <file> with "./users.json".
    Publish as <user-config> <config>.
    Return an <OK: status> for the <config>.
}
```

**orders.aro:**
```aro
(Create Order: Order API) {
    (* Access published variable from users.aro *)
    <Use> the <user-config> in the <order-creation>.
    Return an <OK: status> with <order>.
}
```

---

## 2. Application Lifecycle

### Application-Start (Required)

Every application must have **exactly one** feature set named `Application-Start`:

```aro
(Application-Start: My Application) {
    Log "Starting My Application..." to the <console>.
    Start the <http-server> with <contract>.
    Keepalive the <application> for the <events>.
    Return an <OK: status> for the <startup>.
}
```

**Validation:**
- No `Application-Start` found: Error - "No entry point defined"
- Multiple `Application-Start` found: Error - "Multiple entry points found in: file1.aro, file2.aro"

### Application-End: Success (Optional)

Called when the application terminates normally (SIGTERM, graceful shutdown):

```aro
(Application-End: Success) {
    Log "Shutting down gracefully..." to the <console>.
    Stop the <http-server> with <application>.
    Close the <database-connections>.
    Log "Goodbye!" to the <console>.
    Return an <OK: status> for the <shutdown>.
}
```

### Application-End: Error (Optional)

Called when the application terminates due to an error or crash:

```aro
(Application-End: Error) {
    Extract the <error> from the <shutdown: error>.
    Log "Fatal error occurred" to the <console>.
    Send the <alert> to the <ops-webhook> with <error>.
    Return an <OK: status> for the <error-handling>.
}
```

**Validation:**
- At most **one** `Application-End: Success` per application
- At most **one** `Application-End: Error` per application

### Lifecycle Flow

```
+----------------------------------------------------------+
|                  Application Lifecycle                    |
+----------------------------------------------------------+

  STARTUP:
  +-- Discover all .aro files in directory
  +-- Parse and compile all files
  +-- Validate Application-Start (exactly one)
  +-- Validate Application-End (at most one of each)
  +-- Register all feature sets with EventBus
  +-- Execute Application-Start
  +-- Enter event loop

  RUNNING:
  +-- Events arrive (HTTP, file, socket, custom)
  +-- Match event to registered feature sets
  +-- Execute matching feature set(s)
  +-- Return to event loop

  SHUTDOWN:
  +-- Shutdown signal received (SIGINT/SIGTERM or error)
  +-- Stop accepting new events
  +-- Wait for pending events (with timeout)
  +-- Execute Application-End: Success or Error
  +-- Stop all services
  +-- Exit

+----------------------------------------------------------+
```

### Shutdown Context Variables

Exit handlers have access to shutdown context:

| Variable | Description |
|----------|-------------|
| `<shutdown: reason>` | Human-readable shutdown reason |
| `<shutdown: code>` | Exit code (0 for success, non-zero for error) |
| `<shutdown: signal>` | Signal name if applicable (SIGTERM, SIGINT) |
| `<shutdown: error>` | Error object if shutdown due to error |

---

## 3. Import System

### Importing Other Applications

To use feature sets and types from another application:

```aro
import ../user-service
import ../payment-gateway
import ../../shared/auth
```

After an import:
- All feature sets from the imported application are accessible
- All types from the imported application are accessible
- All published variables are accessible

### Import Syntax

```ebnf
import_statement = "import" , relative_path ;

relative_path = "./" , path_segment , { "/" , path_segment }
              | "../" , { "../" } , path_segment , { "/" , path_segment } ;
```

### Example: Service Composition

```
workspace/
+-- user-service/           # Can import ../payment-service
|   +-- main.aro
|   +-- users.aro
+-- payment-service/        # Can import ../user-service
|   +-- main.aro
|   +-- payments.aro
+-- api-gateway/            # Can import both
    +-- main.aro
```

**api-gateway/main.aro:**
```aro
import ../user-service
import ../payment-service

(Application-Start: API Gateway) {
    Log "Gateway starting..." to the <console>.
    Start the <http-server> on port 8080.
    Keepalive the <application> for the <events>.
    Return an <OK: status> for the <startup>.
}
```

### No Visibility Modifiers

ARO explicitly rejects visibility modifiers:

| Traditional | ARO Approach |
|-------------|--------------|
| `public` | Everything is accessible after import |
| `private` | Don't publish what you don't want shared |
| `internal` | Feature set scope handles this |
| `protected` | No inheritance hierarchy |

---

## 4. Concurrency Model

ARO's concurrency model is **event-driven async with synchronous statement execution**.

### Feature Sets Are Async

Every feature set runs asynchronously when triggered by an event:

```
+-------------------------------------------------------------+
|                      Event Bus                               |
|                                                              |
|  HTTP Request --+---> (listUsers: User API)                 |
|                 |                                            |
|  Socket Data ---+---> (Handle Data: Socket Handler)         |
|                 |                                            |
|  File Changed --+---> (Process File: File Handler)          |
|                 |                                            |
|  UserCreated ---+---> (Send Email: UserCreated Handler)     |
|                                                              |
|  (Multiple events can trigger multiple feature sets         |
|   running concurrently)                                      |
+-------------------------------------------------------------+
```

When multiple events arrive, multiple feature sets execute simultaneously.

### Statements Are Sync

Inside a feature set, statements execute **synchronously** and **serially**:

```aro
(Process Order: Order API) {
    Extract the <data> from the <request: body>.      (* 1. First *)
    Validate the <data> for the <order-schema>.       (* 2. Second *)
    Create the <order> with <data>.                   (* 3. Third *)
    Store the <order> in the <order-repository>.      (* 4. Fourth *)
    Emit an <OrderCreated: event> with <order>.       (* 5. Fifth *)
    Return a <Created: status> with <order>.          (* 6. Last *)
}
```

Each statement completes before the next one starts. No callbacks. No promises. No async/await syntax.

### No Concurrency Primitives

ARO explicitly does **not** provide:

- `async` / `await` keywords
- Promises / Futures
- Threads / Task spawning
- Locks / Mutexes / Semaphores
- Channels / Actors
- Race / All / Any combinators
- Parallel for loops

The runtime handles concurrency. The programmer writes sequential code.

### Runtime Optimization (Transparent)

While code appears synchronous, the runtime executes I/O operations asynchronously:

```aro
(Process Config: File Handler) {
    <Open> the <config-file> from the <path>.        (* Starts file load async *)
    Compute the <hash> for the <request>.          (* Runs while file loads *)
    Log "Processing..." to the <console>.          (* Runs while file loads *)
    Parse the <config> from the <config-file>.     (* Waits for file if needed *)
    Return an <OK: status> with <config>.
}
```

The programmer writes synchronous code. The runtime delivers async performance.

### Event Emission

Feature sets trigger other feature sets via events:

```aro
(Create User: User API) {
    Extract the <data> from the <request: body>.
    Create the <user> with <data>.
    Store the <user> in the <user-repository>.

    (* Triggers other feature sets asynchronously *)
    Emit a <UserCreated: event> with <user>.

    (* Continues immediately, doesn't wait for handlers *)
    Return a <Created: status> with <user>.
}

(* Runs asynchronously when UserCreated is emitted *)
(Send Welcome Email: UserCreated Handler) {
    Extract the <user> from the <event: user>.
    Send the <welcome-email> to the <user: email>.
    Return an <OK: status>.
}
```

---

## 5. Long-Running Applications

Applications that need to stay alive and process events use the `<Keepalive>` action.

### The Keepalive Action

```aro
(Application-Start: File Watcher) {
    Log "Starting file watcher..." to the <console>.
    Start the <file-monitor> with ".".

    (* Keep the application running to process events *)
    Keepalive the <application> for the <events>.

    Return an <OK: status> for the <startup>.
}
```

### Semantics

The `<Keepalive>` action:

1. **Blocks Execution**: Pauses the current feature set
2. **Enables Event Processing**: Allows the event bus to dispatch events
3. **Respects OS Signals**: Unblocks on SIGINT (Ctrl+C) or SIGTERM
4. **Triggers Cleanup**: After unblocking, executes `Application-End: Success`

### Signal Handling

```
+------------------------------------------+
|           Signal Handler                  |
+------------------------------------------+
|                                          |
|  SIGINT (Ctrl+C)  --+--> Graceful        |
|                     |    Shutdown        |
|  SIGTERM ---------->|                    |
|                                          |
|  1. Stop accepting new events            |
|  2. Wait for pending events (timeout)    |
|  3. Execute Application-End: Success     |
|  4. Stop all services                    |
|  5. Exit with code 0                     |
|                                          |
+------------------------------------------+
```

---

## Complete Example

### Directory Structure

```
UserService/
+-- openapi.yaml       # API contract
+-- main.aro           # Application lifecycle
+-- users.aro          # User API handlers
+-- events.aro         # Event handlers
```

### main.aro

```aro
(Application-Start: User Service) {
    Log "Starting User Service..." to the <console>.
    Start the <http-server> with <contract>.
    Log "Service ready on port 8080" to the <console>.

    (* Keep server running until Ctrl+C *)
    Keepalive the <application> for the <events>.

    Return an <OK: status> for the <startup>.
}

(Application-End: Success) {
    Log "Shutting down gracefully..." to the <console>.
    Stop the <http-server> with <application>.
    Log "Goodbye!" to the <console>.
    Return an <OK: status> for the <shutdown>.
}

(Application-End: Error) {
    Extract the <error> from the <shutdown: error>.
    Log "Fatal error occurred" to the <console>.
    Send the <alert> to the <ops-webhook> with <error>.
    Return an <OK: status> for the <error-handling>.
}
```

### users.aro

```aro
(listUsers: User API) {
    Retrieve the <users> from the <user-repository>.
    Return an <OK: status> with <users>.
}

(getUser: User API) {
    Extract the <id> from the <pathParameters: id>.
    Retrieve the <user> from the <user-repository> where id = <id>.
    Return an <OK: status> with <user>.
}

(createUser: User API) {
    Extract the <data> from the <request: body>.
    Validate the <data> for the <user-schema>.
    Create the <user> with <data>.
    Store the <user> in the <user-repository>.
    Emit a <UserCreated: event> with <user>.
    Return a <Created: status> with <user>.
}
```

### events.aro

```aro
(Send Welcome Email: UserCreated Handler) {
    Extract the <user> from the <event: user>.
    Extract the <email> from the <user: email>.
    Send the <welcome-email> to the <email>.
    Log "Welcome email sent" to the <console>.
    Return an <OK: status> for the <notification>.
}

(Track Signup: UserCreated Handler) {
    Extract the <user> from the <event: user>.
    <Record> the <signup: metric> with <user>.
    Return an <OK: status> for the <analytics>.
}
```

---

## CLI Commands

```bash
aro run ./UserService       # Run application directory
aro compile ./UserService   # Compile all .aro files
aro check ./UserService     # Validate all .aro files
aro build ./UserService     # Compile to native binary
```

---

## Error Messages

```
Error: No entry point defined
  No 'Application-Start' feature set found in application.

  Hint: Add a feature set named 'Application-Start':

    (Application-Start: My App) {
        Return an <OK: status> for the <startup>.
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
```

---

## Summary

ARO's application architecture is radically simple:

| Concept | ARO Approach |
|---------|--------------|
| **Application** | A directory containing `.aro` files |
| **File Discovery** | Automatic, no imports needed within app |
| **Entry Point** | Exactly one `Application-Start` |
| **Exit Handlers** | Optional `Application-End: Success/Error` |
| **Cross-App Import** | `import ../path` |
| **Visibility** | No modifiers, everything accessible after import |
| **Concurrency** | Feature sets async, statements sync |
| **Long-Running** | `<Keepalive>` action for servers/watchers |
| **Shutdown** | Graceful via SIGINT/SIGTERM |

Write sequential code. Get concurrent execution. No callbacks, no promises, no async/await.
