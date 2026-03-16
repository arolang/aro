# Action Reference

ARO provides **60 built-in actions** organized by semantic role — the direction data flows through the statement.

| Role | Direction | Count |
|------|-----------|-------|
| **REQUEST** | External → Feature set | 11 |
| **OWN** | Inside the feature set | 19 |
| **RESPONSE** | Feature set → Caller | 2 |
| **EXPORT** | Feature set → Persistent / Event bus | 9 |
| **FILE** | File system | 3 |
| **TERMINAL** | Interactive terminal UI | 4 |
| **SERVICE** | Infrastructure lifecycle | 7 |
| **TEST** | BDD testing framework | 4 |
| **SCHEDULE** | Timed events | 1 |

---

## REQUEST Actions

Pull data from an external source into the current feature set.

---

### Extract

**Verbs:** `extract` · `parse` · `get`
**Prepositions:** `from` · `via`

Extracts a named field from a structured source: request body, path parameters, query string, event payload, or any dictionary.

```aro
(getUser: User API) {
    Extract the <id> from the <pathParameters: id>.
    Extract the <locale> from the <request: locale>.
    Retrieve the <user> from the <user-repository> where id = <id>.
    Return an <OK: status> with <user>.
}
```

---

### Retrieve

**Verbs:** `retrieve` · `fetch` · `load` · `find`
**Prepositions:** `from`

Retrieves one or more records from an in-memory repository. Supports `where` clauses for field filtering.

```aro
(listOrders: Order API) {
    Extract the <user-id> from the <pathParameters: userId>.
    Retrieve the <orders> from the <order-repository> where userId = <user-id>.
    Return an <OK: status> with <orders>.
}
```

---

### Receive

**Verbs:** `receive`
**Prepositions:** `from` · `via`

Receives data from an external source such as a socket packet.

```aro
(Handle Message: Socket Event Handler) {
    Receive the <message> from the <packet: buffer>.
    Log <message> to the <console>.
    Return an <OK: status> for the <message>.
}
```

---

### Read

**Verbs:** `read`
**Prepositions:** `from`

Reads content from a file path. Auto-detects format: `.json` → dict, `.yaml` → dict, `.csv` → list of dicts, plain text → String.

```aro
(Application-Start: Config Loader) {
    Read the <config> from "config.json".
    Read the <users> from "seed-data.csv".
    Log "Config loaded" to the <console>.
    Return an <OK: status> for the <startup>.
}
```

---

### Request

**Verbs:** `request` · `http`
**Prepositions:** `from` · `to` · `via` · `with`

Makes an HTTP request to an external URL. Default is GET; use `to` for POST with a body.

```aro
(fetchWeather: Weather API) {
    Extract the <city> from the <pathParameters: city>.
    Request the <forecast> from <weather-api-url> with <city>.
    Return an <OK: status> with <forecast>.
}
```

---

### List

**Verbs:** `list`
**Prepositions:** `from`

Lists the entries of a directory, returning a list of names.

```aro
(listFiles: Files API) {
    List the <entries> from the <uploads-directory>.
    Return an <OK: status> with <entries>.
}
```

---

### Stat

**Verbs:** `stat`
**Prepositions:** `for`

Returns metadata for a file or directory: `name`, `path`, `size`, `isDirectory`, `createdAt`, `modifiedAt`, `extension`.

```aro
(File Info: File Event Handler) {
    Extract the <path> from the <event: path>.
    Stat the <info> for the <path>.
    Extract the <size> from the <info: size>.
    Log <size> to the <console>.
    Return an <OK: status> for the <info>.
}
```

---

### Exists

**Verbs:** `exists`
**Prepositions:** `for`

Checks whether a file or directory exists. Returns a Boolean.

```aro
(loadCache: Cache Handler) {
    Exists the <cache-exists> for the <cache-path>.
    Read the <cache> from the <cache-path> when <cache-exists>.
    Return an <OK: status> with <cache>.
}
```

---

### Prompt

**Verbs:** `prompt` · `ask`
**Prepositions:** `with` · `from`

Displays a text prompt in the terminal and reads the user's input. Used in interactive CLI applications.

```aro
(Application-Start: CLI Tool) {
    Prompt the <username> with "Enter your username: ".
    Prompt the <password> with "Password: ".
    Log "Logging in..." to the <console>.
    Return an <OK: status> for the <startup>.
}
```

