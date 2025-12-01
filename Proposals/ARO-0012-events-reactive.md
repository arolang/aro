# ARO-0012: Events and Reactive Programming

* Proposal: ARO-0012
* Author: ARO Language Team
* Status: **Draft**
* Requires: ARO-0001, ARO-0006, ARO-0011

## Abstract

This proposal introduces event-driven programming constructs to ARO, enabling reactive systems, event sourcing, and pub/sub patterns.

## Motivation

Event-driven architectures require:

1. **Event Definition**: Typed event structures
2. **Publishing**: Emit events to topics
3. **Subscribing**: React to events
4. **Event Sourcing**: Rebuild state from events

---

### 1. Event Definition

#### 1.1 Event Type

```ebnf
event_definition = "event" , event_name , [ ":" , parent_event ] ,
                   "{" , { event_field } , "}" ;
```

**Example:**
```
event DomainEvent {
    id: EventId;
    timestamp: DateTime;
    correlationId: String?;
}

event UserCreated: DomainEvent {
    userId: UserId;
    email: String;
    name: String;
}

event UserEmailChanged: DomainEvent {
    userId: UserId;
    oldEmail: String;
    newEmail: String;
}

event OrderPlaced: DomainEvent {
    orderId: OrderId;
    userId: UserId;
    items: List<OrderItem>;
    total: Money;
}
```

#### 1.2 Event Metadata

```
@topic("users")
@version(1)
@schema("user-events-v1.json")
event UserCreated: DomainEvent {
    // ...
}
```

---

### 2. Event Emission

#### 2.1 Emit Statement

```ebnf
emit_statement = "<Emit>" , event_expression , 
                 [ "to" , topic_reference ] , "." ;
```

**Example:**
```
(Create User: Registration) {
    <Create> the <user> in the <repository>.
    
    <Emit> UserCreated {
        userId: <user>.id,
        email: <user>.email,
        name: <user>.name
    }.
    
    // Or to specific topic
    <Emit> UserCreated { ... } to <user-events>.
}
```

#### 2.2 Event Builder

```
<Build> the <event: UserCreated> with {
    userId: <user>.id,
    email: <user>.email,
    name: <user>.name,
    correlationId: <request>.correlationId
}.

<Emit> the <event>.
```

---

### 3. Event Subscription

#### 3.1 On Event Handler

```ebnf
event_handler = "on" , event_pattern , [ "from" , topic ] ,
                [ "where" , condition ] , block ;
```

**Example:**
```
(User Notifications: Communication) {
    on UserCreated as <event> {
        <Send> the <welcome-email> to <event>.email.
    }
    
    on UserEmailChanged as <event> where <event>.newEmail contains "@company.com" {
        <Send> the <internal-welcome> to <event>.newEmail.
    }
    
    on OrderPlaced as <event> from <order-events> {
        <Send> the <order-confirmation> to <event>.userId.
    }
}
```

#### 3.2 Multiple Event Handling

```
(Analytics: Tracking) {
    on UserCreated | UserDeleted as <event> {
        <Track> the <user-lifecycle-event> with <event>.
    }
    
    on * as <event> from <audit-events> {
        <Store> the <event> in <audit-log>.
    }
}
```

---

### 4. Event Streams

#### 4.1 Stream Definition

```
(Real-time Dashboard: Analytics) {
    <Subscribe> to <order-events> as <orders: Stream<OrderPlaced>>.
    
    <Transform> the <revenue-stream> from 
        <orders>
            .filter(<e> => <e>.total.amount > 100)
            .map(<e> => <e>.total)
            .window(1.minute)
            .aggregate(sum).
    
    for await <revenue> in <revenue-stream> {
        <Update> the <dashboard>.revenue with <revenue>.
    }
}
```

#### 4.2 Stream Operators

| Operator | Description |
|----------|-------------|
| `.filter(predicate)` | Filter events |
| `.map(transform)` | Transform events |
| `.flatMap(fn)` | Flatten nested streams |
| `.window(duration)` | Time-based windowing |
| `.sliding(size, step)` | Sliding window |
| `.aggregate(fn)` | Aggregate over window |
| `.groupBy(key)` | Group by key |
| `.merge(other)` | Merge streams |
| `.zip(other)` | Zip with another stream |
| `.debounce(duration)` | Debounce rapid events |
| `.throttle(duration)` | Rate limit |
| `.distinct()` | Remove duplicates |
| `.take(n)` | Take first n |
| `.skip(n)` | Skip first n |
| `.buffer(size)` | Buffer events |

---

### 5. Event Sourcing

#### 5.1 Aggregate Definition

