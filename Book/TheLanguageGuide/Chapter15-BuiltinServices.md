# Chapter 15: Built-in Services

*"Batteries included."*

---

## 14.1 Available Services

ARO provides five built-in services that handle common infrastructure concerns: an HTTP server for serving web requests, an HTTP client for making outbound requests, a file system service for reading and writing files, and socket services for TCP communication.

These services are available without additional configuration or dependencies. When you need to serve HTTP requests, you start the HTTP server. When you need to make outbound API calls, you use the HTTP client. When you need to read configuration files or write data, you use the file system service. When you need low-level TCP communication, you use the socket services.

Each service follows the same pattern of interaction. You start or configure the service using an action, you interact with it through subsequent actions, and you stop it during shutdown. Services that produce events—file changes, socket messages—trigger event handlers that you define.

The services are designed to be sufficient for most application needs while remaining simple. If you need more specialized functionality, you can create custom actions that wrap specialized libraries.

---

## 14.2 HTTP Server

The HTTP server handles incoming HTTP requests based on your OpenAPI specification. It provides a production-capable server built on SwiftNIO that efficiently handles concurrent connections.

Starting the server is a single statement that tells the runtime to load the OpenAPI specification, configure routes, and begin listening for connections. The server typically starts during Application-Start and runs until shutdown. Without the Keepalive action, the application would start the server and immediately exit.

You can configure the port on which the server listens. The default is typically port 8080, but you can specify any available port. You can also specify a host address to control which network interfaces accept connections—binding to "0.0.0.0" accepts connections from any interface, while binding to "127.0.0.1" accepts only local connections.

Additional configuration options control request validation, timeout behavior, maximum body size, and CORS settings. Validation tells the server to check incoming requests against the OpenAPI schemas before routing them to handlers. Timeout settings control how long requests can run. CORS settings control cross-origin access for browser-based clients.

Stopping the server during shutdown allows it to complete in-flight requests gracefully. The server stops accepting new connections, waits for existing requests to complete, and then releases resources.

---

## 14.3 HTTP Client

The HTTP client makes outbound HTTP requests to external services. It provides a high-performance client built on AsyncHTTPClient that handles connection pooling, timeouts, and retries.

Simple GET requests use the Fetch action with a URL. The action makes the request, waits for the response, and binds the result. You can then extract the response body, status code, and headers.

POST, PUT, DELETE, and other methods use the Send action with method, body, and header configuration. The body is serialized as JSON by default. Headers can include authentication tokens, content type specifications, and other metadata.

The client supports various configuration options. Timeout settings control how long to wait for a response. Retry settings enable automatic retry on transient failures. Follow redirect settings control whether redirects are followed automatically.

Error handling follows the same happy path philosophy as other ARO operations. If a request fails—connection refused, timeout, server error—the runtime generates an appropriate error message. You do not write explicit error handling for HTTP failures.

---

## 14.4 File System Service

The file system service provides operations for reading, writing, and monitoring files. It handles the mechanics of file I/O while you focus on what data to read or write.

Reading files uses the Read action with a file path. The action reads the file contents and binds them to a result. For JSON files, the content is parsed into a structured object. For text files, the content is a string. The path can be relative to the application directory or absolute.

Writing files uses the Write action with data and a path. The action serializes the data and writes it to the specified location. You can control the encoding and whether to create parent directories if they do not exist.

Additional operations check whether files exist, list directory contents, and delete files. These operations support file management tasks that applications commonly need.

File watching monitors a directory for changes and emits events when files are created, modified, or deleted. You start watching during Application-Start by specifying the directory to monitor. When changes occur, the runtime emits File Event events that your handlers can process. This is useful for applications that need to react to external file changes—configuration reloading, data import, file synchronization.

---

## 14.5 Socket Services

The socket server and client provide low-level TCP communication for applications that need more control than HTTP offers or that need to communicate using custom protocols.

The socket server listens for incoming TCP connections on a specified port. When clients connect and send data, the runtime emits Socket Event events. Your handlers receive the client identifier and the data, and can send responses back to specific clients or broadcast to all connected clients.

The socket client connects to remote TCP servers. You establish a connection, send data, receive responses, and close the connection when done. This is useful for communicating with services that use custom TCP protocols.

