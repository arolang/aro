# Actions Reference

Complete reference for all built-in actions in ARO.

## Quick Reference Table

| Action | Role | Description | Example |
|--------|------|-------------|---------|
| **Extract** | REQUEST | Pull data from structured source | `<Extract> the <id> from the <request: params>.` |
| **Retrieve** | REQUEST | Fetch from repository | `<Retrieve> the <user> from the <users> where id = <id>.` |
| **Request** | REQUEST | Make HTTP request | `<Request> the <data> from the <api-url>.` |
| **Fetch** | REQUEST | Fetch from external API | `<Fetch> the <weather> from <WeatherAPI: GET /forecast>.` |
| **Read** | REQUEST | Read from file | `<Read> the <config> from the <file: "./config.json">.` |
| **Parse** | REQUEST | Parse structured data | `<Parse> the <json> from the <raw-string>.` |
| **Receive** | REQUEST | Receive event data | `<Receive> the <message> from the <event>.` |
| **Exec** | REQUEST | Execute shell command | `<Exec> the <result> for the <command> with "ls -la".` |
| **Create** | OWN | Create new data | `<Create> the <user> with { name: "Alice" }.` |
| **Compute** | OWN | Perform calculations | `<Compute> the <total> for the <items>.` |
| **Transform** | OWN | Convert/map data | `<Transform> the <dto> from the <entity>.` |
| **Validate** | OWN | Check against rules | `<Validate> the <data> for the <schema>.` |
| **Compare** | OWN | Compare values | `<Compare> the <hash> against the <stored>.` |
| **Update** | OWN | Modify existing data | `<Update> the <user> with <changes>.` |
| **Map** | OWN | Transform collection elements | `<Map> the <names> from the <users: name>.` |
| **Filter** | OWN | Select matching elements | `<Filter> the <active> from the <users> where status = "active".` |
| **Reduce** | OWN | Aggregate collection | `<Reduce> the <total> from the <items> with sum(<amount>).` |
| **Sort** | OWN | Order collection | `<Sort> the <users> by <name>.` |
| **Merge** | OWN | Combine data | `<Merge> the <existing-user> with <update-data>.` |
| **Return** | RESPONSE | Return result | `<Return> an <OK: status> with <data>.` |
| **Throw** | RESPONSE | Throw error | `<Throw> a <NotFound: error> for the <user>.` |
| **Log** | EXPORT | Write to logs | `<Log> the <msg> for the <console> with "Done".` |
| **Store** | EXPORT | Save to repository | `<Store> the <user> into the <users>.` |
| **Write** | EXPORT | Write to file | `<Write> the <data> to the <file: "./out.txt">.` |
| **Send** | EXPORT | Send to destination | `<Send> the <email> to the <recipient>.` |
| **Emit** | EXPORT | Emit domain event | `<Emit> a <UserCreated: event> with <user>.` |
| **Publish** | EXPORT | Make globally available | `<Publish> as <config> <settings>.` |
| **Notify** | EXPORT | Send notification | `<Notify> the <alert> to the <admin>.` |
| **Delete** | EXPORT | Remove data | `<Delete> the <user> from the <users> where id = <id>.` |
| **Start** | SERVICE | Start a service | `<Start> the <http-server> on port 8080.` |
| **Listen** | SERVICE | Listen for connections | `<Listen> on port 9000 as <socket-server>.` |
| **Connect** | SERVICE | Connect to service | `<Connect> to <host: "db"> on port 5432.` |
| **Close** | SERVICE | Close connection | `<Close> the <connection>.` |
| **Watch** | SERVICE | Monitor directory | `<Watch> the <dir: "./uploads"> as <monitor>.` |
| **Broadcast** | SERVICE | Send to all connections | `<Broadcast> the <msg> to the <server>.` |
| **Route** | SERVICE | Define HTTP route | `<Route> the <handler> for "/api/users".` |
| **Keepalive** | SERVICE | Keep app running | `<Keepalive> the <app> for the <events>.` |
| **Call** | SERVICE | Call external API | `<Call> the <result> via <API: POST /users>.` |
| **Accept** | STATE | Accept state transition | `<Accept> the <order: placed>.` |
| **Given** | TEST | Test precondition | `<Given> the <user> with { name: "Test" }.` |
| **When** | TEST | Test action | `<When> the <action> is performed.` |
| **Then** | TEST | Test expectation | `<Then> the <result> should be <expected>.` |
| **Assert** | TEST | Assert condition | `<Assert> the <value> equals <expected>.` |

