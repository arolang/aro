# ARO-0008: Error Handling

* Proposal: ARO-0008
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0004, ARO-0006

## Abstract

This proposal defines ARO's unique approach to error handling: **the code is the error message**. Programmers write only the happy path, and the runtime automatically generates descriptive error messages derived directly from the source code.

## Philosophy

ARO is designed for how project managers think about software: they describe what should happen, not what could go wrong. Edge cases, error handling, and failure modes are the domain of implementation details that ARO abstracts away.

**The fundamental principle**: Every ARO statement describes the ideal outcome. When that outcome cannot be achieved, the statement itself becomes the error message.

## Security Warning

**ARO is not secure for production use.**

Error messages in ARO expose everything: variable names, values, conditions, and internal state. If you write:

```aro
<Retrieve> the <user> from the <user-repository> where password = <password>.
```

And this fails, the error message will be:

```
Cannot retrieve the user from the user-repository where password = "hunter2".
```

This is by design. ARO prioritizes clarity and debugging over security. The statement you write is exactly what you see in your logs.

---

## How It Works

### 1. The Happy Path

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

### 2. Automatic Error Generation

When any step fails, the runtime generates an error message from the statement:

| Statement | Generated Error |
|-----------|-----------------|
| `<Extract> the <id> from the <pathParameters: id>.` | `Cannot extract the id from the pathParameters: id.` |
| `<Retrieve> the <user> from the <user-repository> where id = <id>.` | `Cannot retrieve the user from the user-repository where id = 530.` |
| `<Validate> the <email> for the <format>.` | `Cannot validate the email for the format.` |

The runtime substitutes resolved variable values into the error message, making it immediately clear what went wrong.

### 3. Conditions Become Part of the Error

When a statement includes conditions, they appear in the error:

```aro
<Retrieve> the <order> from the <order-repository> where userId = <userId> and status = "pending".
```

Error:
```
Cannot retrieve the order from the order-repository where userId = 42 and status = "pending".
```

---

## The Error Message Is the Code

This design has a profound implication: **your code is your documentation**.

When you read an ARO statement:
```aro
<Retrieve> the <user> from the <user-repository> where id = <id>.
```

You know exactly what the error message will be. There's no separate error handling code to maintain, no error message strings to keep in sync, no wondering "what does this error mean?"

The line of code says exactly what we want to see in our logs. That is how we wrote it.

---

## Runtime Behavior

### HTTP Response Mapping

The runtime automatically maps errors to appropriate HTTP responses:

| Error Source | HTTP Status | Response Body |
|--------------|-------------|---------------|
| `<Extract>` failures | 400 Bad Request | `{ "error": "Cannot extract..." }` |
| `<Retrieve>` failures | 404 Not Found | `{ "error": "Cannot retrieve..." }` |
| `<Validate>` failures | 422 Unprocessable | `{ "error": "Cannot validate..." }` |
| System failures | 500 Internal Error | `{ "error": "Cannot..." }` |

### Logging

All errors are automatically logged with full context:

```
[ERROR] [Get User: User API] Cannot retrieve the user from the user-repository where id = 530.
```

The feature set name, business activity, and full error message are always included.

---

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

---

## Why This Approach?

### 1. Simplicity

Error handling traditionally accounts for 40-60% of code. In ARO, it's 0%. You describe what should happen, not what could go wrong.

### 2. Perfect Error Messages

Error messages are always accurate because they ARE the code. No stale error strings, no "this error doesn't match what happened."

### 3. Project Manager Friendly

ARO code reads like requirements:
- "Retrieve the user from the repository"
- "Validate the email for the format"
- "Store the order in the database"

Project managers can read, understand, and even write ARO code because it matches how they think about features.

### 4. Debugging Paradise

When something fails, the error tells you exactly what line failed and with what values. No stack traces to decode, no "what was the state when this failed?"

---

## Explicit Error Handling (Optional)

For cases where you want custom behavior, ARO provides the `<Throw>` action:

```aro
(Delete User: User API) {
    <Retrieve> the <user> from the <user-repository> where id = <id>.

    (* Custom business rule *)
    if <user: role> = "admin" then {
        <Throw> a <Forbidden: error> for the <admin-deletion>.
    }

    <Delete> the <user> from the <user-repository>.
    <Return> an <OK: status>.
}
```

But this is rarely needed. The automatic error handling covers most cases.

---

## Implementation

### Error Type

```swift
public struct AROError: Error, Sendable {
    public let message: String
    public let featureSet: String
    public let statement: String
    public let resolvedValues: [String: String]
}
```

### Error Generation

When an action fails, the runtime:

1. Takes the original statement text
2. Replaces the verb with "Cannot [verb]"
3. Substitutes resolved variable values
4. Wraps in appropriate HTTP response

```swift
// Original: <Retrieve> the <user> from the <repo> where id = <id>.
// id = 530
// Generated: Cannot retrieve the user from the repo where id = 530.
```

---

## Non-Goals

ARO explicitly does **not** provide:

- Try-catch blocks
- Error types or hierarchies
- Error propagation control
- Retry logic
- Circuit breakers
- Fallback values

These are implementation concerns. If you need them, use a different language or handle them in the runtime/framework layer.

---

## Summary

ARO's error handling philosophy is radical simplicity:

1. **Write the happy path** - Describe what should happen
2. **The code is the error** - Your statement becomes the error message
3. **Values are exposed** - Debugging over security
4. **Runtime handles the rest** - HTTP mapping, logging, responses

This isn't enterprise-grade error handling. It's error handling for humans who want to understand what went wrong, immediately, without digging through logs or decoding stack traces.

The line of code says exactly what we want to see in our logs. That is how we wrote it.

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-01 | Initial specification with traditional error handling |
| 2.0 | 2024-12 | Complete rewrite: "The Code Is The Error Message" philosophy |