---

### Select

**Verbs:** `select` · `choose`
**Prepositions:** `from` · `with`

Displays a numbered menu and reads the user's selection. Returns the selected item.

```aro
(Application-Start: Menu App) {
    Create the <options> with ["Create user", "List users", "Exit"].
    Select the <action> from the <options>.
    Log <action> to the <console>.
    Return an <OK: status> for the <startup>.
}
```

---

### Stream

**Verbs:** `stream` · `subscribe`
**Prepositions:** `from` · `with`

Opens a lazy stream from an event source or large data producer (ARO-0051).

```aro
(Process Log: Log Handler) {
    Stream the <log-events> from the <event-source>.
    Filter the <errors> from the <log-events> where level = "error".
    Return an <OK: status> with <errors>.
}
```

---

## OWN Actions

Transform data or make decisions entirely within the feature set.

---

### Compute

**Verbs:** `compute` · `calculate` · `derive`
**Prepositions:** `from` · `for` · `with`

Performs arithmetic, string operations, or built-in transformations. Supports `+`, `-`, `*`, `/`, `%` and qualifiers like `length`, `uppercase`, `lowercase`, `hash`, `count`, `intersect`, `difference`, `union`.

```aro
(calculateInvoice: Invoice API) {
    Extract the <items> from the <request: body>.
    Reduce the <subtotal: sum> from the <items: price>.
    Compute the <tax> from <subtotal> * 0.2.
    Compute the <total> from <subtotal> + <tax>.
    Create the <invoice> with { subtotal: <subtotal>, tax: <tax>, total: <total> }.
    Return an <OK: status> with <invoice>.
}
```

---

### Validate

**Verbs:** `validate` · `verify` · `check`
**Prepositions:** `for` · `against` · `with`

Validates a value against a schema, pattern, or rule. Returns a Boolean.

```aro
(createUser: User API) {
    Extract the <data> from the <request: body>.
    Extract the <email> from the <data: email>.
    Validate the <valid-email> for the <email>.
    Throw a <BadRequest: error> for the <email> when not <valid-email>.
    Store the <user: user> into the <user-repository>.
    Return a <Created: status> with <user>.
}
```

---

### Compare

**Verbs:** `compare` · `match`
**Prepositions:** `against` · `with` · `to`

Compares two values and binds a Boolean result.

```aro
(login: Auth API) {
    Extract the <data> from the <request: body>.
    Extract the <password> from the <data: password>.
    Retrieve the <user> from the <user-repository> where email = <data: email>.
    Extract the <stored-hash> from the <user: passwordHash>.
    Compute the <input-hash: hash> from the <password>.
    Compare the <match> against the <stored-hash> with the <input-hash>.
    Throw a <Unauthorized: error> for the <login> when not <match>.
    Return an <OK: status> with <user>.
}
```

---

### Transform

**Verbs:** `transform` · `convert`
**Prepositions:** `from` · `into` · `to`

Converts a value from one type or format to another. Qualifiers: `int`, `string`, `float`, `bool`, `date`, `json`, `markdown`.

```aro
(processOrder: Order API) {
    Extract the <quantity-string> from the <request: quantity>.
    Transform the <quantity: int> from the <quantity-string>.
    Compute the <total> from <unit-price> * <quantity>.
    Return an <OK: status> with <total>.
}
```

---

### Create

**Verbs:** `create` · `build` · `construct`
**Prepositions:** `with` · `from` · `for`

Creates a new in-memory object from a dict literal or existing variables. Does not persist — use `Store` to save.

```aro
(createProduct: Product API) {
    Extract the <data> from the <request: body>.
    Create the <product> with {
        name:      <data: name>,
        price:     <data: price>,
        stock:     <data: stock>,
        createdAt: <now>
    }.
    Store the <saved-product: product> into the <product-repository>.
    Return a <Created: status> with <saved-product>.
}
```

---

### Update

**Verbs:** `update` · `modify` · `change` · `set` · `configure`
**Prepositions:** `with` · `to` · `for`

Produces a new object with specified fields changed. The original binding is immutable.

```aro
(activateUser: User API) {
    Extract the <id> from the <pathParameters: id>.
    Retrieve the <user> from the <user-repository> where id = <id>.
    Update the <active-user> with { status: "active" } from the <user>.
    Store the <active-user> into the <user-repository>.
    Return an <OK: status> with <active-user>.
}
```