## Action Categories

| Category | Role | Data Flow |
|----------|------|-----------|
| REQUEST | Bring data in | External → Internal |
| OWN | Transform data | Internal → Internal |
| RESPONSE | Send results | Internal → External |
| EXPORT | Publish/persist | Internal → External |
| SERVICE | Control services | System operations |
| STATE | State transitions | Internal state changes |
| TEST | Testing | Verification actions |

---

## REQUEST Actions

### Extract

Pulls data from a structured source.

**Syntax:**
```aro
<Extract> the <result> from the <source: property>.
```

**Examples:**
```aro
<Extract> the <user-id> from the <request: parameters>.
<Extract> the <body> from the <request: body>.
<Extract> the <token> from the <request: headers.Authorization>.
<Extract> the <email> from the <user: email>.
<Extract> the <order> from the <event: order>.
```

**Valid Prepositions:** `from`

---

### Retrieve

Fetches data from a repository.

**Syntax:**
```aro
<Retrieve> the <result> from the <repository> [where <condition>].
```

**Examples:**
```aro
<Retrieve> the <user> from the <user-repository>.
<Retrieve> the <user> from the <user-repository> where id = <user-id>.
<Retrieve> the <orders> from the <order-repository> where status = "pending".
<Retrieve> the <products> from the <repository> where category = <cat> and active = true.
```

**Valid Prepositions:** `from`

---

### Fetch

Makes HTTP requests to external APIs.

**Syntax:**
```aro
<Fetch> the <result> from <url-or-api-reference>.
```

**Examples:**
```aro
<Fetch> the <data> from "https://api.example.com/resource".
<Fetch> the <users> from <UserAPI: GET /users>.
<Fetch> the <weather> from <WeatherAPI: GET /forecast?city=${city}>.
```

**Valid Prepositions:** `from`

---

### Request

Makes HTTP requests to external URLs or APIs.

**Syntax:**
```aro
<Request> the <result> from <url>.              (* GET request *)
<Request> the <result> to <url> with <data>.    (* POST request *)
<Request> the <result> via METHOD <url>.        (* Explicit method *)
```

**Examples:**
```aro
(* GET request *)
<Create> the <api-url> with "https://api.open-meteo.com/v1/forecast".
<Request> the <weather> from the <api-url>.

(* POST request *)
<Create> the <user-data> with { name: "Alice", email: "alice@example.com" }.
<Request> the <result> to the <api-url> with <user-data>.

(* PUT/DELETE/PATCH via explicit method *)
<Request> the <result> via PUT the <url> with <update-data>.
<Request> the <result> via DELETE the <url>.
```

**Response Metadata:**
After a request, these variables are available:
- `result` - Parsed response body (JSON as map/list, or string)
- `result.statusCode` - HTTP status code (e.g., 200, 404)
- `result.headers` - Response headers as map
- `result.isSuccess` - Boolean: true if status 200-299

**Valid Prepositions:** `from`, `to`, `via`

---

### Read

Reads from files.

**Syntax:**
```aro
<Read> the <result> from the <file: path>.
<Read> the <result: type> from the <file: path>.
```

**Examples:**
```aro
<Read> the <content> from the <file: "./data.txt">.
<Read> the <config: JSON> from the <file: "./config.json">.
<Read> the <image: bytes> from the <file: "./logo.png">.
```

**Valid Prepositions:** `from`

---

### Parse

Parses structured data from strings.

**Syntax:**
```aro
<Parse> the <result: type> from the <source>.
```

**Examples:**
```aro
<Parse> the <config: JSON> from the <json-string>.
<Parse> the <date> from the <date-string>.
<Parse> the <token> from the <auth-header> as "Bearer".
```

**Valid Prepositions:** `from`

---

### Exec

Executes shell commands on the host system and returns structured results.

**Syntax:**
```aro
<Exec> the <result> for the <command> with "command-string".
<Exec> the <result> for the <command> with <variable>.
<Exec> the <result> on the <system> with {
    command: "command-string",
    workingDirectory: "/path",
    timeout: 30000
}.
```

**Result Object:**
The Exec action returns a structured result with the following fields:
- `result.error` - Boolean: true if command failed (non-zero exit code)
- `result.message` - Human-readable status message
- `result.output` - Command stdout (or stderr if error)
- `result.exitCode` - Process exit code (0 = success, -1 = timeout)
- `result.command` - The executed command string

