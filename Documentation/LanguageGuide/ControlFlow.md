# Control Flow

ARO provides control flow constructs for conditional execution and early returns. This chapter covers how to make decisions in your feature sets.

## If-Then-Else

The primary conditional construct in ARO:

```aro
if <condition> then {
    (* statements if true *)
}
```

With else:

```aro
if <condition> then {
    (* statements if true *)
} else {
    (* statements if false *)
}
```

### Basic Conditions

```aro
(GET /users/{id}: User API) {
    <Extract> the <user-id> from the <request: parameters>.
    <Retrieve> the <user> from the <repository> where id = <user-id>.

    if <user> is empty then {
        <Return> a <NotFound: status> for the <missing: user>.
    }

    <Return> an <OK: status> with <user>.
}
```

### Comparison Operators

| Operator | Meaning |
|----------|---------|
| `is` | Equality |
| `is not` | Inequality |
| `is empty` | Null/empty check |
| `is not empty` | Has value |
| `>` | Greater than |
| `<` | Less than |
| `>=` | Greater than or equal |
| `<=` | Less than or equal |

### Examples

```aro
if <count> is 0 then {
    <Return> a <NotFound: status> for the <empty: list>.
}

if <user: role> is "admin" then {
    <Return> an <OK: status> with <admin-data>.
} else {
    <Return> an <OK: status> with <user-data>.
}

if <order: total> > 100 then {
    <Compute> the <discount> for the <order>.
    <Transform> the <discounted-order> from the <order> with <discount>.
}

if <stock> < <required> then {
    <Return> a <BadRequest: status> for the <insufficient: stock>.
}
```

### Nested Conditions

```aro
if <user> is not empty then {
    if <user: active> is true then {
        if <user: role> is "admin" then {
            <Return> an <OK: status> with <admin-view>.
        } else {
            <Return> an <OK: status> with <user-view>.
        }
    } else {
        <Return> a <Forbidden: status> for the <inactive: user>.
    }
} else {
    <Return> a <NotFound: status> for the <missing: user>.
}
```

### Boolean Operators

Combine conditions with `and`, `or`, `not`:

```aro
if <user: active> is true and <user: verified> is true then {
    <Return> an <OK: status> with <user>.
}

if <stock> is empty or <stock> < <required> then {
    <Return> a <BadRequest: status> for the <unavailable: product>.
}

if not <user: banned> then {
    <Allow> the <access> for the <user>.
}
```

## When Guards

Guards provide early exit for preconditions:

```aro
when <condition> {
    (* exit statements *)
}
```

### Basic Guards

```aro
(PUT /users/{id}: User API) {
    <Extract> the <user-id> from the <request: parameters>.
    <Extract> the <updates> from the <request: body>.

    when <user-id> is empty {
        <Return> a <BadRequest: status> for the <missing: id>.
    }

    when <updates> is empty {
        <Return> a <BadRequest: status> for the <missing: data>.
    }

    (* Continue with valid input *)
    <Retrieve> the <user> from the <repository> where id = <user-id>.

    when <user> is empty {
        <Return> a <NotFound: status> for the <missing: user>.
    }

    <Transform> the <updated-user> from the <user> with <updates>.
    <Store> the <updated-user> into the <repository>.
    <Return> an <OK: status> with <updated-user>.
}
```

### Guard vs If

Use **guards** for:
- Input validation
- Preconditions
- Early exits on error

Use **if-then-else** for:
- Business logic branches
- Multiple outcomes
- Computed decisions

```aro
(Process Payment: Payment Service) {
    <Extract> the <payment-data> from the <request: body>.

    (* Guards for validation *)
    when <payment-data: amount> <= 0 {
        <Return> a <BadRequest: status> for the <invalid: amount>.
    }

    when <payment-data: cardNumber> is empty {
        <Return> a <BadRequest: status> for the <missing: card>.
    }

    (* Business logic with if *)
    <Process> the <result> for the <payment-data>.

    if <result: success> is true then {
        <Emit> a <PaymentSucceeded: event> with <result>.
        <Return> an <OK: status> with <result>.
    } else {
        <Emit> a <PaymentFailed: event> with <result>.
        <Return> a <BadRequest: status> with <result: error>.
    }
}
```

## Match Expressions

Pattern matching for multiple cases:

```aro
match <value> {
    case "pending" {
        (* handle pending *)
    }
    case "approved" {
        (* handle approved *)
    }
    case "rejected" {
        (* handle rejected *)
    }
    default {
        (* handle other cases *)
    }
}
```

### Example

