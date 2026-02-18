# ARO-0006: Error Philosophy

* Proposal: ARO-0006
* Author: ARO Language Team
* Status: **Implemented**

## Abstract

This proposal defines ARO's foundational approach to error handling: **the code is the error message**. Programmers write only the happy path, and the runtime automatically generates descriptive error messages derived directly from the source code.

## Introduction

ARO is designed for how project managers think about software: they describe what should happen, not what could go wrong. Edge cases, error handling, and failure modes are implementation details that ARO abstracts away.

**The fundamental principle**: Every ARO statement describes the ideal outcome. When that outcome cannot be achieved, the statement itself becomes the error message.

### Design Goals

1. **Simplicity**: Write only the successful case
2. **Clarity**: Error messages match the code exactly
3. **Transparency**: Full context in every error
4. **Automation**: No manual error handling code

### Philosophy Overview

```
+------------------------------------------------------------------+
|                  Traditional Programming                          |
|                                                                    |
|   +------------+     +---------------+     +------------------+   |
|   | Happy Path | --> | Error Checks  | --> | Error Messages   |   |
|   | (40% code) |     | (30% code)    |     | (30% code)       |   |
|   +------------+     +---------------+     +------------------+   |
|                                                                    |
|   Total: 100% code, 3 things to maintain, can get out of sync     |
+------------------------------------------------------------------+

+------------------------------------------------------------------+
|                       ARO Programming                             |
|                                                                    |
|   +----------------------------------------------------------+   |
|   |                    Happy Path Only                        |   |
|   |                     (100% code)                           |   |
|   +----------------------------------------------------------+   |
|                            |                                      |
|                            v                                      |
|   +----------------------------------------------------------+   |
|   |          Runtime-Generated Errors (automatic)             |   |
|   +----------------------------------------------------------+   |
|                                                                    |
|   Total: Your code IS your error messages                         |
+------------------------------------------------------------------+
```

---

## Happy Path Programming

In ARO, you only write the successful case:

```aro
(getUser: User API) {
    Extract the <id> from the <pathParameters: id>.
    Retrieve the <user> from the <user-repository> where id = <id>.
    Return an <OK: status> with <user>.
}
```

This code assumes:
- The path parameter exists
- The user can be found
- Everything works

There is no error handling code. No try-catch blocks. No null checks. You describe what should happen, and the runtime handles what could go wrong.

### Why This Works

Traditional error handling accounts for 40-60% of code. In ARO, it is 0%. This is not because errors do not happen - they do. It is because ARO generates error handling automatically from your statements.

The statement you write IS the error message you will see when something fails.

---

## Automatic Error Generation

When any step fails, the runtime generates an error message from the statement:

```
+------------------------------------------------------------------+
|                    Error Generation Flow                          |
|                                                                    |
|   Statement:                                                       |
|   Retrieve the <user> from the <user-repository> where id = <id>|
|                                                                    |
|                            |                                      |
|                            v (failure)                            |
|                                                                    |
|   1. Take original statement                                      |
|   2. Replace verb with "Cannot [verb]"                            |
|   3. Substitute resolved variable values                          |
|   4. Return as error message                                      |
|                                                                    |
|                            |                                      |
|                            v                                      |
|                                                                    |
|   Error:                                                           |
|   "Cannot retrieve the user from the user-repository where id=530"|
+------------------------------------------------------------------+
```

### Example Transformations

| Statement | Generated Error |
|-----------|-----------------|
| `Extract the <id> from the <pathParameters: id>.` | `Cannot extract the id from the pathParameters: id.` |
| `Retrieve the <user> from the <user-repository> where id = <id>.` | `Cannot retrieve the user from the user-repository where id = 530.` |
| `Validate the <email> for the <email-format>.` | `Cannot validate the email for the email-format.` |
| `Store the <order> in the <order-repository>.` | `Cannot store the order in the order-repository.` |

### Conditions Become Part of the Error

When a statement includes conditions, they appear in the error:

```aro
Retrieve the <order> from the <order-repository> where userId = <userId> and status = "pending".
```

Error:
```
Cannot retrieve the order from the order-repository where userId = 42 and status = "pending".
```

---

## Error Message Format

All ARO errors follow the same pattern:

```
Cannot <action> the <result> [preposition] the <object> [conditions].
```

### Format Components

