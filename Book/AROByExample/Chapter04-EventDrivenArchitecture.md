# Chapter 4: Event-Driven Architecture

*"In ARO, code does not call code. Code emits events, and other code listens."*

---

## What We Will Learn

- Why ARO uses events instead of function calls
- The naming convention for event handlers
- How to emit events with data
- How to receive and extract event data
- The event bus that connects everything

---

## 4.1 Why Events?

In most languages, when one piece of code needs another, it calls a function:

```javascript
// JavaScript
const result = processPage(url);
saveToFile(result);
```

This creates tight coupling. `processPage` must exist when we write this code. If we want to add logging, we modify this code. If we want to skip saving sometimes, we add conditionals.

ARO takes a different approach. Code emits events, and other code listens for those events:

```aro
(* In one file *)
<Emit> a <PageProcessed: event> with { content: <result>, url: <url> }.

(* In another file, maybe added later *)
(Save Content: PageProcessed Handler) {
    (* This runs when PageProcessed is emitted *)
}
```

The emitter does not know who is listening. The handler does not know who emitted. They are connected only by the event name. This is loose coupling.

---

## 4.2 The Architectural Decision

**Our Choice:** Full event-driven architecture. Every piece of our crawler communicates through events.

**Alternative Considered:** ARO does not actually support direct calls between feature sets, so this is not really a choice—it is the only way. But we could minimize events by putting more logic in each handler. Instead, we choose many small handlers with clear responsibilities.

**Why This Approach:** Small, focused handlers are easier to understand, test, and modify. When we add rate limiting later, we add a new handler in the pipeline. We do not touch existing code. The event-driven model makes this natural.

---

## 4.3 Event Handler Naming

In ARO, feature sets become event handlers through their **business activity** name. The pattern is:

```
({Feature Name}: {EventType} Handler)
```

For example:

```aro
(Save Page: SavePage Handler) {
    (* Handles SavePage events *)
}

(Extract Links: ExtractLinks Handler) {
    (* Handles ExtractLinks events *)
}
```

The runtime matches `{EventType} Handler` to events of type `EventType`. When a `SavePage` event is emitted, the `SavePage Handler` feature set executes.

---

## 4.4 Emitting Events

The `<Emit>` action sends an event to the event bus:

```aro
<Emit> a <CrawlPage: event> with { url: <url>, base: <domain> }.
```

Breaking this down:

- `<Emit>` — The action
- `a` — Article (grammatical, for readability)
- `<CrawlPage: event>` — The event type is `CrawlPage`
- `with { ... }` — The event data, an object with named fields

The event data can contain any values:

```aro
(* Simple values *)
<Emit> a <LogMessage: event> with { message: "Hello" }.

(* Multiple fields *)
<Emit> a <UserCreated: event> with { id: <user-id>, name: <name>, email: <email> }.

(* Nested data *)
<Emit> a <OrderPlaced: event> with { order: <order-data>, customer: <customer> }.
```

---

## 4.5 Receiving Event Data

When a handler receives an event, it extracts data using nested `<Extract>` actions:

```aro
(Process Order: OrderPlaced Handler) {
    (* First, extract the event data object *)
    <Extract> the <event-data> from the <event: data>.

    (* Then, extract individual fields from the object *)
    <Extract> the <order-id> from the <event-data: id>.
    <Extract> the <customer-name> from the <event-data: customer>.

    (* Now use the extracted values *)
    <Log> "Processing order ${<order-id>} for ${<customer-name>}" to the <console>.

    <Return> an <OK: status> for the <processing>.
}
```

The pattern is always:

1. `<Extract> the <event-data> from the <event: data>.` — Get the data object
2. `<Extract> the <field-name> from the <event-data: field>.` — Get each field

---

## 4.6 The Event Bus

The event bus is the invisible glue connecting emitters and handlers. When you emit an event:

1. The event is placed on the bus
2. The runtime finds all handlers for that event type
3. Each handler executes (potentially in parallel)
4. When handlers emit new events, those go on the bus too

This creates a pipeline:

```
Event A emitted
    → Handler A runs
        → Emits Event B
            → Handler B runs
                → Emits Event C
                    → ...
```

In our crawler, the pipeline is:

```
CrawlPage
    → Crawl Page Handler
        → SavePage
            → Save Page Handler (writes file)
        → ExtractLinks
            → Extract Links Handler
                → NormalizeUrl (for each link)
                    → Normalize URL Handler
                        → FilterUrl
                            → Filter URL Handler
                                → QueueUrl
                                    → Queue URL Handler
                                        → CrawlPage (loops)
```

---

## 4.7 A Complete Example

Let us write a simple two-handler pipeline to see this in action. Create a file `events-demo.aro`:

```aro
(Application-Start: Event Demo) {
    <Log> "Starting event demo..." to the <console>.

    (* Emit first event *)
    <Emit> a <Greet: event> with { name: "World" }.

    <Log> "Event emitted, waiting..." to the <console>.
    <Keepalive> the <application> for the <events>.

    <Return> an <OK: status> for the <startup>.
}

(Say Hello: Greet Handler) {
    <Log> "Greet handler triggered!" to the <console>.

    (* Extract the name from event data *)
    <Extract> the <event-data> from the <event: data>.
    <Extract> the <name> from the <event-data: name>.

    <Log> "Hello, ${<name>}!" to the <console>.

    (* Emit another event *)
    <Emit> a <Farewell: event> with { name: <name> }.

    <Return> an <OK: status> for the <greeting>.
}

(Say Goodbye: Farewell Handler) {
    <Log> "Farewell handler triggered!" to the <console>.

    <Extract> the <event-data> from the <event: data>.
    <Extract> the <name> from the <event-data: name>.

    <Log> "Goodbye, ${<name>}!" to the <console>.

    <Return> an <OK: status> for the <farewell>.
}
```

Run it:

```bash
aro run .
```

Output:

```
Starting event demo...
Event emitted, waiting...
Greet handler triggered!
Hello, World!
Farewell handler triggered!
Goodbye, World!
```

Notice the flow: Start → Greet event → Hello handler → Farewell event → Goodbye handler.

---

## 4.8 What ARO Does Well Here

**Natural Decoupling.** Handlers do not import each other. They only know about events. Adding a new handler requires no changes to existing code.

**Clear Data Flow.** Event data is explicit. You can see exactly what data passes between handlers.

**Scalable Pattern.** The same pattern works for simple demos and complex applications. Our crawler uses six event types, but the mechanism is identical.

---

## 4.9 What Could Be Better

**No Event Tracing.** When something goes wrong, there is no built-in way to trace which events led to the error. You add `<Log>` statements manually.

**No Event Schema.** Event data is untyped. If a handler expects `name` but the emitter sends `userName`, you get a runtime error. A type system for events would catch this earlier.

**No Guaranteed Order.** If multiple handlers listen to the same event, their execution order is not guaranteed. Usually this is fine, but sometimes order matters.

---

## Chapter Recap

- ARO uses events for all communication between feature sets
- Handler naming: `({Name}: {EventType} Handler)`
- `<Emit>` sends events; `<Extract>` receives event data
- The event bus connects emitters and handlers automatically
- Events create loose coupling; handlers do not know about each other
- Our crawler uses a pipeline of six event types

---

*Next: Chapter 5 - Fetching Pages*
