# ARO-0013: State Machines

* Proposal: ARO-0013
* Author: ARO Language Team
* Status: **Draft**
* Requires: ARO-0001, ARO-0006

## Abstract

This proposal introduces formal state machine constructs to ARO, enabling explicit modeling of stateful business processes.

## Motivation

Many business processes are naturally state machines:

1. **Order Lifecycle**: draft → placed → paid → shipped → delivered
2. **User Onboarding**: registered → verified → active
3. **Approval Workflows**: pending → approved/rejected

---

### 1. State Machine Definition

#### 1.1 Basic Syntax

```ebnf
state_machine = "machine" , machine_name , 
                [ "for" , type_annotation ] ,
                "{" , { machine_member } , "}" ;

machine_member = state_def | transition_def | guard_def | action_def ;
```

**Example:**
```
machine OrderStateMachine for Order {
    // States
    initial state Draft;
    state Placed;
    state Paid;
    state Shipped;
    state Delivered;
    final state Cancelled;
    final state Completed;
    
    // Transitions
    Draft -> Placed on PlaceOrder;
    Placed -> Paid on ConfirmPayment;
    Placed -> Cancelled on CancelOrder;
    Paid -> Shipped on ShipOrder;
    Shipped -> Delivered on ConfirmDelivery;
    Delivered -> Completed on Complete;
    
    // Any state can be cancelled (except final states)
    * -> Cancelled on CancelOrder;
}
```

---

### 2. States

#### 2.1 State Types

```ebnf
state_def = [ state_modifier ] , "state" , state_name , 
            [ state_data ] , [ state_body ] , ";" ;

state_modifier = "initial" | "final" ;

state_data = "(" , field_list , ")" ;

state_body = "{" , { state_member } , "}" ;
```

**Example:**
```
machine PaymentStateMachine {
    initial state Pending;
    
    state Processing {
        on entry {
            <Start> the <payment-timer>.
        }
        on exit {
            <Stop> the <payment-timer>.
        }
    }
    
    state Failed(reason: String, attempts: Int);
    
    state Succeeded(transactionId: String, amount: Money);
    
    final state Refunded(refundId: String);
}
```

#### 2.2 Nested States (Hierarchical)

```
machine DocumentStateMachine {
    initial state Draft;
    
    state Review {
        initial state PendingReview;
        state InReview;
        state ChangesRequested;
        
        PendingReview -> InReview on StartReview;
        InReview -> ChangesRequested on RequestChanges;
        ChangesRequested -> InReview on SubmitChanges;
    }
    
    state Published;
    final state Archived;
    
    Draft -> Review on SubmitForReview;
    Review -> Published on Approve;
    Review -> Draft on Reject;
    Published -> Archived on Archive;
}
```

#### 2.3 Parallel States

```
machine OrderProcessing {
    parallel state Processing {
        region Payment {
            initial state PaymentPending;
            state PaymentProcessing;
            final state PaymentComplete;
            
            PaymentPending -> PaymentProcessing on ProcessPayment;
            PaymentProcessing -> PaymentComplete on PaymentSucceeded;
        }
        
        region Inventory {
            initial state InventoryPending;
            state InventoryReserving;
            final state InventoryReserved;
            
            InventoryPending -> InventoryReserving on ReserveInventory;
            InventoryReserving -> InventoryReserved on InventoryConfirmed;
        }
    }
    
    // Transition when both regions complete
    Processing -> ReadyToShip when Payment.complete and Inventory.complete;
}
```

---

### 3. Transitions

#### 3.1 Basic Transitions

```ebnf
transition_def = source_state , "->" , target_state , 
                 "on" , trigger ,
                 [ "when" , guard ] ,
                 [ "/" , action_list ] , ";" ;

source_state = state_name | "*" ;  (* wildcard for any state *)
trigger = identifier ;
guard = condition ;
action_list = action_name , { "," , action_name } ;
```

**Example:**
```
machine OrderMachine {
    // Simple transition
    Draft -> Placed on PlaceOrder;
    
    // Transition with guard
    Placed -> Paid on ProcessPayment when <payment>.valid;
    
    // Transition with action
    Paid -> Shipped on Ship / notifyCustomer, updateInventory;
    
    // Wildcard source
    * -> Cancelled on Cancel when state is not Shipped;
}
```

#### 3.2 Internal Transitions

Don't change state, just execute action:

```
machine SessionMachine {
    state Active {
        // Internal transition - stays in Active
        internal on Heartbeat / resetTimeout;
        internal on UserAction / updateLastActivity;
    }
}
```

#### 3.3 Self Transitions

Exit and re-enter same state:

```
machine RetryMachine {
    state Processing {
        on entry {
            <Increment> the <attempts>.
        }
    }
    
    // Self transition - triggers entry/exit
    Processing -> Processing on Retry when <attempts> < 3;
    Processing -> Failed on Retry when <attempts> >= 3;
}
```