**Examples:**
```aro
(* Basic command execution *)
<Exec> the <listing> for the <command> with "ls -la".
<Return> an <OK: status> for the <listing>.

(* With error handling *)
<Exec> the <result> for the <disk-check> with "df -h".
<Log> the <error> for the <console> with <result.message> when <result.error> = true.
<Return> an <Error: status> for the <result> when <result.error> = true.
<Return> an <OK: status> for the <result>.

(* Using a variable for the command *)
<Create> the <cmd> with "ps aux | head -20".
<Exec> the <processes> for the <listing> with <cmd>.

(* With configuration options *)
<Exec> the <result> on the <system> with {
    command: "npm install",
    workingDirectory: "/app",
    timeout: 60000
}.
```

**Configuration Options:**
When using object syntax, these options are available:
- `command` (required) - The shell command to execute
- `workingDirectory` - Working directory (default: current)
- `timeout` - Timeout in milliseconds (default: 30000)
- `shell` - Shell to use (default: /bin/sh)
- `environment` - Additional environment variables as object

**Security Note:**
Be cautious when constructing commands from user input. Always validate and sanitize input to prevent command injection.

**Valid Prepositions:** `for`, `on`, `with`

---

## OWN Actions

### Create

Creates new data structures.

**Syntax:**
```aro
<Create> the <result> with <data>.
```

**Examples:**
```aro
<Create> the <user> with <user-data>.
<Create> the <response> with { message: "Success" }.
<Create> the <order> with {
    items: <items>,
    total: <total>,
    customer: <customer-id>
}.
```

**Valid Prepositions:** `with`

---

### Compute

Performs calculations.

**Syntax:**
```aro
<Compute> the <result> for the <input>.
<Compute> the <result> from <expression>.
```

**Examples:**
```aro
<Compute> the <total> for the <items>.
<Compute> the <hash> for the <password>.
<Compute> the <tax> for the <subtotal>.
<Compute> the <sum> from <a> + <b>.
```

**Valid Prepositions:** `for`, `from`

---

### Transform

Converts or maps data.

**Syntax:**
```aro
<Transform> the <result> from the <source>.
<Transform> the <result> from the <source> with <modifications>.
```

**Examples:**
```aro
<Transform> the <dto> from the <entity>.
<Transform> the <updated-user> from the <user> with <updates>.
<Transform> the <response> from the <data>.
```

**Valid Prepositions:** `from`

---

### Validate

Checks data against rules.

**Syntax:**
```aro
<Validate> the <data> for the <schema>.
```

**Examples:**
```aro
<Validate> the <user-data> for the <user-schema>.
<Validate> the <email> for the <email-pattern>.
<Validate> the <order> for the <order-rules>.
```

**Valid Prepositions:** `for`

---

### Compare

Compares two values.

**Syntax:**
```aro
<Compare> the <value1> against the <value2>.
```

**Examples:**
```aro
<Compare> the <password-hash> against the <stored-hash>.
<Compare> the <signature> against the <expected>.
```

**Valid Prepositions:** `against`

---

### Set

Assigns a value.

**Syntax:**
```aro
<Set> the <variable> to <value>.
```

**Examples:**
```aro
<Set> the <status> to "active".
<Set> the <count> to 0.
<Set> the <timestamp> to <current-time>.
```

**Valid Prepositions:** `to`

---

### Configure

Sets configuration values.

**Syntax:**
```aro
<Configure> the <setting> with <value>.
```

**Examples:**
```aro
<Configure> the <timeout> with 30.
<Configure> the <retry-limit> with 3.
```

**Valid Prepositions:** `with`

---

### Merge

Combines two data structures together. The source values are merged into the target, with source values overwriting target values for matching keys.

**Syntax:**
```aro
<Merge> the <target> with <source>.
<Merge> the <target> from <source>.
```

**Examples:**
```aro
(* Merge update data into existing entity *)
<Retrieve> the <existing-user> from the <user-repository> where id = <id>.
<Extract> the <update-data> from the <request: body>.
<Merge> the <existing-user> with <update-data>.
<Store> the <existing-user> into the <user-repository>.

(* Combine configuration objects *)
<Merge> the <defaults> with <overrides>.

(* Concatenate arrays *)
<Merge> the <all-items> with <new-items>.

(* Concatenate strings *)
<Merge> the <greeting> with <name>.
```

**Supported Types:**
- **Dictionaries**: Source keys overwrite target keys; other target keys preserved
- **Arrays**: Source elements appended to target array
- **Strings**: Source string concatenated to target string

**Valid Prepositions:** `with`, `into`, `from`