---

### Sort

**Verbs:** `sort` · `order` · `arrange`
**Prepositions:** `for` · `with`

Sorts a collection. Default ascending; qualifier `desc` for descending; use a field name to sort by field.

```aro
(listProducts: Product API) {
    Retrieve the <products> from the <product-repository>.
    Sort the <by-price: price> for the <products>.
    Return an <OK: status> with <by-price>.
}
```

---

### Merge

**Verbs:** `merge` · `combine`
**Prepositions:** `with` · `from`

Merges two collections (concatenates) or two dicts (later keys override).

```aro
(getFullCatalog: Catalog API) {
    Retrieve the <active-items> from the <item-repository> where status = "active".
    Retrieve the <featured-items> from the <featured-repository>.
    Merge the <catalog> with <featured-items> from <active-items>.
    Return an <OK: status> with <catalog>.
}
```

---

### Delete

**Verbs:** `delete` · `remove` · `destroy`
**Prepositions:** `from` · `for`

Removes an element from a collection or deletes a record from a repository.

```aro
(deleteUser: User API) {
    Extract the <id> from the <pathParameters: id>.
    Retrieve the <user> from the <user-repository> where id = <id>.
    Delete the <removed> from the <user-repository> where id = <id>.
    Emit a <UserDeleted: event> with <user>.
    Return a <NoContent: status> for the <deletion>.
}
```

---

### Map

**Verbs:** `map`
**Prepositions:** `from` · `to`

Transforms each element in a collection using a qualifier or field accessor.

```aro
(listUserEmails: User API) {
    Retrieve the <users> from the <user-repository>.
    Map the <emails> from the <users: email>.
    Return an <OK: status> with <emails>.
}
```

---

### Reduce

**Verbs:** `reduce` · `aggregate`
**Prepositions:** `from` · `with`

Aggregates a collection into a single value. Qualifiers: `sum`, `avg`, `count`, `min`, `max`, `first`, `last`.

```aro
(getSalesReport: Report API) {
    Retrieve the <orders> from the <order-repository>.
    Reduce the <total-revenue: sum> from the <orders: total>.
    Reduce the <order-count: count> from the <orders>.
    Reduce the <average-order: avg> from the <orders: total>.
    Create the <report> with { revenue: <total-revenue>, count: <order-count>, average: <average-order> }.
    Return an <OK: status> with <report>.
}
```

---

### Filter

**Verbs:** `filter`
**Prepositions:** `from`

Filters a collection by field-value conditions using `where` clauses.

```aro
(listActiveOrders: Order API) {
    Retrieve the <orders> from the <order-repository>.
    Filter the <pending> from the <orders> where status = "pending".
    Filter the <high-value> from the <pending> where total >= 100.
    Return an <OK: status> with <high-value>.
}
```

---

### Call

**Verbs:** `call` · `invoke`
**Prepositions:** `from` · `to` · `with` · `via`

Invokes an external service method or plugin action.

```aro
(processPayment: Payment API) {
    Extract the <charge-data> from the <request: body>.
    Call the <result> from the <payment-service> with <charge-data>.
    Extract the <transaction-id> from the <result: transactionId>.
    Return an <OK: status> with <result>.
}
```

---

### Execute

**Verbs:** `execute` · `exec` · `run` · `shell`
**Prepositions:** `on` · `with` · `for`

Executes a shell command and captures stdout as a String.

```aro
(Application-Start: Build Tool) {
    Execute the <git-log> with "git log --oneline -10".
    Log <git-log> to the <console>.
    Return an <OK: status> for the <startup>.
}
```

---

### Parse

**Verbs:** `parse` (HTML/XML variant)
**Prepositions:** `from`

Parses HTML or XML content into a structured document. Also parses RFC 8288 Link headers.

```aro
(scrapeLinks: Scraper API) {
    Request the <html> from the <target-url>.
    Parse the <document> from the <html>.
    Extract the <links> from the <document: links>.
    Return an <OK: status> with <links>.
}
```

---

### Accept

**Verbs:** `accept`
**Prepositions:** `on`

Validates and applies a state transition on a repository entity. Emits a `StateTransition` event on success.