---

### 4. Guards

#### 4.1 Guard Definition

```ebnf
guard_def = "guard" , guard_name , "(" , param_list , ")" ,
            "->" , "Bool" , block ;
```

**Example:**
```
machine OrderMachine {
    guard canCancel(order: Order) -> Bool {
        <Return> <order>.status is not Shipped 
            and <order>.status is not Delivered.
    }
    
    guard hasStock(order: Order) -> Bool {
        for each <item> in <order>.items {
            if <inventory>.available(<item>.productId) < <item>.quantity then {
                <Return> false.
            }
        }
        <Return> true.
    }
    
    Placed -> Processing on Process when hasStock(order);
    * -> Cancelled on Cancel when canCancel(order);
}
```

---

### 5. Actions

#### 5.1 Action Types

```ebnf
action_def = "action" , action_name , [ "(" , param_list , ")" ] , block ;
```

**Example:**
```
machine OrderMachine {
    action notifyCustomer {
        <Send> the <order-update-email> to <order>.customer.email.
    }
    
    action reserveInventory {
        for each <item> in <order>.items {
            <Reserve> <item>.quantity of <item>.productId.
        }
    }
    
    action releaseInventory {
        for each <item> in <order>.items {
            <Release> <item>.quantity of <item>.productId.
        }
    }
    
    Placed -> Processing on Process / reserveInventory;
    Processing -> Cancelled on Cancel / releaseInventory, notifyCustomer;
}
```

#### 5.2 Entry and Exit Actions

```
machine DocumentMachine {
    state UnderReview {
        on entry {
            <Assign> the <reviewers> to <document>.
            <Send> the <review-request> to <reviewers>.
            <Start> the <review-timer>.
        }
        
        on exit {
            <Stop> the <review-timer>.
            <Clear> the <reviewers>.
        }
    }
}
```

---

### 6. Using State Machines

#### 6.1 In Feature Sets

```
(Order Processing: E-Commerce) {
    <Require> <order: Order> from context.
    <Require> <machine: OrderStateMachine> from framework.
    
    // Get current state
    <Get> the <current-state> from <machine>.state(<order>).
    
    // Check if transition allowed
    if <machine>.can(<order>, PlaceOrder) then {
        // Trigger transition
        <Transition> the <order> with PlaceOrder via <machine>.
    }
    
    // Get available transitions
    <Get> the <available> from <machine>.availableTransitions(<order>).
}
```

#### 6.2 State Queries

```
(Order Dashboard: Reporting) {
    // Find orders in specific state
    <Query> the <pending-orders> from <orders> 
        where <machine>.isInState(<order>, Placed).
    
    // Check if in any of multiple states
    <Query> the <active-orders> from <orders>
        where <machine>.isInAnyState(<order>, [Placed, Paid, Shipped]).
    
    // Check nested state
    <Query> the <reviewing> from <documents>
        where <machine>.isInState(<doc>, Review.InReview).
}
```

---

### 7. State Machine Visualization

The compiler can generate:

```
┌─────────────────────────────────────────────────────────────┐
│                     OrderStateMachine                        │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│   ┌─────────┐  PlaceOrder   ┌─────────┐  ConfirmPayment     │
│   │  Draft  │──────────────▶│ Placed  │──────────────────┐  │
│   └─────────┘               └────┬────┘                  │  │
│        ●                         │                       ▼  │
│                            Cancel│               ┌─────────┐│
│                                  │               │  Paid   ││
│                                  ▼               └────┬────┘│
│                          ┌───────────┐                │     │
│                          │ Cancelled │◀───────────────┤     │
│                          └───────────┘           Ship │     │
│                               ◉                      ▼     │
│                                              ┌─────────┐   │
│   ◉ = final                                  │ Shipped │   │
│   ● = initial                                └────┬────┘   │
│                                                   │        │
│                                         Delivered │        │
│                                                   ▼        │
│                                           ┌───────────┐    │
│                                           │ Delivered │    │
│                                           └─────┬─────┘    │
│                                                 │          │
│                                        Complete │          │
│                                                 ▼          │
│                                          ┌───────────┐     │
│                                          │ Completed │     │
│                                          └───────────┘     │
│                                               ◉            │
└─────────────────────────────────────────────────────────────┘
```

---

### 8. Complete Grammar Extension

