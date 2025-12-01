# Feature Sets

Feature sets are the primary organizational unit in ARO. They group related statements that work together to accomplish a business goal.

## Defining Feature Sets

A feature set consists of a name, business activity, and body:

```aro
(Feature Name: Business Activity) {
    (* statements *)
}
```

### Naming Guidelines

**Feature Set Name** - Describes what the feature does:
- Use action-oriented names: `Create User`, `Calculate Total`, `Send Notification`
- Be specific: `Validate Email Format` not just `Validate`
- Use business terminology: `Process Refund`, `Approve Order`

**Business Activity** - Describes the domain context:
- Use noun phrases: `User Management`, `Order Processing`
- Group related features: All user features might use `User API`
- Be consistent across your application

### Examples

```aro
(Create User Account: User Management) { ... }
(Validate User Credentials: Authentication) { ... }
(Process Payment: Order Processing) { ... }
(Send Order Confirmation: Notifications) { ... }
(Calculate Shipping Cost: Shipping) { ... }
```

## Feature Set Categories

### Application Lifecycle

These special feature sets manage the application lifecycle:

```aro
(* Entry point - exactly one per application *)
(Application-Start: My Application) {
    <Log> the <message> for the <console> with "Starting...".
    <Start> the <http-server> on port 8080.
    <Return> an <OK: status> for the <startup>.
}

(* Called on graceful shutdown - optional, at most one *)
(Application-End: Success) {
    <Stop> the <http-server>.
    <Close> the <database-connections>.
    <Return> an <OK: status> for the <shutdown>.
}

(* Called on error - optional, at most one *)
(Application-End: Error) {
    <Extract> the <error> from the <shutdown: error>.
    <Log> the <error: message> for the <console> with <error>.
    <Return> an <OK: status> for the <error-handling>.
}
```

### HTTP Route Handlers

Feature sets prefixed with HTTP methods handle web requests:

```aro
(* GET request *)
(GET /users: User API) {
    <Retrieve> the <users> from the <user-repository>.
    <Return> an <OK: status> with <users>.
}

(* POST request *)
(POST /users: User API) {
    <Extract> the <user-data> from the <request: body>.
    <Create> the <user> with <user-data>.
    <Store> the <user> into the <user-repository>.
    <Return> a <Created: status> with <user>.
}

(* PUT request with path parameter *)
(PUT /users/{id}: User API) {
    <Extract> the <user-id> from the <request: parameters>.
    <Extract> the <updates> from the <request: body>.
    <Retrieve> the <user> from the <user-repository> where id = <user-id>.
    <Transform> the <updated-user> from the <user> with <updates>.
    <Store> the <updated-user> into the <user-repository>.
    <Return> an <OK: status> with <updated-user>.
}

(* DELETE request *)
(DELETE /users/{id}: User API) {
    <Extract> the <user-id> from the <request: parameters>.
    <Delete> the <user> from the <user-repository> where id = <user-id>.
    <Return> a <NoContent: status> for the <deletion>.
}

(* PATCH request *)
(PATCH /users/{id}: User API) {
    <Extract> the <user-id> from the <request: parameters>.
    <Extract> the <partial-update> from the <request: body>.
    <Retrieve> the <user> from the <user-repository> where id = <user-id>.
    <Transform> the <patched-user> from the <user> with <partial-update>.
    <Store> the <patched-user> into the <user-repository>.
    <Return> an <OK: status> with <patched-user>.
}
```

#### Path Parameters

Use `{param}` syntax for dynamic path segments:

```aro
(GET /users/{userId}/orders/{orderId}: Order API) {
    <Extract> the <user-id> from the <request: parameters userId>.
    <Extract> the <order-id> from the <request: parameters orderId>.
    <Retrieve> the <order> from the <order-repository>
        where userId = <user-id> and id = <order-id>.
    <Return> an <OK: status> with <order>.
}
```

### Event Handlers

Feature sets with "Handler" in the business activity respond to events:

```aro
(* Handle domain events *)
(Send Welcome Email: UserCreated Handler) {
    <Extract> the <user> from the <event: user>.
    <Extract> the <email> from the <user: email>.
    <Send> the <welcome-email> to the <email>.
    <Return> an <OK: status> for the <notification>.
}

(* Handle file system events *)
(Process Upload: FileCreated Handler) {
    <Extract> the <path> from the <event: path>.
    <Read> the <content> from the <file: path>.
    <Transform> the <processed> from the <content>.
    <Store> the <processed> into the <processed-repository>.
    <Return> an <OK: status> for the <processing>.
}

(* Handle socket events *)
(Echo Data: DataReceived Handler) {
    <Extract> the <data> from the <event: data>.
    <Extract> the <connection> from the <event: connection>.
    <Send> the <data> to the <connection>.
    <Return> an <OK: status> for the <echo>.
}
```