```aro
(shipOrder: Order API) {
    Extract the <id> from the <pathParameters: id>.
    Retrieve the <order> from the <order-repository> where id = <id>.
    Accept the <order> on the <paid-state>.
    Emit a <OrderShipped: event> with <order>.
    Return an <OK: status> with <order>.
}
```

---

### Join

**Verbs:** `join`
**Prepositions:** `from`

Joins the elements of a list into a single string. The qualifier specifies the separator.

```aro
(buildReport: Report API) {
    Retrieve the <log-entries> from the <log-repository>.
    Map the <lines> from the <log-entries: message>.
    Join the <report: \n> from the <lines>.
    Write the <report> to "report.txt".
    Return an <OK: status> for the <report>.
}
```

---

### Split

**Verbs:** `split`
**Prepositions:** `from`

Splits a string by a regex delimiter into a list of strings.

```aro
(parseCSV: Data API) {
    Read the <content> from the <csv-file>.
    Split the <lines> from the <content> by /\n/.
    For each <line> in <lines> {
        Split the <fields> from the <line> by /,/.
        Log <fields> to the <console>.
    }
    Return an <OK: status> for the <content>.
}
```

---

### Sleep

**Verbs:** `sleep` · `delay` · `pause`
**Prepositions:** `for` · `with`

Suspends execution for a given number of seconds. Non-blocking to other feature sets.

```aro
(retryWebhook: Webhook Handler) {
    Extract the <url> from the <event: url>.
    Extract the <payload> from the <event: payload>.
    Sleep the <pause> for 5.
    Request the <response> to the <url> with <payload>.
    Return an <OK: status> for the <response>.
}
```

---

## RESPONSE Actions

Return a result or error to the caller and end the execution path.

---

### Return

**Verbs:** `return` · `respond`
**Prepositions:** `for` · `to` · `with`

Returns a response from the feature set. For HTTP, sets the HTTP status code and body. The qualifier on the result names the status.

```aro
(getUser: User API) {
    Extract the <id> from the <pathParameters: id>.
    Retrieve the <user> from the <user-repository> where id = <id>.
    Return an <OK: status> with <user>.              (* 200 OK *)
}

(createUser: User API) {
    Extract the <data> from the <request: body>.
    Store the <user: user> into the <user-repository>.
    Return a <Created: status> with <user>.           (* 201 Created *)
}

(deleteUser: User API) {
    Extract the <id> from the <pathParameters: id>.
    Delete the <removed> from the <user-repository> where id = <id>.
    Return a <NoContent: status> for the <deletion>.  (* 204 No Content *)
}
```

---

### Throw

**Verbs:** `throw` · `raise` · `fail`
**Prepositions:** `for`

Throws an error that propagates to the caller. For HTTP, produces an error response.

```aro
(getUser: User API) {
    Extract the <id> from the <pathParameters: id>.
    Validate the <valid-id> for the <id>.
    Throw a <BadRequest: error> for the <id> when not <valid-id>.
    Retrieve the <user> from the <user-repository> where id = <id>.
    Return an <OK: status> with <user>.
}
```

---

## EXPORT Actions

Persist data, publish events, or broadcast output beyond the current feature set.

---

### Store

**Verbs:** `store` · `save` · `persist`
**Prepositions:** `into` · `to` · `in`

Saves an object to an in-memory repository. Auto-assigns a UUID `id`. The qualifier names the entity type.

```aro
(createOrder: Order API) {
    Extract the <data> from the <request: body>.
    Create the <order> with { items: <data: items>, status: "pending", total: <data: total> }.
    Store the <saved-order: order> into the <order-repository>.
    Emit a <OrderCreated: event> with <saved-order>.
    Return a <Created: status> with <saved-order>.
}
```

---

### Publish

**Verbs:** `publish` · `export` · `expose` · `share`
**Syntax:** `Publish as <alias> <variable>.`

Publishes a variable so it is accessible to other feature sets within the same business activity scope.

```aro
(Application-Start: Web App) {
    Read the <config> from "config.json".
    Start the <http-server> with <contract>.
    Publish as <app-config> <config>.
    Publish as <http-server> <http-server>.
    Keepalive the <application> for the <events>.
    Return an <OK: status> for the <startup>.
}
```

---

### Log

**Verbs:** `log` · `print` · `output` · `debug`
**Prepositions:** `for` · `to` · `with`

Writes a message to the console or log file.

