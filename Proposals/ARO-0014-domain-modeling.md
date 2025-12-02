# ARO-0014: Domain Modeling

* Proposal: ARO-0014
* Author: ARO Language Team
* Status: **Draft**
* Requires: ARO-0001, ARO-0006, ARO-0012

## Abstract

This proposal introduces Domain-Driven Design (DDD) constructs to ARO, enabling rich domain modeling with entities, value objects, aggregates, and bounded contexts.

## Motivation

ARO is designed for business feature specification. DDD provides:

1. **Ubiquitous Language**: Shared vocabulary between code and business
2. **Rich Domain Model**: Entities, value objects, aggregates
3. **Bounded Contexts**: Clear boundaries between domains
4. **Strategic Design**: Context mapping, anti-corruption layers

---

### 1. Value Objects

#### 1.1 Definition

```ebnf
value_object = "value" , identifier , "{" , { field_def } , "}" ;
```

**Example:**
```
value Money {
    amount: Decimal;
    currency: Currency;
    
    invariant amount >= 0 : "Amount must be non-negative";
    
    func add(other: Money) -> Money {
        guard <currency> == <other>.currency else {
            <Throw> a <CurrencyMismatchError>.
        }
        <Return> Money { 
            amount: <amount> + <other>.amount, 
            currency: <currency> 
        }.
    }
    
    func multiply(factor: Decimal) -> Money {
        <Return> Money { 
            amount: <amount> * <factor>, 
            currency: <currency> 
        }.
    }
}

value Address {
    street: String;
    city: String;
    state: String;
    postalCode: String;
    country: Country;
    
    invariant <postalCode> matches postalCodePattern(<country>)
        : "Invalid postal code for country";
}

value EmailAddress {
    value: String;
    
    invariant <value> matches "^[^@]+@[^@]+\\.[^@]+$"
        : "Invalid email format";
    
    func domain() -> String {
        <Return> <value>.split("@")[1].
    }
}

value DateRange {
    start: Date;
    end: Date;
    
    invariant <start> <= <end> : "Start must be before end";
    
    func contains(date: Date) -> Bool {
        <Return> <date> >= <start> and <date> <= <end>.
    }
    
    func overlaps(other: DateRange) -> Bool {
        <Return> <start> <= <other>.end and <end> >= <other>.start.
    }
}
```

#### 1.2 Value Object Semantics

- **Immutable**: Cannot be modified after creation
- **Equality**: Compared by value, not identity
- **No Identity**: No ID field
- **Self-Validating**: Invariants checked on creation

---

### 2. Entities

#### 2.1 Definition

```ebnf
entity = "entity" , identifier , "{" , { entity_member } , "}" ;
entity_member = identity_field | field_def | method_def | invariant ;
identity_field = "identity" , identifier , ":" , type_annotation , ";" ;
```

**Example:**
```
entity User {
    identity id: UserId;
    
    email: EmailAddress;
    name: PersonName;
    passwordHash: String;
    status: UserStatus;
    roles: Set<Role>;
    createdAt: DateTime;
    updatedAt: DateTime?;
    
    invariant <roles> is not empty : "User must have at least one role";
    
    func changeEmail(newEmail: EmailAddress) {
        <Set> the <email> to <newEmail>.
        <Set> the <updatedAt> to now().
        <Emit> UserEmailChanged { userId: <id>, newEmail: <newEmail> }.
    }
    
    func addRole(role: Role) {
        <Add> <role> to <roles>.
        <Emit> UserRoleAdded { userId: <id>, role: <role> }.
    }
    
    func hasPermission(permission: Permission) -> Bool {
        <Return> <roles>.any(<r> => <r>.permissions.contains(<permission>)).
    }
}

entity Product {
    identity sku: SKU;
    
    name: String;
    description: String;
    price: Money;
    category: Category;
    inventory: InventoryLevel;
    active: Bool;
    
    invariant <price>.amount > 0 : "Price must be positive";
    
    func adjustPrice(newPrice: Money, reason: String) {
        <Emit> PriceChanged { 
            sku: <sku>, 
            oldPrice: <price>, 
            newPrice: <newPrice>,
            reason: <reason>
        }.
        <Set> the <price> to <newPrice>.
    }
}
```

#### 2.2 Entity Semantics

- **Identity**: Unique identifier field
- **Mutable**: State can change over time
- **Lifecycle**: Created, modified, possibly deleted
- **Equality**: Compared by identity, not value

---

### 3. Aggregates

#### 3.1 Definition