```ebnf
(* State Machine Grammar *)

state_machine = "machine" , identifier , 
                [ "for" , type_annotation ] ,
                "{" , { machine_member } , "}" ;

machine_member = state_def | transition_def | guard_def | action_def ;

(* State *)
state_def = [ state_modifier ] , "state" , identifier ,
            [ "(" , field_list , ")" ] ,
            [ "{" , { state_body_member } , "}" ] , ";" ;

state_modifier = "initial" | "final" | "parallel" ;

state_body_member = nested_state | region | entry_action | exit_action 
                  | internal_transition ;

nested_state = state_def ;
region = "region" , identifier , "{" , { state_def | transition_def } , "}" ;
entry_action = "on" , "entry" , block ;
exit_action = "on" , "exit" , block ;
internal_transition = "internal" , "on" , identifier , 
                      [ "/" , action_list ] , ";" ;

(* Transition *)
transition_def = source , "->" , target , "on" , identifier ,
                 [ "when" , condition ] ,
                 [ "/" , action_list ] , ";" ;

source = identifier | "*" ;
target = identifier ;
action_list = identifier , { "," , identifier } ;

(* Guard *)
guard_def = "guard" , identifier , "(" , param_list , ")" ,
            "->" , "Bool" , block ;

(* Action *)
action_def = "action" , identifier , 
             [ "(" , param_list , ")" ] , block ;

(* Usage *)
transition_stmt = "<Transition>" , variable_reference , 
                  "with" , identifier ,
                  "via" , variable_reference , "." ;
```

---

### 9. Complete Example

```
// Order state machine with full features
machine OrderLifecycle for Order {
    // Guards
    guard hasValidPayment(order: Order) -> Bool {
        <Return> <order>.payment exists and <order>.payment.valid.
    }
    
    guard hasStock(order: Order) -> Bool {
        <Return> <inventory>.checkAvailability(<order>.items).
    }
    
    guard canCancel(order: Order) -> Bool {
        <Return> <order>.status is not Shipped 
            and <order>.status is not Delivered.
    }
    
    // Actions
    action reserveStock {
        <Reserve> the <order>.items in <inventory>.
    }
    
    action releaseStock {
        <Release> the <order>.items from <inventory>.
    }
    
    action sendConfirmation {
        <Send> the <order-confirmation> to <order>.customer.
    }
    
    action sendShippingNotification {
        <Send> the <shipping-notification> to <order>.customer.
    }
    
    action processRefund {
        <Refund> the <order>.payment.
    }
    
    // States
    initial state Draft {
        on entry {
            <Set> <order>.createdAt to now().
        }
    }
    
    state Submitted {
        on entry {
            <Validate> the <order>.
        }
    }
    
    parallel state Processing {
        region Payment {
            initial state AwaitingPayment;
            state PaymentProcessing;
            final state PaymentReceived;
            
            AwaitingPayment -> PaymentProcessing on ProcessPayment;
            PaymentProcessing -> PaymentReceived on PaymentConfirmed;
            PaymentProcessing -> AwaitingPayment on PaymentFailed;
        }
        
        region Stock {
            initial state CheckingStock;
            final state StockReserved;
            state OutOfStock;
            
            CheckingStock -> StockReserved on StockAvailable / reserveStock;
            CheckingStock -> OutOfStock on StockUnavailable;
        }
    }
    
    state ReadyToShip {
        on entry {
            <Generate> the <shipping-label> for <order>.
        }
    }
    
    state Shipped {
        on entry / sendShippingNotification;
    }
    
    state Delivered {
        on entry {
            <Set> <order>.deliveredAt to now().
        }
    }
    
    final state Completed;
    
    final state Cancelled {
        on entry {
            if <order>.paymentReceived then {
                <Execute> processRefund.
            }
            <Execute> releaseStock.
        }
    }
    
    // Transitions
    Draft -> Submitted on Submit when hasValidPayment(order) / sendConfirmation;
    Submitted -> Processing on StartProcessing;
    
    Processing -> ReadyToShip 
        when Payment.complete and Stock.complete;
    
    Processing -> Cancelled on Cancel when canCancel(order);
    
    ReadyToShip -> Shipped on Ship;
    Shipped -> Delivered on ConfirmDelivery;
    Delivered -> Completed on Complete;
    
    // Can cancel from most states
    Draft -> Cancelled on Cancel;
    Submitted -> Cancelled on Cancel;
}

// Usage in feature set
(Ship Order: Fulfillment) {
    <Load> the <order> from <order-repository>.
    <Require> <machine: OrderLifecycle> from framework.
    
    // Verify current state
    guard <machine>.isInState(<order>, ReadyToShip) else {
        <Throw> an <InvalidStateError> with {
            expected: "ReadyToShip",
            actual: <machine>.state(<order>)
        } for the <order>.
    }
    
    // Prepare shipment
    <Create> the <shipment> for the <order>.
    <Assign> the <carrier> to the <shipment>.
    
    // Transition
    <Transition> the <order> with Ship via <machine>.
    
    // Save
    <Save> the <order> to <order-repository>.
    
    <Return> the <shipment> for the <request>.
}
```

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-01 | Initial specification |
