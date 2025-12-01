# ARO-0008: Error Handling

* Proposal: ARO-0008
* Author: ARO Language Team
* Status: **Draft**
* Requires: ARO-0001, ARO-0004, ARO-0006

## Abstract

This proposal introduces structured error handling to ARO, enabling robust specifications that gracefully handle failures.

## Motivation

Real-world systems must handle:

1. **Expected failures**: User not found, validation errors
2. **Unexpected errors**: Network failures, timeouts
3. **Recovery**: Retry logic, fallbacks
4. **Propagation**: Bubbling errors up the call chain

## Proposed Solution

A comprehensive error handling system with:

1. **Error types**: Typed error definitions
2. **Throw/Catch**: Try-catch blocks
3. **Result types**: Success/failure unions
4. **Guard clauses**: Early exit on errors

---

### 1. Error Types

#### 1.1 Error Definition

```ebnf
error_definition = "error" , error_name , [ ":" , parent_error ] ,
                   "{" , { error_field } , "}" ;

error_field = identifier , ":" , type_annotation , ";" ;
```

**Example:**
```
error AppError {
    code: String;
    message: String;
    timestamp: DateTime;
}

error AuthError: AppError {
    userId: String?;
    attemptCount: Int;
}

error NotFoundError: AppError {
    resourceType: String;
    resourceId: String;
}

error ValidationError: AppError {
    field: String;
    constraint: String;
    providedValue: Any;
}
```

#### 1.2 Error Hierarchy

```
Error (built-in)
├── AppError
│   ├── AuthError
│   │   ├── UnauthorizedError
│   │   └── ForbiddenError
│   ├── NotFoundError
│   └── ValidationError
└── SystemError
    ├── NetworkError
    ├── TimeoutError
    └── DatabaseError
```

---

### 2. Throwing Errors

#### 2.1 Throw Statement

```ebnf
throw_statement = "<Throw>" , [ "a" | "an" ] , 
                  "<" , error_expression , ">" ,
                  "for" , "<" , context , ">" , "." ;

error_expression = error_name , [ error_initializer ] ;
error_initializer = "with" , ( inline_object | variable_reference ) ;
```

#### 2.2 Examples

```
// Simple throw
<Throw> a <NotFoundError> for the <user-id>.

// With inline data
<Throw> a <ValidationError> with {
    field: "email",
    constraint: "format",
    providedValue: <email>
} for the <request>.

// With error variable
<Create> the <e: AuthError> with {
    message: "Invalid credentials",
    userId: <user-id>,
    attemptCount: <attempts>
}.
<Throw> the <e> for the <login-request>.
```

---

### 3. Try-Catch Blocks

#### 3.1 Syntax

```ebnf
try_catch = "try" , block ,
            { catch_clause } ,
            [ finally_clause ] ;

catch_clause = "catch" , "<" , error_pattern , ">" , 
               [ "as" , identifier ] , block ;

error_pattern = error_name | "_" ;

finally_clause = "finally" , block ;
```

#### 3.2 Examples

##### Basic Try-Catch

```
try {
    <Retrieve> the <user> from the <database>.
    <Process> the <data> for the <user>.
} catch <NotFoundError> as <e> {
    <Log> the <e: message> for the <monitoring>.
    <Return> a <404: response> for the <request>.
} catch <DatabaseError> as <e> {
    <Log> the <e> for the <error-tracking>.
    <Return> a <503: response> for the <request>.
}
```

##### With Finally

```
try {
    <Open> the <connection> to the <database>.
    <Execute> the <query> on the <connection>.
} catch <_> as <e> {
    <Log> the <e> for the <monitoring>.
    <Throw> the <e> for the <caller>.
} finally {
    <Close> the <connection>.
}
```

##### Catch Multiple Types

```
try {
    <Process> the <payment> for the <order>.
} catch <PaymentDeclinedError> {
    <Notify> the <user> about the <declined-payment>.
    <Return> a <PaymentFailed> for the <request>.
} catch <InsufficientFundsError> {
    <Suggest> the <alternative-payments> to the <user>.
    <Return> a <PaymentFailed> for the <request>.
} catch <PaymentError> as <e> {
    // Catches all other PaymentError subtypes
    <Log> the <e> for the <payment-monitoring>.
    <Throw> the <e> for the <caller>.
}
```

---

### 4. Result Types

#### 4.1 Built-in Result Type

