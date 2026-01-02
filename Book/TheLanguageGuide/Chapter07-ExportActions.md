# Chapter 7: Export Actions

*"Know where your data goes."*

---

## 7.1 Three Paths Out

When data leaves your feature set, it takes one of three paths. Each path serves a distinct purpose in the ARO architecture. Understanding which path to choose is essential for building well-structured applications.

<div style="text-align: center; margin: 2em 0;">
<svg width="500" height="200" viewBox="0 0 500 200" xmlns="http://www.w3.org/2000/svg">
  <!-- Central feature set box -->
  <rect x="175" y="20" width="150" height="50" rx="5" fill="#e0e7ff" stroke="#6366f1" stroke-width="2"/>
  <text x="250" y="50" text-anchor="middle" font-family="sans-serif" font-size="12" font-weight="bold" fill="#4338ca">Feature Set</text>

  <!-- Three diverging arrows -->
  <!-- Store path (left) -->
  <line x1="200" y1="70" x2="100" y2="130" stroke="#22c55e" stroke-width="2"/>
  <polygon points="100,130 94,122 106,122" fill="#22c55e"/>
  <rect x="50" y="140" width="100" height="40" rx="5" fill="#dcfce7" stroke="#22c55e" stroke-width="2"/>
  <text x="100" y="158" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#166534">Repository</text>
  <text x="100" y="172" text-anchor="middle" font-family="sans-serif" font-size="9" fill="#16a34a">&lt;Store&gt;</text>

  <!-- Emit path (center) -->
  <line x1="250" y1="70" x2="250" y2="130" stroke="#f59e0b" stroke-width="2"/>
  <polygon points="250,130 244,120 256,120" fill="#f59e0b"/>
  <rect x="200" y="140" width="100" height="40" rx="5" fill="#fef3c7" stroke="#f59e0b" stroke-width="2"/>
  <text x="250" y="158" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#92400e">Event Bus</text>
  <text x="250" y="172" text-anchor="middle" font-family="sans-serif" font-size="9" fill="#d97706">&lt;Emit&gt;</text>

  <!-- Publish path (right) -->
  <line x1="300" y1="70" x2="400" y2="130" stroke="#8b5cf6" stroke-width="2"/>
  <polygon points="400,130 394,122 406,122" fill="#8b5cf6"/>
  <rect x="350" y="140" width="100" height="40" rx="5" fill="#f3e8ff" stroke="#8b5cf6" stroke-width="2"/>
  <text x="400" y="158" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#6b21a8">Global Registry</text>
  <text x="400" y="172" text-anchor="middle" font-family="sans-serif" font-size="9" fill="#7c3aed">&lt;Publish&gt;</text>
</svg>
</div>

**Store** sends data to a repository. The data persists for the application's lifetime and can be retrieved later by any feature set. Use Store when you need to save data for future access.

**Emit** sends data to the event bus. Handlers that match the event type receive the data and execute independently. Use Emit when you want to trigger reactive behavior in other parts of the application.

**Publish** registers data in a global registry. The data becomes accessible to other feature sets but does not trigger any handlers. Use Publish when you need to share a value without triggering logic.

Each path has different characteristics that make it suitable for different scenarios. The following sections explore each path in detail.

---

## 7.2 Store: Persistent Data

The Store action saves data to a named repository. Repositories are identified by names ending with `-repository`. This naming convention is not merely a style guide—the runtime uses this suffix to recognize storage targets.

### When to Use Store

Store is the right choice when:

- You need to save data for later retrieval
- Multiple feature sets need to query the same data
- You want to maintain a collection of records
- You need audit logs or history

### Basic Storage

The simplest form of Store appends a value to a repository:

```aro
(createUser: User API) {
    <Extract> the <user-data> from the <request: body>.
    <Create> the <user> with <user-data>.

    (* Store saves the user to the repository *)
    <Store> the <user> into the <user-repository>.

    <Return> a <Created: status> with <user>.
}
```

Each Store operation appends to the repository. If you store three users, the repository contains all three. Repositories are list-based, not key-value stores.

### Retrieval

Data stored in a repository can be retrieved by any feature set:

```aro
(listUsers: User API) {
    (* Retrieve all users from the repository *)
    <Retrieve> the <users> from the <user-repository>.
    <Return> an <OK: status> with <users>.
}

(getUser: User API) {
    <Extract> the <id> from the <pathParameters: id>.

    (* Retrieve with a filter *)
    <Retrieve> the <user> from the <user-repository> where id = <id>.
    <Return> an <OK: status> with <user>.
}
```

The where clause filters the repository contents. Multiple conditions can be combined:

```aro
<Retrieve> the <orders> from the <order-repository>
    where status = "pending" and customer = <customer-id>.
```

### Repository Observers

When data is stored, updated, or deleted in a repository, observers can react automatically. This is a powerful pattern for implementing side effects without coupling:

```aro
(* This observer runs automatically when user-repository changes *)
(Audit Changes: user-repository Observer) {
    <Extract> the <changeType> from the <event: changeType>.
    <Extract> the <entityId> from the <event: entityId>.

    <Compute> the <message> from "[AUDIT] user-repository: " + <changeType> + " (id: " + <entityId> + ")".
    <Log> <message> to the <console>.

    <Return> an <OK: status> for the <audit>.
}
```

The observer receives an event with details about the change:

| Field | Description |
|-------|-------------|
| `changeType` | "created", "updated", or "deleted" |
| `entityId` | ID of the affected entity (if the entity has an "id" field) |
| `newValue` | The new value (nil for deletes) |
| `oldValue` | The previous value (nil for creates) |
| `repositoryName` | Name of the repository |

---

## 7.3 Emit: Event-Driven Communication

The Emit action fires a domain event that triggers handlers in other feature sets. Unlike Store, the event payload is transient—it exists only during handler execution. Once all handlers complete, the event is gone.

### When to Use Emit

Emit is the right choice when:

- You want to trigger side effects (notifications, analytics, etc.)
- You are building event-driven workflows or sagas
- You need loose coupling between feature sets
- Multiple handlers should react to the same occurrence

### Basic Emission

Emit creates a domain event with a type and payload:

```aro
(createUser: User API) {
    <Extract> the <user-data> from the <request: body>.
    <Create> the <user> with <user-data>.
    <Store> the <user> into the <user-repository>.

    (* Emit notifies interested handlers *)
    <Emit> a <UserCreated: event> with <user>.

    <Return> a <Created: status> with <user>.
}
```

The event type is derived from the result descriptor. In this case, `UserCreated` becomes the event type, and handlers for "UserCreated Handler" are triggered.

### Event Handlers

Handlers receive the event payload and can extract data from it:

```aro
(* Triggered by <Emit> a <UserCreated: event> with <user> *)
(Send Welcome Email: UserCreated Handler) {
    <Extract> the <user> from the <event: user>.
    <Extract> the <email> from the <user: email>.

    <Send> the <welcome-email> to the <email-service> with {
        to: <email>,
        subject: "Welcome!",
        template: "welcome"
    }.

    <Return> an <OK: status> for the <notification>.
}

(* Another handler for the same event *)
(Track Signup: UserCreated Handler) {
    <Extract> the <user> from the <event: user>.

    <Send> the <analytics-event> to the <analytics-service> with {
        event: "user_signup",
        properties: <user>
    }.

    <Return> an <OK: status> for the <tracking>.
}
```

Both handlers execute independently when a UserCreated event is emitted. The emitting code does not know or care which handlers exist.

### Event Chains

Handlers can emit additional events, creating processing chains:

```aro
(* OrderPlaced triggers inventory reservation *)
(Reserve Inventory: OrderPlaced Handler) {
    <Extract> the <order> from the <event: order>.
    <Update> the <inventory> for the <order: items>.

    (* Continue the chain *)
    <Emit> an <InventoryReserved: event> with <order>.

    <Return> an <OK: status> for the <reservation>.
}

(* InventoryReserved triggers payment *)
(Process Payment: InventoryReserved Handler) {
    <Extract> the <order> from the <event: order>.
    <Send> the <charge> to the <payment-gateway> with <order>.

    (* Continue the chain *)
    <Emit> a <PaymentProcessed: event> with <order>.

    <Return> an <OK: status> for the <payment>.
}
```

This pattern enables complex workflows while keeping each handler focused on a single responsibility.

---

