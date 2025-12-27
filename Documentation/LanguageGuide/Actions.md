# Actions

Actions are the verbs of ARO. They describe what operation to perform on data. This chapter covers all built-in actions and how to use them effectively.

## Action Categories

ARO actions are organized by their **semantic role** - the direction of data flow:

| Role | Direction | Purpose |
|------|-----------|---------|
| REQUEST | External → Internal | Bring data into the feature set |
| OWN | Internal → Internal | Transform data within the feature set |
| RESPONSE | Internal → External | Send results back |
| EXPORT | Internal → External | Publish or persist data |

## REQUEST Actions

These actions bring data from external sources into your feature set.

### Extract

Pull data from a structured source:

```aro
<Extract> the <user-id> from the <request: parameters>.
<Extract> the <body> from the <request: body>.
<Extract> the <email> from the <user: email>.
<Extract> the <items> from the <order: lineItems>.
```

**Common Sources:**
- `<request: parameters>` - URL path parameters
- `<request: query>` - Query string parameters
- `<request: body>` - Request body
- `<request: headers>` - HTTP headers
- `<event: ...>` - Event data
- Any variable with properties

### Retrieve

Fetch data from a repository or data store:

```aro
<Retrieve> the <user> from the <user-repository>.
<Retrieve> the <user> from the <user-repository> where id = <user-id>.
<Retrieve> the <orders> from the <order-repository> where status = "pending".
<Retrieve> the <products> from the <product-repository> where category = <category>.
```

**With Conditions:**
```aro
<Retrieve> the <user> from the <user-repository>
    where email = <email> and active = true.
```

### Fetch

Make HTTP requests to external APIs:

```aro
<Fetch> the <data> from "https://api.example.com/resource".
<Fetch> the <users> from <UserAPI: GET /users>.
<Fetch> the <weather> from <WeatherAPI: GET /forecast?city=${city}>.
```

### Read

Read from files:

```aro
<Read> the <content> from the <file: "./data.txt">.
<Read> the <config: JSON> from the <file: "./config.json">.
<Read> the <data: bytes> from the <file: "./image.png">.
```

### Parse

Parse structured data:

```aro
<Parse> the <config: JSON> from the <json-string>.
<Parse> the <data: XML> from the <xml-string>.
<Parse> the <date> from the <date-string>.
```

## OWN Actions

These actions create or transform data within your feature set.

### Create

Create new data structures:

```aro
<Create> the <user> with <user-data>.
<Create> the <response> with { message: "Success", code: 200 }.
<Create> the <order> with {
    items: <items>,
    total: <total>,
    customer: <customer-id>
}.
```

### Compute

Perform calculations:

```aro
<Compute> the <total> for the <items>.
<Compute> the <hash> for the <password>.
<Compute> the <tax> for the <subtotal>.
<Compute> the <average> for the <values>.
```

### Transform

Convert or map data:

```aro
<Transform> the <dto> from the <entity>.
<Transform> the <response> from the <data>.
<Transform> the <updated-user> from the <user> with <updates>.
<Transform> the <formatted-date> from the <date>.
```

### Validate

Check data against rules:

```aro
<Validate> the <user-data> for the <user-schema>.
<Validate> the <email> for the <email-pattern>.
<Validate> the <order> for the <order-rules>.
```

Validation can fail, which should be handled:

```aro
<Validate> the <input> for the <schema>.
<Return> a <BadRequest: status> with <validation: errors> when <validation> is failed.
```

### Compare

Compare values:

```aro
<Compare> the <password-hash> against the <stored-hash>.
<Compare> the <signature> against the <expected-signature>.
<Compare> the <version> against the <minimum-version>.
```

### Set

Assign a value:

```aro
<Set> the <status> to "active".
<Set> the <count> to 0.
<Set> the <timestamp> to <current-time>.
```

### Configure

Set configuration values:

```aro
<Configure> the <timeout> with 30.
<Configure> the <retry-limit> with 3.
<Configure> the <debug-mode> with true.
```

## RESPONSE Actions

These actions send results back from your feature set.

### Return

Return a result with status:

```aro
(* Success responses *)
<Return> an <OK: status> with <data>.
<Return> a <Created: status> with <resource>.
<Return> a <NoContent: status> for the <deletion>.
<Return> an <Accepted: status> for the <async-operation>.

(* Error responses *)
<Return> a <BadRequest: status> with <errors>.
<Return> a <NotFound: status> for the <missing: resource>.
<Return> a <Forbidden: status> for the <unauthorized: access>.
<Return> an <Unauthorized: status> for the <invalid: credentials>.
```

**Status Codes:**