```
enum Result<T, E: Error> {
    Success(value: T),
    Failure(error: E)
}
```

#### 4.2 Using Results

```
(Safe Division: Math) {
    <Compute> the <r: Result<Float, MathError>> from 
        if <divisor> == 0 then 
            Result.Failure(DivisionByZeroError) 
        else 
            Result.Success(<dividend> / <divisor>).
    
    match <r> {
        case <Success: s> {
            <Return> the <s>.value for the <operation>.
        }
        case <Failure: f> {
            <Log> the <f>.error for the <diagnostics>.
            <Return> a <default-value> for the <operation>.
        }
    }
}
```

#### 4.3 Result Chaining

```
<Retrieve> the <user: Result<User, DbError>> from the <database>.
<Transform> the <profile: Result<Profile, Error>> from 
    <user>.map(<u> => <u>.profile).
<Return> the <profile>.unwrapOr(<default-profile>) for the <request>.
```

---

### 5. Optional and Error Handling

#### 5.1 Try Expression

Convert throwing to optional:

```ebnf
try_expression = "try?" , expression ;
```

**Example:**
```
// Returns Optional<User> instead of throwing
<Compute> the <user: User?> from try? <repository>.find(<id>).

if <user> exists then {
    <Process> the <user>.
} else {
    <Return> a <NotFound> for the <request>.
}
```

#### 5.2 Force Try

Assert success or crash:

```ebnf
force_try = "try!" , expression ;
```

**Example:**
```
// Crashes if error occurs (use only when certain)
<Compute> the <config: Config> from try! <load-config>().
```

---

### 6. Guard Statements

#### 6.1 Guard-Else

Early exit if condition fails:

```ebnf
guard_statement = "guard" , condition , "else" , block ;
```

**Example:**
```
(Validate User: Security) {
    guard <user> exists else {
        <Throw> a <NotFoundError> for the <user-id>.
    }
    
    guard <user>.isActive else {
        <Throw> a <InactiveUserError> for the <user>.
    }
    
    guard <user>.hasPermission(<required-permission>) else {
        <Throw> a <ForbiddenError> for the <user>.
    }
    
    // All guards passed, user is valid
    <Process> the <request> for the <user>.
}
```

#### 6.2 Guard with Binding

```
guard <Retrieve> the <user> from <repository> else {
    <Return> a <NotFound> for the <request>.
}
// user is now available and non-optional
```

---

### 7. Error Propagation

#### 7.1 Implicit Propagation

Errors propagate automatically if not caught:

```
(Feature A: Example) {
    <Call> the <Feature-B>.  // If B throws, it propagates
}

(Feature B: Example) {
    <Throw> an <Error> for the <something>.  // Propagates to A
}
```

#### 7.2 Explicit Rethrow

```
try {
    <Process> the <data>.
} catch <ValidationError> as <e> {
    <Log> the <e> for the <monitoring>.
    <Throw> the <e> for the <caller>.  // Rethrow
}
```

#### 7.3 Error Wrapping

```
try {
    <Call> the <external-service>.
} catch <HttpError> as <e> {
    <Throw> a <ServiceError> with {
        message: "External service failed",
        cause: <e>
    } for the <caller>.
}
```

---

### 8. Defer Statement

Execute cleanup regardless of errors:

```ebnf
defer_statement = "defer" , block ;
```

**Example:**
```
(File Processing: IO) {
    <Open> the <file> at <path>.
    
    defer {
        <Close> the <file>.
    }
    
    <Read> the <contents> from the <file>.
    <Process> the <contents>.
    
    // File is closed even if Process throws
}
```

---

### 9. Assertions

#### 9.1 Assert Statement

```ebnf
assert_statement = "assert" , condition , 
                   [ ":" , string_literal ] , "." ;
```

**Example:**
```
assert <count> >= 0 : "Count must be non-negative".
assert <user> exists : "User required".
```

#### 9.2 Preconditions

```
(Transfer Funds: Banking) {
    precondition <amount> > 0 : "Amount must be positive".
    precondition <from-account> != <to-account> : "Cannot transfer to same account".
    
    <Debit> the <amount> from the <from-account>.
    <Credit> the <amount> to the <to-account>.
}
```

---

### 10. Complete Grammar Extension

