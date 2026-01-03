# ARO-0008: I/O Services

* Proposal: ARO-0008
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0004, ARO-0005

## Abstract

This proposal defines ARO's input/output services: the System Objects protocol for reading and writing, HTTP server and client capabilities, file system operations, file monitoring, and socket communication. These services enable ARO applications to interact with the external world through a consistent source/sink pattern.

## Introduction

ARO applications communicate with the outside world through I/O services. This proposal establishes:

1. **System Objects Protocol**: A unified interface for sources (readable) and sinks (writable)
2. **HTTP Server**: Contract-first HTTP APIs via OpenAPI
3. **HTTP Client**: Outgoing HTTP requests to external services
4. **File System**: Reading, writing, and managing files with format-aware I/O
5. **File Monitoring**: Real-time file system change detection
6. **Socket Communication**: TCP server and client capabilities

### I/O Service Architecture

```
+------------------------------------------------------------------+
|                        ARO Application                            |
+------------------------------------------------------------------+
                               |
           +-------------------+-------------------+
           |                   |                   |
           v                   v                   v
+------------------+  +------------------+  +------------------+
|  System Objects  |  |   HTTP Services  |  | Socket Services  |
|                  |  |                  |  |                  |
|  - console       |  |  - Server        |  |  - Server        |
|  - stderr        |  |  - Client        |  |  - Client        |
|  - stdin         |  |                  |  |                  |
|  - file          |  +------------------+  +------------------+
|  - env           |           |                   |
+------------------+           v                   v
        |           +------------------+  +------------------+
        |           |   EventBus       |  |   EventBus       |
        v           |   (HTTP events)  |  |   (Socket events)|
+------------------++------------------+  +------------------+
|  File System     |
|                  |
|  - Read/Write    |
|  - Monitor       |
|  - Operations    |
+------------------+
```

---

## 1. System Objects Protocol

System objects provide a unified interface for ARO's built-in I/O targets. Objects are classified as **sources** (readable), **sinks** (writable), or **bidirectional**.

### 1.1 Object Categories

| Identifier | Type | Capabilities | Description |
|------------|------|--------------|-------------|
| `console` | Static | Sink | Standard output stream |
| `stderr` | Static | Sink | Standard error stream |
| `stdin` | Static | Source | Standard input stream |
| `env` | Static | Source | Environment variables |
| `file` | Dynamic | Both | File I/O (path in qualifier) |
| `request` | Context | Source | HTTP request (in HTTP handlers) |
| `pathParameters` | Context | Source | URL path parameters |
| `queryParameters` | Context | Source | URL query parameters |
| `headers` | Context | Source | HTTP headers |
| `body` | Context | Source | Request body |
| `connection` | Context | Both | Socket connection |
| `event` | Context | Source | Event payload |

### 1.2 Source and Sink Semantics

```
SOURCES (read FROM)                    SINKS (write TO)
+-------------------+                  +-------------------+
|                   |                  |                   |
|  stdin            |                  |  console          |
|  env              |   Readable       |  stderr           |   Writable
|  request          |      |           |                   |      |
|  pathParameters   |      |           +-------------------+      |
|  queryParameters  |      |                                      |
|  headers          |      |           BIDIRECTIONAL               |
|  body             |      |           +-------------------+       |
|  event            |      |           |                   |       |
|                   |      +---------> |  file             | <-----+
+-------------------+                  |  connection       |
                                       |                   |
                                       +-------------------+
```

### 1.3 Sink Syntax

For sink operations, the data comes first, followed by the destination:

```aro
(* Log to console - data "to" destination *)
<Log> "Starting server..." to the <console>.
<Log> "Error occurred" to the <stderr>.

(* Log variable to console *)
<Log> <message> to the <console>.

(* Write to file *)
<Write> <data> to the <file: "./output.json">.
<Write> { name: "Alice", age: 30 } to the <file: "./user.yaml">.

(* Send to socket *)
<Send> <message> to the <connection>.
<Send> "PONG" to the <connection>.
```

### 1.4 Source Syntax

For source operations, the result variable is bound from the source:

