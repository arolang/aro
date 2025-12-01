# ARO-0010: Annotations and Metadata

* Proposal: ARO-0010
* Author: ARO Language Team
* Status: **Draft**
* Requires: ARO-0001

## Abstract

This proposal introduces annotations (metadata) to ARO, enabling declarative configuration, documentation, and compile-time processing.

## Motivation

Annotations provide:

1. **Documentation**: Attach docs to declarations
2. **Configuration**: Route mapping, validation rules
3. **Code Generation**: Hints for generators
4. **Tooling**: IDE support, linting

## Proposed Solution

A flexible annotation system with built-in and custom annotations.

---

### 1. Annotation Syntax

#### 1.1 Basic Syntax

```ebnf
annotation = "@" , annotation_name , [ annotation_args ] ;

annotation_name = identifier ;

annotation_args = "(" , [ arg_list ] , ")" ;

arg_list = annotation_arg , { "," , annotation_arg } ;

annotation_arg = [ identifier , ":" ] , expression ;
```

#### 1.2 Placement

Annotations can precede:

- Feature sets
- Statements
- Type definitions
- Fields
- Actions

---

### 2. Documentation Annotations

#### 2.1 @doc

```
@doc("Authenticates a user and returns a session token")
@doc(
    summary: "User authentication",
    description: "Validates credentials and creates a session",
    since: "1.0.0",
    deprecated: false
)
(User Authentication: Security) {
    // ...
}
```

#### 2.2 @param and @returns

```
@doc("Creates a new user account")
@param("email", "User's email address")
@param("password", "User's password (min 8 characters)")
@returns("The created user object")
(Create User: Registration) {
    // ...
}
```

#### 2.3 @example

```
@example("""
    Request:
    POST /users
    { "email": "user@example.com", "password": "secret123" }
    
    Response:
    { "id": "123", "email": "user@example.com" }
""")
(Create User: Registration) {
    // ...
}
```

#### 2.4 @see

```
@see(UpdateUser, DeleteUser)
@see("https://docs.example.com/users")
(Create User: Registration) {
    // ...
}
```

---

### 3. Validation Annotations

#### 3.1 @validate

```
(Create User: Registration) {
    @validate(notEmpty, message: "Email is required")
    @validate(email, message: "Invalid email format")
    <Extract> the <email: String> from the <request: body>.
    
    @validate(minLength: 8, message: "Password too short")
    @validate(pattern: "^(?=.*[A-Z])(?=.*[0-9])", message: "Must contain uppercase and number")
    <Extract> the <password: String> from the <request: body>.
}
```

#### 3.2 Built-in Validators

| Validator | Description |
|-----------|-------------|
| `notEmpty` | Not null/empty |
| `notNull` | Not null |
| `email` | Valid email format |
| `url` | Valid URL |
| `minLength(n)` | Minimum string length |
| `maxLength(n)` | Maximum string length |
| `min(n)` | Minimum numeric value |
| `max(n)` | Maximum numeric value |
| `range(min, max)` | Numeric range |
| `pattern(regex)` | Regex match |
| `oneOf(values)` | One of allowed values |
| `custom(fn)` | Custom validator function |

---

### 4. HTTP/API Annotations

#### 4.1 @route

```
@route("POST", "/api/v1/users")
@route(method: "POST", path: "/users", version: "v1")
(Create User: Registration) {
    // ...
}
```

#### 4.2 @middleware

```
@middleware(authenticate)
@middleware(rateLimit: 100, per: "minute")
@middleware(cors: ["https://example.com"])
(Protected Resource: API) {
    // ...
}
```

#### 4.3 @response

```
@response(200, UserResponse, "Success")
@response(400, ErrorResponse, "Validation error")
@response(401, ErrorResponse, "Unauthorized")
@response(500, ErrorResponse, "Server error")
(Get User: API) {
    // ...
}
```

#### 4.4 @header

```
(API Request: Integration) {
    @header("Authorization", required: true)
    @header("X-Request-ID", required: false)
    <Extract> the <headers> from the <request>.
}
```

---

