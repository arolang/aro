# OrderService

Demonstrates state machine functionality with the `<Accept>` action for validated state transitions.

## What It Does

Implements a complete order lifecycle (draft, placed, paid, shipped, delivered, cancelled) as a REST API. Each state transition is validated by the `<Accept>` action, preventing invalid transitions like shipping an unpaid order.

## Features Tested

- **Accept action** - `<Accept>` for state machine transitions
- **State validation** - Transition syntax: `<Accept> the <transition: from_to_target> on <order: status>`
- **Contract-first API** - Full order management routes from `openapi.yaml`
- **Repository pattern** - `<Retrieve>`, `<Store>`, `<Update>` operations
- **Path parameters** - `<Extract>` from `pathParameters: id`
- **Request body handling** - Payment and shipping details extraction

## Related Proposals

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

## Project Structure

```
OrderService/
├── main.aro        # Application-Start, server startup
├── orders.aro      # All order operations with <Accept> transitions
└── openapi.yaml    # Complete API contract with state machine docs
```

---

*State machines made declarative. The transition syntax reads like a rule: "Accept the transition from draft to placed on the order's status." Invalid states become impossible states.*