```aro
(* Read from file *)
<Read> the <config> from the <file: "./config.yaml">.

(* Extract from HTTP request context *)
<Extract> the <id> from the <pathParameters: id>.
<Extract> the <data> from the <body>.
<Extract> the <auth> from the <headers: Authorization>.

(* Get from environment *)
<Get> the <api-key> from the <env: "API_KEY">.

(* Read from stdin *)
<Read> the <input> from the <stdin>.
```

### 1.5 Built-in Object Behaviors

#### Console and Stderr

Write-only streams for output. The console object supports qualifier-based stream selection:

```aro
(* stdout (default) *)
<Log> "Application starting..." to the <console>.

(* stdout (explicit) *)
<Log> "Processing data..." to the <console: output>.

(* stderr for errors/warnings *)
<Log> "Warning: deprecated feature used" to the <console: error>.

(* Backward compatibility - direct stderr object still works *)
<Log> "Error message" to the <stderr>.
```

**Use cases for stderr:**
- Error messages that should be captured separately
- Warnings and diagnostic output
- Progress indicators that shouldn't pollute stdout data
- Logging in data pipeline applications where stdout contains actual data

**Stream redirection examples:**

```bash
# Separate streams
aro run ./MyApp 1> output.dat 2> errors.log

# Combine streams
aro run ./MyApp 2>&1 | tee combined.log

# Discard errors
aro run ./MyApp 2> /dev/null
```

#### Environment Variables

Read-only access to process environment:

```aro
(* Get specific variable *)
<Get> the <api-key> from the <env: "API_KEY">.
<Get> the <port> from the <env: "PORT">.

(* Get all environment variables *)
<Get> the <all-env> from the <env>.
```

#### File Object

Dynamic object created with path qualifier (covered in detail in Section 4):

```aro
(* Read with format detection *)
<Read> the <config> from the <file: "./config.yaml">.

(* Write with format serialization *)
<Write> <data> to the <file: "./output.json">.
```

---

## 2. HTTP Server

ARO uses **contract-first** HTTP API development. Routes are defined in an OpenAPI specification, and the HTTP server starts automatically when the contract exists.

### 2.1 Contract-First Architecture

```
+------------------+     +------------------+     +------------------+
|   openapi.yaml   | --> |   Application    | --> |   HTTP Server    |
|                  |     |   Loader         |     |   (SwiftNIO)     |
|   paths:         |     |                  |     |                  |
|     /users:      |     |   - Load spec    |     |   - Listen 8080  |
|       get:       |     |   - Match ops    |     |   - Route events |
|         opId:    |     |   - Validate     |     |   - Publish to   |
|         listUsers|     |                  |     |     EventBus     |
+------------------+     +------------------+     +------------------+
                                   |
                                   v
                         +------------------+
                         |   Feature Sets   |
                         |                  |
                         |  (listUsers)     |
                         |  (createUser)    |
                         |  (getUser)       |
                         +------------------+
```

### 2.2 OpenAPI Contract

Routes are defined in `openapi.yaml` (or `.yml`/`.json`), not in ARO code:

```yaml
# openapi.yaml
openapi: 3.0.3
info:
  title: User API
  version: 1.0.0

paths:
  /users:
    get:
      operationId: listUsers
      summary: List all users
      responses:
        '200':
          description: Success
    post:
      operationId: createUser
      summary: Create a user
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/CreateUserRequest'
      responses:
        '201':
          description: Created

  /users/{id}:
    get:
      operationId: getUser
      summary: Get user by ID
      parameters:
        - name: id
          in: path
          required: true
          schema:
            type: string
      responses:
        '200':
          description: Success
```

### 2.3 Feature Set Naming

Feature sets **must be named after the `operationId`** from the OpenAPI spec:

```aro
(* Feature set name = operationId from openapi.yaml *)

(listUsers: User API) {
    <Retrieve> the <users> from the <user-repository>.
    <Return> an <OK: status> with <users>.
}

(createUser: User API) {
    <Extract> the <data> from the <body>.
    <Validate> the <data> for the <user-schema>.
    <Create> the <user> with <data>.
    <Store> the <user> into the <user-repository>.
    <Return> a <Created: status> with <user>.
}

(getUser: User API) {
    <Extract> the <id> from the <pathParameters: id>.
    <Retrieve> the <user> from the <user-repository> where id = <id>.
    <Return> an <OK: status> with <user>.
}
```