## 7.4 Publish: Shared Values

The Publish action makes a value globally accessible without triggering any logic. Published values are available to other feature sets within the same business activity but do not cause handlers to execute.

### When to Use Publish

Publish is rarely needed. Consider it only when:

- You load configuration at startup that multiple feature sets need
- You create a singleton resource (connection pool, service instance)
- You compute a value that multiple feature sets use without needing events

In most cases, Emit provides better decoupling. Use Publish only when you specifically need a shared value without reactive behavior.

### Basic Publication

Publish registers a value under an alias:

```aro
(Application-Start: Config Loader) {
    <Read> the <config-data> from the <file: "./config.json">.
    <Parse> the <config: JSON> from the <config-data>.

    (* Make config available to all feature sets *)
    <Publish> as <app-config> <config>.

    <Return> an <OK: status> for the <startup>.
}
```

The alias (`app-config`) becomes the name other feature sets use to access the value.

### Accessing Published Values

Published values can be referenced directly by their alias:

```aro
(getApiUrl: Configuration Handler) {
    (* app-config was published at startup *)
    <Extract> the <url> from the <app-config: apiUrl>.

    <Return> an <OK: status> with <url>.
}
```

Published values are scoped to the business activity. Feature sets in different business activities cannot access each other's published values.

---

## 7.5 Decision Guide

Choosing between Store, Emit, and Publish becomes straightforward when you ask the right question.

<div style="text-align: center; margin: 2em 0;">
<svg width="450" height="220" viewBox="0 0 450 220" xmlns="http://www.w3.org/2000/svg">
  <!-- Question boxes and decision flow -->
  <rect x="125" y="10" width="200" height="35" rx="5" fill="#f3f4f6" stroke="#6b7280" stroke-width="1.5"/>
  <text x="225" y="32" text-anchor="middle" font-family="sans-serif" font-size="11" fill="#374151">What do you need?</text>

  <!-- Three branches -->
  <line x1="175" y1="45" x2="80" y2="80" stroke="#6b7280" stroke-width="1.5"/>
  <polygon points="80,80 88,74 84,82" fill="#6b7280"/>
  <line x1="225" y1="45" x2="225" y2="80" stroke="#6b7280" stroke-width="1.5"/>
  <polygon points="225,80 220,72 230,72" fill="#6b7280"/>
  <line x1="275" y1="45" x2="370" y2="80" stroke="#6b7280" stroke-width="1.5"/>
  <polygon points="370,80 362,74 366,82" fill="#6b7280"/>

  <!-- Store branch -->
  <rect x="20" y="80" width="120" height="45" rx="5" fill="#dcfce7" stroke="#22c55e" stroke-width="1.5"/>
  <text x="80" y="98" text-anchor="middle" font-family="sans-serif" font-size="9" fill="#166534">Persist data for</text>
  <text x="80" y="112" text-anchor="middle" font-family="sans-serif" font-size="9" fill="#166534">later retrieval?</text>
  <line x1="80" y1="125" x2="80" y2="155" stroke="#22c55e" stroke-width="1.5"/>
  <polygon points="80,155 75,148 85,148" fill="#22c55e"/>
  <rect x="30" y="160" width="100" height="30" rx="5" fill="#22c55e"/>
  <text x="80" y="180" text-anchor="middle" font-family="sans-serif" font-size="11" font-weight="bold" fill="white">&lt;Store&gt;</text>

  <!-- Emit branch -->
  <rect x="165" y="80" width="120" height="45" rx="5" fill="#fef3c7" stroke="#f59e0b" stroke-width="1.5"/>
  <text x="225" y="98" text-anchor="middle" font-family="sans-serif" font-size="9" fill="#92400e">Trigger handlers</text>
  <text x="225" y="112" text-anchor="middle" font-family="sans-serif" font-size="9" fill="#92400e">reactively?</text>
  <line x1="225" y1="125" x2="225" y2="155" stroke="#f59e0b" stroke-width="1.5"/>
  <polygon points="225,155 220,148 230,148" fill="#f59e0b"/>
  <rect x="175" y="160" width="100" height="30" rx="5" fill="#f59e0b"/>
  <text x="225" y="180" text-anchor="middle" font-family="sans-serif" font-size="11" font-weight="bold" fill="white">&lt;Emit&gt;</text>

  <!-- Publish branch -->
  <rect x="310" y="80" width="120" height="45" rx="5" fill="#f3e8ff" stroke="#8b5cf6" stroke-width="1.5"/>
  <text x="370" y="98" text-anchor="middle" font-family="sans-serif" font-size="9" fill="#6b21a8">Share value without</text>
  <text x="370" y="112" text-anchor="middle" font-family="sans-serif" font-size="9" fill="#6b21a8">triggering logic?</text>
  <line x1="370" y1="125" x2="370" y2="155" stroke="#8b5cf6" stroke-width="1.5"/>
  <polygon points="370,155 365,148 375,148" fill="#8b5cf6"/>
  <rect x="320" y="160" width="100" height="30" rx="5" fill="#8b5cf6"/>
  <text x="370" y="180" text-anchor="middle" font-family="sans-serif" font-size="11" font-weight="bold" fill="white">&lt;Publish&gt;</text>