```ebnf
aggregate = "aggregate" , identifier , 
            "{" , { aggregate_member } , "}" ;

aggregate_member = "root" , entity 
                 | entity 
                 | value_object
                 | invariant
                 | command_handler
                 | domain_event ;
```

**Example:**
```
aggregate Order {
    // Aggregate root
    root entity OrderRoot {
        identity id: OrderId;
        
        customerId: CustomerId;
        status: OrderStatus;
        items: List<OrderItem>;
        shippingAddress: Address;
        billingAddress: Address;
        payment: PaymentInfo?;
        totals: OrderTotals;
        placedAt: DateTime?;
        
        invariant <items> is not empty when <status> != .draft
            : "Placed order must have items";
    }
    
    // Nested entity (only accessible through aggregate)
    entity OrderItem {
        identity lineId: LineId;
        
        productId: ProductId;
        productName: String;
        unitPrice: Money;
        quantity: Quantity;
        
        func lineTotal() -> Money {
            <Return> <unitPrice>.multiply(<quantity>.value).
        }
    }
    
    // Value objects
    value OrderTotals {
        subtotal: Money;
        tax: Money;
        shipping: Money;
        discount: Money;
        total: Money;
    }
    
    // Aggregate-level invariants
    invariant <totals>.total == 
        <totals>.subtotal + <totals>.tax + <totals>.shipping - <totals>.discount
        : "Totals must be consistent";
    
    // Commands
    handle AddItem(productId: ProductId, quantity: Quantity) {
        guard <status> is .draft else {
            <Throw> an <OrderNotModifiableError>.
        }
        
        <Create> the <item: OrderItem> with {
            lineId: generateLineId(),
            productId: <productId>,
            productName: <lookup>(<productId>).name,
            unitPrice: <lookup>(<productId>).price,
            quantity: <quantity>
        }.
        
        <Add> <item> to <items>.
        <Recalculate> the <totals>.
        
        <Emit> ItemAddedToOrder { 
            orderId: <id>, 
            item: <item> 
        }.
    }
    
    handle RemoveItem(lineId: LineId) {
        guard <status> is .draft else {
            <Throw> an <OrderNotModifiableError>.
        }
        
        <Remove> item where <item>.lineId == <lineId> from <items>.
        <Recalculate> the <totals>.
        
        <Emit> ItemRemovedFromOrder { 
            orderId: <id>, 
            lineId: <lineId> 
        }.
    }
    
    handle PlaceOrder {
        guard <items> is not empty else {
            <Throw> an <EmptyOrderError>.
        }
        guard <payment> exists else {
            <Throw> a <PaymentRequiredError>.
        }
        
        <Set> the <status> to .placed.
        <Set> the <placedAt> to now().
        
        <Emit> OrderPlaced {
            orderId: <id>,
            customerId: <customerId>,
            items: <items>,
            totals: <totals>
        }.
    }
}
```

#### 3.2 Aggregate Rules

1. **Single Root**: One entity is the aggregate root
2. **Transactional Boundary**: All changes are atomic
3. **Reference by ID**: Other aggregates referenced by ID only
4. **Invariant Enforcement**: All invariants checked on save

---

### 4. Repositories

#### 4.1 Definition

```ebnf
repository = "repository" , identifier , 
             "for" , aggregate_name ,
             "{" , { repository_method } , "}" ;
```

**Example:**
```
repository OrderRepository for Order {
    find(id: OrderId) -> Order?;
    
    findByCustomer(customerId: CustomerId) -> List<Order>;
    
    findByStatus(status: OrderStatus) -> List<Order>;
    
    findPending() -> List<Order> {
        <Return> findByStatus(.placed).
    }
    
    save(order: Order);
    
    delete(id: OrderId);
    
    nextId() -> OrderId;
}

repository UserRepository for User {
    find(id: UserId) -> User?;
    
    findByEmail(email: EmailAddress) -> User?;
    
    findByRole(role: Role) -> List<User>;
    
    exists(email: EmailAddress) -> Bool {
        <Return> findByEmail(<email>) exists.
    }
    
    save(user: User);
}
```

---

### 5. Domain Services

#### 5.1 Definition

```ebnf
domain_service = "service" , identifier , 
                 "{" , { service_method } , "}" ;
```

