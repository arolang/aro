# Actions Reference

Complete reference for all built-in actions in ARO.

## Action Categories

| Category | Role | Data Flow |
|----------|------|-----------|
| REQUEST | Bring data in | External → Internal |
| OWN | Transform data | Internal → Internal |
| RESPONSE | Send results | Internal → External |
| EXPORT | Publish/persist | Internal → External |
| SERVICE | Control services | System operations |

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
<Extract> the <token> from the <request: headers Authorization>.
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

## Action Summary Table

| Action | Role | Prepositions |
|--------|------|--------------|
| Extract | REQUEST | from |
| Retrieve | REQUEST | from |
| Fetch | REQUEST | from |
| Read | REQUEST | from |
| Parse | REQUEST | from |
| Create | OWN | with |
| Compute | OWN | for, from |
| Transform | OWN | from |
| Validate | OWN | for |
| Compare | OWN | against |
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
| Start | SERVICE | on |
| Stop | SERVICE | - |
| Watch | SERVICE | as |
| Listen | SERVICE | on, as |
| Connect | SERVICE | to, on, as |
| Close | SERVICE | - |
| Flush | SERVICE | - |
| Call | SERVICE | via, with |
| Broadcast | SERVICE | to, with |
| Wait | SERVICE | for, with |
