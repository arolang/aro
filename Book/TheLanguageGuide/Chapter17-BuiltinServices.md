# Chapter 17: Built-in Services

*"Batteries included."*

---

## 17.1 Available Services

ARO provides five built-in services that handle common infrastructure concerns: an HTTP server for serving web requests, an HTTP client for making outbound requests, a file system service for reading and writing files, and socket services for TCP communication.

These services are available without additional configuration or dependencies. When you need to serve HTTP requests, you start the HTTP server. When you need to make outbound API calls, you use the HTTP client. When you need to read configuration files or write data, you use the file system service. When you need low-level TCP communication, you use the socket services.

Each service follows the same pattern of interaction. You start or configure the service using an action, you interact with it through subsequent actions, and you stop it during shutdown. Services that produce events—file changes, socket messages—trigger event handlers that you define.

The services are designed to be sufficient for most application needs while remaining simple. If you need more specialized functionality, you can create custom actions that wrap specialized libraries.

---

## 17.2 HTTP Server

The HTTP server handles incoming HTTP requests based on your OpenAPI specification. It provides a production-capable server built on SwiftNIO that efficiently handles concurrent connections.

Starting the server is a single statement that tells the runtime to load the OpenAPI specification, configure routes, and begin listening for connections. The server typically starts during Application-Start and runs until shutdown. Without the Keepalive action, the application would start the server and immediately exit.

You can configure the port on which the server listens. The default is typically port 8080, but you can specify any available port. You can also specify a host address to control which network interfaces accept connections—binding to "0.0.0.0" accepts connections from any interface, while binding to "127.0.0.1" accepts only local connections.

Additional configuration options control request validation, timeout behavior, maximum body size, and CORS settings. Validation tells the server to check incoming requests against the OpenAPI schemas before routing them to handlers. Timeout settings control how long requests can run. CORS settings control cross-origin access for browser-based clients.

Stopping the server during shutdown allows it to complete in-flight requests gracefully. The server stops accepting new connections, waits for existing requests to complete, and then releases resources.

---

## 17.3 HTTP Client

The HTTP client makes outbound HTTP requests to external services. It provides a high-performance client built on AsyncHTTPClient that handles connection pooling, timeouts, and retries.

Simple GET requests use the Fetch action with a URL. The action makes the request, waits for the response, and binds the result. You can then extract the response body, status code, and headers.

POST, PUT, DELETE, and other methods use the Send action with method, body, and header configuration. The body is serialized as JSON by default. Headers can include authentication tokens, content type specifications, and other metadata.

The client supports various configuration options. Timeout settings control how long to wait for a response. Retry settings enable automatic retry on transient failures. Follow redirect settings control whether redirects are followed automatically.

Error handling follows the same happy path philosophy as other ARO operations. If a request fails—connection refused, timeout, server error—the runtime generates an appropriate error message. You do not write explicit error handling for HTTP failures.

---

## 17.4 File System Service

The file system service provides comprehensive operations for reading, writing, and managing files and directories. It handles the mechanics of file I/O while you focus on what data to read or write.

### Reading Files

Reading files uses the Read action with a file path. The action reads the file contents and binds them to a result. For JSON files, the content is parsed into a structured object. For text files, the content is a string. The path can be relative to the application directory or absolute.

```aro
<Read> the <content> from the <file: "./README.md">.
<Read> the <config: JSON> from the <file: "./config.json">.
<Read> the <image: bytes> from the <file: "./logo.png">.
```

### Writing Files

Writing files uses the Write action with data and a path. The action serializes the data and writes it to the specified location. Parent directories are created automatically if they do not exist.

```aro
<Write> the <report> to the <file: "./output/report.txt">.
<Write> the <data: JSON> to the <file: "./export.json">.
```

### Appending to Files

The Append action adds content to the end of an existing file, creating the file if it does not exist.

```aro
<Append> the <log-line> to the <file: "./logs/app.log">.
```

### Checking File Existence