```aro
(Application-Start: Service) {
    Log "Starting service..." to the <console>.
    Start the <http-server> with <contract>.
    Log "HTTP server running on port 8080" to the <console>.
    Keepalive the <application> for the <events>.
    Return an <OK: status> for the <startup>.
}
```

---

### Send

**Verbs:** `send` · `dispatch`
**Prepositions:** `to` · `via` · `with`

Sends a message to a specific socket connection.

```aro
(Handle Connection: Socket Event Handler) {
    Extract the <connection-id> from the <event: connectionId>.
    Create the <welcome> with { message: "Welcome!", connectionId: <connection-id> }.
    Send the <welcome> to the <connection>.
    Return an <OK: status> for the <welcome>.
}
```

---

### Emit

**Verbs:** `emit`
**Prepositions:** `with` · `to`

Emits a domain event on the event bus. Matching handlers are triggered asynchronously.

```aro
(createUser: User API) {
    Extract the <data> from the <request: body>.
    Store the <user: user> into the <user-repository>.
    Emit a <UserCreated: event> with <user>.
    Return a <Created: status> with <user>.
}

(Send Welcome Email: UserCreated Handler) {
    Extract the <user> from the <event: user>.
    Extract the <email> from the <user: email>.
    Log <email> to the <console>.
    Return an <OK: status> for the <email>.
}
```

---

### Notify

**Verbs:** `notify` · `alert` · `signal`
**Prepositions:** `to` · `for` · `with`

Sends a notification to a recipient or collection. Handlers named `{Name}: NotificationSent Handler` with optional `when` guards receive it.

```aro
(shipOrder: Order API) {
    Retrieve the <order> from the <order-repository> where id = <order-id>.
    Retrieve the <customer> from the <user-repository> where id = <order: userId>.
    Notify the <customer> with "Your order has shipped!".
    Return an <OK: status> with <order>.
}

(Email Customer: NotificationSent Handler) when <role> = "customer" {
    Extract the <user> from the <event: user>.
    Log <user: email> to the <console>.
    Return an <OK: status> for the <notification>.
}
```

---

### Write

**Verbs:** `write`
**Prepositions:** `to` · `into`

Writes content to a file. Dicts and lists are serialized to JSON automatically.

```aro
(exportReport: Report API) {
    Retrieve the <orders> from the <order-repository>.
    Write the <orders> to "orders-export.json".
    Return an <OK: status> for the <orders>.
}
```

---

### Append

**Verbs:** `append`
**Prepositions:** `to` · `into`

Appends content to a file, creating it if it doesn't exist.

```aro
(Log Event: Audit Handler) {
    Extract the <action> from the <event: action>.
    Extract the <user-id> from the <event: userId>.
    Create the <entry> with { action: <action>, userId: <user-id>, timestamp: <now> }.
    Append the <entry> to "audit.log".
    Return an <OK: status> for the <entry>.
}
```

---

### Schedule

**Verbs:** `schedule`
**Prepositions:** `with`

Schedules a recurring domain event every N seconds. Feature sets can handle the event by name.

```aro
(Application-Start: Monitor) {
    Start the <http-server> with <contract>.
    Schedule the <health-tick> with 30.
    Keepalive the <application> for the <events>.
    Return an <OK: status> for the <startup>.
}

(Health Check: health-tick Handler) {
    Request the <status> from "http://internal/health".
    Log <status> to the <console>.
    Return an <OK: status> for the <status>.
}
```

---

## FILE Actions

---

### Make

**Verbs:** `make` · `touch` · `mkdir`
**Prepositions:** `to` · `for` · `at`

Creates a new empty file or directory. Use qualifier `directory` or `file` to specify.

```aro
(Application-Start: File Service) {
    Make the <uploads: directory> at "uploads/".
    Make the <temp: directory> at "tmp/".
    Log "Directories created" to the <console>.
    Return an <OK: status> for the <startup>.
}
```

---

### Copy

**Verbs:** `copy`
**Prepositions:** `to`

Copies a file or directory to a destination path.

```aro
(backupConfig: Admin API) {
    Copy the <backup> to "config.backup.json".
    Return an <OK: status> for the <backup>.
}
```

---

### Move

**Verbs:** `move` · `rename`
**Prepositions:** `to`

Moves or renames a file or directory.

