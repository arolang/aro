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
    <Keepalive> the <application> for the <events>.
    <Return> an <OK: status> for the <startup>.
}

(* Called on graceful shutdown - optional, at most one *)
(Application-End: Success) {
    <Log> the <message> for the <console> with "Shutting down...".
    <Return> an <OK: status> for the <shutdown>.
}

(* Called on error - optional, at most one *)
(Application-End: Error) {
    <Extract> the <error> from the <shutdown: error>.
    <Log> the <error: message> for the <console> with <error>.
    <Return> an <OK: status> for the <error-handling>.
}
```

### HTTP Route Handlers (Contract-First)

ARO uses **contract-first** HTTP development. Routes are defined in `openapi.yaml`, and feature sets are named after `operationId` values:

**openapi.yaml:**
```yaml
openapi: 3.0.3
info:
  title: User API
  version: 1.0.0

paths:
  /users:
    get:
      operationId: listUsers
    post:
      operationId: createUser
  /users/{id}:
    get:
      operationId: getUser
    put:
      operationId: updateUser
    delete:
      operationId: deleteUser
```

**handlers.aro:**
```aro
(* GET /users *)
(listUsers: User API) {
    <Retrieve> the <users> from the <user-repository>.
    <Return> an <OK: status> with <users>.
}

(* POST /users *)
(createUser: User API) {
    <Extract> the <user-data> from the <request: body>.
    <Create> the <user> with <user-data>.
    <Store> the <user> into the <user-repository>.
    <Return> a <Created: status> with <user>.
}

(* GET /users/{id} *)
(getUser: User API) {
    <Extract> the <user-id> from the <pathParameters: id>.
    <Retrieve> the <user> from the <user-repository> where id = <user-id>.
    <Return> an <OK: status> with <user>.
}

(* PUT /users/{id} *)
(updateUser: User API) {
    <Extract> the <user-id> from the <pathParameters: id>.
    <Extract> the <updates> from the <request: body>.
    <Retrieve> the <user> from the <user-repository> where id = <user-id>.
    <Transform> the <updated-user> from the <user> with <updates>.
    <Store> the <updated-user> into the <user-repository>.
    <Return> an <OK: status> with <updated-user>.
}

(* DELETE /users/{id} *)
(deleteUser: User API) {
    <Extract> the <user-id> from the <pathParameters: id>.
    <Delete> the <user> from the <user-repository> where id = <user-id>.
    <Return> a <NoContent: status> for the <deletion>.
}
```

#### Path Parameters

Access path parameters via `<pathParameters: name>`:

```aro
(* For /users/{userId}/orders/{orderId} *)
(getUserOrder: Order API) {
    <Extract> the <user-id> from the <pathParameters: userId>.
    <Extract> the <order-id> from the <pathParameters: orderId>.
    <Retrieve> the <order> from the <order-repository>
        where userId = <user-id> and id = <order-id>.
    <Return> an <OK: status> with <order>.
}
```

### Event Handlers

Feature sets with "Handler" in the business activity respond to events:

```aro
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
2. **HTTP requests**: Route handlers match incoming requests via operationId
3. **Events**: Event handlers respond to file/socket events
4. **Application shutdown**: `Application-End` runs during shutdown

### Execution Flow

Within a feature set, statements execute sequentially:

```aro
(createOrder: Order Management) {
    (* 1. Extract data *)
    <Extract> the <order-data> from the <request: body>.

    (* 2. Validate *)
    <Validate> the <order-data> for the <order-schema>.

    (* 3. Create order *)
    <Create> the <order> with <order-data>.

    (* 4. Store *)
    <Store> the <order> into the <order-repository>.

    (* 5. Return response *)
    <Return> a <Created: status> with <order>.
}
```

### Early Returns

Use control flow to return early:

```aro
(getUser: User API) {
    <Extract> the <user-id> from the <pathParameters: id>.
    <Retrieve> the <user> from the <user-repository> where id = <user-id>.

    <Return> a <NotFound: status> for the <missing: user> when <user> is empty.

    <Return> an <OK: status> with <user>.
}
```

## Organizing Feature Sets

### By File

Organize related feature sets in files:

```
MyApp/
├── openapi.yaml       # API contract (required for HTTP)
├── main.aro           # Application lifecycle
├── users.aro          # User CRUD operations
├── orders.aro         # Order management
├── payments.aro       # Payment processing
└── events.aro         # Event handlers
```

### By Domain

Group by business domain:

**users.aro:**
```aro
(listUsers: User API) { ... }
(createUser: User API) { ... }
(getUser: User API) { ... }
(updateUser: User API) { ... }
(deleteUser: User API) { ... }
```

**orders.aro:**
```aro
(listOrders: Order API) { ... }
(createOrder: Order API) { ... }
(getOrder: Order API) { ... }
(updateOrderStatus: Order API) { ... }
```

### By Concern

Group by technical concern:

**events.aro:**
```aro
(Log User Activity: FileCreated Handler) { ... }
(Process Upload: FileCreated Handler) { ... }
(Echo Data: DataReceived Handler) { ... }
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
(getSettings: Settings API) {
    <Extract> the <timeout> from the <app-config: timeout>.
    <Return> an <OK: status> with <timeout>.
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
(featureName: Domain) {
    (* 1. Extract/validate inputs *)
    <Extract> the <input> from the <source>.
    <Validate> the <input> for the <schema>.

    (* 2. Business logic *)
    <Create> the <result> with <input>.
    <Transform> the <output> from the <result>.

    (* 3. Side effects *)
    <Store> the <output> into the <repository>.

    (* 4. Return *)
    <Return> an <OK: status> with <output>.
}
```

## Next Steps

- [Actions](actions.html) - Understanding and using actions
- [Variables and Data Flow](variables.html) - Variable binding and scoping
- [Events](events.html) - Event-driven programming
