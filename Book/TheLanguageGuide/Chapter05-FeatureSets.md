# Chapter 5: Feature Sets

*"A feature set is not a function. It's a response to the world."*

---

## 5.1 What Is a Feature Set?

A feature set is ARO's fundamental unit of organization. It groups related statements that together accomplish a business goal. If statements are sentences, then a feature set is a paragraph—a coherent unit of meaning that expresses a complete thought about what should happen in response to some triggering condition.

The term "feature set" is deliberately chosen over alternatives like "function," "method," or "procedure" because it emphasizes the reactive nature of ARO code. A feature set does not run because you call it. It runs because something in the world triggered it. An HTTP request arrives. A file changes. A custom event is emitted. The application starts. These external stimuli activate feature sets, which then execute their statements in response.

This reactive model is fundamental to understanding ARO. In traditional programming, you write a main function that calls other functions in a sequence you control. In ARO, you write feature sets that respond to events, and the runtime orchestrates when they execute based on what happens. You describe what should occur when certain conditions arise; the runtime ensures your descriptions become reality when those conditions occur.

Every feature set has a two-part header enclosed in parentheses, followed by a body enclosed in curly braces. The header consists of a feature name and a business activity, separated by a colon. The body contains the statements that execute when the feature set is triggered. There is no other structure. No parameter lists, no return type declarations, no visibility modifiers. The simplicity is intentional.

---

## 5.2 The Header

The feature set header serves two purposes: it gives the feature set a unique identity, and it documents what business context the feature set belongs to.

The first part, before the colon, is the feature name. This name must be unique within the application. If two feature sets have the same name, the compiler reports an error. The name identifies this specific feature set for routing purposes—HTTP requests match against feature names that correspond to operation identifiers in the OpenAPI specification, custom events match against handler patterns that include the event name.

Names can take several forms. Simple identifiers like `listUsers` or `getOrder` are common for HTTP handlers because OpenAPI operation identifiers typically follow this style. Hyphenated names like `Application-Start` or `Handle-Error` read more like natural language and are common for lifecycle handlers. Descriptive phrases with spaces like `Send Welcome Email` work well for event handlers because they clearly describe the purpose.

The second part, after the colon, is the business activity. This describes the domain context or purpose of the feature set. For an HTTP API handling user operations, you might use `User API` as the business activity. For an event handler dealing with order processing, you might use `Order Processing`. For the application entry point, you might use the application name itself.

The business activity serves two purposes: documentation and scoping.

As documentation, it helps readers understand what larger goal this feature set contributes to. When you scan a file containing many feature sets, the business activities provide orientation. They answer the question: what is this code about?

As a scoping mechanism, the business activity controls variable visibility. When you publish a variable using the Publish action, that variable becomes accessible only to other feature sets with the same business activity. This enforces modularity and prevents unintended coupling between different business domains.

