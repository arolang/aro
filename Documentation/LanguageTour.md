# A Tour of ARO

This tour gives you a comprehensive overview of ARO by exploring its features through examples. By the end, you'll understand how ARO programs are structured and how to build event-driven applications.

## Hello, World!

Tradition suggests that the first program in a new language should print "Hello, World!" Here's how you do it in ARO:

```aro
(Application-Start: Hello World) {
    <Log> the <message> for the <console> with "Hello, World!".
    <Return> an <OK: status> for the <startup>.
}
```

If you've programmed before, this syntax might look unusual. ARO is designed to read like natural language while remaining precise and unambiguous.

## Feature Sets

The fundamental unit of organization in ARO is the **feature set**. A feature set groups related statements that accomplish a business goal:

```aro
(Calculate Order Total: Order Processing) {
    <Extract> the <items> from the <order: lineItems>.
    <Compute> the <subtotal> for the <items>.
    <Compute> the <tax> for the <subtotal>.
    <Compute> the <total> from the <subtotal> with <tax>.
    <Return> an <OK: status> with <total>.
}
```

Every feature set has:
- A **name** (`Calculate Order Total`)
- A **business activity** (`Order Processing`)
- A **body** containing statements

## The ARO Statement

ARO statements follow the **Action-Result-Object** pattern:

```
<Action> the <result> preposition the <object>.
```

For example:

```aro
<Extract> the <user-id> from the <request: parameters>.
<Retrieve> the <user> from the <user-repository>.
<Create> the <response> with <user>.
<Return> an <OK: status> with <response>.
```

Each statement:
1. Performs an **action** (verb like Extract, Retrieve, Create)
2. Produces a **result** (variable to store the outcome)
3. Uses an **object** (source of data or target of action)

## Variables and Qualifiers

Variables in ARO use angle brackets and can have **qualifiers**:

```aro
<user>                  (* Simple variable *)
<user: id>              (* Variable with qualifier *)
<request: body>         (* Access nested property *)
<user-repository>       (* Hyphenated names allowed *)
```

Variables are automatically typed based on context. Qualifiers provide additional context about what aspect of a variable you're accessing.

## Actions by Role

ARO actions are categorized by their semantic role:

### REQUEST Actions
Bring data from external sources into your feature set:

```aro
<Extract> the <data> from the <request: body>.
<Retrieve> the <user> from the <user-repository>.
<Fetch> the <weather> from the <weather-api>.
<Parse> the <config> from the <json-string>.
```

### OWN Actions
Create or transform data within your feature set:

```aro
<Create> the <user> with <user-data>.
<Compute> the <total> for the <items>.
<Transform> the <dto> from the <entity>.
<Validate> the <input> for the <schema>.
```

### RESPONSE Actions
Send results back from your feature set:

```aro
<Return> an <OK: status> with <data>.
<Return> a <NotFound: status> for the <missing: user>.
<Throw> an <ValidationError> for the <invalid: input>.
```

### EXPORT Actions
Publish data or send to external systems:

```aro
<Store> the <user> into the <user-repository>.
<Publish> as <current-user> <user>.
<Log> the <message> for the <console>.
<Send> the <email> to the <user: email>.
<Emit> a <UserCreated: event> with <user>.
```

## Prepositions

Different prepositions convey different relationships:

| Preposition | Meaning | Example |
|-------------|---------|---------|
| `from` | Source of data | `<Extract> the <id> from the <request>` |
| `for` | Purpose/target | `<Compute> the <hash> for the <password>` |
| `with` | Additional data | `<Create> the <user> with <data>` |
| `into` | Storage destination | `<Store> the <user> into the <repository>` |
| `to` | Recipient | `<Send> the <message> to the <user>` |
| `against` | Comparison target | `<Compare> the <hash> against the <stored-hash>` |
| `via` | Method/channel | `<Call> the <api> via <POST /users>` |

## Application Lifecycle

Every ARO application has a defined lifecycle:

### Application-Start

The entry point - exactly one per application:

```aro
(Application-Start: My Application) {
    <Log> the <startup: message> for the <console> with "Starting...".

    (* Initialize services *)
    <Start> the <http-server> on port 8080.
    <Watch> the <directory: "./uploads"> as <file-monitor>.

    <Return> an <OK: status> for the <startup>.
}
```

### Application-End

Optional exit handlers for cleanup:

```aro
(* Called on graceful shutdown *)
(Application-End: Success) {
    <Stop> the <http-server>.
    <Close> the <database-connections>.
    <Return> an <OK: status> for the <shutdown>.
}

(* Called on error/crash *)
(Application-End: Error) {
    <Extract> the <error> from the <shutdown: error>.
    <Log> the <error: message> for the <console> with <error>.
    <Send> the <alert> to the <ops-team>.
    <Return> an <OK: status> for the <error-handling>.
}
```