### 2.4 Automatic Server Startup

The HTTP server starts automatically when:

1. An `openapi.yaml` (or `.yml`/`.json`) file exists in the application directory
2. At least one route is defined in the OpenAPI document
3. Feature sets with matching `operationId` names exist

**No explicit `<Start>` action is required for the HTTP server.**

```aro
(Application-Start: User API) {
    <Log> "User API starting..." to the <console>.

    (* HTTP server starts automatically from openapi.yaml *)
    (* Keep running to handle requests *)
    <Keepalive> the <application> for the <events>.

    <Return> an <OK: status> for the <startup>.
}
```

### 2.5 Request Data Access

Access request data via context objects:

| Object | Description |
|--------|-------------|
| `pathParameters` | Path parameters from URL (e.g., `/users/{id}`) |
| `pathParameters: {name}` | Individual path parameter |
| `queryParameters` | Query string parameters |
| `body` | Parsed request body (JSON) |
| `headers` | Request headers |

```aro
(getUser: User API) {
    (* Path parameter from /users/{id} *)
    <Extract> the <user-id> from the <pathParameters: id>.

    (* Query parameters *)
    <Extract> the <include-details> from the <queryParameters: details>.

    <Retrieve> the <user> from the <user-repository> where id = <user-id>.
    <Return> an <OK: status> with <user>.
}

(createUser: User API) {
    (* Request body parsed as JSON *)
    <Extract> the <data> from the <body>.
    <Extract> the <name> from the <data: name>.
    <Extract> the <email> from the <data: email>.

    <Create> the <user> with <data>.
    <Return> a <Created: status> with <user>.
}
```

### 2.6 Response Building

Return responses with standard HTTP status codes:

```aro
(* Success responses *)
<Return> an <OK: status> with <data>.           (* 200 *)
<Return> a <Created: status> with <resource>.   (* 201 *)
<Return> a <NoContent: status> for the <action>.(* 204 *)

(* Error responses *)
<Return> a <BadRequest: status> with <errors>.  (* 400 *)
<Return> a <NotFound: status> for the <resource>.(* 404 *)
<Return> a <Forbidden: status> for the <access>.(* 403 *)
```

### 2.7 Server Behavior

**Without OpenAPI Contract:**
```
$ aro run ./MyApp
No openapi.yaml found - HTTP server disabled
Application running (no HTTP routes available)
```

**With OpenAPI Contract:**
```
$ aro run ./MyApp
Loading openapi.yaml...
Validating contract against feature sets...
  + listUsers -> GET /users
  + createUser -> POST /users
  + getUser -> GET /users/{id}
HTTP Server started on port 8080
```

**Missing Feature Sets:**
```
Error: Missing ARO feature set handlers for the following operations:
  - GET /users requires feature set named 'listUsers'
  - POST /users requires feature set named 'createUser'

Create feature sets with names matching the operationIds in your OpenAPI contract.
```

---

## 3. HTTP Client

The HTTP client enables outgoing requests to external services.

### 3.1 GET Requests

Use `<Request>` with `from` preposition:

```aro
(* GET request *)
<Request> the <response> from the <url>.

(* With variable URL *)
<Create> the <api-url> with "https://api.example.com/users".
<Request> the <users> from the <api-url>.
```

### 3.2 POST Requests

Use `<Request>` with `to` preposition:

```aro
(* POST request - body from context *)
<Request> the <result> to the <url> with <data>.

(* POST with JSON body *)
<Create> the <user-data> with { name: "Alice", email: "alice@example.com" }.
<Request> the <created-user> to the <api-url> with <user-data>.
```

### 3.3 Other HTTP Methods

Use `<Request>` with `via` preposition and method specifier:

```aro
(* PUT request *)
<Request> the <result> via PUT the <url> with <data>.

(* DELETE request *)
<Request> the <result> via DELETE the <url>.

(* PATCH request *)
<Request> the <result> via PATCH the <url> with <partial-data>.
```

### 3.4 Config Object Syntax

Use `with { ... }` to specify custom headers, method, body, and timeout:

```aro
(* POST with custom headers *)
<Request> the <response> from the <api-url> with {
    method: "POST",
    headers: { "Content-Type": "application/json", "Authorization": "Bearer token" },
    body: <data>,
    timeout: 60
}.

(* GET with authorization header *)
<Request> the <protected-data> from the <api-url> with {
    headers: { "Authorization": "Bearer my-token" }
}.

(* POST with custom timeout *)
<Request> the <result> from the <api-url> with {
    method: "POST",
    body: { name: "Alice", email: "alice@example.com" },
    timeout: 120
}.
```

**Config Options:**

| Option | Type | Description |
|--------|------|-------------|
| `method` | String | HTTP method: GET, POST, PUT, DELETE, PATCH |
| `headers` | Map | Custom HTTP headers |
| `body` | String/Map | Request body (auto-serialized to JSON if map) |
| `timeout` | Number | Request timeout in seconds (default: 30) |

### 3.5 Response Data

The `<Request>` action automatically:
- Parses JSON responses into ARO maps/lists
- Returns raw string for non-JSON responses
- Binds response metadata to result variables

**Response Variables:**

| Variable | Description |
|----------|-------------|
| `result` | Parsed response body (JSON as map/list, or string) |
| `result.statusCode` | HTTP status code (e.g., 200, 404) |
| `result.headers` | Response headers as map |
| `result.isSuccess` | Boolean: true if status 200-299 |

```aro
<Request> the <response> from "https://api.example.com/users".
<Extract> the <status> from the <response: statusCode>.
<Extract> the <users> from the <response>.
```

### 3.6 HTTP Client Example

```aro
(Fetch Weather: External API) {
    <Create> the <api-url> with "https://api.open-meteo.com/v1/forecast?latitude=52.52&longitude=13.41&current_weather=true".
    <Request> the <weather> from the <api-url>.
    <Extract> the <temperature> from the <weather: current_weather temp>.
    <Return> an <OK: status> with <temperature>.
}

(Create External User: User API) {
    <Extract> the <user-data> from the <body>.
    <Request> the <created> to "https://external-api.com/users" with <user-data>.
    <Return> a <Created: status> with <created>.
}
```

---

## 4. File System

ARO provides comprehensive file system operations with automatic format detection based on file extensions.

### 4.1 Basic File Operations

#### Reading Files

```aro
(* Read file contents *)
<Read> the <contents> from the <file: "./config.json">.

(* With path variable *)
<Create> the <config-path> with "./config.json".
<Read> the <config> from the <file: config-path>.
```

#### Writing Files

```aro
(* Write content to file *)
<Write> <content> to the <file: "./output.txt">.

(* Append to file *)
<Append> <log-entry> to the <file: "./logs/app.log">.
```

### 4.2 Format-Aware I/O

ARO automatically detects file format from the extension and serializes/deserializes accordingly:

```
+----------+     +------------------+     +------------+
|  Object  | --> | Format Detector  | --> | Serializer | --> File
+----------+     | (by extension)   |     +------------+
                 +------------------+

        +------------------+     +--------------+     +----------+
File -> | Format Detector  | --> | Deserializer | --> |  Object  |
        | (by extension)   |     +--------------+     +----------+
        +------------------+
```

#### Supported Formats

| Extension | Format | Description |
|-----------|--------|-------------|
| `.json` | JSON | JavaScript Object Notation |
| `.jsonl`, `.ndjson` | JSON Lines | Newline-delimited JSON |
| `.yaml`, `.yml` | YAML | YAML Ain't Markup Language |
| `.xml` | XML | Extensible Markup Language |
| `.toml` | TOML | Tom's Obvious Minimal Language |
| `.csv` | CSV | Comma-Separated Values |
| `.tsv` | TSV | Tab-Separated Values |
| `.md` | Markdown | Simple markdown tables |
| `.html` | HTML | HTML table elements |
| `.txt` | Plain Text | Key=value format |
| `.sql` | SQL | INSERT statements |
| `.log` | Log | Date-prefixed log entries |
| `.env` | Environment | KEY=VALUE format |
| (unknown) | Binary | Default for unknown extensions |