| Component | Source | Example |
|-----------|--------|---------|
| Action | The verb from the statement | `retrieve`, `validate`, `store` |
| Result | The result descriptor | `user`, `email`, `order` |
| Preposition | From the statement | `from`, `for`, `in` |
| Object | The object descriptor | `user-repository`, `email-format` |
| Conditions | Where clauses with resolved values | `where id = 530` |

### Context Inclusion

Error messages include all resolved variable values:

```aro
Retrieve the <paymentMethod> from the <payment-repository> where userId = <userId> and type = <type>.
```

With `userId = 42` and `type = "credit"`:

```
Cannot retrieve the paymentMethod from the payment-repository where userId = 42 and type = "credit".
```

This makes debugging immediate - you see exactly what values caused the failure.

---

## HTTP Status Code Mapping

The runtime automatically maps errors to appropriate HTTP responses based on the action type:

```
+------------------------------------------------------------------+
|                   HTTP Status Mapping                             |
|                                                                    |
|   Action Category        HTTP Status        Meaning               |
|   +-----------------+    +------------+    +------------------+   |
|   | Extract, Parse  | -> | 400        | -> | Bad Request      |   |
|   | Read, Receive   |    |            |    | (malformed input)|   |
|   +-----------------+    +------------+    +------------------+   |
|                                                                    |
|   +-----------------+    +------------+    +------------------+   |
|   | Retrieve, Fetch | -> | 404        | -> | Not Found        |   |
|   | Get, Load       |    |            |    | (missing data)   |   |
|   +-----------------+    +------------+    +------------------+   |
|                                                                    |
|   +-----------------+    +------------+    +------------------+   |
|   | Validate        | -> | 422        | -> | Unprocessable    |   |
|   |                 |    |            |    | (invalid data)   |   |
|   +-----------------+    +------------+    +------------------+   |
|                                                                    |
|   +-----------------+    +------------+    +------------------+   |
|   | Store, Send     | -> | 500        | -> | Server Error     |   |
|   | Compute, Create |    |            |    | (system failure) |   |
|   +-----------------+    +------------+    +------------------+   |
|                                                                    |
|   +-----------------+    +------------+    +------------------+   |
|   | Throw           | -> | (custom)   | -> | As specified     |   |
|   +-----------------+    +------------+    +------------------+   |
+------------------------------------------------------------------+
```

### HTTP Response Format

All error responses follow this JSON structure:

```json
{
    "error": "Cannot retrieve the user from the user-repository where id = 530."
}
```

### Automatic Logging

All errors are automatically logged with full context:

```
[ERROR] [getUser: User API] Cannot retrieve the user from the user-repository where id = 530.
```

The feature set name, business activity, and full error message are always included.

---

## The Throw Action

For cases where you need explicit error control, ARO provides the `<Throw>` action:

```aro
(deleteUser: Admin API) {
    Extract the <id> from the <pathParameters: id>.
    Retrieve the <user> from the <user-repository> where id = <id>.

    (* Custom business rule - cannot delete admin users *)
    if <user: role> == "admin" then {
        Throw a <Forbidden: error> for the <admin-deletion>.
    }

    Delete the <user> from the <user-repository>.
    Return an <OK: status> for the <deletion>.
}
```

### Throw Syntax

```ebnf
throw_statement = "<Throw>" , [ article ] , "<" , error_descriptor , ">" ,
                  "for" , [ article ] , "<" , context , ">" , "." ;

error_descriptor = status_code , ":" , "error" ;
status_code      = "BadRequest" | "Unauthorized" | "Forbidden" | "NotFound"
                 | "Conflict" | "Unprocessable" | "InternalError" ;
```

### Status Codes

| Error Descriptor | HTTP Status | Use Case |
|------------------|-------------|----------|
| `BadRequest: error` | 400 | Malformed request |
| `Unauthorized: error` | 401 | Missing authentication |
| `Forbidden: error` | 403 | Insufficient permissions |
| `NotFound: error` | 404 | Resource does not exist |
| `Conflict: error` | 409 | State conflict |
| `Unprocessable: error` | 422 | Invalid data |
| `InternalError: error` | 500 | System failure |

### Custom Error Messages

For custom error text, use the Log action before throwing:

```aro
(updateOrder: Order API) {
    Extract the <id> from the <pathParameters: id>.
    Retrieve the <order> from the <order-repository> where id = <id>.

    if <order: status> == "shipped" then {
        Log "Cannot modify shipped orders" to the <console>.
        Throw a <Conflict: error> for the <order-modification>.
    }

    (* Continue with update... *)
}
```