## Feature Set Execution

### Triggering

Feature sets are **never called directly**. They're triggered by:

1. **Application start**: `Application-Start` runs once at startup
2. **HTTP requests**: Route handlers match incoming requests
3. **Events**: Event handlers respond to emitted events
4. **Application shutdown**: `Application-End` runs during shutdown

### Execution Flow

Within a feature set, statements execute sequentially:

```aro
(Process Order: Order Management) {
    (* 1. Extract data *)
    <Extract> the <order-data> from the <request: body>.

    (* 2. Validate *)
    <Validate> the <order-data> for the <order-schema>.

    (* 3. Create order *)
    <Create> the <order> with <order-data>.

    (* 4. Store *)
    <Store> the <order> into the <order-repository>.

    (* 5. Emit event *)
    <Emit> an <OrderCreated: event> with <order>.

    (* 6. Return response *)
    <Return> a <Created: status> with <order>.
}
```

### Early Returns

Use control flow to return early:

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

## Organizing Feature Sets

### By File

Organize related feature sets in files:

```
MyApp/
├── main.aro           # Application lifecycle
├── users.aro          # User CRUD operations
├── orders.aro         # Order management
├── payments.aro       # Payment processing
├── notifications.aro  # Email/SMS handlers
└── events.aro         # Domain event handlers
```

### By Domain

Group by business domain:

**users.aro:**
```aro
(GET /users: User API) { ... }
(POST /users: User API) { ... }
(GET /users/{id}: User API) { ... }
(PUT /users/{id}: User API) { ... }
(DELETE /users/{id}: User API) { ... }
```

**orders.aro:**
```aro
(GET /orders: Order API) { ... }
(POST /orders: Order API) { ... }
(GET /orders/{id}: Order API) { ... }
(PUT /orders/{id}/status: Order API) { ... }
```

### By Concern

Group by technical concern:

**events.aro:**
```aro
(Log User Activity: UserCreated Handler) { ... }
(Log User Activity: UserUpdated Handler) { ... }
(Log User Activity: UserDeleted Handler) { ... }
(Send Notification: OrderPlaced Handler) { ... }
(Send Notification: OrderShipped Handler) { ... }
```

## Cross-File Communication

### Publishing Variables

Make variables available to other feature sets:

```aro
(* In config.aro *)
(Load Configuration: Initialization) {
    <Read> the <config: JSON> from the <file: "./config.json">.
    <Publish> as <app-config> <config>.
    <Return> an <OK: status> for the <loading>.
}

(* In any other file *)
(GET /settings: Settings API) {
    <Extract> the <timeout> from the <app-config: timeout>.
    <Return> an <OK: status> with <timeout>.
}
```

### Emitting Events

Trigger other feature sets via events:

```aro
(* In orders.aro *)
(POST /orders: Order API) {
    <Create> the <order> with <order-data>.
    <Store> the <order> into the <order-repository>.
    <Emit> an <OrderCreated: event> with <order>.
    <Return> a <Created: status> with <order>.
}

(* In notifications.aro - automatically triggered *)
(Send Confirmation: OrderCreated Handler) {
    <Extract> the <order> from the <event: order>.
    <Send> the <confirmation-email> to the <order: customerEmail>.
    <Return> an <OK: status> for the <notification>.
}
```

## Best Practices

### Single Responsibility

Each feature set should do one thing well:

```aro
(* Good - focused on one task *)
(Validate Email Format: Validation) {
    <Extract> the <email> from the <input: email>.
    <Validate> the <email> for the <email-pattern>.
    <Return> an <OK: status> for the <validation>.
}

(* Avoid - too many responsibilities *)
(Handle User: User Management) {
    (* Don't mix validation, creation, notification, and logging *)
}
```

### Clear Naming

Names should describe the action and context:

```aro
(* Good - clear and specific *)
(Send Password Reset Email: Authentication) { ... }
(Calculate Order Subtotal: Pricing) { ... }
(Validate Credit Card Number: Payment Validation) { ... }

(* Avoid - vague or unclear *)
(Do Stuff: Things) { ... }
(Process: Handler) { ... }
```

### Consistent Structure

Follow a consistent pattern:

```aro
(Feature Name: Domain) {
    (* 1. Extract/validate inputs *)
    <Extract> the <input> from the <source>.
    <Validate> the <input> for the <schema>.

    (* 2. Business logic *)
    <Create> the <result> with <input>.
    <Transform> the <output> from the <result>.

    (* 3. Side effects *)
    <Store> the <output> into the <repository>.
    <Emit> an <Event: type> with <output>.

    (* 4. Return *)
    <Return> an <OK: status> with <output>.
}
```

## Next Steps

- [Actions](Actions.md) - Understanding and using actions
- [Variables and Data Flow](Variables.md) - Variable binding and scoping
- [Events](Events.md) - Event-driven programming