## Event-Driven Programming

Feature sets don't call each other directly. Instead, they respond to **events**:

### HTTP Events

Feature sets with route patterns respond to HTTP requests:

```aro
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
    <Create> the <user> with <user-data>.
    <Store> the <user> into the <user-repository>.
    <Emit> a <UserCreated: event> with <user>.
    <Return> a <Created: status> with <user>.
}
```

### Domain Events

Feature sets can emit and handle custom events:

```aro
(* Emitting an event *)
(POST /orders: Order API) {
    <Create> the <order> with <order-data>.
    <Store> the <order> into the <order-repository>.
    <Emit> an <OrderPlaced: event> with <order>.
    <Return> a <Created: status> with <order>.
}

(* Handling an event *)
(Send Confirmation: OrderPlaced Handler) {
    <Extract> the <order> from the <event: order>.
    <Extract> the <customer-email> from the <order: customerEmail>.
    <Create> the <email> with {
        to: <customer-email>,
        subject: "Order Confirmation",
        body: "Your order has been placed..."
    }.
    <Send> the <email> to the <email-service>.
    <Return> an <OK: status> for the <notification>.
}
```

### File System Events

React to file system changes:

```aro
(Process Upload: FileCreated Handler) {
    <Extract> the <path> from the <event: path>.
    <Read> the <content> from the <file: path>.
    <Transform> the <processed> from the <content>.
    <Store> the <processed> into the <processed-repository>.
    <Return> an <OK: status> for the <processing>.
}
```

### Socket Events

Handle TCP connections:

```aro
(Handle Client Connected: ClientConnected Handler) {
    <Extract> the <client-id> from the <event: connectionId>.
    <Log> the <connection: message> for the <console> with <client-id>.
    <Return> an <OK: status> for the <connection>.
}

(Echo Data: DataReceived Handler) {
    <Extract> the <data> from the <event: data>.
    <Extract> the <client> from the <event: connection>.
    <Send> the <data> to the <client>.
    <Return> an <OK: status> for the <echo>.
}
```

## Control Flow

ARO supports conditional logic:

### If-Then-Else

```aro
(GET /users/{id}: User API) {
    <Extract> the <user-id> from the <request: parameters>.
    <Retrieve> the <user> from the <user-repository> where id = <user-id>.

    if <user> is empty then {
        <Return> a <NotFound: status> for the <missing: user>.
    }

    <Return> an <OK: status> with <user>.
}
```

### Guards

```aro
(Update User: User API) {
    <Extract> the <user-id> from the <request: parameters>.
    <Extract> the <updates> from the <request: body>.

    when <user-id> is empty {
        <Return> a <BadRequest: status> for the <missing: id>.
    }

    when <updates> is empty {
        <Return> a <BadRequest: status> for the <missing: data>.
    }

    <Retrieve> the <user> from the <user-repository> where id = <user-id>.
    <Transform> the <updated-user> from the <user> with <updates>.
    <Store> the <updated-user> into the <user-repository>.
    <Return> an <OK: status> with <updated-user>.
}
```

## Multi-File Applications

ARO applications can span multiple files without imports:

```
MyApp/
├── main.aro           # Application-Start, Application-End
├── users.aro          # User feature sets
├── orders.aro         # Order feature sets
└── notifications.aro  # Notification handlers
```

All feature sets are automatically visible to each other. Published variables are shared:

**users.aro:**
```aro
(Load Default User: Initialization) {
    <Retrieve> the <admin> from the <user-repository> where role = "admin".
    <Publish> as <system-admin> <admin>.
    <Return> an <OK: status> for the <loading>.
}
```

**notifications.aro:**
```aro
(Send Admin Alert: CriticalError Handler) {
    (* Access published variable from users.aro *)
    <Extract> the <admin-email> from the <system-admin: email>.
    <Send> the <alert> to the <admin-email>.
    <Return> an <OK: status> for the <alert>.
}
```

## HTTP Server

ARO has built-in HTTP server capabilities:

```aro
(Application-Start: REST API) {
    <Start> the <http-server> on port 8080.
    <Return> an <OK: status> for the <startup>.
}

(GET /api/products: Product API) {
    <Retrieve> the <products> from the <product-repository>.
    <Return> an <OK: status> with <products>.
}

(POST /api/products: Product API) {
    <Extract> the <product-data> from the <request: body>.
    <Validate> the <product-data> for the <product-schema>.
    <Create> the <product> with <product-data>.
    <Store> the <product> into the <product-repository>.
    <Return> a <Created: status> with <product>.
}

(PUT /api/products/{id}: Product API) {
    <Extract> the <product-id> from the <request: parameters>.
    <Extract> the <updates> from the <request: body>.
    <Retrieve> the <product> from the <product-repository> where id = <product-id>.
    <Transform> the <updated> from the <product> with <updates>.
    <Store> the <updated> into the <product-repository>.
    <Return> an <OK: status> with <updated>.
}

(DELETE /api/products/{id}: Product API) {
    <Extract> the <product-id> from the <request: parameters>.
    <Delete> the <product> from the <product-repository> where id = <product-id>.
    <Return> a <NoContent: status> for the <deletion>.
}
```