### 5. Lifecycle Annotations

#### 5.1 @async

```
@async
(Long Running Task: Background) {
    // Executes asynchronously
}
```

#### 5.2 @timeout

```
@timeout(seconds: 30)
@timeout(30, onTimeout: TimeoutError)
(External API Call: Integration) {
    <Call> the <external-service>.
}
```

#### 5.3 @retry

```
@retry(attempts: 3, delay: 1000, backoff: "exponential")
@retry(3, on: [NetworkError, TimeoutError])
(Unreliable Service: Integration) {
    <Call> the <flaky-service>.
}
```

#### 5.4 @transaction

```
@transaction(isolation: "serializable")
@transaction(rollbackOn: [PaymentError])
(Transfer Funds: Banking) {
    <Debit> the <amount> from the <source-account>.
    <Credit> the <amount> to the <target-account>.
}
```

---

### 6. Testing Annotations

#### 6.1 @test

```
@test
@test(name: "should authenticate valid user")
(Test Valid Login: Testing) {
    <Given> the <user> with { email: "test@example.com", password: "password123" }.
    <When> the <login> is attempted.
    <Then> the <response> should be <OK>.
}
```

#### 6.2 @mock

```
@test
(Test With Mocks: Testing) {
    @mock(UserRepository, returns: [testUser])
    <Retrieve> the <users> from the <user-repository>.
    
    @mock(EmailService, throws: NetworkError)
    <Send> the <email> via the <email-service>.
}
```

#### 6.3 @skip and @only

```
@skip("Not implemented yet")
@skip(when: platform is "windows")
(Skipped Test: Testing) { }

@only  // Run only this test
(Focused Test: Testing) { }
```

---

### 7. Deprecation and Migration

#### 7.1 @deprecated

```
@deprecated("Use CreateUserV2 instead")
@deprecated(since: "2.0.0", removal: "3.0.0", replacement: "CreateUserV2")
(Create User: Registration) {
    // ...
}
```

#### 7.2 @experimental

```
@experimental("This API may change without notice")
(New Feature: Beta) {
    // ...
}
```

#### 7.3 @available

```
@available(ios: "14.0", macos: "11.0")
@available(swift: "5.5")
(Platform Specific: Features) {
    // ...
}
```

---

### 8. Security Annotations

#### 8.1 @auth

```
@auth(required: true)
@auth(roles: ["admin", "editor"])
@auth(permissions: ["users:read", "users:write"])
(Manage Users: Admin) {
    // ...
}
```

#### 8.2 @rateLimit

```
@rateLimit(requests: 100, per: "hour")
@rateLimit(100, window: 3600, key: "ip")
(Public API: Access) {
    // ...
}
```

#### 8.3 @audit

```
@audit(action: "USER_CREATED", level: "info")
@audit(log: true, sensitive: ["password", "ssn"])
(Create User: Registration) {
    // ...
}
```

---

### 9. Code Generation Annotations

#### 9.1 @generate

```
@generate(swift: true, kotlin: true, typescript: true)
@generate(client: true, server: true)
(API Endpoint: Public) {
    // ...
}
```

#### 9.2 @name

```
@name(swift: "createUser", kotlin: "createUser", rest: "POST /users")
(Create User: Registration) {
    // ...
}
```

#### 9.3 @inline

```
@inline  // Generate inline code instead of function call
(Simple Operation: Optimization) {
    // ...
}
```

---

### 10. Custom Annotations

#### 10.1 Definition

```
annotation @cached(
    ttl: Duration = 60.seconds,
    key: String? = null,
    invalidateOn: List<String> = []
)
```

#### 10.2 Usage

```
@cached(ttl: 5.minutes, key: "user-${id}")
@cached(invalidateOn: ["UpdateUser", "DeleteUser"])
(Get User: Caching) {
    <Retrieve> the <user> from the <database>.
}
```

#### 10.3 Processing

```swift
// In Swift code generator
func processAnnotation(_ annotation: Annotation, on: ASTNode) {
    switch annotation.name {
    case "cached":
        let ttl = annotation.arg("ttl") ?? 60
        let key = annotation.arg("key")
        // Generate caching wrapper
    default:
        break
    }
}
```

