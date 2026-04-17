# Build a typed event extraction demo with OpenAPI schemas

Create an ARO application demonstrating schema-validated event extraction (ARO-0046).

The application needs two files:

- `openapi.yaml` -- No HTTP paths (`paths: {}`), but define three event schemas in `components.schemas`: `UserRegisteredEvent` (userId, email, name required, premium boolean), `OrderPlacedEvent` (orderId, customerId, items array with productId/quantity, total), and `NotificationEvent` (message required, priority enum).

- `main.aro` -- Four feature sets:
  1. `Application-Start` -- Emit three events: `<UserRegistered: event>` with user data, `<OrderPlaced: event>` with order and items, `<Notification: event>` with message and priority.
  2. `Handle User Registration: UserRegistered Handler` -- Use typed extraction: `Extract the <user: UserRegisteredEvent> from the <event>`. Access properties with specifier syntax: `${<user: userId>}`.
  3. `Handle Order Placed: OrderPlaced Handler` -- Extract with `OrderPlacedEvent` schema, extract nested items array, compute item count.
  4. `Handle Notification: Notification Handler` -- Extract with `NotificationEvent` schema, log message and priority.