#### Format Examples

**JSON (.json):**
```aro
<Write> <users> to the <file: "./data/users.json">.
```
Output:
```json
[
  {"id": 1, "name": "Alice"},
  {"id": 2, "name": "Bob"}
]
```

**YAML (.yaml):**
```aro
<Write> <config> to the <file: "./settings.yaml">.
```
Output:
```yaml
id: 1
name: Alice
```

**CSV (.csv):**
```aro
<Write> <records> to the <file: "./report.csv">.
```
Output:
```csv
id,name
1,Alice
2,Bob
```

**JSON Lines (.jsonl):**
```aro
<Write> <logs> to the <file: "./events.jsonl">.
```
Output:
```
{"id":1,"name":"Alice"}
{"id":2,"name":"Bob"}
```

#### CSV/TSV Options

```aro
(* Custom delimiter *)
<Write> <data> to the <file: "./export.csv"> with { delimiter: ";" }.

(* Without header row *)
<Write> <data> to the <file: "./export.csv"> with { header: false }.

(* Reading with options *)
<Read> the <data> from the <file: "./import.csv"> with { delimiter: ";", header: false }.
```

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `delimiter` | String | `,` (CSV) / `\t` (TSV) | Field separator |
| `header` | Boolean | `true` | Include/expect header row |
| `quote` | String | `"` | Quote character |
| `encoding` | String | `UTF-8` | Text encoding |

#### Raw String Override

Bypass format detection with `as String` qualifier:

```aro
(* Parse JSON to structured data *)
<Read> the <config> from the <file: "./settings.json">.

(* Read raw JSON as string - no parsing *)
<Read> the <raw-json: as String> from the <file: "./settings.json">.
```

### 4.3 Directory Operations

#### List Directory Contents

```aro
(* List all entries *)
<List> the <entries> from the <directory: "./uploads">.

(* List with glob pattern *)
<List> the <aro-files> from the <directory: "./src"> matching "*.aro".

(* List recursively *)
<List> the <all-files> from the <directory: "./project"> recursively.

(* Combine pattern and recursive *)
<List> the <sources> from the <directory: "./src"> matching "*.swift" recursively.
```

Entry structure:
```
{
    name: "filename.txt",
    path: "/full/path/to/filename.txt",
    isFile: true,
    isDirectory: false,
    size: 1024,
    modified: "2024-12-27T14:22:00Z"
}
```

#### File/Directory Metadata

```aro
(* Get file info *)
<Stat> the <info> for the <file: "./document.pdf">.

(* Access metadata *)
<Log> <info: size> to the <console>.
<Log> <info: modified> to the <console>.
```

Metadata structure:
```
{
    name: "filename.txt",
    path: "/full/path/to/filename.txt",
    size: 1024,
    isFile: true,
    isDirectory: false,
    created: "2024-01-15T10:30:00Z",
    modified: "2024-12-27T14:22:00Z",
    accessed: "2024-12-27T15:00:00Z",
    permissions: "rw-r--r--"
}
```

#### Existence Check

```aro
(* Check file existence *)
<Exists> the <found> for the <file: "./config.json">.

(* Check directory existence *)
<Exists> the <dir-exists> for the <directory: "./output">.
```

#### Create Directory

```aro
(* Create a directory (including intermediates) *)
<Make> the <directory> at the <path: "./output/reports/2024">.

(* Create or touch a file *)
<Touch> the <file> at the <path: "./logs/app.log">.

(* Check and create *)
<Exists> the <exists> for the <directory: "./cache">.
<Make> the <cache-dir> at the <path: "./cache"> when <exists> is false.
```

#### Copy and Move