---

## Security Warning

**ARO is not secure for production use.**

Error messages in ARO expose everything: variable names, values, conditions, and internal state. If you write:

```aro
Retrieve the <user> from the <user-repository> where password = <password>.
```

And this fails, the error message will be:

```
Cannot retrieve the user from the user-repository where password = "hunter2".
```

This is by design. ARO prioritizes clarity and debugging over security.

### What Gets Exposed

| Category | Exposed Information |
|----------|---------------------|
| Variable names | All identifiers from your statements |
| Variable values | Resolved values at time of failure |
| Conditions | Full where clauses with all values |
| Repository names | Data store identifiers |
| Internal state | Current values during execution |

### Intended Use Cases

ARO is designed for:
- Rapid prototyping
- Internal tools
- Learning and experimentation
- Demos and presentations
- Development environments

ARO is NOT designed for:
- Production systems
- Public-facing APIs
- Systems handling sensitive data
- Security-critical applications

---

## Examples

### User Registration

```aro
(registerUser: User API) {
    Extract the <data> from the <request: body>.
    Validate the <data: email> for the <email-format>.
    Validate the <data: password> for the <password-strength>.
    Create the <user> with <data>.
    Store the <user> in the <user-repository>.
    Return a <Created: status> with <user>.
}
```

**Possible errors:**
- `Cannot extract the data from the request: body.`
- `Cannot validate the data: email for the email-format.`
- `Cannot validate the data: password for the password-strength.`
- `Cannot create the user with { email: "bad", password: "123" }.`
- `Cannot store the user in the user-repository.`

### Traditional vs ARO Error Handling

**Traditional approach (pseudocode):**
```
function getUser(id):
    if id is null:
        throw BadRequestError("User ID is required")
    if id is not a number:
        throw BadRequestError("User ID must be a number")

    user = repository.find(id)

    if user is null:
        throw NotFoundError("User with ID " + id + " not found")

    return user
```

**ARO approach:**
```aro
(getUser: User API) {
    Extract the <id> from the <pathParameters: id>.
    Retrieve the <user> from the <user-repository> where id = <id>.
    Return an <OK: status> with <user>.
}
```

Same result. Less code. Perfect error messages.

### Payment Processing

```aro
(processPayment: Checkout) {
    Retrieve the <order> from the <order-repository> where id = <orderId>.
    Retrieve the <paymentMethod> from the <payment-repository> where userId = <userId>.
    <Charge> the <amount> to the <paymentMethod>.
    Update the <order: status> to "paid".
    Return an <OK: status> with <receipt>.
}
```

**Possible errors:**
- `Cannot retrieve the order from the order-repository where id = 12345.`
- `Cannot retrieve the paymentMethod from the payment-repository where userId = 67.`
- `Cannot charge the amount to the paymentMethod.`
- `Cannot update the order: status to "paid".`

---

## Non-Goals

ARO explicitly does **not** provide:

| Feature | Reason |
|---------|--------|
| Try-catch blocks | Automatic error handling makes them unnecessary |
| Error types or hierarchies | The statement IS the error type |
| Error propagation control | Errors stop execution immediately |
| Retry logic | Implementation concern for runtime layer |
| Circuit breakers | Infrastructure concern |
| Fallback values | Explicit handling required if needed |

These are implementation concerns. If you need them, handle them in the runtime/framework layer.

---

## Summary

ARO's error handling philosophy is radical simplicity:

```
+------------------------------------------------------------------+
|                   The Four Principles                             |
|                                                                    |
|   1. Write the happy path                                         |
|      - Describe what should happen                                |
|      - No error handling code                                     |
|                                                                    |
|   2. The code is the error                                        |
|      - Your statement becomes the error message                   |
|      - Perfect accuracy guaranteed                                |
|                                                                    |
|   3. Values are exposed                                           |
|      - Full debugging context                                     |
|      - Not suitable for production                                |
|                                                                    |
|   4. Runtime handles the rest                                     |
|      - HTTP status mapping                                        |
|      - Automatic logging                                          |
|      - JSON response formatting                                   |
+------------------------------------------------------------------+
```

This is not enterprise-grade error handling. It is error handling for humans who want to understand what went wrong, immediately, without digging through logs or decoding stack traces.

The line of code says exactly what you will see in your logs. That is how you wrote it.