```aro
(archiveLog: Maintenance Handler) {
    Extract the <log-path> from the <event: path>.
    Move the <archived> to "archive/app.log".
    Return an <OK: status> for the <archived>.
}
```

---

## TERMINAL Actions

---

### Clear

**Verbs:** `clear`
**Prepositions:** `for`

Clears the terminal screen and resets the section compositor. No-op in non-TTY mode.

```aro
(Application-Start: Dashboard) {
    Clear the <display> for the <terminal>.
    Render the <screen> to the <terminal>.
    Keepalive the <application> for the <events>.
    Return an <OK: status> for the <startup>.
}
```

---

### Show

**Verbs:** `show`
**Prepositions:** `for`

Shows content in the terminal outside the section compositor.

```aro
(Application-Start: Help Tool) {
    Show the <help-text> for the <terminal>.
    Return an <OK: status> for the <startup>.
}
```

---

### Render

**Verbs:** `render`
**Prepositions:** `to`

Renders a template into a named terminal section. First call places the section; subsequent calls diff and update in-place.

```aro
(Refresh Display: tick Handler) {
    Retrieve the <stats> from the <stats-repository> where key = "latest".
    Render the <dashboard> to the <terminal>.
    Return an <OK: status> for the <stats>.
}
```

---

### Repaint

**Verbs:** `repaint` · `patch`
**Prepositions:** `at` · `to`

Partially updates a named section of the terminal without a full re-render.

```aro
(Update Header: status Handler) {
    Extract the <title> from the <event: title>.
    Repaint the <header> at the <terminal>.
    Return an <OK: status> for the <title>.
}
```

---

## SERVICE Actions

---

### Start

**Verbs:** `start`
**Prepositions:** `with`

Starts a service. Common targets: `http-server` (requires `openapi.yaml` contract), `file-monitor`, `socket-server`.

```aro
(Application-Start: Web Service) {
    Start the <http-server> with <contract>.
    Start the <file-monitor> with "uploads/".
    Keepalive the <application> for the <events>.
    Return an <OK: status> for the <startup>.
}
```

---

### Stop

**Verbs:** `stop`
**Prepositions:** `with`

Stops a running service gracefully.

```aro
(Application-End: Success) {
    Stop the <http-server> with <application>.
    Log "Shutdown complete" to the <console>.
    Return an <OK: status> for the <shutdown>.
}
```

---

### Listen

**Verbs:** `listen` · `await`
**Prepositions:** `on` · `for` · `to`

Registers a listener on an event channel or port.

```aro
(Application-Start: Event Bridge) {
    Listen the <incoming> on the <event-channel>.
    Keepalive the <application> for the <events>.
    Return an <OK: status> for the <startup>.
}
```

---

### Keepalive

**Verbs:** `keepalive` · `wait` · `block`
**Prepositions:** `for`

Blocks `Application-Start` until SIGINT/SIGTERM. Required for any long-running application (servers, file watchers, schedulers).

```aro
(Application-Start: Long Running Service) {
    Start the <http-server> with <contract>.
    Schedule the <tick> with 60.
    Keepalive the <application> for the <events>.
    Return an <OK: status> for the <startup>.
}
```

---

### Connect

**Verbs:** `connect`
**Prepositions:** `to` · `with`

Establishes a TCP socket connection to a remote host.

```aro
(Application-Start: Socket Client) {
    Create the <server-address> with "localhost:9000".
    Connect the <connection> to the <server-address>.
    Send the <greeting> to the <connection>.
    Keepalive the <application> for the <events>.
    Return an <OK: status> for the <startup>.
}
```

---

### Broadcast

**Verbs:** `broadcast`
**Prepositions:** `to` · `via`

Broadcasts a message to all currently connected socket clients.

```aro
(Announce Update: Update Handler) {
    Extract the <message> from the <event: message>.
    Broadcast the <message> to the <socket-server>.
    Return an <OK: status> for the <message>.
}
```

---

### Close

**Verbs:** `close` · `disconnect` · `terminate`
**Prepositions:** `with` · `from`

Closes a socket connection gracefully.

```aro
(Handle Disconnect: Socket Event Handler) {
    Extract the <connection-id> from the <event: connectionId>.
    Close the <session> with <connection>.
    Log "Client disconnected" to the <console>.
    Return an <OK: status> for the <session>.
}
```

---

