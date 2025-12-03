# ARO-0014: Domain Modeling

* Proposal: ARO-0014
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0006, ARO-0012

## Abstract

This proposal documents how ARO implements Domain-Driven Design (DDD) concepts through existing language features. ARO follows a "conventions over syntax" approach: types are defined in OpenAPI, behavior lives in feature sets, and DDD patterns emerge from their combination.

## Motivation

ARO is designed for business feature specification. DDD provides:

1. **Ubiquitous Language**: Shared vocabulary between code and business
2. **Rich Domain Model**: Entities, value objects, aggregates
3. **Bounded Contexts**: Clear boundaries between domains
4. **Event-Driven Design**: Domain events for decoupling

ARO implements these concepts without introducing new type syntax, staying consistent with ARO-0006's principle that all complex types come from OpenAPI schemas.

---

## Design Principle

> **Types in OpenAPI, Behavior in Feature Sets**

ARO separates structure from behavior:
- **OpenAPI schemas** define data structures (entities, value objects, aggregates)
- **Feature sets** define behavior (domain services, event handlers, factories)
- **Business Activity** defines bounded context

---

## DDD Concepts in ARO

| DDD Concept | ARO Implementation |
|-------------|-------------------|
| Value Object | OpenAPI schema (no `id` field) |
| Entity | OpenAPI schema with `id` field |
| Aggregate | OpenAPI schema with nested objects |
| Bounded Context | Business Activity in feature set header |
| Domain Event | `<Emit>` action + Event Handler feature sets |
| Repository | `<Retrieve>` and `<Store>` actions |
| Domain Service | Feature set with business logic |
| Factory | Feature set that creates objects |

---

## 1. Value Objects

Value objects are immutable data structures defined by their attributes, not identity.

### Definition

Define in `openapi.yaml` as a schema **without an `id` field**:

```yaml
components:
  schemas:
    Money:
      type: object
      properties:
        amount:
          type: number
        currency:
          type: string
          enum: [USD, EUR, GBP]
      required: [amount, currency]

    Address:
      type: object
      properties:
        street:
          type: string
        city:
          type: string
        postal-code:
          type: string
        country:
          type: string
      required: [street, city, country]

    EmailAddress:
      type: object
      properties:
        value:
          type: string
          format: email
      required: [value]
```

### Usage in ARO

```aro
(Create Order: Sales) {
    <Create> the <shipping-cost: Money> with {
        amount: 9.99,
        currency: "USD"
    }.

    <Create> the <shipping-address: Address> with {
        street: "123 Main St",
        city: "Springfield",
        postal-code: "12345",
        country: "USA"
    }.
}
```

### Conventions

- Value objects are **immutable by convention** - create new instances instead of modifying
- Compare by value, not reference
- No `id` field (that makes it an entity)

---

## 2. Entities

Entities are objects with identity that persists over time.

### Definition

Define in `openapi.yaml` with a **required `id` field**:

```yaml
components:
  schemas:
    User:
      type: object
      properties:
        id:
          type: string
        email:
          type: string
          format: email
        name:
          type: string
        status:
          type: string
          enum: [active, inactive, suspended]
        created-at:
          type: string
          format: date-time
      required: [id, email, name]

    Product:
      type: object
      properties:
        id:
          type: string
        name:
          type: string
        price:
          $ref: '#/components/schemas/Money'
        stock:
          type: integer
      required: [id, name, price]
```

### Usage in ARO

```aro
(Get User: User Management) {
    <Extract> the <user-id> from the <pathParameters: id>.
    <Retrieve> the <user: User> from the <user-repository>
        where id = <user-id>.
    <Return> an <OK: status> with <user>.
}

(Update User Email: User Management) {
    <Extract> the <user-id> from the <pathParameters: id>.
    <Extract> the <new-email> from the <request: email>.

    <Retrieve> the <user: User> from the <user-repository>
        where id = <user-id>.

    <Update> the <user: email> with <new-email>.
    <Store> the <user> in the <user-repository>.

    <Emit> a <UserEmailChanged: event> with <user>.
    <Return> an <OK: status> with <user>.
}
```

### Conventions

- Always has an `id` field (identity)
- Can be modified over time
- Compared by identity, not value
- Typically stored in a repository

---

## 3. Aggregates

Aggregates are clusters of entities and value objects with a root entity that controls access.

### Definition

Define the aggregate root with nested references:

```yaml
components:
  schemas:
    Order:
      type: object
      properties:
        id:
          type: string
        customer-id:
          type: string
        status:
          type: string
          enum: [draft, placed, shipped, delivered, cancelled]
        items:
          type: array
          items:
            $ref: '#/components/schemas/OrderItem'
        shipping-address:
          $ref: '#/components/schemas/Address'
        totals:
          $ref: '#/components/schemas/OrderTotals'
        placed-at:
          type: string
          format: date-time
      required: [id, customer-id, status, items]

    OrderItem:
      type: object
      properties:
        line-id:
          type: string
        product-id:
          type: string
        product-name:
          type: string
        unit-price:
          $ref: '#/components/schemas/Money'
        quantity:
          type: integer
      required: [line-id, product-id, quantity]

    OrderTotals:
      type: object
      properties:
        subtotal:
          $ref: '#/components/schemas/Money'
        tax:
          $ref: '#/components/schemas/Money'
        shipping:
          $ref: '#/components/schemas/Money'
        total:
          $ref: '#/components/schemas/Money'
```

### Usage in ARO

```aro
(Add Item to Order: Sales) {
    <Extract> the <order-id> from the <pathParameters: order-id>.
    <Extract> the <product-id> from the <request: product-id>.
    <Extract> the <quantity> from the <request: quantity>.

    (* Load aggregate root *)
    <Retrieve> the <order: Order> from the <order-repository>
        where id = <order-id>.

    (* Load related entity for item details *)
    <Retrieve> the <product: Product> from the <product-repository>
        where id = <product-id>.

    (* Create nested entity *)
    <Create> the <item: OrderItem> with {
        line-id: generate-id(),
        product-id: <product-id>,
        product-name: <product: name>,
        unit-price: <product: price>,
        quantity: <quantity>
    }.

    (* Modify aggregate through root *)
    <Update> the <order: items> with <item>.

    (* Recalculate totals *)
    <Compute> the <new-totals: OrderTotals> from the <order: items>.
    <Update> the <order: totals> with <new-totals>.

    (* Persist entire aggregate *)
    <Store> the <order> in the <order-repository>.

    <Emit> an <ItemAddedToOrder: event> with <order>.
    <Return> an <OK: status> with <order>.
}
```

### Aggregate Rules

1. **Single Root**: The `Order` is the aggregate root
2. **Access Through Root**: Modify `OrderItem` only through `Order`
3. **Transactional Boundary**: Store the entire `Order` atomically
4. **Reference by ID**: Other aggregates referenced by ID only (`customer-id`, `product-id`)

---

## 4. Bounded Contexts

Bounded contexts define boundaries within which a domain model applies.

### Definition

In ARO, the **Business Activity** in the feature set header defines the bounded context:

```aro
(* Sales Context *)
(Place Order: Sales) {
    (* Sales-specific order handling *)
}

(Cancel Order: Sales) {
    (* Sales-specific cancellation *)
}

(* Shipping Context *)
(Create Shipment: Shipping) {
    (* Shipping-specific logic *)
}

(Track Shipment: Shipping) {
    (* Shipping-specific tracking *)
}

(* Inventory Context *)
(Reserve Stock: Inventory) {
    (* Inventory-specific reservation *)
}

(Update Stock Level: Inventory) {
    (* Inventory-specific updates *)
}
```

### Context Boundaries

Each context may have its own view of shared concepts:

```yaml
# Sales context - Order with pricing focus
components:
  schemas:
    Order:
      properties:
        id: { type: string }
        customer-id: { type: string }
        items: { ... }
        totals: { ... }

# Shipping context - Shipment with logistics focus
    Shipment:
      properties:
        id: { type: string }
        order-id: { type: string }  # Reference to Sales.Order
        destination: { ... }
        carrier: { ... }
        tracking-number: { ... }
```

### Cross-Context Communication

Use domain events to communicate between contexts:

```aro
(* Sales context places order *)
(Place Order: Sales) {
    <Handle> order placement...
    <Emit> an <OrderPlaced: event> with <order>.
    <Return> an <OK: status> with <order>.
}

(* Inventory context responds *)
(Reserve Stock: OrderPlaced Handler) {
    <Extract> the <order> from the <event: order>.
    (* Reserve inventory for order items *)
    <Return> an <OK: status> for the <reservation>.
}

(* Shipping context responds *)
(Create Shipment: OrderPlaced Handler) {
    <Extract> the <order> from the <event: order>.
    (* Create shipment for order *)
    <Return> an <OK: status> for the <shipment>.
}
```

---

## 5. Domain Events

Domain events represent significant occurrences in the domain.

### Publishing Events

Use the `<Emit>` action to publish domain events:

```aro
(Register User: User Management) {
    <Extract> the <data> from the <request: body>.
    <Create> the <user: User> with <data>.
    <Store> the <user> in the <user-repository>.

    (* Publish domain event *)
    <Emit> a <UserRegistered: event> with <user>.

    <Return> a <Created: status> with <user>.
}

(Place Order: Sales) {
    (* ... order placement logic ... *)

    (* Publish domain event *)
    <Emit> an <OrderPlaced: event> with {
        order-id: <order: id>,
        customer-id: <order: customer-id>,
        total: <order: totals: total>,
        placed-at: now()
    }.

    <Return> an <OK: status> with <order>.
}
```

