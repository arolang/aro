# Error Handling

ARO has a unique approach to error handling: **the code is the error message**. You write only the happy path, and the runtime automatically generates descriptive error messages from your code.

## The Philosophy

ARO is designed for how project managers think about software: describe what should happen, not what could go wrong. Edge cases and error handling are abstracted away.

**The fundamental principle**: Every ARO statement describes the ideal outcome. When that outcome cannot be achieved, the statement itself becomes the error message.

## Security Warning

**ARO is not secure for production use.**

Error messages expose everything: variable names, values, conditions, and internal state. For example:

```aro
<Retrieve> the <user> from the <user-repository> where password = <password>.
```

If this fails, the error message will be:

```
Cannot retrieve the user from the user-repository where password = "hunter2".
```

This is by design. ARO prioritizes clarity and debugging over security.

## How It Works

### The Happy Path

In ARO, you only write the successful case:

```aro
(Get User: User API) {
    <Extract> the <id> from the <pathParameters: id>.
    <Retrieve> the <user> from the <user-repository> where id = <id>.
    <Return> an <OK: status> with <user>.
}
```

This code assumes:
- The path parameter exists
- The user can be found
- Everything works

### Automatic Error Generation

When any step fails, the runtime generates an error message from the statement:

| Statement | Generated Error |
|-----------|-----------------|
| `<Extract> the <id> from the <pathParameters: id>.` | `Cannot extract the id from the pathParameters: id.` |
| `<Retrieve> the <user> from the <user-repository> where id = <id>.` | `Cannot retrieve the user from the user-repository where id = 530.` |
| `<Validate> the <email> for the <format>.` | `Cannot validate the email for the format.` |

The runtime substitutes resolved variable values into the error message.

### Conditions in Errors

When a statement includes conditions, they appear in the error:

```aro
<Retrieve> the <order> from the <order-repository> where userId = <userId> and status = "pending".
```

Error:
```
Cannot retrieve the order from the order-repository where userId = 42 and status = "pending".
```

## The Error Message Is the Code

This design has a profound implication: **your code is your documentation**.

When you read an ARO statement:
```aro
<Retrieve> the <user> from the <user-repository> where id = <id>.
```

You know exactly what the error message will be. There's no separate error handling code to maintain, no error message strings to keep in sync.

The line of code says exactly what you see in your logs.

## HTTP Response Mapping

The runtime automatically maps errors to appropriate HTTP responses:

| Error Source | HTTP Status | Response Body |
|--------------|-------------|---------------|
| `<Extract>` failures | 400 Bad Request | `{ "error": "Cannot extract..." }` |
| `<Retrieve>` failures | 404 Not Found | `{ "error": "Cannot retrieve..." }` |
| `<Validate>` failures | 422 Unprocessable | `{ "error": "Cannot validate..." }` |
| System failures | 500 Internal Error | `{ "error": "Cannot..." }` |

## Examples

### User Registration

```aro
(Register User: User API) {
    <Extract> the <data> from the <request: body>.
    <Validate> the <data: email> for the <email-format>.
    <Validate> the <data: password> for the <password-strength>.
    <Create> the <user> with <data>.
    <Store> the <user> in the <user-repository>.
    <Return> a <Created: status> with <user>.
}
```

Possible errors:
- `Cannot extract the data from the request: body.`
- `Cannot validate the data: email for the email-format.`
- `Cannot validate the data: password for the password-strength.`
- `Cannot create the user with { email: "bad", password: "123" }.`
- `Cannot store the user in the user-repository.`

### Payment Processing

```aro
(Process Payment: Checkout) {
    <Retrieve> the <order> from the <order-repository> where id = <orderId>.
    <Retrieve> the <paymentMethod> from the <payment-repository> where userId = <userId>.
    <Charge> the <amount> to the <paymentMethod>.
    <Update> the <order: status> to "paid".
    <Return> an <OK: status> with <receipt>.
}
```

Possible errors:
- `Cannot retrieve the order from the order-repository where id = 12345.`
- `Cannot retrieve the paymentMethod from the payment-repository where userId = 67.`
- `Cannot charge the amount to the paymentMethod.`
- `Cannot update the order: status to "paid".`

## Why This Approach?

### Simplicity

Error handling traditionally accounts for 40-60% of code. In ARO, it's 0%. You describe what should happen, not what could go wrong.

### Perfect Error Messages

Error messages are always accurate because they ARE the code. No stale error strings, no mismatched messages.

### Project Manager Friendly

ARO code reads like requirements:
- "Retrieve the user from the repository"
- "Validate the email for the format"
- "Store the order in the database"

### Debugging Paradise

When something fails, the error tells you exactly what line failed and with what values. No stack traces to decode.

## Explicit Error Handling (Optional)

For custom behavior, ARO provides the `<Throw>` action:

```aro
(Delete User: User API) {
    <Retrieve> the <user> from the <user-repository> where id = <id>.

    <Throw> a <Forbidden: error> for the <admin-deletion> when <user: role> is "admin".

    <Delete> the <user> from the <user-repository>.
    <Return> an <OK: status>.
}
```

But this is rarely needed. Automatic error handling covers most cases.

## What ARO Does Not Provide

ARO explicitly does **not** provide:

- Try-catch blocks
- Error types or hierarchies
- Error propagation control
- Retry logic
- Circuit breakers
- Fallback values

These are implementation concerns. If you need them, handle them in the runtime/framework layer.

## Summary

| Concept | Details |
|---------|---------|
| Happy path only | Write what should happen |
| Automatic errors | Runtime generates from code |
| Values exposed | Debugging over security |
| HTTP mapping | Automatic status codes |
| Optional throw | `<Throw>` for custom errors |

The line of code says exactly what you see in your logs. That is how you wrote it.