```ebnf
(* Error Handling Grammar *)

(* Error Definition *)
error_definition = "error" , identifier , 
                   [ ":" , identifier ] ,
                   "{" , { field_def } , "}" ;

(* Statements *)
statement += throw_statement
           | try_catch
           | guard_statement
           | defer_statement
           | assert_statement ;

(* Throw *)
throw_statement = "<Throw>" , [ article ] , 
                  "<" , error_expr , ">" ,
                  "for" , variable_reference , "." ;

error_expr = identifier , [ "with" , ( inline_object | variable_reference ) ] ;

(* Try-Catch *)
try_catch = "try" , block ,
            { catch_clause } ,
            [ finally_clause ] ;

catch_clause = "catch" , "<" , ( identifier | "_" ) , ">" ,
               [ "as" , identifier ] , block ;

finally_clause = "finally" , block ;

(* Guard *)
guard_statement = "guard" , condition , "else" , block ;

(* Defer *)
defer_statement = "defer" , block ;

(* Assert *)
assert_statement = ( "assert" | "precondition" ) , condition ,
                   [ ":" , string_literal ] , "." ;

(* Expressions *)
expression += try_expression ;
try_expression = ( "try?" | "try!" ) , expression ;

(* Result Type Operations *)
result_operation = variable_reference , "." , 
                   ( "map" | "flatMap" | "mapError" | 
                     "unwrap" | "unwrapOr" ) ,
                   "(" , expression , ")" ;
```

---

### 11. Complete Examples

#### Comprehensive Error Handling

```
// Error definitions
error PaymentError {
    orderId: String;
    message: String;
}

error PaymentDeclinedError: PaymentError {
    declineCode: String;
}

error InsufficientFundsError: PaymentError {
    available: Float;
    required: Float;
}

// Feature with full error handling
(Process Payment: E-Commerce) {
    <Require> <order: Order> from context.
    <Require> <payment-gateway: PaymentGateway> from framework.
    
    // Preconditions
    precondition <order>.total > 0 : "Order total must be positive".
    precondition <order>.paymentMethod exists : "Payment method required".
    
    // Guard clauses
    guard <order>.status is "pending" else {
        <Throw> an <InvalidOrderStateError> with {
            orderId: <order>.id,
            currentState: <order>.status
        } for the <order>.
    }
    
    <Set> the <attempts> to 0.
    <Set> the <max-attempts> to 3.
    
    // Retry loop with error handling
    while <attempts> < <max-attempts> {
        <Increment> the <attempts>.
        
        try {
            <Charge> the <r: PaymentResult> 
                from <payment-gateway> for the <order>.
            
            if <r>.success then {
                <Update> the <order>.status to "paid".
                <Create> the <receipt> for the <order>.
                <Return> the <receipt> for the <request>.
            }
            
        } catch <InsufficientFundsError> as <e> {
            // Don't retry, notify user
            <Notify> the <order>.customer about {
                message: "Insufficient funds",
                available: <e>.available,
                required: <e>.required
            }.
            <Return> a <PaymentFailed: response> for the <request>.
            
        } catch <PaymentDeclinedError> as <e> {
            // Might be temporary, retry
            <Log> the <e> for the <payment-monitoring>.
            
            if <attempts> >= <max-attempts> then {
                <Throw> the <e> for the <caller>.
            }
            
            <Wait> for 1000.  // 1 second
            <Continue>.
            
        } catch <PaymentError> as <e> {
            // Generic payment error
            <Log> the <e> for the <error-tracking>.
            <Throw> the <e> for the <caller>.
            
        } catch <_> as <e> {
            // Unexpected error
            <Log> the <e> for the <critical-errors>.
            <Throw> a <SystemError> with {
                message: "Unexpected payment error",
                cause: <e>
            } for the <caller>.
        }
    }
    
    <Throw> a <PaymentError> with {
        orderId: <order>.id,
        message: "Payment failed after max attempts"
    } for the <caller>.
}
```

---

## Implementation Notes

### Error Representation

```swift
public protocol AROError: Error, Sendable {
    var code: String { get }
    var message: String { get }
    var cause: (any AROError)? { get }
    var context: [String: Any] { get }
}

public struct GenericError: AROError {
    public let code: String
    public let message: String
    public let cause: (any AROError)?
    public let context: [String: Any]
}
```

### Control Flow Analysis

The compiler must verify:

1. All code paths either return or throw
2. Catch clauses are reachable
3. Finally blocks don't throw
4. Guard else blocks must exit (throw/return)

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-01 | Initial specification |
