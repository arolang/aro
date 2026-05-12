# Build a full order management service with state machine transitions

Create an ARO application implementing an order lifecycle with state machine validation and reactive observers.

The application needs four files:

- `openapi.yaml` -- Define an API on `http://localhost:8081` with CRUD and lifecycle endpoints: `GET /orders` (listOrders), `POST /orders` (createOrder), `GET /orders/{id}` (getOrder), plus transition endpoints: `POST /orders/{id}/place` (placeOrder), `/pay` (payOrder), `/ship` (shipOrder), `/deliver` (deliverOrder), `/cancel` (cancelOrder). Define Order, OrderItem, CreateOrderRequest, PaymentRequest, and ShippingRequest schemas. Order status enum: draft, placed, paid, shipped, delivered, cancelled.

- `main.aro` -- `Application-Start` that starts the HTTP server with `<Contract>`, logs the order lifecycle, uses Keepalive, returns OK.

- `orders.aro` -- Seven feature sets for order operations:
  - `listOrders` / `getOrder` -- Standard retrieval from `<order-repository>`.
  - `createOrder` -- Extract request body, create order with Order type, set status to "draft" with Update, store to repository.
  - `placeOrder` -- Retrieve order, `Accept the <transition: draft_to_placed> on <order: status>`, store.
  - `payOrder` -- Retrieve order, `Accept the <transition: placed_to_paid> on <order: status>`, update payment details.
  - `shipOrder` -- `Accept the <transition: paid_to_shipped> on <order: status>`, update tracking number.
  - `deliverOrder` -- `Accept the <transition: shipped_to_delivered> on <order: status>`.
  - `cancelOrder` -- `Accept the <transition: draft_to_cancelled> on <order: status>`.

- `observers.aro` -- Four state observer feature sets:
  - `Audit Order Status: status StateObserver` -- Fires on every status change, logs from/to states.
  - `Notify Order Placed: status StateObserver<draft_to_placed>` -- Fires only on draft->placed transition.
  - `Notify Shipped: status StateObserver<paid_to_shipped>` -- Fires only on paid->shipped, logs tracking number.
  - `Track Delivery: status StateObserver<shipped_to_delivered>` -- Fires only on shipped->delivered.