---

## RESPONSE Actions

### Return

Returns a result with status.

**Syntax:**
```aro
<Return> [article] <status> [with <data>] [for <context>].
```

**Examples:**
```aro
<Return> an <OK: status> with <data>.
<Return> a <Created: status> with <resource>.
<Return> a <NoContent: status> for the <deletion>.
<Return> a <BadRequest: status> with <errors>.
<Return> a <NotFound: status> for the <missing: user>.
```

**Valid Prepositions:** `with`, `for`

---

### Throw

Throws an error.

**Syntax:**
```aro
<Throw> [article] <error-type> for the <context>.
```

**Examples:**
```aro
<Throw> a <ValidationError> for the <invalid: input>.
<Throw> a <NotFoundError> for the <missing: user>.
<Throw> an <AuthenticationError> for the <invalid: token>.
```

**Valid Prepositions:** `for`

---

## EXPORT Actions

### Store

Saves to a repository.

**Syntax:**
```aro
<Store> the <data> into the <repository>.
```

**Examples:**
```aro
<Store> the <user> into the <user-repository>.
<Store> the <order> into the <order-repository>.
<Store> the <log-entry> into the <file: "./app.log">.
```

**Valid Prepositions:** `into`

---

### Publish

Makes variables globally available.

**Syntax:**
```aro
<Publish> as <alias> <variable>.
```

**Examples:**
```aro
<Publish> as <app-config> <config>.
<Publish> as <current-user> <user>.
```

**Valid Prepositions:** `as`

---

### Log

Writes to logs.

**Syntax:**
```aro
<Log> the <message-type> for the <destination> with <content>.
```

**Examples:**
```aro
<Log> the <message> for the <console> with "User logged in".
<Log> the <error: message> for the <console> with <error>.
<Log> the <audit: entry> for the <audit-log> with <details>.
```

**Valid Prepositions:** `for`, `with`

---

### Send

Sends data to external destinations.

**Syntax:**
```aro
<Send> the <data> to the <destination>.
<Send> the <data> to the <destination> with <content>.
```

**Examples:**
```aro
<Send> the <email> to the <user: email>.
<Send> the <notification> to the <push-service>.
<Send> the <data> to the <connection>.
<Send> the <message> to the <connection> with "Hello".
```

**Valid Prepositions:** `to`, `with`

---

### Emit

Emits domain events.

**Syntax:**
```aro
<Emit> [article] <event-type: event> with <data>.
```

**Examples:**
```aro
<Emit> a <UserCreated: event> with <user>.
<Emit> an <OrderPlaced: event> with <order>.
<Emit> a <PaymentProcessed: event> with <payment>.
```

**Valid Prepositions:** `with`

---

### Write

Writes to files.

**Syntax:**
```aro
<Write> the <data> to the <file: path>.
```

**Examples:**
```aro
<Write> the <content> to the <file: "./output.txt">.
<Write> the <data: JSON> to the <file: "./data.json">.
```

**Valid Prepositions:** `to`

---

### Delete

Removes data.

**Syntax:**
```aro
<Delete> the <target> from the <source> [where <condition>].
<Delete> the <file: path>.
```

**Examples:**
```aro
<Delete> the <user> from the <user-repository> where id = <user-id>.
<Delete> the <file: "./temp.txt">.
<Delete> the <sessions> from the <repository> where expired = true.
```

**Valid Prepositions:** `from`

---

## SERVICE Actions

### Start

Starts a service.

**Syntax:**
```aro
<Start> the <service> [on port <number>].
```

**Examples:**
```aro
<Start> the <http-server> on port 8080.
<Start> the <scheduler>.
<Start> the <background-worker>.
```

**Valid Prepositions:** `on`

---

### Stop

Stops a service.

**Syntax:**
```aro
<Stop> the <service>.
```

**Examples:**
```aro
<Stop> the <http-server>.
<Stop> the <scheduler>.
<Stop> the <file-watcher>.
```

**Valid Prepositions:** None

---

### Watch

Monitors a directory.

**Syntax:**
```aro
<Watch> the <directory: path> as <name>.
```

**Examples:**
```aro
<Watch> the <directory: "./uploads"> as <file-monitor>.
<Watch> the <directory: "./config"> as <config-watcher>.
```

**Valid Prepositions:** `as`

---

### Listen

Listens for connections.

**Syntax:**
```aro
<Listen> on port <number> as <name>.
```

**Examples:**
```aro
<Listen> on port 9000 as <socket-server>.
```