```aro
(* Copy a file *)
<Copy> the <file: "./template.txt"> to the <destination: "./copy.txt">.

(* Copy a directory recursively *)
<Copy> the <directory: "./src"> to the <destination: "./backup/src">.

(* Move/rename a file *)
<Move> the <file: "./draft.txt"> to the <destination: "./final.txt">.

(* Move to different directory *)
<Move> the <file: "./inbox/report.pdf"> to the <destination: "./archive/report.pdf">.
```

### 4.4 Path Handling

ARO normalizes paths for cross-platform compatibility:

| Aspect | Behavior |
|--------|----------|
| Separator | Always use `/` in ARO code |
| Translation | Converted to `\` on Windows automatically |
| Relative paths | Resolved from working directory |
| Absolute paths | Preserved as-is |

---

## 5. File Monitoring

ARO provides real-time file system change detection through the `<Watch>` action.

### 5.1 Watch Action

```aro
(* Watch a directory for changes *)
<Watch> the <file-monitor> for the <directory> with "./watched".

(* Watch current directory *)
<Watch> the <file-monitor> for the <directory> with ".".
```

**Behavior:**
- Watches the specified directory recursively
- Emits events when file content changes (create, modify, delete)
- Runs asynchronously - does not block execution
- Continues monitoring until application shutdown

### 5.2 File Event Types

| Event | Trigger | Data |
|-------|---------|------|
| `FileCreatedEvent` | New file created | `path` - file path |
| `FileModifiedEvent` | File content changed | `path` - file path |
| `FileDeletedEvent` | File removed | `path` - file path |

### 5.3 Event Handlers

Feature sets with business activity `File Event Handler` receive file events:

| Feature Set Name | Handles Event |
|------------------|---------------|
| `Handle File Created` | `FileCreatedEvent` |
| `Handle File Modified` | `FileModifiedEvent` |
| `Handle File Deleted` | `FileDeletedEvent` |

```aro
(Handle File Created: File Event Handler) {
    <Extract> the <path> from the <event: path>.
    <Log> "File created: " to the <console>.
    <Log> <path> to the <console>.
    <Return> an <OK: status> for the <event>.
}

(Handle File Modified: File Event Handler) {
    <Extract> the <path> from the <event: path>.
    <Log> "File modified: " to the <console>.
    <Log> <path> to the <console>.
    <Return> an <OK: status> for the <event>.
}

(Handle File Deleted: File Event Handler) {
    <Extract> the <path> from the <event: path>.
    <Log> "File deleted: " to the <console>.
    <Log> <path> to the <console>.
    <Return> an <OK: status> for the <event>.
}
```

### 5.4 Platform-Specific Implementation

| Platform | API | Characteristics |
|----------|-----|-----------------|
| macOS | FSEvents | Kernel-level, ~0.5s latency, recursive |
| Linux | inotify | Kernel-based, per-directory watches |
| Other | Polling | 1-second interval, higher CPU usage |

### 5.5 Complete File Watcher Example

```aro
(Application-Start: File Watcher) {
    <Log> "Starting file watcher" to the <console>.

    (* Watch the current directory for changes *)
    <Watch> the <file-monitor> for the <directory> with ".".

    <Log> "Watching for file changes... Press Ctrl+C to stop." to the <console>.

    (* Keep the application running until Ctrl+C *)
    <Keepalive> the <application> for the <events>.

    <Return> an <OK: status> for the <startup>.
}

(Handle File Created: File Event Handler) {
    <Extract> the <path> from the <event: path>.
    <Log> "[Created] " to the <console>.
    <Log> <path> to the <console>.
    <Return> an <OK: status> for the <event>.
}

(Handle File Modified: File Event Handler) {
    <Extract> the <path> from the <event: path>.
    <Log> "[Modified] " to the <console>.
    <Log> <path> to the <console>.
    <Return> an <OK: status> for the <event>.
}

(Handle File Deleted: File Event Handler) {
    <Extract> the <path> from the <event: path>.
    <Log> "[Deleted] " to the <console>.
    <Log> <path> to the <console>.
    <Return> an <OK: status> for the <event>.
}

