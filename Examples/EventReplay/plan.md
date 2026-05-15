# Build an event recording and replay demo

Create a single-file ARO application that demonstrates event recording by emitting multiple domain events and handling them.

In `main.aro`:

1. `Application-Start: Event Replay Test` -- Emit three events: `<UserCreated: event>` with userId and name, `<OrderPlaced: event>` with orderId and amount, and `<PaymentProcessed: event>` with paymentId and status.

2. Three event handler feature sets, one for each event type (`UserCreated Handler`, `OrderPlaced Handler`, `PaymentProcessed Handler`). Each extracts the payload from `<event: payload>`, logs the event type name and the data, and returns OK.