**Example:**
```
service PricingService {
    calculateDiscount(order: Order, customer: Customer) -> Money {
        <Set> the <discount> to Money.zero(<order>.currency).
        
        // Volume discount
        if <order>.totals.subtotal.amount > 1000 then {
            <Add> <order>.totals.subtotal.multiply(0.1) to <discount>.
        }
        
        // Loyalty discount
        if <customer>.loyaltyTier is .gold then {
            <Add> <order>.totals.subtotal.multiply(0.05) to <discount>.
        }
        
        <Return> <discount>.
    }
    
    calculateShipping(order: Order, destination: Address) -> Money {
        <Compute> the <weight> from <order>.items.sum(<i> => <i>.weight).
        <Compute> the <zone> from shippingZone(<destination>).
        <Return> shippingRate(<weight>, <zone>).
    }
}

service OrderService {
    <Require> <orderRepo: OrderRepository>.
    <Require> <customerRepo: CustomerRepository>.
    <Require> <pricingService: PricingService>.
    <Require> <inventoryService: InventoryService>.
    
    placeOrder(orderId: OrderId) -> Order {
        <Load> the <order> from <orderRepo>.
        <Load> the <customer> from <customerRepo> 
            with { id: <order>.customerId }.
        
        // Check inventory
        for each <item> in <order>.items {
            guard <inventoryService>.isAvailable(<item>.productId, <item>.quantity) else {
                <Throw> an <InsufficientStockError> for <item>.
            }
        }
        
        // Calculate final pricing
        <Compute> the <discount> from 
            <pricingService>.calculateDiscount(<order>, <customer>).
        <Apply> <discount> to <order>.
        
        // Place order
        <Handle> PlaceOrder on <order>.
        
        // Reserve inventory
        <Reserve> inventory for <order> via <inventoryService>.
        
        // Save
        <Save> <order> to <orderRepo>.
        
        <Return> <order>.
    }
}
```

---

### 6. Bounded Contexts

#### 6.1 Context Definition

```ebnf
bounded_context = "context" , context_name ,
                  "{" , { context_member } , "}" ;

context_member = aggregate | entity | value_object | service | repository ;
```

**Example:**
```
context Sales {
    // Sales-specific models
    aggregate Order { ... }
    entity Customer { ... }
    value Money { ... }
    repository OrderRepository for Order { ... }
    service OrderService { ... }
}

context Inventory {
    // Inventory-specific models
    aggregate Product { ... }
    entity StockLevel { ... }
    value Quantity { ... }
    repository ProductRepository for Product { ... }
    service InventoryService { ... }
}

context Shipping {
    // Shipping-specific models
    aggregate Shipment { ... }
    value Address { ... }
    value TrackingNumber { ... }
    service ShippingService { ... }
}
```

#### 6.2 Context Mapping

```
context_map {
    // Sales <-> Inventory relationship
    Sales <-[Customer-Supplier]-> Inventory {
        Sales.Order.items[*].productId -> Inventory.Product.sku;
    }
    
    // Sales <-> Shipping relationship
    Sales <-[Partnership]-> Shipping {
        Sales.Order -> Shipping.Shipment;
        Sales.Order.shippingAddress -> Shipping.Shipment.destination;
    }
    
    // Anti-corruption layer
    Sales <-[ACL]-> ExternalPaymentGateway {
        translator PaymentTranslator {
            Sales.Payment -> External.PaymentRequest;
            External.PaymentResponse -> Sales.PaymentResult;
        }
    }
}
```

---

### 7. Specifications (Query Objects)

```
specification ActiveCustomers for Customer {
    <Return> <customer>.status is .active 
        and <customer>.lastOrderDate > now().minus(90.days).
}

specification HighValueOrder for Order {
    param threshold: Money = Money(1000, USD);
    
    <Return> <order>.totals.total >= <threshold>.
}

// Usage
(Customer Report: Analytics) {
    <Query> the <customers> from <customerRepo> 
        matching ActiveCustomers.
    
    <Query> the <orders> from <orderRepo>
        matching HighValueOrder(threshold: Money(5000, USD)).
}
```

---

### 8. Factories

```
factory OrderFactory {
    createOrder(customerId: CustomerId, items: List<OrderItemRequest>) -> Order {
        <Create> the <order> with {
            id: <orderRepo>.nextId(),
            customerId: <customerId>,
            status: .draft,
            items: [],
            totals: OrderTotals.zero()
        }.
        
        for each <item> in <items> {
            <Handle> AddItem(<item>.productId, <item>.quantity) on <order>.
        }
        
        <Return> <order>.
    }
    
    reconstitute(snapshot: OrderSnapshot) -> Order {
        // Rebuild from persistence
        <Return> Order.fromSnapshot(<snapshot>).
    }
}
```

---

### 9. Complete Grammar Extension