---

### 11. Complete Grammar Extension

```ebnf
(* Annotation Grammar *)

annotation_list = { annotation } ;

annotation = "@" , identifier , [ "(" , arg_list , ")" ] ;

arg_list = annotation_arg , { "," , annotation_arg } ;

annotation_arg = [ identifier , ":" ] , expression ;

(* Annotated Declarations *)
annotated_feature_set = annotation_list , feature_set ;

annotated_statement = annotation_list , statement ;

annotated_type = annotation_list , type_definition ;

annotated_field = annotation_list , field_definition ;

(* Custom Annotation Definition *)
annotation_definition = "annotation" , "@" , identifier ,
                        [ "(" , annotation_params , ")" ] ;

annotation_params = annotation_param , { "," , annotation_param } ;

annotation_param = identifier , ":" , type_annotation , 
                   [ "=" , expression ] ;
```

---

### 12. Complete Example

```
// Full-featured API endpoint with annotations

@doc(
    summary: "Create a new user account",
    description: """
        Creates a new user with the provided email and password.
        Sends a verification email upon successful creation.
    """,
    since: "1.0.0"
)
@route("POST", "/api/v1/users")
@auth(required: false)
@rateLimit(requests: 10, per: "minute", key: "ip")
@response(201, UserResponse, "User created successfully")
@response(400, ValidationError, "Invalid input")
@response(409, ConflictError, "Email already exists")
@transaction
@audit(action: "USER_CREATED")
public (Create User: Registration) {
    
    @validate(notEmpty, email)
    @doc("User's email address")
    <Extract> the <email: String> from the <request: body>.
    
    @validate(minLength: 8)
    @validate(pattern: "^(?=.*[A-Z])(?=.*[0-9])")
    @doc("User's password")
    <Extract> the <password: String> from the <request: body>.
    
    // Check for existing user
    @cached(ttl: 1.minute, key: "email-exists-${email}")
    <Retrieve> the <existing: User?> from the <user-repository>
        with { email: <email> }.
    
    if <existing> exists then {
        <Throw> a <ConflictError> with { 
            message: "Email already registered" 
        } for the <request>.
    }
    
    // Create user
    <Compute> the <password-hash: String> from hash(<password>).
    
    <Create> the <user: User> with {
        email: <email>,
        passwordHash: <password-hash>,
        status: "pending",
        createdAt: now()
    }.
    
    @retry(attempts: 3)
    <Store> the <user> in the <user-repository>.
    
    // Send verification email
    @async
    @timeout(seconds: 10)
    <Send> the <verification-email> to the <user: email>.
    
    <Return> a <Created: response> with <user>.
}

// Test
@test("should create user with valid input")
(Test Create User: Testing) {
    @mock(UserRepository, findByEmail: null)
    @mock(EmailService, send: true)
    
    <Given> the <request> with {
        body: { email: "new@example.com", password: "Password123" }
    }.
    
    <When> the <Create User> is executed.
    
    <Then> the <response: status> should be 201.
    <Then> the <response: body>.email should be "new@example.com".
}
```

---

## Implementation Notes

### Annotation Processing

```swift
public struct Annotation: Sendable {
    public let name: String
    public let arguments: [String: Any]
    public let span: SourceSpan
    
    public func arg<T>(_ name: String) -> T? {
        arguments[name] as? T
    }
    
    public func arg<T>(_ name: String, default: T) -> T {
        (arguments[name] as? T) ?? default
    }
}

public protocol AnnotationProcessor {
    var supportedAnnotations: Set<String> { get }
    
    func process(_ annotation: Annotation, on node: ASTNode) throws
}
```

### Built-in Processors

| Processor | Handles |
|-----------|---------|
| ValidationProcessor | @validate |
| RouteProcessor | @route, @middleware |
| DocProcessor | @doc, @param, @returns |
| LifecycleProcessor | @async, @timeout, @retry |
| TestProcessor | @test, @mock, @skip |

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-01 | Initial specification |
