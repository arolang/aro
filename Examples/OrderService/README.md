# OrderService

Demonstrates state machine functionality with the `<Accept>` action for validated state transitions, plus **State Observers** for reactive handling of state changes.

## What It Does

Implements a complete order lifecycle (draft, placed, paid, shipped, delivered, cancelled) as a REST API. Each state transition is validated by the `<Accept>` action, preventing invalid transitions like shipping an unpaid order.

**State Observers** automatically react to transitions:
- **Audit logging** - Records all status changes
- **Notifications** - Logs when orders are placed or shipped
- **Analytics** - Tracks delivery completions

## Features Tested

- **Accept action** - `<Accept>` for state machine transitions
- **State validation** - Transition syntax: `<Accept> the <transition: from_to_target> on <order: status>`
- **State observers** - React to transitions: `(Name: status StateObserver)` or `(Name: status StateObserver<from_to_target>)`
- **Contract-first API** - Full order management routes from `openapi.yaml`
- **Repository pattern** - `<Retrieve>`, `<Store>`, `<Update>` operations
- **Path parameters** - `<Extract>` from `pathParameters: id`
- **Request body handling** - Payment and shipping details extraction

## Related Proposals

- [ARO-0013: State Objects](../../Proposals/ARO-0013-state-machines.md) - State machines and observers
- [ARO-0027: Contract-First APIs](../../Proposals/ARO-0027-contract-first-api.md)
- [ARO-0022: HTTP Server](../../Proposals/ARO-0022-http-server.md)

## Usage

```bash
# Start the server
aro run ./Examples/OrderService

# Server runs on http://localhost:8081
```

## Order Lifecycle

```
draft -> placed -> paid -> shipped -> delivered
  |
  v
cancelled
```

## API Walkthrough

```bash
# Create a draft order
curl -X POST http://localhost:8081/orders \
  -H "Content-Type: application/json" \
  -d '{"customerId": "cust-123", "items": [{"productId": "prod-1", "quantity": 2, "price": 29.99}]}'

# Place the order (draft -> placed)
curl -X POST http://localhost:8081/orders/{id}/place

# Pay for the order (placed -> paid)
curl -X POST http://localhost:8081/orders/{id}/pay \
  -H "Content-Type: application/json" \
  -d '{"paymentMethod": "credit_card", "amount": 59.98}'

# Ship the order (paid -> shipped)
curl -X POST http://localhost:8081/orders/{id}/ship \
  -H "Content-Type: application/json" \
  -d '{"carrier": "FedEx", "trackingNumber": "TRACK-12345"}'

# Mark as delivered (shipped -> delivered)
curl -X POST http://localhost:8081/orders/{id}/deliver
```

## Invalid Transitions

The `<Accept>` action validates transitions. Trying to ship an unpaid order fails:

```bash
# This fails - order must be in "paid" state to ship
curl -X POST http://localhost:8081/orders/{id}/ship \
  -d '{"carrier": "UPS", "trackingNumber": "TRACK-999"}'
# Error: Cannot transition from "placed" to "shipped"
```

## State Observers

When state transitions occur, observers automatically react:

```
<Accept> the <transition: draft_to_placed> on <order: status>.
    │
    ├── (Audit Order Status: status StateObserver)           → Logs ALL transitions
    ├── (Notify Order Placed: status StateObserver<draft_to_placed>)  → Logs "Order placed!"
    ├── (Notify Shipped: status StateObserver<paid_to_shipped>)       → No-op (not shipped)
    └── (Track Delivery: status StateObserver<shipped_to_delivered>)  → No-op (not delivered)
```

Each observer uses a business activity pattern:
- `status StateObserver` - Matches ALL status transitions
- `status StateObserver<draft_to_placed>` - Matches ONLY draft→placed

## Project Structure

```
OrderService/
├── main.aro        # Application-Start, server startup
├── orders.aro      # All order operations with <Accept> transitions
├── observers.aro   # State observers for audit, notifications, analytics
└── openapi.yaml    # Complete API contract with state machine docs
```

---

*State machines + Observers = Reactive state management. The transition syntax reads like a rule, and observers react without coupling.*