### Subscribing to Events

Feature sets with `Handler` suffix subscribe to events:

```aro
(* Naming pattern: (Feature Name: EventName Handler) *)

(Send Welcome Email: UserRegistered Handler) {
    <Extract> the <user> from the <event: user>.
    <Send> the <welcome-email> to the <user: email>.
    <Return> an <OK: status> for the <notification>.
}

(Update Analytics: OrderPlaced Handler) {
    <Extract> the <order-id> from the <event: order-id>.
    <Extract> the <total> from the <event: total>.
    <Log> the <message> for the <analytics> with "Order placed: " + <order-id>.
    <Return> an <OK: status> for the <analytics>.
}
```

---

## 6. Repositories (Data Access)

Repositories provide access to aggregates and entities.

### Usage

ARO uses `<Retrieve>` and `<Store>` actions for repository operations:

```aro
(* Find by ID *)
<Retrieve> the <order: Order> from the <order-repository>
    where id = <order-id>.

(* Find with filter *)
<Retrieve> the <pending-orders: List<Order>> from the <order-repository>
    where status = "pending".

(* Save *)
<Store> the <order> in the <order-repository>.

(* Delete *)
<Delete> the <order> from the <order-repository>.
```

### Repository Naming Convention

Use descriptive repository names that indicate the aggregate:

- `user-repository` for `User` entities
- `order-repository` for `Order` aggregates
- `product-repository` for `Product` entities

---

## 7. Domain Services

Domain services contain business logic that doesn't belong to a single entity.

### Definition

Feature sets naturally serve as domain services:

```aro
(Calculate Shipping Cost: Pricing) {
    <Extract> the <order> from the <request: order>.
    <Extract> the <destination> from the <request: destination>.

    (* Business logic spanning multiple entities *)
    <Compute> the <weight> from the <order: items>.
    <Compute> the <zone> from the <destination>.
    <Compute> the <shipping-cost: Money> from {
        weight: <weight>,
        zone: <zone>
    }.

    <Return> an <OK: status> with <shipping-cost>.
}

(Apply Discount: Pricing) {
    <Extract> the <order> from the <request: order>.
    <Extract> the <customer> from the <request: customer>.

    (* Volume discount *)
    <Compute> the <volume-discount> from the <order: totals: subtotal>
        where amount > 1000.

    (* Loyalty discount *)
    <Compute> the <loyalty-discount> from the <customer: tier>
        where tier is "gold".

    <Compute> the <total-discount: Money> from {
        volume: <volume-discount>,
        loyalty: <loyalty-discount>
    }.

    <Return> an <OK: status> with <total-discount>.
}
```

---

## 8. Factories

Factories create complex objects or aggregates.

### Definition

Feature sets that create objects serve as factories:

```aro
(Create Order: Sales) {
    <Extract> the <customer-id> from the <request: customer-id>.
    <Extract> the <items> from the <request: items>.

    (* Factory logic - create aggregate with proper initialization *)
    <Create> the <order: Order> with {
        id: generate-id(),
        customer-id: <customer-id>,
        status: "draft",
        items: [],
        totals: {
            subtotal: { amount: 0, currency: "USD" },
            tax: { amount: 0, currency: "USD" },
            shipping: { amount: 0, currency: "USD" },
            total: { amount: 0, currency: "USD" }
        }
    }.

    (* Add items through aggregate operations *)
    <Process> each <item> in <items> {
        <Update> the <order: items> with <item>.
    }.

    (* Calculate totals *)
    <Compute> the <totals: OrderTotals> from the <order: items>.
    <Update> the <order: totals> with <totals>.

    <Store> the <order> in the <order-repository>.
    <Return> a <Created: status> with <order>.
}
```

---

## Complete Example

### openapi.yaml