**Valid Prepositions:** `on`, `as`

---

### Connect

Connects to a service.

**Syntax:**
```aro
<Connect> to <host: address> on port <number> as <name>.
```

**Examples:**
```aro
<Connect> to <host: "localhost"> on port 5432 as <database>.
<Connect> to <host: "redis.local"> on port 6379 as <cache>.
```

**Valid Prepositions:** `to`, `on`, `as`

---

### Close

Closes connections.

**Syntax:**
```aro
<Close> the <connection>.
```

**Examples:**
```aro
<Close> the <database-connections>.
<Close> the <socket-server>.
<Close> the <connection>.
```

**Valid Prepositions:** None

---

### Flush

Flushes buffers.

**Syntax:**
```aro
<Flush> the <buffer>.
```

**Examples:**
```aro
<Flush> the <log-buffer>.
<Flush> the <cache>.
<Flush> the <pending-requests>.
```

**Valid Prepositions:** None

---

### Call

Makes API calls.

**Syntax:**
```aro
<Call> the <result> via <api-reference> [with <data>].
```

**Examples:**
```aro
<Call> the <result> via <UserAPI: POST /users> with <user-data>.
<Call> the <response> via <PaymentAPI: POST /charge> with <payment>.
```

**Valid Prepositions:** `via`, `with`

---

### Broadcast

Sends to all connections.

**Syntax:**
```aro
<Broadcast> the <message> to the <server>.
```

**Examples:**
```aro
<Broadcast> the <message> to the <socket-server>.
<Broadcast> the <notification> to the <chat-server> with "User joined".
```

**Valid Prepositions:** `to`, `with`

---

### Wait

Pauses execution.

**Syntax:**
```aro
<Wait> for <duration>.
<Wait> for the <async-operation> [with timeout <duration>].
```

**Examples:**
```aro
<Wait> for 5 seconds.
<Wait> for the <pending-requests> with timeout 30.
```

**Valid Prepositions:** `for`, `with`

---

### Keepalive

Keeps a long-running application alive to process events.

**Syntax:**
```aro
<Keepalive> the <application> for the <events>.
```

**Description:**
The `Keepalive` action blocks execution until a shutdown signal is received (SIGINT/SIGTERM). This is essential for applications that need to stay alive and process events, such as HTTP servers, file watchers, and socket servers.

**Examples:**
```aro
(Application-Start: My Server) {
    <Start> the <http-server> on port 8080.
    <Keepalive> the <application> for the <events>.
    <Return> an <OK: status> for the <startup>.
}

(Application-Start: File Watcher) {
    <Watch> the <directory> for the <changes> with "./watched".
    <Keepalive> the <application> for the <events>.
    <Return> an <OK: status> for the <startup>.
}
```

**Valid Prepositions:** `for`

---

## Action Summary Table

| Action | Role | Prepositions |
|--------|------|--------------|
| Extract | REQUEST | from |
| Retrieve | REQUEST | from |
| Request | REQUEST | from, to, via |
| Fetch | REQUEST | from |
| Read | REQUEST | from |
| Parse | REQUEST | from |
| Receive | REQUEST | from |
| Exec | REQUEST | for, on, with |
| Create | OWN | with |
| Compute | OWN | for, from |
| Transform | OWN | from |
| Validate | OWN | for |
| Compare | OWN | against |
| Update | OWN | with |
| Map | OWN | from |
| Filter | OWN | from, where |
| Reduce | OWN | from, with |
| Sort | OWN | by |
| Merge | OWN | with, into, from |
| Set | OWN | to |
| Configure | OWN | with |
| Return | RESPONSE | with, for |
| Throw | RESPONSE | for |
| Store | EXPORT | into |
| Publish | EXPORT | as |
| Log | EXPORT | for, with |
| Send | EXPORT | to, with |
| Emit | EXPORT | with |
| Write | EXPORT | to |
| Delete | EXPORT | from |
| Notify | EXPORT | to |
| Start | SERVICE | on |
| Stop | SERVICE | - |
| Watch | SERVICE | as |
| Listen | SERVICE | on, as |
| Connect | SERVICE | to, on, as |
| Close | SERVICE | - |
| Route | SERVICE | for |
| Call | SERVICE | via, with |
| Broadcast | SERVICE | to, with |
| Wait | SERVICE | for, with |
| Keepalive | SERVICE | for |
| Accept | STATE | - |
| Given | TEST | with |
| When | TEST | - |
| Then | TEST | - |
| Assert | TEST | equals, contains |
