# Chapter 27: Control Flow

ARO provides control flow constructs for conditional execution. This chapter covers how to make decisions in your feature sets using guarded statements and match expressions.

## When Guards

The `when` clause conditionally executes a single statement. If the condition is false, the statement is skipped and execution continues to the next statement.

### Syntax

```aro
<Action> the <result> preposition the <object> when <condition>.
```

### Basic Guards

```aro
(getUser: User API) {
    <Extract> the <user-id> from the <pathParameters: id>.
    <Retrieve> the <user> from the <user-repository> where id = <user-id>.

    (* Return NotFound only when user is empty *)
    <Return> a <NotFound: status> for the <missing: user> when <user> is empty.

    <Return> an <OK: status> with <user>.
}
```

### Guard Examples

```aro
(* Only return OK when count is not zero *)
<Return> an <OK: status> with <items> when <count> is not 0.

(* Send notification only when user has email *)
<Send> the <notification> to the <user: email> when <user: email> exists.

(* Log admin access only for admins *)
<Log> "admin access" to the <audit> when <user: role> = "admin".

(* Return error when validation fails *)
<Return> a <BadRequest: status> for the <invalid: input> when <validation> is failed.
```

### Comparison Operators

| Operator | Meaning |
|----------|---------|
| `is` | Equality |
| `is not` | Inequality |
| `is empty` | Null/empty check |
| `is not empty` | Has value |
| `exists` | Value exists |
| `is defined` | Value is defined |
| `is null` | Value is null |
| `>` | Greater than |
| `<` | Less than |
| `>=` | Greater than or equal |
| `<=` | Less than or equal |
| `=` | Equality |
| `!=` | Strict inequality |

### Boolean Operators

Combine conditions with `and`, `or`, `not`:

```aro
(* Multiple conditions with and *)
<Return> an <OK: status> with <user> when <user: active> is true and <user: verified> is true.

(* Either condition with or *)
<Return> a <BadRequest: status> for the <unavailable: product> when <stock> is empty or <stock> < <required>.

(* Negation *)
<Allow> the <access> for the <user> when not <user: banned>.

(* Complex condition *)
<Grant> the <admin-features> for the <user> when (<user: role> is "admin" or <user: is-owner> is true) and <resource: public> is false.
```

## Match Expressions

Pattern matching for multiple cases:

```aro
match <value> {
    case <pattern> {
        (* handle this case *)
    }
    case <pattern> where <condition> {
        (* handle case with guard *)
    }
    otherwise {
        (* handle all other cases *)
    }
}
```

### Simple Value Matching

```aro
(PUT /orders/{id}/status: Order API) {
    <Extract> the <order-id> from the <pathParameters: id>.
    <Extract> the <new-status> from the <request: body.status>.
    <Retrieve> the <order> from the <order-repository> where id = <order-id>.

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
        otherwise {
            <Return> a <BadRequest: status> for the <invalid: status>.
        }
    }

    <Transform> the <updated-order> from the <order> with { status: <new-status> }.
    <Store> the <updated-order> into the <order-repository>.
    <Return> an <OK: status> with <updated-order>.
}
```

### HTTP Method Routing

```aro
match <http: method> {
    case "GET" {
        <Retrieve> the <resource> from the <database>.
    }
    case "POST" {
        <Create> the <resource> in the <database>.
    }
    case "PUT" {
        <Update> the <resource> in the <database>.
    }
    case "DELETE" {
        <Remove> the <resource> from the <database>.
    }
    otherwise {
        <Return> a <MethodNotAllowed: error> for the <request>.
    }
}
```

### Pattern Matching with Guards

```aro
match <user: subscription> {
    case <premium> where <user: credits> > 0 {
        <Grant> the <premium-features> for the <user>.
        <Deduct> the <credit> from the <user: account>.
    }
    case <premium> {
        <Notify> the <user> about the <low-credits>.
        <Grant> the <basic-features> for the <user>.
    }
    case <basic> {
        <Grant> the <basic-features> for the <user>.
    }
    otherwise {
        <Redirect> the <user> to the <subscription-page>.
    }
}
```