```yaml
openapi: 3.0.3
info:
  title: E-Commerce Domain
  version: 1.0.0

components:
  schemas:
    # Value Objects
    Money:
      type: object
      properties:
        amount: { type: number }
        currency: { type: string }
      required: [amount, currency]

    Address:
      type: object
      properties:
        street: { type: string }
        city: { type: string }
        postal-code: { type: string }
        country: { type: string }
      required: [street, city, country]

    # Entities
    Customer:
      type: object
      properties:
        id: { type: string }
        name: { type: string }
        email: { type: string }
        tier: { type: string, enum: [standard, gold, platinum] }
      required: [id, name, email]

    Product:
      type: object
      properties:
        id: { type: string }
        name: { type: string }
        price: { $ref: '#/components/schemas/Money' }
        stock: { type: integer }
      required: [id, name, price]

    # Aggregates
    Order:
      type: object
      properties:
        id: { type: string }
        customer-id: { type: string }
        status: { type: string }
        items:
          type: array
          items: { $ref: '#/components/schemas/OrderItem' }
        shipping-address: { $ref: '#/components/schemas/Address' }
        totals: { $ref: '#/components/schemas/OrderTotals' }
      required: [id, customer-id, status]

    OrderItem:
      type: object
      properties:
        line-id: { type: string }
        product-id: { type: string }
        product-name: { type: string }
        unit-price: { $ref: '#/components/schemas/Money' }
        quantity: { type: integer }

    OrderTotals:
      type: object
      properties:
        subtotal: { $ref: '#/components/schemas/Money' }
        tax: { $ref: '#/components/schemas/Money' }
        shipping: { $ref: '#/components/schemas/Money' }
        total: { $ref: '#/components/schemas/Money' }
```

### sales.aro

```aro
(* ============================================================
   Sales Bounded Context
   ============================================================ *)

(* Factory: Create new order *)
(Create Order: Sales) {
    <Extract> the <customer-id> from the <request: customer-id>.

    <Create> the <order: Order> with {
        id: generate-id(),
        customer-id: <customer-id>,
        status: "draft",
        items: [],
        totals: { subtotal: { amount: 0, currency: "USD" } }
    }.

    <Store> the <order> in the <order-repository>.
    <Return> a <Created: status> with <order>.
}

(* Aggregate operation: Add item *)
(Add Item: Sales) {
    <Extract> the <order-id> from the <pathParameters: order-id>.
    <Extract> the <product-id> from the <request: product-id>.
    <Extract> the <quantity> from the <request: quantity>.

    <Retrieve> the <order: Order> from the <order-repository>
        where id = <order-id>.

    <Retrieve> the <product: Product> from the <product-repository>
        where id = <product-id>.

    <Create> the <item: OrderItem> with {
        line-id: generate-id(),
        product-id: <product-id>,
        product-name: <product: name>,
        unit-price: <product: price>,
        quantity: <quantity>
    }.

    <Update> the <order: items> with <item>.
    <Store> the <order> in the <order-repository>.

    <Return> an <OK: status> with <order>.
}

(* Domain operation: Place order *)
(Place Order: Sales) {
    <Extract> the <order-id> from the <pathParameters: order-id>.

    <Retrieve> the <order: Order> from the <order-repository>
        where id = <order-id>.

    <Validate> the <order: items> is not empty.

    <Update> the <order: status> with "placed".
    <Store> the <order> in the <order-repository>.

    (* Publish domain event *)
    <Emit> an <OrderPlaced: event> with <order>.

    <Return> an <OK: status> with <order>.
}
```

### inventory.aro

```aro
(* ============================================================
   Inventory Bounded Context
   ============================================================ *)

(* Event Handler: Reserve stock when order placed *)
(Reserve Stock: OrderPlaced Handler) {
    <Extract> the <order> from the <event: order>.

    (* Reserve inventory for each item *)
    <Process> each <item> in <order: items> {
        <Retrieve> the <product: Product> from the <product-repository>
            where id = <item: product-id>.

        <Compute> the <new-stock> from <product: stock> - <item: quantity>.
        <Update> the <product: stock> with <new-stock>.
        <Store> the <product> in the <product-repository>.
    }.

    <Emit> a <StockReserved: event> with <order: id>.
    <Return> an <OK: status> for the <reservation>.
}
```

### shipping.aro

```aro
(* ============================================================
   Shipping Bounded Context
   ============================================================ *)

(* Event Handler: Create shipment when stock reserved *)
(Create Shipment: StockReserved Handler) {
    <Extract> the <order-id> from the <event: order-id>.

    <Retrieve> the <order: Order> from the <order-repository>
        where id = <order-id>.

    <Create> the <shipment: Shipment> with {
        id: generate-id(),
        order-id: <order-id>,
        destination: <order: shipping-address>,
        status: "pending"
    }.

    <Store> the <shipment> in the <shipment-repository>.
    <Return> an <OK: status> with <shipment>.
}
```

---

## Summary

ARO implements DDD through conventions rather than syntax:

| Pattern | Implementation |
|---------|---------------|
| Define types | OpenAPI schemas |
| Define behavior | Feature sets |
| Define context | Business Activity |
| Communicate | Domain events |
| Persist | Repository actions |

This approach keeps ARO simple while supporting rich domain modeling.

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 2.0 | 2024-12 | Simplified to document existing features |
| 1.0 | 2024-01 | Initial specification with custom syntax |