(Application-End: Success) {
    <Log> "File watcher stopped." to the <console>.
    <Return> an <OK: status> for the <shutdown>.
}
```

---

## 6. Socket Communication

ARO provides TCP socket server and client capabilities for bidirectional real-time communication.

### 6.1 Socket Server

Start a TCP socket server using the `<Listen>` action:

```aro
(Application-Start: Echo Server) {
    <Log> "Starting socket server" to the <console>.
    <Listen> on port 9000 as <socket-server>.
    <Keepalive> the <application> for the <events>.
    <Return> an <OK: status> for the <startup>.
}
```

### 6.2 Socket Events

| Event | Trigger | Data |
|-------|---------|------|
| `ClientConnectedEvent` | Client connects | `connectionId`, `remoteAddress`, `localPort` |
| `DataReceivedEvent` | Data received | `connectionId`, `data` |
| `ClientDisconnectedEvent` | Client disconnects | `connectionId`, `reason` |

### 6.3 Socket Event Handlers

```aro
(Handle Client Connected: Socket Event Handler) {
    <Extract> the <client-id> from the <event: connectionId>.
    <Extract> the <remote-address> from the <event: remoteAddress>.
    <Log> "Client connected: " to the <console>.
    <Log> <remote-address> to the <console>.
    <Return> an <OK: status> for the <connection>.
}

(Handle Data Received: Socket Event Handler) {
    <Extract> the <data> from the <event: data>.
    <Extract> the <client> from the <event: connection>.

    (* Process received data *)
    <Transform> the <response> from the <data>.

    (* Send response back *)
    <Send> <response> to the <client>.

    <Return> an <OK: status> for the <event>.
}

(Handle Client Disconnected: Socket Event Handler) {
    <Extract> the <client-id> from the <event: connectionId>.
    <Log> "Client disconnected: " to the <console>.
    <Log> <client-id> to the <console>.
    <Return> an <OK: status> for the <event>.
}
```

### 6.4 Socket Client

Connect to external services:

```aro
(Connect to Service: Socket Client) {
    <Connect> to <host: "192.168.1.100"> on port 8080 as <service-connection>.
    <Send> <handshake-data> to the <service-connection>.
    <Return> an <OK: status> for the <connection>.
}
```

### 6.5 Socket Operations

```aro
(* Send data to a specific connection *)
<Send> <data> to the <connection>.

(* Send to all connected clients *)
<Broadcast> <message> to the <socket-server>.

(* Close a connection *)
<Close> the <connection>.
```

### 6.6 Complete Echo Server Example

```aro
(* Echo Socket Server - Bidirectional TCP communication *)

(Application-Start: Echo Socket) {
    <Log> "Starting echo socket on port 9000" to the <console>.
    <Listen> on port 9000 as <socket-server>.
    <Log> "Socket server listening on port 9000" to the <console>.
    <Keepalive> the <application> for the <events>.
    <Return> an <OK: status> for the <startup>.
}

(Handle Client Connected: Socket Event Handler) {
    <Extract> the <client-id> from the <event: connectionId>.
    <Extract> the <remote-address> from the <event: remoteAddress>.
    <Log> "Client connected" to the <console>.
    <Return> an <OK: status> for the <connection>.
}

(Handle Data Received: Socket Event Handler) {
    <Extract> the <data> from the <event: data>.
    <Extract> the <client> from the <event: connection>.

    (* Echo back the received data *)
    <Send> <data> to the <client>.

    <Log> "Echoed data back to client" to the <console>.
    <Return> an <OK: status> for the <event>.
}

(Handle Client Disconnected: Socket Event Handler) {
    <Extract> the <client-id> from the <event: connectionId>.
    <Log> "Client disconnected" to the <console>.
    <Return> an <OK: status> for the <event>.
}
```

---

## 7. Complete Examples

### 7.1 HTTP API with File Persistence

```aro
(* main.aro *)

(Application-Start: User Service) {
    <Log> "User Service starting..." to the <console>.
    <Keepalive> the <application> for the <events>.
    <Return> an <OK: status> for the <startup>.
}