## TEST Actions

BDD-style testing framework. Tests are co-located with feature set files.

---

### Given

**Verbs:** `given`
**Prepositions:** `with`

Sets up the test context with initial state.

```aro
(Create User Test: User Tests) {
    Given the <context> with { name: "Alice", email: "alice@example.com" }.
    When the <response> from the <createUser>.
    Then the <created-user> with <context>.
    Assert the <has-id> for the <response: id>.
}
```

---

### When

**Verbs:** `when`
**Prepositions:** `from`

Executes the feature set under test and captures its result.

```aro
(* See Given example above *)
```

---

### Then

**Verbs:** `then`
**Prepositions:** `with`

Verifies the result against expected output.

```aro
(* See Given example above *)
```

---

### Assert

**Verbs:** `assert`
**Prepositions:** `for` · `with`

Asserts that a value satisfies an expectation. Fails the test with a descriptive message if not.

```aro
(Validate Email Test: Validation Tests) {
    Given the <email> with "user@example.com".
    Validate the <result> for the <email>.
    Assert the <result> for the <email> with true.
    Assert the <result-type> for the <result> with "bool".
}
```

---

## Quick Reference

| Action | Verbs (primary · aliases) | Role | Prepositions |
|--------|---------------------------|------|--------------|
| Extract | extract · parse, get | REQUEST | from, via |
| Retrieve | retrieve · fetch, load, find | REQUEST | from |
| Receive | receive | REQUEST | from, via |
| Read | read | REQUEST | from |
| Request | request · http | REQUEST | from, to, via, with |
| List | list | REQUEST | from |
| Stat | stat | REQUEST | for |
| Exists | exists | REQUEST | for |
| Prompt | prompt · ask | REQUEST | with, from |
| Select | select · choose | REQUEST | from, with |
| Stream | stream · subscribe | REQUEST | from, with |
| Compute | compute · calculate, derive | OWN | from, for, with |
| Validate | validate · verify, check | OWN | for, against, with |
| Compare | compare · match | OWN | against, with, to |
| Transform | transform · convert | OWN | from, into, to |
| Create | create · build, construct | OWN | with, from, for |
| Update | update · modify, set, configure | OWN | with, to, for |
| Sort | sort · order, arrange | OWN | for, with |
| Merge | merge · combine | OWN | with, from |
| Delete | delete · remove, destroy | OWN | from, for |
| Map | map | OWN | from, to |
| Reduce | reduce · aggregate | OWN | from, with |
| Filter | filter | OWN | from |
| Call | call · invoke | OWN | from, to, with, via |
| Execute | execute · exec, run, shell | OWN | on, with, for |
| Parse | parse (HTML/XML) | OWN | from |
| Accept | accept | OWN | on |
| Join | join | OWN | from |
| Split | split | OWN | from |
| Sleep | sleep · delay, pause | OWN | for, with |
| Return | return · respond | RESPONSE | for, to, with |
| Throw | throw · raise, fail | RESPONSE | for |
| Store | store · save, persist | EXPORT | into, to, in |
| Publish | publish · export, expose, share | EXPORT | (as syntax) |
| Log | log · print, output, debug | EXPORT | for, to, with |
| Send | send · dispatch | EXPORT | to, via, with |
| Emit | emit | EXPORT | with, to |
| Notify | notify · alert, signal | EXPORT | to, for, with |
| Write | write | EXPORT | to, into |
| Append | append | EXPORT | to, into |
| Schedule | schedule | EXPORT | with |
| Make | make · touch, mkdir | FILE | to, for, at |
| Copy | copy | FILE | to |
| Move | move · rename | FILE | to |
| Clear | clear | TERMINAL | for |
| Show | show | TERMINAL | for |
| Render | render | TERMINAL | to |
| Repaint | repaint · patch | TERMINAL | at, to |
| Start | start | SERVICE | with |
| Stop | stop | SERVICE | with |
| Listen | listen · await | SERVICE | on, for, to |
| Keepalive | keepalive · wait, block | SERVICE | for |
| Connect | connect | SERVICE | to, with |
| Broadcast | broadcast | SERVICE | to, via |
| Close | close · disconnect, terminate | SERVICE | with, from |
| Given | given | TEST | with |
| When | when | TEST | from |
| Then | then | TEST | with |
| Assert | assert | TEST | for, with |