</svg>
</div>

### Comparison Table

| Aspect | Store | Emit | Publish |
|--------|-------|------|---------|
| **Target** | Repository | Event bus | Global registry |
| **Triggers** | Repository observers | Event handlers | Nothing |
| **Data lifespan** | Application lifetime | Handler execution only | Application lifetime |
| **Access pattern** | `<Retrieve>` with filters | `<Extract>` from event | Direct variable reference |
| **Typical use** | CRUD data, audit logs | Reactive workflows, notifications | Config, singletons |
| **Coupling** | Medium (via repository name) | Low (via event type) | Low (via alias name) |

---

## 7.6 Common Mistakes

### Using Emit for Persistence

A common mistake is emitting an event when you need persistent data:

```aro
(* WRONG: Events are transient *)
(createMessage: Chat API) {
    <Extract> the <message-data> from the <request: body>.
    <Create> the <message> with <message-data>.

    (* This event disappears after handlers complete! *)
    <Emit> a <MessageCreated: event> with <message>.

    <Return> a <Created: status> with <message>.
}

(listMessages: Chat API) {
    (* ERROR: There's no way to retrieve emitted events *)
    (* The messages are gone! *)
}
```

The fix is to Store the data:

```aro
(* CORRECT: Store for persistence, Emit for notifications *)
(createMessage: Chat API) {
    <Extract> the <message-data> from the <request: body>.
    <Create> the <message> with <message-data>.

    (* Store the message for later retrieval *)
    <Store> the <message> into the <message-repository>.

    (* Also emit for any handlers that want to react *)
    <Emit> a <MessageCreated: event> with <message>.

    <Return> a <Created: status> with <message>.
}

(listMessages: Chat API) {
    (* Now we can retrieve stored messages *)
    <Retrieve> the <messages> from the <message-repository>.
    <Return> an <OK: status> with <messages>.
}
```

### Using Store for Communication

Another mistake is storing data just to trigger an observer when Emit would be cleaner:

```aro
(* AWKWARD: Using store just to trigger behavior *)
(processPayment: Payment API) {
    <Extract> the <payment> from the <request: body>.

    (* Storing just to trigger the observer *)
    <Store> the <payment> into the <payment-notification-repository>.

    <Return> an <OK: status> with <payment>.
}

(Send Receipt: payment-notification-repository Observer) {
    (* This works but is awkward *)
    <Extract> the <payment> from the <event: newValue>.
    <Send> the <receipt> to the <email-service>.
}
```

The fix is to use Emit for reactive behavior:

```aro
(* BETTER: Use Emit for reactive communication *)
(processPayment: Payment API) {
    <Extract> the <payment> from the <request: body>.

    (* Emit for handlers that need to react *)
    <Emit> a <PaymentProcessed: event> with <payment>.

    <Return> an <OK: status> with <payment>.
}

(Send Receipt: PaymentProcessed Handler) {
    <Extract> the <payment> from the <event: payment>.
    <Send> the <receipt> to the <email-service>.
}
```

Use Store when you need persistence. Use Emit when you need reactive behavior. Use both when you need both.

### Overusing Publish

Publish is sometimes overused when Emit would provide better decoupling:

```aro
(* QUESTIONABLE: Publishing user for other feature sets *)
(createUser: User API) {
    <Create> the <user> with <user-data>.
    <Store> the <user> into the <user-repository>.

    (* Publishing forces other feature sets to poll for this value *)
    <Publish> as <latest-user> <user>.

    <Return> a <Created: status> with <user>.
}
```

The problem is that other feature sets must know to check for the published value. With Emit, handlers are triggered automatically:

```aro
(* BETTER: Emit notifies interested parties automatically *)
(createUser: User API) {
    <Create> the <user> with <user-data>.
    <Store> the <user> into the <user-repository>.

    (* Handlers are triggered automatically *)
    <Emit> a <UserCreated: event> with <user>.

    <Return> a <Created: status> with <user>.
}
```

Reserve Publish for truly shared values like configuration, not for communication between feature sets.

---

## 7.7 Complete Example: User Registration

Here is a realistic example that uses all three export actions appropriately. The scenario is user registration with email verification, welcome notifications, and analytics tracking.

**main.aro** — Application startup:

```aro
(Application-Start: User Service) {
    <Read> the <config-data> from the <file: "./config.json">.
    <Parse> the <config: JSON> from the <config-data>.

    (* Publish config for all feature sets *)
    <Publish> as <app-config> <config>.

    <Start> the <http-server> with <contract>.
    <Keepalive> the <application> for the <events>.
    <Return> an <OK: status> for the <startup>.
}
```

**users.aro** — User creation:

```aro
(createUser: User API) {
    <Extract> the <user-data> from the <request: body>.
    <Create> the <user> with <user-data>.

    (* Store for persistence — we need to retrieve users later *)
    <Store> the <user> into the <user-repository>.

    (* Emit for reactive behavior — handlers will send emails, track analytics *)
    <Emit> a <UserCreated: event> with <user>.

    <Return> a <Created: status> with <user>.
}

(getUser: User API) {
    <Extract> the <id> from the <pathParameters: id>.

    (* Retrieve stored user *)
    <Retrieve> the <user> from the <user-repository> where id = <id>.

    <Return> an <OK: status> with <user>.
}

(listUsers: User API) {
    (* Retrieve all stored users *)
    <Retrieve> the <users> from the <user-repository>.

    <Return> an <OK: status> with <users>.
}
```

**handlers.aro** — Event handlers:

```aro
(* Send welcome email when user is created *)
(Send Welcome Email: UserCreated Handler) {
    <Extract> the <user> from the <event: user>.
    <Extract> the <email> from the <user: email>.

    (* Access published config *)
    <Extract> the <from-address> from the <app-config: email.fromAddress>.

    <Send> the <welcome-email> to the <email-service> with {
        to: <email>,
        from: <from-address>,
        subject: "Welcome to our service!",
        template: "welcome"
    }.

    <Return> an <OK: status> for the <notification>.
}

(* Track signup in analytics *)
(Track Signup: UserCreated Handler) {
    <Extract> the <user> from the <event: user>.

    (* Access published config *)
    <Extract> the <analytics-key> from the <app-config: analytics.apiKey>.

    <Send> the <analytics-event> to the <analytics-service> with {
        apiKey: <analytics-key>,
        event: "user_signup",
        properties: {
            userId: <user: id>,
            email: <user: email>,
            createdAt: <user: createdAt>
        }
    }.

    <Return> an <OK: status> for the <tracking>.
}
```

**observers.aro** — Repository observers:

```aro
(* Audit all changes to user repository *)
(Audit User Changes: user-repository Observer) {
    <Extract> the <changeType> from the <event: changeType>.
    <Extract> the <entityId> from the <event: entityId>.
    <Extract> the <timestamp> from the <event: timestamp>.

    <Compute> the <message> from "[AUDIT] " + <timestamp> + " user-repository: " + <changeType> + " (id: " + <entityId> + ")".
    <Log> <message> to the <console>.

    <Return> an <OK: status> for the <audit>.
}
```

This example demonstrates:

- **Publish** for shared configuration loaded at startup
- **Store** for user data that needs to be retrieved later
- **Emit** for triggering welcome emails and analytics
- **Repository observers** for audit logging

Each action serves its intended purpose, creating a well-structured, maintainable application.

---

*Next: Chapter 8 — Computations*
