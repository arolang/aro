# Chapter 7: The Happy Path

*"Optimism is a strategy, not naivety."*

---

## 7.1 The Philosophy

ARO code expresses only the happy path—what should happen when everything works correctly. There is no try/catch mechanism, no error handling blocks, no defensive programming patterns. You write the successful case, and the runtime handles everything else.

This is not an oversight or a limitation. It is a deliberate design choice based on the observation that error handling code often obscures the business logic it surrounds. When you read traditional code, you spend significant mental effort distinguishing between the actual work and the error handling scaffolding. The happy path philosophy eliminates this noise by moving error handling entirely to the runtime.

The approach works because the structure of ARO statements provides enough information to generate meaningful error messages automatically. Every statement expresses what it intends to accomplish in business terms: extracting a user identifier from path parameters, retrieving a user from a repository, returning an OK status with data. When any of these operations fails, the runtime constructs an error message from the statement itself, describing what could not be done using the same business language.

This means that error handling is not absent—it is automated. The runtime catches every failure, logs it with appropriate context, and returns or propagates an appropriate error response. You get consistent error handling across your entire application without writing any error handling code.

---

## 7.2 How Errors Work

When an action cannot complete successfully, ARO generates an error message derived from the failed statement. The message describes the operation in business terms rather than technical ones. If a statement attempts to retrieve a user from a repository and no matching user exists, the error message says exactly that: "Cannot retrieve the user from the user-repository where id = 42."

For HTTP handlers, the runtime translates these errors into appropriate HTTP responses. A failed retrieval becomes a 404 response. A failed validation becomes a 400 response. A permission denial becomes a 403 response. The runtime infers the appropriate status code from the error context, and the response body contains a structured representation of the error including the descriptive message.

The key insight is that the error message describes what the code was trying to accomplish, not what went wrong internally. This makes error messages immediately understandable to anyone who knows the business domain. A message like "Cannot retrieve the user from the user-repository where id = 42" tells you exactly what the application was trying to do. You do not need to understand implementation details to understand the error.

The runtime also logs every error with full context: which feature set was executing, which statement failed, what values were involved, the timestamp, and a request identifier for correlation. This logging happens automatically for every failure, ensuring that debugging information is always available when you need it.

---

## 7.3 Error Message Generation

ARO constructs error messages systematically from the components of the failed statement. The message typically follows the pattern "Cannot [action] the [result] [preposition] the [object]" with any where clause or other qualifiers appended.

The action verb provides the main operation that failed. The result name identifies what was being produced or acted upon. The preposition clarifies the relationship between the action and its object. The object identifies the source, destination, or context of the operation. If the statement includes a where clause for filtering, that clause appears in the error message to help identify which specific item could not be found.

This systematic construction means that choosing good names in your code automatically produces good error messages. If you name your result "user-profile" and your repository "user-repository," the error message will say "Cannot retrieve the user-profile from the user-repository," which is immediately comprehensible. If you use names like "x" and "data," the error message becomes "Cannot retrieve the x from the data," which tells you nothing useful.

This connection between code quality and error message quality creates a positive incentive. Writing readable code with descriptive names not only helps human readers understand the code but also produces better error messages that help during debugging and troubleshooting.

### Error Message Examples

Here is ARO code followed by the runtime error messages it produces when operations fail:

**Code:**
```aro
(getUser: User API) {
    <Extract> the <id> from the <pathParameters: id>.
    <Retrieve> the <user> from the <user-repository> where id = <id>.
    <Return> an <OK: status> with <user>.
}
```

**When user ID 530 does not exist:**
```
Runtime Error: Cannot retrieve the user from the user-repository where id = 530
  Feature: getUser
  Statement: <Retrieve> the <user> from the <user-repository> where id = <id>
```

**When pathParameters does not contain id:**
```
Runtime Error: Cannot extract the id from the pathParameters
  Feature: getUser
  Statement: <Extract> the <id> from the <pathParameters: id>
  Cause: Key 'id' not found in pathParameters
```

**Another example with validation:**
```aro
(createOrder: Order API) {
    <Extract> the <data> from the <request: body>.
    <Validate> the <data> against the <order-schema>.
    <Store> the <order> in the <order-repository>.
    <Return> a <Created: status> with <order>.
}
```

**When validation fails:**
```
Runtime Error: Cannot validate the data against the order-schema
  Feature: createOrder
  Statement: <Validate> the <data> against the <order-schema>
  Cause: Validation failed
```

**When the repository is unavailable:**
```
Runtime Error: Cannot store the order in the order-repository
  Feature: createOrder
  Statement: <Store> the <order> in the <order-repository>
  Cause: Connection refused
```

The pattern is consistent: the statement's natural language structure becomes the error message, with context about which feature failed and what caused the failure.

---

## 7.4 Why This Works

The happy path philosophy reduces code dramatically. Traditional error handling often quadruples the size of a function. Every operation that might fail needs a corresponding error check. Every error check needs logging, response construction, and potentially cleanup. A simple three-step operation can become twenty or thirty lines when fully protected with error handling.

ARO's approach eliminates all of this boilerplate. A three-step operation remains three statements. The code expresses exactly what it accomplishes with no noise from error handling. Readers can understand the business logic at a glance because there is nothing else to distract them.