| Status | HTTP Code | Use Case |
|--------|-----------|----------|
| OK | 200 | Successful GET, PUT, PATCH |
| Created | 201 | Successful POST creating resource |
| Accepted | 202 | Async operation started |
| NoContent | 204 | Successful DELETE |
| BadRequest | 400 | Invalid input |
| Unauthorized | 401 | Missing/invalid auth |
| Forbidden | 403 | Insufficient permissions |
| NotFound | 404 | Resource not found |
| Conflict | 409 | Resource conflict |
| InternalError | 500 | Server error |

### Throw

Throw an error:

```aro
<Throw> a <ValidationError> for the <invalid: input>.
<Throw> a <NotFoundError> for the <missing: user>.
<Throw> an <AuthenticationError> for the <invalid: token>.
```

## EXPORT Actions

These actions publish data or send to external systems.

### Store

Save to a repository:

```aro
<Store> the <user> into the <user-repository>.
<Store> the <order> into the <order-repository>.
<Store> the <log-entry> into the <audit-log>.
```

### Publish

Make variables globally available:

```aro
<Publish> as <current-user> <user>.
<Publish> as <app-config> <config>.
<Publish> as <connection-pool> <pool>.
```

Published variables can be accessed from any feature set.

### Log

Write to logs:

```aro
<Log> the <message> for the <console> with "User logged in".
<Log> the <error: message> for the <console> with <error>.
<Log> the <audit: entry> for the <audit-log> with <details>.
```

### Send

Send data to external destinations:

```aro
<Send> the <email> to the <user: email>.
<Send> the <notification> to the <push-service>.
<Send> the <message> to the <queue>.
<Send> the <data> to the <connection>.
```

### Emit

Emit domain events:

```aro
<Emit> a <UserCreated: event> with <user>.
<Emit> an <OrderPlaced: event> with <order>.
<Emit> a <PaymentProcessed: event> with <payment>.
```

### Write

Write to files:

```aro
<Write> the <content> to the <file: "./output.txt">.
<Write> the <data: JSON> to the <file: "./data.json">.
```

### Delete

Remove data:

```aro
<Delete> the <user> from the <user-repository> where id = <user-id>.
<Delete> the <file: "./temp.txt">.
<Delete> the <sessions> from the <session-repository> where expired = true.
```

## Service Actions

These actions interact with runtime services.

### Start

Start a service:

```aro
<Start> the <http-server> on port 8080.
<Start> the <scheduler>.
<Start> the <background-worker>.
```

### Stop

Stop a service:

```aro
<Stop> the <http-server>.
<Stop> the <scheduler>.
<Stop> the <background-worker>.
```

### Watch

Monitor a directory:

```aro
<Watch> the <directory: "./uploads"> as <file-monitor>.
<Watch> the <directory: "./config"> as <config-watcher>.
```

### Listen

Listen for connections:

```aro
<Listen> on port 9000 as <socket-server>.
```

### Connect

Connect to a service:

```aro
<Connect> to <host: "localhost"> on port 5432 as <database>.
<Connect> to <host: "redis.local"> on port 6379 as <cache>.
```

### Close

Close connections:

```aro
<Close> the <database-connections>.
<Close> the <connection>.
```

### Flush

Flush buffers:

```aro
<Flush> the <log-buffer>.
<Flush> the <cache>.
```

### Call

Make API calls:

```aro
<Call> the <result> via <UserAPI: POST /users> with <user-data>.
<Call> the <response> via <PaymentAPI: POST /charge> with <payment>.
```

### Broadcast

Send to all connections:

```aro
<Broadcast> the <message> to the <socket-server>.
```

## Action Patterns

### Extract-Process-Return

Common pattern for request handlers:

```aro
(POST /users: User API) {
    (* Extract *)
    <Extract> the <user-data> from the <request: body>.

    (* Process *)
    <Validate> the <user-data> for the <user-schema>.
    <Create> the <user> with <user-data>.
    <Store> the <user> into the <user-repository>.

    (* Return *)
    <Return> a <Created: status> with <user>.
}
```

### Retrieve-Transform-Return

Pattern for GET requests:

```aro
(GET /users/{id}: User API) {
    (* Retrieve *)
    <Extract> the <user-id> from the <request: parameters>.
    <Retrieve> the <user> from the <user-repository> where id = <user-id>.

    (* Transform (optional) *)
    <Transform> the <user-dto> from the <user>.

    (* Return *)
    <Return> an <OK: status> with <user-dto>.
}
```

### Extract-Emit Pattern

Pattern for event-driven updates:

```aro
(POST /orders: Order API) {
    <Extract> the <order-data> from the <request: body>.
    <Create> the <order> with <order-data>.
    <Store> the <order> into the <order-repository>.

    (* Emit for other handlers *)
    <Emit> an <OrderCreated: event> with <order>.

    <Return> a <Created: status> with <order>.
}
```

## Next Steps

- [Variables and Data Flow](variables.html) - How data flows through actions
- [Control Flow](controlflow.html) - Conditional execution
- [Events](events.html) - Event-driven patterns