```ebnf
aggregate_definition = "aggregate" , aggregate_name ,
                       "{" , { aggregate_member } , "}" ;

aggregate_member = state_field | event_handler | command_handler ;
```

**Example:**
```
aggregate Order {
    // State
    state id: OrderId;
    state status: OrderStatus = .draft;
    state items: List<OrderItem> = [];
    state total: Money = Money.zero;
    
    // Apply events (rebuild state)
    apply OrderPlaced as <event> {
        <Set> the <id> to <event>.orderId.
        <Set> the <items> to <event>.items.
        <Set> the <total> to <event>.total.
        <Set> the <status> to .placed.
    }
    
    apply OrderShipped as <event> {
        <Set> the <status> to .shipped.
    }
    
    apply OrderCancelled as <event> {
        <Set> the <status> to .cancelled.
    }
    
    // Handle commands (produce events)
    handle PlaceOrder as <cmd> {
        guard <status> is .draft else {
            <Throw> an <InvalidStateError> for <cmd>.
        }
        
        <Emit> OrderPlaced {
            orderId: <cmd>.orderId,
            items: <cmd>.items,
            total: <calculate-total>(<cmd>.items)
        }.
    }
    
    handle ShipOrder as <cmd> {
        guard <status> is .placed else {
            <Throw> an <InvalidStateError> for <cmd>.
        }
        
        <Emit> OrderShipped {
            orderId: <id>,
            shippedAt: now()
        }.
    }
}
```

#### 5.2 Event Store

```
(Order Service: E-Commerce) {
    <Require> <event-store: EventStore> from framework.
    
    // Load aggregate from events
    <Load> the <order: Order> from <event-store> 
        with { aggregateId: <order-id> }.
    
    // Execute command
    <Handle> <ShipOrder: cmd> on <order>.
    
    // Persist new events
    <Save> the <order> to <event-store>.
}
```

#### 5.3 Projections

```
projection OrderSummary {
    state orders: Map<OrderId, OrderSummaryView> = {};
    
    on OrderPlaced as <event> {
        <Set> <orders>[<event>.orderId] to OrderSummaryView {
            id: <event>.orderId,
            status: "placed",
            itemCount: <event>.items.count(),
            total: <event>.total
        }.
    }
    
    on OrderShipped as <event> {
        <Update> <orders>[<event>.orderId].status to "shipped".
    }
    
    on OrderCancelled as <event> {
        <Update> <orders>[<event>.orderId].status to "cancelled".
    }
    
    query GetOrderSummary(orderId: OrderId) -> OrderSummaryView? {
        <Return> <orders>[<orderId>].
    }
    
    query GetActiveOrders() -> List<OrderSummaryView> {
        <Return> <orders>.values()
            .filter(<o> => <o>.status != "cancelled").
    }
}
```

---

### 6. Sagas / Process Managers

```ebnf
saga_definition = "saga" , saga_name , "{" , { saga_step } , "}" ;
saga_step = "on" , event_pattern , block ;
```

**Example:**
```
saga OrderFulfillment {
    state orderId: OrderId?;
    state paymentConfirmed: Bool = false;
    state inventoryReserved: Bool = false;
    
    on OrderPlaced as <event> {
        <Set> the <orderId> to <event>.orderId.
        
        // Start parallel processes
        <Send> ReserveInventory { 
            orderId: <orderId>, 
            items: <event>.items 
        } to <inventory-service>.
        
        <Send> ProcessPayment { 
            orderId: <orderId>, 
            amount: <event>.total 
        } to <payment-service>.
    }
    
    on PaymentConfirmed as <event> where <event>.orderId == <orderId> {
        <Set> the <paymentConfirmed> to true.
        <Check> if <complete>.
    }
    
    on InventoryReserved as <event> where <event>.orderId == <orderId> {
        <Set> the <inventoryReserved> to true.
        <Check> if <complete>.
    }
    
    on PaymentFailed as <event> where <event>.orderId == <orderId> {
        // Compensate
        if <inventoryReserved> then {
            <Send> ReleaseInventory { orderId: <orderId> } 
                to <inventory-service>.
        }
        <Emit> OrderFailed { orderId: <orderId>, reason: "Payment failed" }.
        <Complete> saga.
    }
    
    action complete {
        if <paymentConfirmed> and <inventoryReserved> then {
            <Send> ShipOrder { orderId: <orderId> } to <shipping-service>.
            <Complete> saga.
        }
    }
}
```

---

### 7. Topics and Channels

#### 7.1 Topic Definition

```
@retention(7.days)
@partitions(8)
@replication(3)
topic UserEvents of DomainEvent;

@retention(forever)
@compacted(key: "userId")
topic UserSnapshots of UserSnapshot;
```