Socket communication is lower level than HTTP. You are responsible for message framing, serialization, and protocol handling. The services provide the transport; you provide the protocol logic.

For most web applications, HTTP is the appropriate choice. Use sockets when you need persistent connections, when you need to implement a specific protocol, or when HTTP overhead is unacceptable for your performance requirements.

---

## 14.6 Service Lifecycle

Services have a lifecycle that mirrors the application lifecycle. They start during Application-Start, run during the application's lifetime, and stop during Application-End.

Starting services is typically one of the first things you do during startup. You start the HTTP server to begin accepting requests. You start file monitoring to begin watching for changes. You start socket servers to begin accepting connections.

After starting services, you use the Keepalive action to keep the application running. Without it, the application would complete the startup sequence and exit. Keepalive blocks until a shutdown signal arrives, allowing services to process events.

When shutdown occurs, you stop services in your Application-End handler. Stopping in reverse order of starting is a common practice—resources started last are often dependencies of resources started first, so they should be stopped first.

The error shutdown handler (Application-End: Error) should also stop services, attempting best-effort cleanup even when an error has occurred. Services might be in inconsistent states, so cleanup should be defensive.

---

## 14.7 Service Configuration

Services accept configuration options that control their behavior. These options are passed when starting or using the service.

HTTP server configuration includes port and host for network binding, validation for request checking, timeout for request duration limits, body size limits, and CORS settings for browser access control. These options shape how the server behaves and what requests it accepts.

HTTP client configuration includes timeout for response waiting, retry for transient failure recovery, and redirect handling. These options affect outbound request behavior.

File system configuration includes encoding for text handling and directory creation settings. These options affect how files are read and written.

Configuration can be hardcoded in your ARO statements or loaded from external files during startup. Loading from external files allows configuration to vary between environments without code changes.

---

## 14.8 Practical Example: Services in Action

Here is a complete example demonstrating multiple built-in services working together. This application watches a directory for configuration changes and uses the HTTP client to report them to an external monitoring service.

```aro
(* Config Monitor - Watch files and report changes via HTTP *)

(Application-Start: Config Monitor) {
    <Log> the <message> for the <console> with "Starting configuration monitor...".

    (* Load the monitoring endpoint from environment or config *)
    <Create> the <webhook-url> with "https://monitoring.example.com/webhook".

    (* Start watching the config directory *)
    <Watch> the <file-monitor> for the <directory> with "./config".

    <Log> the <message> for the <console> with "Watching ./config for changes...".

    (* Keep running until shutdown signal *)
    <Keepalive> the <application> for the <events>.

    <Return> an <OK: status> for the <startup>.
}

(Report Config Change: File Event Handler) {
    (* Extract the changed file path *)
    <Extract> the <path> from the <event: path>.
    <Extract> the <event-type> from the <event: type>.

    <Log> the <message> for the <console> with "Config changed:".
    <Log> the <message> for the <console> with <path>.

    (* Build notification payload *)
    <Create> the <notification> with {
        file: <path>,
        change: <event-type>,
        timestamp: "now"
    }.

    (* Send to monitoring webhook *)
    <Send> the <notification> to the <webhook-url>.

    <Log> the <message> for the <console> with "Change reported to monitoring service.".

    <Return> an <OK: status> for the <event>.
}

(Application-End: Success) {
    <Log> the <message> for the <console> with "Config monitor stopped.".
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

## 14.9 Best Practices

Start all services during Application-Start. Centralizing service startup in one place makes it clear what your application depends on and ensures consistent initialization order.

Stop all services during Application-End. Both success and error handlers should attempt to stop services, releasing resources cleanly. The error handler should be defensive because resources might be in inconsistent states.

Use Keepalive for any application that runs services. Without it, the application starts services and immediately exits. The Keepalive action keeps the application running to process incoming events.

Handle service errors through event handlers when appropriate. Some services emit error events that you can handle to log failures, attempt recovery, or alert operators. The happy path philosophy applies, but observability is still important.

Configure services appropriately for your environment. Development might use permissive CORS settings and verbose logging. Production might use restrictive settings and minimal logging. Load configuration from environment-specific files rather than hardcoding.

---

*Next: Chapter 16 — Custom Actions*