### Status Code Handling

```aro
match <status-code> {
    case 200 {
        <Parse> the <response: body> from the <http-response>.
        <Return> the <data> for the <request>.
    }
    case 404 {
        <Return> a <NotFound: error> for the <request>.
    }
    case 500 {
        <Log> "server error" to the <monitoring>.
        <Return> a <ServerError> for the <request>.
    }
    otherwise {
        <Return> an <UnknownError> for the <request>.
    }
}
```

### Regular Expression Patterns

Match statements support regex patterns for flexible string matching. Use forward slashes to delimit a regex pattern:

```aro
match <message.text> {
    case /^ERROR:/i {
        <Log> <message.text> to the <console>.
        <Emit> an <AlertTriggered: event> with <message>.
    }
    case /^WARN:/i {
        <Log> <message.text> to the <console>.
    }
    case /^[A-Z]{3}-\d{4}$/ {
        (* Matches ticket IDs like "ABC-1234" *)
        <Process> the <ticket-reference> from the <message>.
    }
    otherwise {
        <Log> <message.text> to the <console>.
    }
}
```

#### Regex Flags

| Flag | Description |
|------|-------------|
| `i` | Case insensitive |
| `s` | Dot matches newlines |
| `m` | Multiline (^ and $ match line boundaries) |

#### Common Use Cases

```aro
(* Email validation *)
match <email> {
    case /^[\w.+-]+@[\w.-]+\.[a-zA-Z]{2,}$/i {
        <Return> an <OK: status> with { valid: true }.
    }
    otherwise {
        <Return> a <BadRequest: status> with { error: "Invalid email format" }.
    }
}

(* Command routing *)
match <input> {
    case /^\/help/i {
        <Emit> a <HelpRequested: event> with <message>.
    }
    case /^\/status\s+\w+$/i {
        <Emit> a <StatusQuery: event> with <message>.
    }
    otherwise {
        <Emit> a <MessageReceived: event> with <message>.
    }
}
```

Use `^` and `$` anchors when you need full-string matching rather than substring matching.

## Common Patterns

### Validate-or-Fail

```aro
(POST /users: User API) {
    <Extract> the <user-data> from the <request: body>.
    <Validate> the <user-data> for the <user-schema>.

    <Return> a <BadRequest: status> with <validation: errors> when <validation> is failed.

    <Create> the <user> with <user-data>.
    <Store> the <user> into the <user-repository>.
    <Return> a <Created: status> with <user>.
}
```

### Find-or-404

```aro
(GET /products/{id}: Product API) {
    <Extract> the <product-id> from the <pathParameters: id>.
    <Retrieve> the <product> from the <product-repository> where id = <product-id>.

    <Return> a <NotFound: status> for the <missing: product> when <product> is empty.

    <Return> an <OK: status> with <product>.
}
```

### Check-Permission

```aro
(DELETE /posts/{id}: Post API) {
    <Extract> the <post-id> from the <pathParameters: id>.
    <Retrieve> the <post> from the <post-repository> where id = <post-id>.

    <Return> a <NotFound: status> for the <missing: post> when <post> is empty.

    <Return> a <Forbidden: status> for the <unauthorized: deletion>
        when <post: authorId> is not <current-user: id> and <current-user: role> is not "admin".

    <Delete> the <post> from the <post-repository> where id = <post-id>.
    <Return> a <NoContent: status> for the <deletion>.
}
```

### Fail Fast with Guards

Check error conditions early with guarded returns:

```aro
(POST /transfer: Banking) {
    <Extract> the <amount> from the <request: body.amount>.
    <Extract> the <from-account> from the <request: body.from>.
    <Extract> the <to-account> from the <request: body.to>.

    (* Early exits for invalid input *)
    <Return> a <BadRequest: status> for the <invalid: amount> when <amount> <= 0.
    <Return> a <BadRequest: status> for the <same: accounts> when <from-account> is <to-account>.

    <Retrieve> the <source> from the <account-repository> where id = <from-account>.

    <Return> a <NotFound: status> for the <missing: source-account> when <source> is empty.
    <Return> a <BadRequest: status> for the <insufficient: funds> when <source: balance> < <amount>.

    (* Now proceed with transfer *)
    <Retrieve> the <destination> from the <account-repository> where id = <to-account>.
    <Transfer> the <amount> from the <source> to the <destination>.
    <Return> an <OK: status> for the <transfer>.
}
```

### Conditional Processing

```aro
(POST /orders: Order API) {
    <Extract> the <order-data> from the <request: body>.
    <Create> the <order> with <order-data>.

    (* Conditional discount *)
    <Compute> the <discount> with <order: total> * 0.1 when <order: total> >= 100.
    <Transform> the <order> from the <order> with { discount: <discount> } when <discount> exists.

    (* Conditional express shipping *)
    <Compute> the <express-fee> for the <order> when <order: express> is true.
    <Transform> the <order> from the <order> with { shippingFee: <express-fee> } when <express-fee> exists.

    <Store> the <order> into the <order-repository>.
    <Return> a <Created: status> with <order>.
}
```

## Complete Example

```aro
(User Authentication: Security) {
    <Require> the <request> from the <framework>.
    <Require> the <user-repository> from the <framework>.

    (* Extract credentials *)
    <Extract> the <username> from the <request: body>.
    <Extract> the <password> from the <request: body>.

    (* Validate input - guarded return *)
    <Return> a <BadRequest: error> for the <request>
        when <username> is empty or <password> is empty.

    (* Look up user *)
    <Retrieve> the <user> from the <user-repository>.

    (* Handle user not found - guarded statements *)
    <Log> <username> to the <console> when <user> is null.
    <Return> an <Unauthorized: error> for the <request> when <user> is null.

    (* Check account status with match *)
    match <user: status> {
        case "locked" {
            <Return> an <AccountLocked: error> for the <request>.
        }
        case "pending" {
            <Send> the <verification-email> to the <user: email>.
            <Return> a <PendingVerification: status> for the <request>.
        }
        case "active" {
            (* Verify password *)
            <Compute> the <password-hash> for the <password>.

            match <password-hash> {
                case <user: password-hash> {
                    <Create> the <session-token> for the <user>.
                    <Log> <user> to the <console>.
                    <Return> an <OK: status> with the <session-token>.
                }
                otherwise {
                    <Increment> the <failed-attempts> for the <user>.
                    <Lock> the <user: account> for the <security-policy>
                        when <failed-attempts> >= 5.
                    <Return> an <Unauthorized: error> for the <request>.
                }
            }
        }
        otherwise {
            <Return> an <InvalidAccountStatus: error> for the <request>.
        }
    }
}
```

## Best Practices

### Use Guards for Early Exits

Guards with `when` are ideal for:
- Input validation
- Preconditions
- Error returns

```aro
(* Good - guards for early exit *)
<Return> a <BadRequest: status> for the <missing: id> when <user-id> is empty.
<Return> a <NotFound: status> for the <missing: user> when <user> is empty.
<Return> a <Forbidden: status> for the <private: profile> when <user: private> is true.

(* Continue with main logic *)
<Return> an <OK: status> with <user>.
```

### Use Match for Multiple Outcomes

Match expressions are ideal for:
- Status handling
- Role-based logic
- State machines
- Multiple distinct cases

```aro
(* Good - match for multiple cases *)
match <order: status> {
    case "pending" { ... }
    case "processing" { ... }
    case "shipped" { ... }
    case "delivered" { ... }
    otherwise { ... }
}
```

### Be Explicit in Conditions

```aro
(* Good - explicit conditions *)
<Grant> the <access> for the <user> when <user: active> is true and <user: verified> is true.

(* Avoid - implicit truthiness *)
<Grant> the <access> for the <user> when <user: active> and <user: verified>.
```

---

*Next: Chapter 28 — Data Pipelines*
