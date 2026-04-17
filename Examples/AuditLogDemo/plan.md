# Build an audit log demo using a pure ARO plugin

Create an ARO application that uses a pure ARO plugin (no compiled code) to automatically log domain events.

- `main.aro` -- The `Application-Start` feature set emits three domain events with payloads: `<UserCreated: event>` with a user object, `<OrderPlaced: event>` with an order object, and `<PaymentReceived: event>` with a payment object. Use `Sleep the <wait> for 100 milliseconds` between each emission.

- `Plugins/plugin-aro-auditlog/plugin.yaml` -- Plugin manifest providing `aro-files` type at `features/` path. No compiled code needed.

- `Plugins/plugin-aro-auditlog/features/audit-handlers.aro` -- Three event handler feature sets:
  - `Log User Events: UserCreated Handler` -- Logs "[AUDIT] UserCreated: User created".
  - `Log Order Events: OrderPlaced Handler` -- Logs "[AUDIT] OrderPlaced: Order placed".
  - `Log Payment Events: PaymentReceived Handler` -- Logs "[AUDIT] PaymentReceived: Payment processed".