## HTTP Client

Make outgoing HTTP requests:

```aro
(Fetch Weather: External API) {
    <Extract> the <city> from the <request: query city>.
    <Fetch> the <weather-data> from "https://api.weather.com/v1/weather?city=${city}".
    <Return> an <OK: status> with <weather-data>.
}
```

## File Operations

Read and write files:

```aro
(* Reading files *)
<Read> the <content> from the <file: "./config.json">.
<Read> the <config: JSON> from the <file: "./settings.json">.

(* Writing files *)
<Write> the <data> to the <file: "./output.txt">.
<Store> the <log-entry> into the <file: "./logs/app.log">.

(* Watching directories *)
<Watch> the <directory: "./uploads"> as <file-monitor>.
```

## Comments

ARO uses block comments:

```aro
(* This is a single-line comment *)

(*
   This is a
   multi-line comment
*)

(Calculate Total: Order Processing) {
    (* Extract line items from the order *)
    <Extract> the <items> from the <order: lineItems>.

    (* Calculate the sum *)
    <Compute> the <total> for the <items>.

    <Return> an <OK: status> with <total>.
}
```

## Response Status Codes

ARO maps return statuses to HTTP status codes:

```aro
<Return> an <OK: status> with <data>.           (* 200 OK *)
<Return> a <Created: status> with <resource>.   (* 201 Created *)
<Return> a <NoContent: status> for <deletion>.  (* 204 No Content *)
<Return> a <BadRequest: status> for <error>.    (* 400 Bad Request *)
<Return> a <NotFound: status> for <missing>.    (* 404 Not Found *)
<Return> a <Forbidden: status> for <denied>.    (* 403 Forbidden *)
```

## Complete Example

Here's a complete multi-file application:

### main.aro
```aro
(Application-Start: Task Manager) {
    <Log> the <startup: message> for the <console> with "Starting Task Manager...".
    <Start> the <http-server> on port 3000.
    <Log> the <ready: message> for the <console> with "Task Manager running on port 3000".
    <Return> an <OK: status> for the <startup>.
}

(Application-End: Success) {
    <Log> the <shutdown: message> for the <console> with "Shutting down...".
    <Stop> the <http-server>.
    <Return> an <OK: status> for the <shutdown>.
}
```

### tasks.aro
```aro
(GET /tasks: Task API) {
    <Retrieve> the <tasks> from the <task-repository>.
    <Return> an <OK: status> with <tasks>.
}

(POST /tasks: Task API) {
    <Extract> the <task-data> from the <request: body>.
    <Create> the <task> with <task-data>.
    <Store> the <task> into the <task-repository>.
    <Emit> a <TaskCreated: event> with <task>.
    <Return> a <Created: status> with <task>.
}

(PUT /tasks/{id}/complete: Task API) {
    <Extract> the <task-id> from the <request: parameters>.
    <Retrieve> the <task> from the <task-repository> where id = <task-id>.
    <Transform> the <completed-task> from the <task> with { completed: true }.
    <Store> the <completed-task> into the <task-repository>.
    <Emit> a <TaskCompleted: event> with <completed-task>.
    <Return> an <OK: status> with <completed-task>.
}
```

### notifications.aro
```aro
(Log New Task: TaskCreated Handler) {
    <Extract> the <task> from the <event: task>.
    <Extract> the <title> from the <task: title>.
    <Log> the <notification: message> for the <console> with "New task: ${title}".
    <Return> an <OK: status> for the <notification>.
}

(Log Completed Task: TaskCompleted Handler) {
    <Extract> the <task> from the <event: task>.
    <Extract> the <title> from the <task: title>.
    <Log> the <notification: message> for the <console> with "Completed: ${title}".
    <Return> an <OK: status> for the <notification>.
}
```

## Next Steps

This tour has introduced you to ARO's key features. To learn more:

- **[The Basics](LanguageGuide/TheBasics.md)** - Detailed syntax reference
- **[Feature Sets](LanguageGuide/FeatureSets.md)** - Feature set patterns
- **[Events](LanguageGuide/Events.md)** - Event-driven architecture
- **[HTTP Services](LanguageGuide/HTTPServices.md)** - Building APIs
- **[Action Developer Guide](ActionDeveloperGuide.md)** - Custom actions
