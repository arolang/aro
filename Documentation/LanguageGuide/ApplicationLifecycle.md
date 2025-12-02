# Application Lifecycle

ARO applications have a well-defined lifecycle from startup to shutdown. This chapter explains how to manage your application's lifecycle.

## Lifecycle Overview

```
┌─────────────────────────────────────────────────────┐
│                 Application Lifecycle               │
├─────────────────────────────────────────────────────┤
│                                                     │
│  1. Load all .aro files                             │
│  2. Compile and validate                            │
│  3. Register feature sets with event bus            │
│  4. Execute Application-Start                       │
│  5. Enter event loop                                │
│           │                                         │
│           ▼                                         │
│  ┌─────────────────┐                                │
│  │  Handle Events  │◄──── HTTP, Files, Sockets,    │
│  │  (event loop)   │       Domain Events            │
│  └────────┬────────┘                                │
│           │                                         │
│           ▼ (shutdown signal)                       │
│                                                     │
│  6. Stop accepting new events                       │
│  7. Wait for pending events                         │
│  8. Execute Application-End                         │
│  9. Stop services                                   │
│  10. Exit                                           │
│                                                     │
└─────────────────────────────────────────────────────┘
```

## Application-Start

The entry point for every ARO application.

### Requirements

- **Exactly one** per application
- Must be named `Application-Start`
- Must return a status

### Basic Example

```aro
(Application-Start: My Application) {
    <Log> the <startup: message> for the <console> with "Starting application...".
    <Return> an <OK: status> for the <startup>.
}
```

### Full Example

```aro
(Application-Start: E-Commerce Platform) {
    <Log> the <startup: message> for the <console> with "Starting E-Commerce Platform...".

    (* Load configuration *)
    <Read> the <config: JSON> from the <file: "./config.json">.
    <Publish> as <app-config> <config>.

    (* Initialize database connection *)
    <Connect> to <host: "${config.database.host}"> on port <config: database port> as <database>.

    (* Start HTTP server *)
    <Start> the <http-server> on port <config: server port>.

    (* Start file watcher for uploads *)
    <Watch> the <directory: "./uploads"> as <upload-watcher>.

    (* Start background scheduler *)
    <Start> the <scheduler>.

    <Log> the <ready: message> for the <console> with "Platform ready on port ${config.server.port}".
    <Return> an <OK: status> for the <startup>.
}
```

### Initialization Order

Statements execute sequentially, so order matters:

```aro
(Application-Start: Ordered Initialization) {
    (* 1. Load config first - other steps depend on it *)
    <Read> the <config> from the <file: "./config.json">.
    <Publish> as <app-config> <config>.

    (* 2. Initialize database - services need it *)
    <Connect> to <database-host> as <database>.

    (* 3. Start services - they use config and database *)
    <Start> the <http-server> on port <config: port>.

    <Return> an <OK: status> for the <startup>.
}
```

## Application-End

Exit handlers for cleanup when the application stops.

### Success Handler

Called on graceful shutdown (SIGTERM, SIGINT, or programmatic stop):

```aro
(Application-End: Success) {
    <Log> the <shutdown: message> for the <console> with "Shutting down gracefully...".

    (* Stop accepting new requests *)
    <Stop> the <http-server>.

    (* Wait for in-flight requests *)
    <Flush> the <request-queue>.

    (* Close database connections *)
    <Close> the <database-connections>.

    (* Flush logs *)
    <Flush> the <log-buffer>.

    <Log> the <shutdown: complete> for the <console> with "Shutdown complete. Goodbye!".
    <Return> an <OK: status> for the <shutdown>.
}
```

### Error Handler

Called when the application crashes or encounters a fatal error:

```aro
(Application-End: Error) {
    <Extract> the <error> from the <shutdown: error>.
    <Extract> the <code> from the <shutdown: code>.
    <Extract> the <reason> from the <shutdown: reason>.

    <Log> the <error: message> for the <console> with "FATAL ERROR: ${reason}".
    <Log> the <error: details> for the <console> with <error>.

    (* Send alert to operations *)
    <Send> the <crash-alert> to the <ops-webhook> with {
        service: "E-Commerce Platform",
        error: <error>,
        code: <code>,
        reason: <reason>,
        timestamp: <current-time>
    }.

    (* Attempt graceful cleanup *)
    <Close> the <database-connections>.

    <Return> an <OK: status> for the <error-handling>.
}
```

### Shutdown Context

Available variables in Application-End handlers:

| Variable | Description | Available In |
|----------|-------------|--------------|
| `<shutdown: reason>` | Human-readable reason | Both |
| `<shutdown: code>` | Exit code (0 = success) | Both |
| `<shutdown: signal>` | Signal name (SIGTERM, etc.) | Success |
| `<shutdown: error>` | Error object | Error only |

### Rules

- Both handlers are **optional**
- At most **one of each** per application
- Error handler only runs on errors
- Success handler only runs on graceful shutdown

## Running Applications

### Basic Run

```bash
aro run ./MyApp
```

The application runs and exits when Application-Start completes.

### Keeping Applications Alive

For servers that should run indefinitely, use the `<Keepalive>` action:

```aro
(Application-Start: My Server) {
    <Start> the <http-server> on port 8080.
    <Keepalive> the <application> for the <events>.
    <Return> an <OK: status> for the <startup>.
}
```

The `<Keepalive>` action blocks until interrupted (Ctrl+C or kill signal).

### Graceful Shutdown

When you send SIGTERM or SIGINT:

1. The event loop stops accepting new events
2. Pending events complete (with timeout)
3. `Application-End: Success` executes
4. Services stop
5. Application exits with code 0

### Error Shutdown

When an unhandled error occurs:

1. The error is caught
2. `Application-End: Error` executes
3. Services stop (best effort)
4. Application exits with non-zero code

## Service Initialization

### HTTP Server

```aro
(Application-Start: Web Server) {
    <Start> the <http-server> on port 8080.
    <Keepalive> the <application> for the <events>.
    <Return> an <OK: status> for the <startup>.
}

(Application-End: Success) {
    <Stop> the <http-server>.
    <Return> an <OK: status> for the <shutdown>.
}
```

### File Watcher

```aro
(Application-Start: File Processor) {
    <Watch> the <directory: "./inbox"> as <file-watcher>.
    <Keepalive> the <application> for the <events>.
    <Return> an <OK: status> for the <startup>.
}

(Application-End: Success) {
    <Stop> the <file-watcher>.
    <Return> an <OK: status> for the <shutdown>.
}
```

### Socket Server

```aro
(Application-Start: Socket Server) {
    <Listen> on port 9000 as <socket-server>.
    <Keepalive> the <application> for the <events>.
    <Return> an <OK: status> for the <startup>.
}

(Application-End: Success) {
    <Close> the <socket-server>.
    <Return> an <OK: status> for the <shutdown>.
}
```

### Multiple Services

```aro
(Application-Start: Full Stack) {
    (* HTTP API *)
    <Start> the <http-server> on port 8080.

    (* WebSocket server *)
    <Listen> on port 8081 as <websocket-server>.

    (* File watcher *)
    <Watch> the <directory: "./uploads"> as <upload-watcher>.

    (* Background jobs *)
    <Start> the <job-scheduler>.

    (* Keep the application running *)
    <Keepalive> the <application> for the <events>.

    <Return> an <OK: status> for the <startup>.
}

(Application-End: Success) {
    (* Stop in reverse order *)
    <Stop> the <job-scheduler>.
    <Stop> the <upload-watcher>.
    <Close> the <websocket-server>.
    <Stop> the <http-server>.

    <Return> an <OK: status> for the <shutdown>.
}
```

## Configuration Loading

### From File

