# Chapter 21: Patterns & Practices

*"Good patterns emerge from solving real problems."*

---

## 21.1 CRUD Patterns

Most business applications need to create, read, update, and delete resources. These CRUD operations follow predictable patterns in ARO that you can apply consistently across your domains.

A complete CRUD service for a resource typically has five feature sets. The list operation retrieves collections with pagination support. The get operation retrieves a single resource by identifier. The create operation makes new resources, stores them, and emits events. The update operation modifies existing resources while preserving consistency. The delete operation removes resources and notifies interested parties.

The list operation extracts pagination parameters from the query string, retrieves matching records with those constraints, computes the total count for pagination metadata, and returns a structured response with both data and pagination information. Clients need the total to know how many pages exist.

The get operation extracts the identifier from the path, retrieves the matching record, and returns it. If no record matches, the runtime generates a not-found error automatically. You do not write explicit handling for the missing case.

The create operation extracts data from the request body, validates it against the resource schema, creates the entity, stores it to the repository, emits a created event for downstream processing, and returns the new entity with a Created status.

The update operation must handle the merge between existing and new data. It extracts the identifier and update data, retrieves the existing record, merges the updates into the existing record, stores the result, emits an updated event, and returns the modified entity.

The delete operation extracts the identifier, deletes the matching record, emits a deleted event, and returns NoContent to indicate successful completion without a response body.

---

## 21.2 Event Sourcing

Event sourcing stores the history of changes rather than current state. Instead of updating a record in place, you append an event describing what happened. Current state is computed by replaying events from the beginning.

This pattern provides a complete audit trail of every change. You can reconstruct state at any point in time by replaying events up to that moment. You can analyze patterns of changes. You can correct errors by appending compensating events rather than modifying history.

In ARO, event sourcing stores events to an event store repository rather than storing entities to a regular repository. Each event includes its type, the aggregate identifier it belongs to, the data describing what happened, and a timestamp.

Reading current state requires retrieving all events for an aggregate and reducing them to compute the current state. A custom action can encapsulate this reduction logic, taking a list of events and producing the current state object.

Projections build optimized read models from the event stream. Event handlers listen for events and update read-optimized data structures. This separates the write path (append events) from the read path (query projections), enabling optimization of each independently.

Event sourcing adds complexity compared to simple CRUD. It is most valuable when the audit trail is important, when you need to analyze change patterns, or when you need to support time travel queries. For simpler applications, traditional state-based storage is often sufficient.

---

## 21.3 The Saga Pattern

<div style="float: left; margin: 0 1.5em 1em 0;">
<svg width="160" height="180" viewBox="0 0 160 180" xmlns="http://www.w3.org/2000/svg">  <!-- Title -->  <text x="80" y="15" text-anchor="middle" font-family="sans-serif" font-size="10" font-weight="bold" fill="#166534">Saga Flow</text>  <!-- Step 1 -->  <rect x="50" y="25" width="60" height="22" rx="3" fill="#dcfce7" stroke="#22c55e" stroke-width="1.5"/>  <text x="80" y="40" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#166534">Step 1</text>  <line x1="80" y1="47" x2="80" y2="57" stroke="#22c55e" stroke-width="1.5"/>  <polygon points="80,57 76,52 84,52" fill="#22c55e"/>  <!-- Step 2 -->  <rect x="50" y="60" width="60" height="22" rx="3" fill="#dcfce7" stroke="#22c55e" stroke-width="1.5"/>  <text x="80" y="75" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#166534">Step 2</text>  <line x1="80" y1="82" x2="80" y2="92" stroke="#22c55e" stroke-width="1.5"/>  <polygon points="80,92 76,87 84,87" fill="#22c55e"/>  <!-- Step 3 (fails) -->  <rect x="50" y="95" width="60" height="22" rx="3" fill="#fee2e2" stroke="#ef4444" stroke-width="1.5"/>  <text x="80" y="110" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#991b1b">Step 3 ✗</text>  <!-- Compensation arrows -->  <line x1="50" y1="106" x2="25" y2="106" stroke="#ef4444" stroke-width="1" stroke-dasharray="3,2"/>  <line x1="25" y1="106" x2="25" y2="40" stroke="#ef4444" stroke-width="1" stroke-dasharray="3,2"/>  <polygon points="25,40 21,46 29,46" fill="#ef4444"/>  <!-- Compensation boxes -->  <rect x="5" y="125" width="45" height="18" rx="2" fill="#fef3c7" stroke="#f59e0b" stroke-width="1"/>  <text x="27" y="137" text-anchor="middle" font-family="sans-serif" font-size="6" fill="#92400e">undo 2</text>  <rect x="55" y="125" width="45" height="18" rx="2" fill="#fef3c7" stroke="#f59e0b" stroke-width="1"/>  <text x="77" y="137" text-anchor="middle" font-family="sans-serif" font-size="6" fill="#92400e">undo 1</text>  <!-- Labels -->  <text x="80" y="158" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#9ca3af">compensate on failure</text></svg>
</div>