(listUsers: User API) {
    <Read> the <users> from the <file: "./data/users.json">.
    <Return> an <OK: status> with <users>.
}

(createUser: User API) {
    <Extract> the <data> from the <body>.

    (* Load existing users *)
    <Read> the <users> from the <file: "./data/users.json">.

    (* Add new user *)
    <Create> the <user> with <data>.
    <Append> the <user> to the <users>.

    (* Save back to file *)
    <Write> <users> to the <file: "./data/users.json">.

    <Return> a <Created: status> with <user>.
}

(getUser: User API) {
    <Extract> the <id> from the <pathParameters: id>.
    <Read> the <users> from the <file: "./data/users.json">.
    <Filter> the <user> from <users> where <id> matches <id>.
    <Return> an <OK: status> with <user>.
}
```

### 7.2 File Processor with External API

```aro
(Application-Start: File Processor) {
    <Log> "Starting file processor" to the <console>.
    <Watch> the <file-monitor> for the <directory> with "./inbox".
    <Keepalive> the <application> for the <events>.
    <Return> an <OK: status> for the <startup>.
}

(Handle File Created: File Event Handler) {
    <Extract> the <path> from the <event: path>.

    (* Read the new file *)
    <Read> the <content> from the <file: path>.

    (* Send to external API for processing *)
    <Request> the <result> to "https://api.processor.com/analyze" with <content>.

    (* Write processed result *)
    <Create> the <output-path> with "./outbox/processed.json".
    <Write> <result> to the <file: output-path>.

    <Log> "Processed: " to the <console>.
    <Log> <path> to the <console>.
    <Return> an <OK: status> for the <processing>.
}
```

### 7.3 Data Format Converter

```aro
(Application-Start: Data Converter) {
    (* Read CSV data *)
    <Read> the <records> from the <file: "./input/data.csv">.

    (* Write to multiple formats *)
    <Write> <records> to the <file: "./output/data.json">.
    <Write> <records> to the <file: "./output/data.yaml">.
    <Write> <records> to the <file: "./output/report.md">.
    <Write> <records> to the <file: "./output/backup.sql">.

    <Log> "Converted data to 4 formats" to the <console>.
    <Return> an <OK: status> for the <conversion>.
}
```

---

## 8. Grammar Extensions

### 8.1 Sink Action Syntax

```ebnf
sink_statement = action_verb , expression , "to" , [article] , object_noun , "." ;

expression = string_literal
           | variable_reference
           | object_literal
           | array_literal ;
```

### 8.2 Socket Operations

```ebnf
listen_statement = "<Listen>" , "on" , "port" , integer , "as" , identifier , "." ;
connect_statement = "<Connect>" , "to" , host_reference , "on" , "port" , integer , "as" , identifier , "." ;
send_statement = "<Send>" , expression , "to" , "the" , identifier , "." ;
broadcast_statement = "<Broadcast>" , expression , "to" , "the" , identifier , "." ;
close_statement = "<Close>" , "the" , identifier , "." ;

host_reference = "host:" , string_literal ;
```

### 8.3 File Operations

```ebnf
read_statement = "<Read>" , "the" , result , "from" , "the" , file_object , "." ;
write_statement = "<Write>" , expression , "to" , "the" , file_object , "." ;
list_statement = "<List>" , "the" , result , "from" , "the" , directory_object , [matching_clause] , [recursive_clause] , "." ;
stat_statement = "<Stat>" , "the" , result , "for" , "the" , file_or_directory , "." ;
exists_statement = "<Exists>" , "the" , result , "for" , "the" , file_or_directory , "." ;
make_statement = "<Make>" , "the" , type , "at" , "the" , path_object , "." ;
copy_statement = "<Copy>" , "the" , source , "to" , "the" , destination , "." ;
move_statement = "<Move>" , "the" , source , "to" , "the" , destination , "." ;
append_statement = "<Append>" , expression , "to" , "the" , file_object , "." ;

file_object = "<file:" , string_literal , ">" ;
directory_object = "<directory:" , string_literal , ">" ;
matching_clause = "matching" , string_literal ;
recursive_clause = "recursively" ;
```