```aro
(Application-Start: Configured App) {
    <Read> the <config: JSON> from the <file: "./config.json">.
    <Publish> as <app-config> <config>.

    <Start> the <http-server> on port <config: port>.
    <Return> an <OK: status> for the <startup>.
}
```

### From Environment

```aro
(Application-Start: Environment Config) {
    <Extract> the <port> from the <environment: PORT>.
    <Extract> the <db-url> from the <environment: DATABASE_URL>.

    <Connect> to <db-url> as <database>.
    <Start> the <http-server> on port <port>.

    <Return> an <OK: status> for the <startup>.
}
```

### With Defaults

```aro
(Application-Start: Config with Defaults) {
    <Extract> the <port> from the <environment: PORT>.

    if <port> is empty then {
        <Set> the <port> to 8080.
    }

    <Start> the <http-server> on port <port>.
    <Return> an <OK: status> for the <startup>.
}
```

## Health Checks

Set up health check endpoints during initialization:

```aro
(Application-Start: Healthy App) {
    <Set> the <startup-time> to <current-time>.
    <Publish> as <app-startup-time> <startup-time>.

    <Start> the <http-server> on port 8080.
    <Return> an <OK: status> for the <startup>.
}

(GET /health: Health Check) {
    <Create> the <health> with {
        status: "healthy",
        uptime: <current-time> - <app-startup-time>,
        version: "1.0.0"
    }.
    <Return> an <OK: status> with <health>.
}

(GET /ready: Readiness Check) {
    (* Check dependencies *)
    <Check> the <database-connection>.
    <Check> the <cache-connection>.

    if <checks: allPassed> then {
        <Return> an <OK: status> with { ready: true }.
    } else {
        <Return> a <ServiceUnavailable: status> with { ready: false }.
    }
}
```

## Best Practices

### Initialize Early, Fail Fast

```aro
(Application-Start: Fail Fast) {
    (* Check critical config first *)
    <Read> the <config> from the <file: "./config.json">.

    when <config: database> is empty {
        <Log> the <error> for the <console> with "Missing database configuration".
        <Throw> a <ConfigurationError> for the <missing: database>.
    }

    (* Then initialize services *)
    <Connect> to <config: database url> as <database>.
    <Start> the <http-server> on port <config: port>.

    <Return> an <OK: status> for the <startup>.
}
```

### Clean Shutdown

```aro
(Application-End: Success) {
    <Log> the <shutdown: starting> for the <console> with "Initiating graceful shutdown...".

    (* 1. Stop accepting new work *)
    <Stop> the <http-server>.

    (* 2. Wait for in-progress work *)
    <Wait> for the <pending-requests> with timeout 30.

    (* 3. Close external connections *)
    <Close> the <database-connections>.
    <Close> the <cache-connections>.

    (* 4. Flush buffers *)
    <Flush> the <log-buffer>.
    <Flush> the <metrics-buffer>.

    <Log> the <shutdown: complete> for the <console> with "Shutdown complete".
    <Return> an <OK: status> for the <shutdown>.
}
```

### Log Lifecycle Events

```aro
(Application-Start: Observable App) {
    <Log> the <lifecycle: event> for the <console> with "APPLICATION_STARTING".

    <Start> the <http-server> on port 8080.

    <Log> the <lifecycle: event> for the <console> with "APPLICATION_READY".
    <Return> an <OK: status> for the <startup>.
}

(Application-End: Success) {
    <Log> the <lifecycle: event> for the <console> with "APPLICATION_STOPPING".

    <Stop> the <http-server>.

    <Log> the <lifecycle: event> for the <console> with "APPLICATION_STOPPED".
    <Return> an <OK: status> for the <shutdown>.
}
```

## Next Steps

- [HTTP Services](HTTPServices.md) - HTTP server and client
- [File System](FileSystem.md) - File operations and watching
- [Events](Events.md) - Event-driven architecture