Sagas coordinate long-running business processes that span multiple steps, each of which might succeed or fail independently. Rather than executing all steps in a single transaction, sagas chain steps through events and provide compensation when steps fail.

A typical saga begins with an initiating request that starts the process. This first step stores initial state, emits an event to trigger the next step, and returns immediately with an accepted status. The caller knows the process has started but not that it has completed.

Each subsequent step is an event handler that performs one piece of the overall process. It receives the event from the previous step, does its work, and emits an event to trigger the next step. Success propagates forward through the event chain.

When a step fails, compensation handlers clean up the effects of previous steps. A PaymentFailed event might trigger a handler that releases reserved inventory. An InventoryUnavailable event might trigger a handler that cancels the pending order. Each compensation reverses one step of the saga.

The saga pattern trades atomicity for availability. Unlike a transaction that succeeds or fails completely, a saga can be partially complete while some steps succeed and others fail. The compensation handlers bring the system to a consistent state, but intermediate states are visible.

Use sagas when you need to coordinate actions across multiple services or when steps take significant time. For quick operations that can complete atomically, simpler patterns are appropriate.

---

## 21.4 The Gateway Pattern

API gateways aggregate data from multiple backend services into unified responses. Rather than having clients make multiple calls and combine results, the gateway handles this coordination.

A gateway handler extracts request parameters, makes parallel or sequential calls to backend services, combines the results into a unified response, and returns it. The client sees a single endpoint that provides rich, aggregated data.

The pattern is valuable when clients need data from multiple sources. A product details page might need product information from the catalog service, stock levels from the inventory service, reviews from the review service, and pricing from the pricing service. A gateway endpoint fetches all of this and returns a complete product details object.

Gateway handlers should be designed for resilience. Backend services might be slow or unavailable. Consider timeout handling, fallback data for unavailable services, and partial responses when some data cannot be retrieved.

The gateway pattern can also handle cross-cutting concerns like authentication, rate limiting, and logging that apply across all backend calls. The gateway becomes a single enforcement point for these concerns.

---

## 21.5 Command Query Responsibility Segregation

<div style="float: right; margin: 0 0 1em 1.5em;">
<svg width="180" height="160" viewBox="0 0 180 160" xmlns="http://www.w3.org/2000/svg">  <!-- Title -->  <text x="90" y="15" text-anchor="middle" font-family="sans-serif" font-size="10" font-weight="bold" fill="#374151">CQRS</text>  <!-- Command side -->  <rect x="10" y="30" width="70" height="25" rx="3" fill="#fee2e2" stroke="#ef4444" stroke-width="1.5"/>  <text x="45" y="46" text-anchor="middle" font-family="sans-serif" font-size="8" font-weight="bold" fill="#991b1b">Commands</text>  <line x1="45" y1="55" x2="45" y2="75" stroke="#ef4444" stroke-width="1.5"/>  <polygon points="45,75 40,68 50,68" fill="#ef4444"/>  <rect x="10" y="80" width="70" height="25" rx="3" fill="#fef3c7" stroke="#f59e0b" stroke-width="1.5"/>  <text x="45" y="96" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#92400e">Write Store</text>  <!-- Query side -->  <rect x="100" y="30" width="70" height="25" rx="3" fill="#dbeafe" stroke="#3b82f6" stroke-width="1.5"/>  <text x="135" y="46" text-anchor="middle" font-family="sans-serif" font-size="8" font-weight="bold" fill="#1e40af">Queries</text>  <line x1="135" y1="55" x2="135" y2="75" stroke="#3b82f6" stroke-width="1.5"/>  <polygon points="135,75 130,68 140,68" fill="#3b82f6"/>  <rect x="100" y="80" width="70" height="25" rx="3" fill="#dcfce7" stroke="#22c55e" stroke-width="1.5"/>  <text x="135" y="96" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#166534">Read Model</text>  <!-- Sync arrow -->  <line x1="80" y1="92" x2="100" y2="92" stroke="#9ca3af" stroke-width="1" stroke-dasharray="3,2"/>  <polygon points="100,92 95,89 95,95" fill="#9ca3af"/>  <text x="90" y="118" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#9ca3af">events sync</text>  <!-- Labels -->  <text x="45" y="140" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#ef4444">consistency</text>  <text x="135" y="140" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#3b82f6">optimized</text></svg>
</div>

CQRS separates read operations from write operations, using different models optimized for each. Commands (writes) update the authoritative data store. Queries (reads) retrieve data from optimized read models.