The Exists action checks whether a file or directory exists at a given path.

```aro
<Exists> the <found> for the <file: "./config.json">.

when <found> is false {
    <Log> "Config not found!" to the <console>.
}
```

### Getting File Information

The Stat action retrieves detailed metadata about a file or directory, including size, modification dates, and permissions.

```aro
<Stat> the <info> for the <file: "./document.pdf">.
<Log> <info: size> to the <console>.
<Log> <info: modified> to the <console>.
```

The result contains: name, path, size (bytes), isFile, isDirectory, created, modified, accessed, and permissions.

### Listing Directory Contents

The List action retrieves the contents of a directory. You can filter by glob pattern and list recursively.

```aro
(* List all files in a directory *)
<Create> the <uploads-path> with "./uploads".
<List> the <entries> from the <directory: uploads-path>.

(* Filter with glob pattern *)
<Create> the <src-path> with "./src".
<List> the <aro-files> from the <directory: src-path> matching "*.aro".

(* List recursively *)
<Create> the <project-path> with "./project".
<List> the <all-files> from the <directory: project-path> recursively.
```

Each entry contains: name, path, size, isFile, isDirectory, and modified.

### Creating Directories

The CreateDirectory action creates a directory, including any necessary parent directories.

```aro
<CreateDirectory> the <output-dir> to the <path: "./output/reports/2024">.
```

### Copying Files and Directories

The Copy action copies a file or directory to a new location. Directory copies are recursive by default.

```aro
<Copy> the <file: "./template.txt"> to the <destination: "./copy.txt">.
<Copy> the <directory: "./src"> to the <destination: "./backup/src">.
```

### Moving and Renaming

The Move action moves or renames a file or directory.

```aro
<Move> the <file: "./draft.txt"> to the <destination: "./final.txt">.
<Move> the <file: "./inbox/report.pdf"> to the <destination: "./archive/report.pdf">.
```

### Deleting Files

The Delete action removes a file from the file system.

```aro
<Delete> the <file: "./temp/cache.json">.
```

### File Watching

File watching monitors a directory for changes and emits events when files are created, modified, or deleted. You start watching during Application-Start by specifying the directory to monitor. When changes occur, the runtime emits File Event events that your handlers can process. This is useful for applications that need to react to external file changes—configuration reloading, data import, file synchronization.

```aro
<Start> the <file-monitor> with "./data".
```

Event handlers are named according to the event type: `Handle File Created`, `Handle File Modified`, or `Handle File Deleted`.

### Cross-Platform Behavior

File operations work consistently across macOS, Linux, and Windows. Path separators use `/` in ARO code and are translated appropriately for each platform. Hidden files (those starting with `.` on Unix or with the hidden attribute on Windows) are included in listings by default.

---

## 17.5 Socket Services

The socket server and client provide low-level TCP communication for applications that need more control than HTTP offers or that need to communicate using custom protocols.

The socket server listens for incoming TCP connections on a specified port. When clients connect and send data, the runtime emits Socket Event events. Your handlers receive the client identifier and the data, and can send responses back to specific clients or broadcast to all connected clients.

The socket client connects to remote TCP servers. You establish a connection, send data, receive responses, and close the connection when done. This is useful for communicating with services that use custom TCP protocols.

Socket communication is lower level than HTTP. You are responsible for message framing, serialization, and protocol handling. The services provide the transport; you provide the protocol logic.

For most web applications, HTTP is the appropriate choice. Use sockets when you need persistent connections, when you need to implement a specific protocol, or when HTTP overhead is unacceptable for your performance requirements.

---

## 17.6 Service Lifecycle

Services have a lifecycle that mirrors the application lifecycle. They start during Application-Start, run during the application's lifetime, and stop during Application-End.

Starting services is typically one of the first things you do during startup. You start the HTTP server to begin accepting requests. You start file monitoring to begin watching for changes. You start socket servers to begin accepting connections.