```aro
(PUT /orders/{id}/status: Order API) {
    <Extract> the <order-id> from the <request: parameters>.
    <Extract> the <new-status> from the <request: body status>.
    <Retrieve> the <order> from the <repository> where id = <order-id>.

    match <new-status> {
        case "confirmed" {
            <Validate> the <order> for the <confirmation-rules>.
            <Emit> an <OrderConfirmed: event> with <order>.
        }
        case "shipped" {
            <Validate> the <order> for the <shipping-rules>.
            <Emit> an <OrderShipped: event> with <order>.
        }
        case "delivered" {
            <Emit> an <OrderDelivered: event> with <order>.
        }
        case "cancelled" {
            <Emit> an <OrderCancelled: event> with <order>.
        }
        default {
            <Return> a <BadRequest: status> for the <invalid: status>.
        }
    }

    <Transform> the <updated-order> from the <order> with { status: <new-status> }.
    <Store> the <updated-order> into the <repository>.
    <Return> an <OK: status> with <updated-order>.
}
```

## Early Returns

Use return statements to exit early:

```aro
(GET /users/{id}: User API) {
    <Extract> the <user-id> from the <request: parameters>.

    (* Early return on invalid input *)
    if <user-id> is empty then {
        <Return> a <BadRequest: status> for the <missing: id>.
    }

    <Retrieve> the <user> from the <repository> where id = <user-id>.

    (* Early return on not found *)
    if <user> is empty then {
        <Return> a <NotFound: status> for the <missing: user>.
    }

    (* Early return on forbidden *)
    if <user: private> is true and <current-user: id> is not <user-id> then {
        <Return> a <Forbidden: status> for the <private: profile>.
    }

    (* Normal return *)
    <Return> an <OK: status> with <user>.
}
```

## Common Patterns

### Validate-or-Fail

```aro
(POST /users: User API) {
    <Extract> the <user-data> from the <request: body>.
    <Validate> the <user-data> for the <user-schema>.

    if <validation> is failed then {
        <Return> a <BadRequest: status> with <validation: errors>.
    }

    <Create> the <user> with <user-data>.
    <Store> the <user> into the <repository>.
    <Return> a <Created: status> with <user>.
}
```

### Find-or-404

```aro
(GET /products/{id}: Product API) {
    <Extract> the <product-id> from the <request: parameters>.
    <Retrieve> the <product> from the <repository> where id = <product-id>.

    if <product> is empty then {
        <Return> a <NotFound: status> for the <missing: product>.
    }

    <Return> an <OK: status> with <product>.
}
```

### Check-Permission

```aro
(DELETE /posts/{id}: Post API) {
    <Extract> the <post-id> from the <request: parameters>.
    <Retrieve> the <post> from the <repository> where id = <post-id>.

    if <post> is empty then {
        <Return> a <NotFound: status> for the <missing: post>.
    }

    if <post: authorId> is not <current-user: id> and <current-user: role> is not "admin" then {
        <Return> a <Forbidden: status> for the <unauthorized: deletion>.
    }

    <Delete> the <post> from the <repository> where id = <post-id>.
    <Return> a <NoContent: status> for the <deletion>.
}
```

### Conditional Processing

```aro
(POST /orders: Order API) {
    <Extract> the <order-data> from the <request: body>.
    <Create> the <order> with <order-data>.

    (* Conditional discount *)
    if <order: total> >= 100 then {
        <Compute> the <discount> with <order: total> * 0.1.
        <Transform> the <order> from the <order> with { discount: <discount> }.
    }

    (* Conditional express shipping *)
    if <order: express> is true then {
        <Compute> the <express-fee> for the <order>.
        <Transform> the <order> from the <order> with { shippingFee: <express-fee> }.
    }

    <Store> the <order> into the <repository>.
    <Return> a <Created: status> with <order>.
}
```

## Best Practices

### Fail Fast

Check error conditions early:

```aro
(* Good - fail fast *)
(POST /transfer: Banking) {
    <Extract> the <amount> from the <request: body amount>.
    <Extract> the <from-account> from the <request: body from>.
    <Extract> the <to-account> from the <request: body to>.

    when <amount> <= 0 {
        <Return> a <BadRequest: status> for the <invalid: amount>.
    }

    when <from-account> is <to-account> {
        <Return> a <BadRequest: status> for the <same: accounts>.
    }

    <Retrieve> the <source> from the <account-repository> where id = <from-account>.

    when <source> is empty {
        <Return> a <NotFound: status> for the <missing: source-account>.
    }

    when <source: balance> < <amount> {
        <Return> a <BadRequest: status> for the <insufficient: funds>.
    }

    (* Now proceed with transfer *)
    ...
}
```

### Keep Nesting Shallow

```aro
(* Avoid - deep nesting *)
if <a> then {
    if <b> then {
        if <c> then {
            (* hard to follow *)
        }
    }
}

(* Better - use guards and early returns *)
when not <a> {
    <Return> a <BadRequest: status>.
}
when not <b> {
    <Return> a <BadRequest: status>.
}
when not <c> {
    <Return> a <BadRequest: status>.
}
(* proceed with logic *)
```

### Be Explicit

```aro
(* Good - explicit conditions *)
if <user: active> is true and <user: verified> is true then {
    ...
}

(* Avoid - implicit truthiness *)
if <user: active> and <user: verified> then {
    ...
}
```

## Next Steps

- [Events](events.html) - Event-driven control flow
- [Actions](actions.html) - Actions that affect flow
- [Feature Sets](featuresets.html) - Feature set structure