#### 7.2 Pub/Sub

```
(Event Publisher: Infrastructure) {
    <Require> <event-bus: EventBus> from framework.
    
    // Publish
    <Publish> the <event> to <user-events>.
    
    // Subscribe with group
    <Subscribe> to <user-events> 
        as <consumer> 
        with { group: "notification-service" }.
}
```

---

### 8. Complete Grammar Extension

```ebnf
(* Events Grammar *)

(* Event Definition *)
event_definition = "event" , identifier , [ ":" , identifier ] ,
                   "{" , { field_def } , "}" ;

(* Emit *)
emit_statement = "<Emit>" , event_expr , [ "to" , variable_reference ] , "." ;
event_expr = identifier , [ inline_object ] ;

(* Event Handler *)
event_handler = "on" , event_pattern , [ "as" , identifier ] ,
                [ "from" , variable_reference ] ,
                [ "where" , condition ] , block ;

event_pattern = identifier , { "|" , identifier } | "*" ;

(* Aggregate *)
aggregate_definition = "aggregate" , identifier , 
                       "{" , { aggregate_member } , "}" ;

aggregate_member = state_field | apply_handler | command_handler ;
apply_handler = "apply" , identifier , [ "as" , identifier ] , block ;
command_handler = "handle" , identifier , [ "as" , identifier ] , block ;

(* Projection *)
projection_definition = "projection" , identifier ,
                        "{" , { projection_member } , "}" ;

projection_member = state_field | event_handler | query_def ;
query_def = "query" , identifier , "(" , param_list , ")" , 
            "->" , type_annotation , block ;

(* Saga *)
saga_definition = "saga" , identifier , "{" , { saga_member } , "}" ;
saga_member = state_field | event_handler | action_def ;
action_def = "action" , identifier , block ;

(* Topic *)
topic_definition = [ annotation_list ] , 
                   "topic" , identifier , "of" , type_annotation , ";" ;
```

---

### 9. Complete Example

```
// Events
event CartEvent: DomainEvent { cartId: CartId; }
event ItemAddedToCart: CartEvent { 
    productId: ProductId; 
    quantity: Int; 
}
event ItemRemovedFromCart: CartEvent { productId: ProductId; }
event CartCheckedOut: CartEvent { orderId: OrderId; }

// Aggregate
aggregate ShoppingCart {
    state id: CartId;
    state items: Map<ProductId, CartItem> = {};
    state checkedOut: Bool = false;
    
    apply ItemAddedToCart as <e> {
        if <items>[<e>.productId] exists then {
            <Increment> <items>[<e>.productId].quantity by <e>.quantity.
        } else {
            <Set> <items>[<e>.productId] to CartItem {
                productId: <e>.productId,
                quantity: <e>.quantity
            }.
        }
    }
    
    apply ItemRemovedFromCart as <e> {
        <Remove> <items>[<e>.productId].
    }
    
    apply CartCheckedOut as <e> {
        <Set> the <checkedOut> to true.
    }
    
    handle AddItem as <cmd> {
        guard not <checkedOut> else {
            <Throw> a <CartClosedError> for <cmd>.
        }
        <Emit> ItemAddedToCart {
            cartId: <id>,
            productId: <cmd>.productId,
            quantity: <cmd>.quantity
        }.
    }
    
    handle Checkout as <cmd> {
        guard not <checkedOut> else {
            <Throw> a <CartClosedError> for <cmd>.
        }
        guard <items> is not empty else {
            <Throw> an <EmptyCartError> for <cmd>.
        }
        <Emit> CartCheckedOut {
            cartId: <id>,
            orderId: <cmd>.orderId
        }.
    }
}

// Projection for read model
projection CartView {
    state carts: Map<CartId, CartViewModel> = {};
    
    on ItemAddedToCart as <e> {
        <EnsureCart> <e>.cartId.
        <Add> CartItemView {
            productId: <e>.productId,
            quantity: <e>.quantity
        } to <carts>[<e>.cartId].items.
    }
    
    on CartCheckedOut as <e> {
        <Remove> <carts>[<e>.cartId].
    }
    
    query GetCart(cartId: CartId) -> CartViewModel? {
        <Return> <carts>[<cartId>].
    }
}

// React to events
(Inventory Sync: Integration) {
    on ItemAddedToCart as <event> {
        <Reserve> <event>.quantity of <event>.productId.
    }
    
    on ItemRemovedFromCart as <event> {
        <Release> reservation for <event>.productId.
    }
}
```

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-01 | Initial specification |