The write side receives commands, validates them, updates the authoritative store, and emits events describing what changed. The focus is on maintaining consistency and enforcing business rules.

The read side maintains projections optimized for query patterns. When events occur, handlers update these projections. The projections might denormalize data, pre-compute aggregates, or organize data for specific query patterns.

This separation allows independent optimization. The write side can use a normalized relational database that enforces consistency. The read side can use denormalized document stores, search indices, or caching layers that optimize for specific query patterns.

CQRS adds complexity because you maintain multiple representations of data that must stay synchronized. It is most valuable when read and write patterns differ significantly—when you need rich queries that do not match your write model, or when read load vastly exceeds write load and you need to scale them independently.

---

## 21.6 Error Handling Patterns

ARO's happy path philosophy means you do not write explicit error handling, but you can still respond to errors through event-driven patterns.

Error events can be emitted by custom actions when failures occur. A PaymentFailed event carries information about what went wrong. Handlers for error events can log details, notify administrators, trigger compensating actions, or update status to reflect the failure.

Retry patterns can be implemented in custom actions that wrap unreliable operations. The action attempts the operation, retries on transient failures with backoff, and eventually either succeeds or emits a failure event. The ARO code sees only success or a well-defined failure event.

Dead letter handling captures messages that fail repeatedly. After a configured number of retries, the message goes to a dead letter queue where it can be examined, corrected, and replayed. This prevents poison messages from blocking processing while preserving them for investigation.

Circuit breaker patterns can protect against cascading failures when backend services are unavailable. A custom action tracks failure rates and stops making calls when failures exceed a threshold, returning a fallback response instead. This prevents overwhelming already struggling services.

---

## 21.7 Security Patterns

Authentication verifies caller identity. Security-sensitive endpoints extract authentication tokens, validate them against an authentication service, and extract identity claims. Subsequent operations use the validated identity.

Authorization verifies caller permissions. After authentication establishes who the caller is, authorization checks what they can do. This might involve checking role membership, querying a permissions service, or evaluating policy rules.

Rate limiting prevents abuse by limiting request rates per client. A rate limiting action checks whether the current request exceeds limits and fails if so. This protects against denial of service and ensures fair resource allocation.

Input validation prevents injection and other attacks. Validating request data against schemas catches malformed input before it can cause harm. Custom validation actions can implement domain-specific security rules.

These patterns compose together. A secured endpoint might extract and validate a token, check rate limits, validate input, and only then proceed with business logic. Each layer provides defense in depth.

---

## 21.8 Performance Patterns

Caching reduces load on backend services by storing frequently accessed data. A cache-aware handler first checks the cache. On cache hit, it returns immediately. On cache miss, it fetches from the source, stores in the cache, and returns. Time-to-live settings control cache freshness.

Batch processing handles multiple items efficiently. Rather than processing items one at a time, a batch handler receives a collection and processes them together. This can reduce round trips to backend services and enable bulk operations that are more efficient than individual operations.

Parallel processing handles independent operations concurrently. When multiple pieces of data are needed and they do not depend on each other, fetching them in parallel reduces total latency compared to sequential fetching.

Connection pooling maintains reusable connections to backend services. Rather than establishing a new connection for each request, handlers borrow connections from a pool and return them when done. This amortizes connection setup cost across many requests.

Pagination prevents unbounded result sets. List operations return limited pages of results with metadata indicating total count and how to fetch additional pages. This prevents memory exhaustion from large result sets and provides consistent response times.

---

## 21.9 Best Practices Summary

These practices have emerged from experience building ARO applications and reflect lessons learned about what works well.

Keep feature sets focused on single responsibilities. A feature set that does one thing well is easier to understand, test, and maintain than one that does many things.

Use events for side effects and communication. Rather than calling between feature sets, emit events and let handlers react. This decoupling makes the system more flexible and easier to evolve.

Organize code by domain rather than technical layer. Put user-related code together, not all HTTP handlers together. This makes it easier to understand and modify domain functionality.

Leverage the happy path philosophy. Trust the runtime to handle errors. Focus your code on what should happen when things work correctly.

Use meaningful names because they become part of error messages. Good names make errors understandable without consulting source code.

Keep Application-Start minimal. It should start services and set up the environment, not implement business logic.

Publish variables sparingly. Shared state complicates reasoning about program behavior. Prefer events and repositories for sharing data.

Design for idempotency. Events might be delivered more than once. Handlers that can safely process duplicates are more resilient than those that cannot.

Test at multiple levels. Unit test individual feature sets. Integration test event flows. End-to-end test complete scenarios.

Document the non-obvious. Code should be self-documenting for basic behavior. Comments should explain why, not what—the reasons behind non-obvious choices.

---

*Next: Chapter 22 — State Machines*