After starting services, you use the Keepalive action to keep the application running. Without it, the application would complete the startup sequence and exit. Keepalive blocks until a shutdown signal arrives, allowing services to process events.

When shutdown occurs, you stop services in your Application-End handler. Stopping in reverse order of starting is a common practice—resources started last are often dependencies of resources started first, so they should be stopped first.

The error shutdown handler (Application-End: Error) should also stop services, attempting best-effort cleanup even when an error has occurred. Services might be in inconsistent states, so cleanup should be defensive.

---

## 17.7 Service Configuration

Services accept configuration options that control their behavior. These options are passed when starting or using the service.

HTTP server configuration includes port and host for network binding, validation for request checking, timeout for request duration limits, body size limits, and CORS settings for browser access control. These options shape how the server behaves and what requests it accepts.

HTTP client configuration includes timeout for response waiting, retry for transient failure recovery, and redirect handling. These options affect outbound request behavior.

File system configuration includes encoding for text handling and directory creation settings. These options affect how files are read and written.

Configuration can be hardcoded in your ARO statements or loaded from external files during startup. Loading from external files allows configuration to vary between environments without code changes.

---

## 17.8 Practical Example: Services in Action

Here is a complete example demonstrating multiple built-in services working together. This application watches a directory for configuration changes and uses the HTTP client to report them to an external monitoring service.

```aro
(* Config Monitor - Watch files and report changes via HTTP *)

(Application-Start: Config Monitor) {
    <Log> "Starting configuration monitor..." to the <console>.

    (* Load the monitoring endpoint from environment or config *)
    <Create> the <webhook-url> with "https://monitoring.example.com/webhook".

    (* Start watching the config directory *)
    <Start> the <file-monitor> with "./config".

    <Log> "Watching ./config for changes..." to the <console>.

    (* Keep running until shutdown signal *)
    <Keepalive> the <application> for the <events>.

    <Return> an <OK: status> for the <startup>.
}

(Report Config Change: File Event Handler) {
    (* Extract the changed file path *)
    <Extract> the <path> from the <event: path>.
    <Extract> the <event-type> from the <event: type>.

    <Log> "Config changed:" to the <console>.
    <Log> <path> to the <console>.

    (* Build notification payload *)
    <Create> the <notification> with {
        file: <path>,
        change: <event-type>,
        timestamp: "now"
    }.

    (* Send to monitoring webhook *)
    <Send> <notification> to the <webhook-url>.

    <Log> "Change reported to monitoring service." to the <console>.

    <Return> an <OK: status> for the <event>.
}

(Application-End: Success) {
    <Log> "Config monitor stopped." to the <console>.
    <Return> an <OK: status> for the <shutdown>.
}
```

This example shows:

- **File system service**: The `Watch` action starts monitoring the `./config` directory
- **HTTP client**: The `Send` action posts change notifications to an external webhook
- **Lifecycle management**: `Keepalive` keeps the app running, `Application-End` provides graceful shutdown
- **Event handling**: The File Event Handler processes each file change event

> **See also:** `Examples/FileWatcher` and `Examples/HTTPClient` for standalone examples of each service.

---

## 17.9 Best Practices

Start all services during Application-Start. Centralizing service startup in one place makes it clear what your application depends on and ensures consistent initialization order.

Stop all services during Application-End. Both success and error handlers should attempt to stop services, releasing resources cleanly. The error handler should be defensive because resources might be in inconsistent states.

Use Keepalive for any application that runs services. Without it, the application starts services and immediately exits. The Keepalive action keeps the application running to process incoming events.

Handle service errors through event handlers when appropriate. Some services emit error events that you can handle to log failures, attempt recovery, or alert operators. The happy path philosophy applies, but observability is still important.

Configure services appropriately for your environment. Development might use permissive CORS settings and verbose logging. Production might use restrictive settings and minimal logging. Load configuration from environment-specific files rather than hardcoding.

---

*Next: Chapter 18 — Format-Aware I/O*