```ebnf
(* Domain Modeling Grammar *)

(* Value Object *)
value_object = "value" , identifier , 
               "{" , { value_member } , "}" ;

value_member = field_def | invariant | func_def ;

invariant = "invariant" , condition , [ ":" , string_literal ] , ";" ;

func_def = "func" , identifier , "(" , [ param_list ] , ")" ,
           [ "->" , type_annotation ] , block ;

(* Entity *)
entity = "entity" , identifier , "{" , { entity_member } , "}" ;

entity_member = identity_field | field_def | invariant | func_def ;

identity_field = "identity" , identifier , ":" , type_annotation , ";" ;

(* Aggregate *)
aggregate = "aggregate" , identifier , "{" , { aggregate_member } , "}" ;

aggregate_member = root_entity | entity | value_object 
                 | invariant | command_handler ;

root_entity = "root" , entity ;

command_handler = "handle" , identifier , 
                  [ "(" , param_list , ")" ] , block ;

(* Repository *)
repository = "repository" , identifier , "for" , identifier ,
             "{" , { repository_method } , "}" ;

repository_method = identifier , "(" , [ param_list ] , ")" ,
                    [ "->" , type_annotation ] , [ block ] , ";" ;

(* Service *)
domain_service = "service" , identifier , "{" , { service_member } , "}" ;

service_member = require_stmt | service_method ;

service_method = identifier , "(" , [ param_list ] , ")" ,
                 [ "->" , type_annotation ] , block ;

(* Bounded Context *)
bounded_context = "context" , identifier , "{" , { context_member } , "}" ;

context_member = aggregate | entity | value_object 
               | domain_service | repository ;

(* Specification *)
specification = "specification" , identifier , "for" , identifier ,
                [ "{" , { param_def } , "}" ] , block ;

(* Factory *)
factory = "factory" , identifier , "{" , { factory_method } , "}" ;

factory_method = identifier , "(" , [ param_list ] , ")" ,
                 "->" , type_annotation , block ;
```

---

### 10. Complete Example

```
context ECommerce {
    // Value Objects
    value Money {
        amount: Decimal;
        currency: Currency;
        
        invariant <amount> >= 0;
        
        func add(other: Money) -> Money { ... }
        func subtract(other: Money) -> Money { ... }
        func multiply(factor: Decimal) -> Money { ... }
        
        static func zero(currency: Currency) -> Money {
            <Return> Money { amount: 0, currency: <currency> }.
        }
    }
    
    value Quantity {
        value: Int;
        
        invariant <value> > 0 : "Quantity must be positive";
    }
    
    // Aggregate
    aggregate Order {
        root entity OrderRoot {
            identity id: OrderId;
            customerId: CustomerId;
            items: List<OrderLine>;
            status: OrderStatus;
            total: Money;
        }
        
        entity OrderLine {
            identity lineId: LineId;
            productId: ProductId;
            quantity: Quantity;
            unitPrice: Money;
            
            func lineTotal() -> Money {
                <Return> <unitPrice>.multiply(<quantity>.value).
            }
        }
        
        handle AddLine(productId: ProductId, qty: Quantity, price: Money) {
            <Create> the <line> with {
                lineId: newLineId(),
                productId: <productId>,
                quantity: <qty>,
                unitPrice: <price>
            }.
            <Add> <line> to <items>.
            <Recalculate> <total>.
        }
        
        handle Submit {
            guard <items> is not empty.
            <Set> <status> to .submitted.
            <Emit> OrderSubmitted { orderId: <id>, total: <total> }.
        }
    }
    
    // Repository
    repository OrderRepository for Order {
        find(id: OrderId) -> Order?;
        findByCustomer(customerId: CustomerId) -> List<Order>;
        save(order: Order);
        nextId() -> OrderId;
    }
    
    // Domain Service
    service CheckoutService {
        <Require> <orderRepo: OrderRepository>.
        <Require> <paymentService: PaymentService>.
        
        checkout(orderId: OrderId, payment: PaymentMethod) -> Receipt {
            <Load> the <order> from <orderRepo> with { id: <orderId> }.
            
            <Process> the <payment-result> via <paymentService>
                for <order>.total with <payment>.
            
            guard <payment-result>.success else {
                <Throw> a <PaymentFailedError>.
            }
            
            <Handle> Submit on <order>.
            <Save> <order> to <orderRepo>.
            
            <Return> Receipt {
                orderId: <order>.id,
                amount: <order>.total,
                transactionId: <payment-result>.transactionId
            }.
        }
    }
}
```

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-01 | Initial specification |