<div style="text-align: center; margin: 2em 0;">
<svg width="460" height="200" viewBox="0 0 460 200" xmlns="http://www.w3.org/2000/svg"><rect x="10" y="30" width="200" height="140" rx="8" fill="none" stroke="#3b82f6" stroke-width="2" stroke-dasharray="6,3"/><text x="110" y="20" text-anchor="middle" font-family="sans-serif" font-size="11" font-weight="bold" fill="#1e40af">User Management</text><rect x="25" y="50" width="80" height="50" rx="4" fill="#dbeafe" stroke="#3b82f6" stroke-width="1.5"/><text x="65" y="70" text-anchor="middle" font-family="sans-serif" font-size="8" font-weight="bold" fill="#1e40af">Auth</text><text x="65" y="82" text-anchor="middle" font-family="monospace" font-size="7" fill="#3b82f6">publishes</text><text x="65" y="92" text-anchor="middle" font-family="monospace" font-size="7" fill="#3b82f6">&lt;user&gt;</text><rect x="120" y="50" width="80" height="50" rx="4" fill="#dbeafe" stroke="#3b82f6" stroke-width="1.5"/><text x="160" y="70" text-anchor="middle" font-family="sans-serif" font-size="8" font-weight="bold" fill="#1e40af">Profile</text><text x="160" y="85" text-anchor="middle" font-family="monospace" font-size="7" fill="#22c55e">can access</text><line x1="105" y1="75" x2="120" y2="75" stroke="#22c55e" stroke-width="1.5"/><polygon points="120,75 114,71 114,79" fill="#22c55e"/><rect x="70" y="110" width="80" height="50" rx="4" fill="#dbeafe" stroke="#3b82f6" stroke-width="1.5"/><text x="110" y="130" text-anchor="middle" font-family="sans-serif" font-size="8" font-weight="bold" fill="#1e40af">Audit</text><text x="110" y="145" text-anchor="middle" font-family="monospace" font-size="7" fill="#22c55e">can access</text><line x1="65" y1="100" x2="90" y2="110" stroke="#22c55e" stroke-width="1.5"/><polygon points="90,110 83,108 85,114" fill="#22c55e"/><rect x="250" y="30" width="200" height="140" rx="8" fill="none" stroke="#f59e0b" stroke-width="2" stroke-dasharray="6,3"/><text x="350" y="20" text-anchor="middle" font-family="sans-serif" font-size="11" font-weight="bold" fill="#92400e">Order Processing</text><rect x="265" y="50" width="80" height="50" rx="4" fill="#fef3c7" stroke="#f59e0b" stroke-width="1.5"/><text x="305" y="70" text-anchor="middle" font-family="sans-serif" font-size="8" font-weight="bold" fill="#92400e">Checkout</text><text x="305" y="85" text-anchor="middle" font-family="monospace" font-size="7" fill="#ef4444">cannot access</text><rect x="360" y="50" width="80" height="50" rx="4" fill="#fef3c7" stroke="#f59e0b" stroke-width="1.5"/><text x="400" y="70" text-anchor="middle" font-family="sans-serif" font-size="8" font-weight="bold" fill="#92400e">Shipping</text><text x="400" y="85" text-anchor="middle" font-family="monospace" font-size="7" fill="#ef4444">cannot access</text><line x1="210" y1="75" x2="240" y2="75" stroke="#ef4444" stroke-width="1.5" stroke-dasharray="4,2"/><text x="225" y="68" text-anchor="middle" font-family="sans-serif" font-size="12" fill="#ef4444">✗</text><text x="230" y="190" text-anchor="middle" font-family="sans-serif" font-size="9" fill="#6b7280">Published variables are scoped to business activity</text></svg>
</div>
Consider an application with two business activities: `User Management` and `Order Processing`. If a feature set in `User Management` publishes a variable, only other feature sets with the same `User Management` activity can access it. Feature sets in `Order Processing` cannot see that variable, even if they use the same name. This boundary prevents unintended dependencies between unrelated domains.
Certain business activity patterns also have semantic significance. When the pattern ends with "Handler," the runtime treats the feature set as an event handler. The text before "Handler" specifies which event triggers it. This convention transforms what looks like documentation into configuration, allowing you to wire up event handling simply by naming things according to the pattern.
---
## 5.3 Triggering Patterns
<div style="float: right; margin: 0 0 1em 1.5em;">
<svg width="170" height="180" viewBox="0 0 170 180" xmlns="http://www.w3.org/2000/svg">  <!-- Title -->  <text x="85" y="15" text-anchor="middle" font-family="sans-serif" font-size="10" font-weight="bold" fill="#374151">Triggers</text>  <!-- HTTP -->  <rect x="10" y="30" width="65" height="35" rx="4" fill="#dbeafe" stroke="#3b82f6" stroke-width="1.5"/>  <text x="42" y="45" text-anchor="middle" font-family="sans-serif" font-size="8" font-weight="bold" fill="#1e40af">HTTP</text>  <text x="42" y="57" text-anchor="middle" font-family="monospace" font-size="7" fill="#3b82f6">operationId</text>  <!-- Event -->  <rect x="95" y="30" width="65" height="35" rx="4" fill="#dcfce7" stroke="#22c55e" stroke-width="1.5"/>  <text x="127" y="45" text-anchor="middle" font-family="sans-serif" font-size="8" font-weight="bold" fill="#166534">Event</text>  <text x="127" y="57" text-anchor="middle" font-family="monospace" font-size="7" fill="#22c55e">*Handler</text>  <!-- File -->  <rect x="10" y="80" width="65" height="35" rx="4" fill="#fef3c7" stroke="#f59e0b" stroke-width="1.5"/>  <text x="42" y="95" text-anchor="middle" font-family="sans-serif" font-size="8" font-weight="bold" fill="#92400e">File</text>  <text x="42" y="107" text-anchor="middle" font-family="monospace" font-size="7" fill="#f59e0b">File Event</text>  <!-- Socket -->  <rect x="95" y="80" width="65" height="35" rx="4" fill="#f3e8ff" stroke="#a855f7" stroke-width="1.5"/>  <text x="127" y="95" text-anchor="middle" font-family="sans-serif" font-size="8" font-weight="bold" fill="#7c3aed">Socket</text>  <text x="127" y="107" text-anchor="middle" font-family="monospace" font-size="7" fill="#a855f7">Socket Event</text>  <!-- Arrows to feature set -->  <line x1="42" y1="65" x2="85" y2="135" stroke="#6b7280" stroke-width="1"/>  <line x1="127" y1="65" x2="85" y2="135" stroke="#6b7280" stroke-width="1"/>  <line x1="42" y1="115" x2="85" y2="135" stroke="#6b7280" stroke-width="1"/>  <line x1="127" y1="115" x2="85" y2="135" stroke="#6b7280" stroke-width="1"/>  <!-- Feature Set -->  <rect x="35" y="135" width="100" height="30" rx="4" fill="#e0e7ff" stroke="#6366f1" stroke-width="2"/>  <text x="85" y="155" text-anchor="middle" font-family="sans-serif" font-size="9" font-weight="bold" fill="#4338ca">Feature Set</text>  <text x="85" y="178" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#9ca3af">name matches pattern</text></svg>
</div>
Feature sets execute in response to events. The runtime maintains an event bus that routes events to matching feature sets based on their headers. The triggering mechanism matches feature set names to incoming events:
| Trigger Type | Naming Pattern | Example |
|--------------|----------------|---------|
| Lifecycle | `Application-Start`, `Application-End` | Entry point, shutdown |
| HTTP | OpenAPI `operationId` | `listUsers`, `createOrder` |
| Custom Event | `{EventName} Handler` | `UserCreated Handler` |
| File Event | `File Event Handler` | React to file changes |
| Socket Event | `Socket Event Handler` | React to socket messages |
> **See Chapter 12** for application lifecycle details (startup, shutdown, Keepalive).
> **See Chapter 11** for event bus mechanics and handler patterns.
---
## 5.4 Handler Guards