The approach also produces consistent error responses across the entire application. In traditional codebases, different developers write error messages differently. One might say "User not found," another "user_not_found," another "404." Status codes vary for similar errors. Some errors include stack traces, others do not. This inconsistency makes APIs harder to use and debug.

With ARO, every error follows the same format because every error is generated by the same mechanism. Clients can rely on consistent response structures. Operators can rely on consistent log formats. The application behaves predictably in all error scenarios because the runtime, not the developer, determines how errors are expressed.

Automatic logging eliminates another common failure mode. In traditional code, developers sometimes forget to log errors, especially in rarely-executed code paths. ARO logs every failure automatically with full context, ensuring that debugging information exists when you need it.

---

## 7.5 When Happy Path Hurts

The happy path philosophy is not universally applicable. Several categories of problems fit poorly with this approach.

Custom error messages are difficult when validation rules require specific feedback. If a password must contain at least eight characters, a number, and a special character, and the user's password fails all three requirements, the generic "Cannot validate the password against the password-rules" message does not tell the user how to fix the problem. Custom actions can provide more detailed error messages, but this pushes complexity out of ARO and into Swift.

Conditional error handling becomes awkward when different failures require different responses. If duplicate email and invalid email format both fail validation but require different instructions to the user, ARO cannot distinguish between them at the language level. The runtime treats all validation failures identically.

Retry logic has no direct expression in ARO because there are no loops. If an external service is temporarily unavailable and the operation should be retried with exponential backoff, that logic must be implemented in a custom action. The ARO statement sees only success or failure; it cannot express "try again."

Partial failures present a fundamental mismatch with the happy path model. If you need to send an email, update analytics, and sync with a CRM, and you want to continue even if some of these fail, ARO's approach of stopping on first failure does not work. All-or-nothing semantics are built into the model.

Graceful degradation, where an application continues with reduced functionality when some components fail, similarly does not fit. ARO assumes that every statement is required for successful completion. There is no way to mark some statements as optional or to provide fallback behavior when they fail.

---

## 7.6 Strategies for Complex Error Handling

When you need error handling that goes beyond the automatic behavior, several strategies can help.

Custom actions are the primary escape hatch. By implementing an action in Swift, you gain full access to traditional error handling patterns. You can provide detailed validation error messages, implement retry logic, handle multiple error conditions differently, and perform any other error-related processing. The ARO statement that invokes your action sees only the final result—success with a value, or failure with an error that propagates according to normal rules.

Event-based error handling allows recovery code to execute in a separate feature set. When certain errors occur, the runtime can emit events that trigger handlers. These handlers can log additional context, notify administrators, attempt compensating actions, or perform other recovery activities. The original feature set still fails, but the handlers provide an opportunity for side effects related to that failure.

The when clause provides conditional execution that can skip non-critical operations. A statement with a when clause that evaluates to false is simply not executed rather than causing an error. This is useful for optional notifications, analytics updates, or other operations that should not block the main flow if preconditions are not met.

Separating concerns into multiple feature sets can isolate failures. If you have operations that should succeed or fail independently, triggering them via events rather than executing them inline means each can complete or fail without affecting the others. Event handlers execute in their own isolated contexts.

---

## 7.7 The Happy Path Contract

When you write ARO code, you implicitly accept a contract about how error handling works. You express what should happen when inputs are valid and systems are working. The runtime handles what happens when things fail. Custom actions provide escape hatches for scenarios that require more sophisticated error handling.

This contract works well for CRUD operations, data pipelines, event handling, and straightforward API endpoints—scenarios where the success path is clear and the failure mode is essentially "it didn't work." The automatic error messages are usually sufficient because there is typically only one kind of failure: the operation could not be completed.

The contract works less well for distributed transactions where you need coordination across multiple systems, retry-heavy workflows where transient failures should be retried automatically, complex validation with many specific error cases that each require different user guidance, and real-time systems that must degrade gracefully rather than failing entirely.

Knowing when to use ARO and when to use custom actions or other approaches is part of becoming proficient with the language. The happy path philosophy is a powerful default that eliminates enormous amounts of boilerplate for common scenarios. Recognizing the scenarios where it does not fit is equally important.

---

## 7.8 Best Practices

Trust the runtime's error handling. Do not add defensive checks for conditions that the runtime already handles. If the runtime will produce an appropriate error when a required value is missing, there is no need to add a validation statement that checks for its presence. The redundant check adds code without adding value.

Use descriptive names because they become part of error messages. The quality of your variable and repository names directly affects the quality of automatically generated error messages. Names like "user-profile," "order-repository," and "email-address" produce clear, understandable error messages. Names like "x," "data," and "repo" produce error messages that tell you nothing useful.

Keep feature sets focused so that errors have clear context. When a feature set performs a single coherent operation, an error in that feature set has obvious meaning. When a feature set performs many unrelated operations, errors become harder to interpret because the context is muddied.

Design your domain model so that validation can be expressed through structure rather than explicit checks. If invalid data cannot be created in the first place because the types enforce validity, you eliminate entire categories of validation errors from your code.

---

*Next: Chapter 8 — The Event Bus*