Event handler feature sets can declare a `when` guard directly on the header. The `when` keyword appears between the closing parenthesis and the opening brace, followed by a condition expression. The runtime evaluates this condition each time the event is delivered. If the condition is false, the handler is silently skipped—no statements execute and no error is reported.

```aro
(* Only executes when the notified user is 16 or older *)
(Greet User: NotificationSent Handler) when <age> >= 16 {
    Extract the <user> from the <event: user>.
    Extract the <name> from the <user: name>.
    Log "hello " ++ <name> to the <console>.
    Return an <OK: status> for the <notification>.
}
```

The condition has direct access to the fields of the event's target object. In the example above, `<age>` resolves to the `age` field of the notified user. You do not need to extract the field first—the runtime binds the target's properties into the evaluation context before checking the guard.

Handler guards differ in scope from statement-level `when` clauses. A statement-level `when` clause skips that one statement while execution continues normally. A handler guard skips the entire handler body when the condition is not met. Every handler gets a fresh evaluation—if a `NotificationSent` event is delivered five times (for example, when notifying a collection), each delivery evaluates the guard independently against the specific object being notified.

This pattern is particularly useful when the Notify action targets a collection. The runtime emits one `NotificationSentEvent` per item, and the handler guard acts as an item-level filter without requiring any conditional logic inside the handler body:

```aro
(Application-Start: Notification Demo) {
    Create the <group> with [
        { name: "Bob",   age: 14 },
        { name: "Carol", age: 25 },
        { name: "Eve",   age: 20 }
    ].
    (* Runtime emits one NotificationSentEvent per item in the list *)
    Notify the <group> with "Hello everyone!".
    Return an <OK: status> for the <startup>.
}

(* Guard filters at delivery time — Bob (14) is silently skipped *)
(Greet Adults: NotificationSent Handler) when <age> >= 16 {
    Extract the <user> from the <event: user>.
    Extract the <name> from the <user: name>.
    Log "hello " ++ <name> to the <console>.
    Return an <OK: status> for the <notification>.
}
```

The guard is evaluated with the same comparison operators available in `Filter` and statement-level `when` clauses: `=`, `!=`, `<`, `<=`, `>`, `>=`. String equality (`=`) and inequality (`!=`) work on text values as well.

> **Note:** Handler guards currently work with `{EventType} Handler` feature sets. HTTP handler feature sets use the OpenAPI routing mechanism for filtering and do not support `when` guards on their declarations.

---
## 5.5 Structure and Execution
Within a feature set, statements execute in order from top to bottom. There is no branching, no looping, no early return. Execution begins with the first statement and proceeds through each subsequent statement until reaching the end or encountering an error.
This linearity might seem limiting, but it actually simplifies reasoning about code. When you look at a feature set, you know exactly what order things happen. There are no hidden control flows, no callbacks that might execute at unexpected times, no conditional branches that might skip important steps. What you see is what executes.
The `when` clause provides conditional execution without branching. A statement with a when clause executes only if the condition is true; otherwise, the statement is skipped and execution continues with the next statement. This is not a branch—there is no else path, no alternative action. Either the statement happens or it does not. (For filtering an entire handler based on event data, use the declaration-level `when` guard described in section 5.4.)
Each statement can bind a result to a name. That binding becomes available to all subsequent statements in the same feature set. If you create a value named `user` in the first statement, you can reference `user` in the second, third, and all following statements. This accumulation of bindings creates the context in which later statements operate.
Bindings are immutable within a feature set. Once you bind a name to a value, you cannot rebind it to a different value. If you try, the compiler reports an error. This constraint prevents a common class of bugs where a variable changes unexpectedly. It also pushes you toward descriptive names because you cannot reuse generic names like `temp` or `result`.
---
## 5.6 Scope and Visibility
Variables bound within a feature set are visible only within that feature set. A binding in one feature set does not affect bindings in another. Each feature set has its own isolated symbol table that begins empty and accumulates bindings as statements execute.
This isolation has important implications. If you create a value in one feature set and need to use it in another, you cannot simply reference it by name. The second feature set has no knowledge of what the first feature set bound. This prevents accidental coupling between feature sets that happen to use the same variable names.
When you need to share data between feature sets, you have two options. The first is through events: emit an event carrying the data, and have the receiving feature set extract what it needs from the event payload. This maintains loose coupling because the emitting feature set does not need to know which handlers will receive the event.
The second option is the Publish action, which makes a binding available to other feature sets within the same business activity. When you publish a value under an alias, that alias becomes accessible from any feature set with the same business activity that executes afterward. This scoping enforces modularity—different business domains cannot accidentally depend on each other's published variables. Use publishing for configuration data loaded at startup or for values that need to be shared within a domain, but use it sparingly because shared state complicates reasoning about program behavior.
The execution context provides access to information that is always available. For HTTP handlers, this includes request data: path parameters extracted from the URL, query parameters, headers, and the request body. For event handlers, this includes the event payload containing whatever data was emitted with the event. These context values are not bound to names in advance; you extract them using the Extract action, which binds them to names you choose.
---
## 5.7 Naming Conventions
Good naming makes code readable. In ARO, feature set names serve double duty as identifiers and documentation, so choosing appropriate names is particularly important.
For HTTP handlers, names should match the operation identifiers in your OpenAPI specification exactly. This is not a convention but a requirement—the routing mechanism uses name matching to connect requests to handlers. Operation identifiers typically follow camelCase conventions: `listUsers`, `createOrder`, `getProductById`. Your feature set names should match.
For event handlers, names should be descriptive of the action being performed. The convention is a verb phrase describing the handler's purpose: `Send Welcome Email`, `Update Search Index`, `Notify Administrator`. The business activity specifies the triggering event by ending with "Handler" preceded by the event name: `UserCreated Handler`, `OrderPlaced Handler`.
For lifecycle handlers, use the reserved names exactly as specified. `Application-Start` with a business activity of your choice. `Application-End` with business activity `Success` for graceful shutdown. `Application-End` with business activity `Error` for error handling.
For internal feature sets that handle domain logic but are not directly triggered by external events, use names that describe the business operation. `Calculate Shipping`, `Validate Payment`, `Check Inventory`. These feature sets might be triggered by custom events emitted from other feature sets or might be called through other mechanisms.
---
## 5.8 File Organization
ARO applications are directories, and the runtime automatically discovers all files with the `.aro` extension in that directory. You do not need import statements or explicit file references. When you create a new file and add feature sets to it, those feature sets become part of the application immediately.
This automatic discovery encourages organizing feature sets into files by domain or purpose. A typical pattern separates lifecycle concerns from business logic: one file for application start and shutdown, other files for different domains of functionality. A user service might have a main file for lifecycle, a users file for user-related HTTP handlers, an orders file for order-related handlers, and an events file for event handlers.
The specific organization you choose matters less than consistency. Some teams prefer fine-grained files with only a few feature sets each. Others prefer coarser files that group all related functionality together. What matters is that team members can find what they are looking for and understand where new code should be added.
Because there are no imports, all feature sets are visible throughout the application. An event emitted in one file triggers handlers defined in any file. A variable published in one file is accessible from any feature set with the same business activity, regardless of which file it is defined in. This visibility is powerful but requires discipline. Establish conventions for how feature sets in different files should interact, and document those conventions so team members can follow them.
---
## 5.9 The Context Object
When a feature set executes, it has access to contextual information appropriate to how it was triggered. This information is available through special identifiers that you access using the Extract action.
HTTP handlers have access to request data. The `pathParameters` object contains values extracted from the URL path based on path templates in the OpenAPI specification. If the path template is `/users/{id}`, the `id` path parameter contains whatever value appeared in that position of the actual URL. The `queryParameters` object contains query string parameters. The `headers` object contains HTTP headers. The `request` object contains the full request, including the body.
Event handlers have access to the event that triggered them through the `event` identifier. The event object contains whatever data was included when the event was emitted. If a feature set emits a `UserCreated` event with user data, the handler can extract that user data from the event.
File event handlers have access to file system event details: the path of the file that changed, the type of change that occurred (created, modified, deleted), and other relevant metadata depending on the file system implementation.
You access context data using the Extract action with qualifiers. The expression `<pathParameters: id>` means "the id property of the pathParameters object." The expression `<event: user.email>` means "the email property of the user property of the event object." Qualifiers chain to allow navigation into nested structures.
---
## 5.10 From Here
Feature sets are the building blocks of ARO applications. They respond to events, execute statements, and either complete successfully or encounter errors. The runtime orchestrates their execution based on matching patterns between events and feature set headers.
The next chapter explores how data flows through feature sets and between them. Understanding data flow is essential for building applications that share information appropriately while maintaining the loose coupling that makes event-driven architectures powerful.
---
*Next: Chapter 6 — Data Flow*