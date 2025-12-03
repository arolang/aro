# ARO-0027: OpenAPI Contract-First API Development

* Proposal: ARO-0027
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0021

## Abstract

This proposal introduces OpenAPI contract-first API development to ARO, where an `openapi.yaml` file in the application root becomes the source of truth for HTTP routing.

## Motivation

Contract-first API development offers significant advantages:

1. **Single Source of Truth**: The OpenAPI specification defines the API contract
2. **Documentation-Driven**: API is designed before implementation
3. **Type Safety**: Request/response schemas are validated
4. **Tooling Integration**: Generate clients, documentation, tests from spec
5. **Team Alignment**: Frontend and backend teams agree on contract upfront

## Proposed Solution

### Core Principle

**No contract = No server**: Without an `openapi.yaml` file, the HTTP server does NOT start and no port is opened. This enforces the contract-first approach.

---

### 1. OpenAPI Contract File

#### 1.1 Location

```
MyApp/
├── openapi.yaml          ← Required for HTTP server
├── main.aro
└── users.aro
```

Accepted filenames (in order of precedence):
- `openapi.yaml`
- `openapi.yml`
- `openapi.json`

#### 1.2 Required Structure

```yaml
openapi: 3.0.3
info:
  title: My API
  version: 1.0.0

paths:
  /users:
    get:
      operationId: listUsers    # Maps to ARO feature set name
      responses:
        '200':
          description: Success
```

**Key Requirement**: Every operation MUST have an `operationId`. This maps directly to ARO feature set names.

---

### 2. Feature Set Mapping

#### 2.1 operationId to Feature Set

Feature sets are named after OpenAPI `operationId` values:

```yaml
# openapi.yaml
paths:
  /users:
    get:
      operationId: listUsers
    post:
      operationId: createUser
  /users/{id}:
    get:
      operationId: getUser
```

```aro
(* users.aro - Feature sets match operationIds *)

(listUsers: User API) {
    <Retrieve> the <users> from the <user-repository>.
    <Return> an <OK: status> with <users>.
}

(createUser: User API) {
    <Extract> the <data> from the <request: body>.
    <Create> the <user> with <data>.
    <Return> a <Created: status> with <user>.
}

(getUser: User API) {
    <Extract> the <id> from the <pathParameters: id>.
    <Retrieve> the <user> from the <user-repository> where id = <id>.
    <Return> an <OK: status> with <user>.
}
```

#### 2.2 Validation at Startup

Missing handlers cause startup failure:

```
Error: Missing ARO feature set handlers for the following operations:
  - GET /users requires feature set named 'listUsers'
  - POST /users requires feature set named 'createUser'

Create feature sets with names matching the operationIds in your OpenAPI contract.
```

---

### 3. Path Parameters

#### 3.1 Extraction

Path parameters defined in OpenAPI are automatically extracted:

```yaml
paths:
  /users/{id}:
    parameters:
      - name: id
        in: path
        required: true
        schema:
          type: string
```

```aro
(getUser: User API) {
    <Extract> the <user-id> from the <pathParameters: id>.
    (* user-id contains the path parameter value *)
}
```

#### 3.2 Available Context

| Variable | Description |
|----------|-------------|
| `pathParameters` | Dictionary of path parameters |
| `pathParameters.{name}` | Individual parameter |
| `queryParameters` | Dictionary of query parameters |
| `request.body` | Parsed request body |
| `request.headers` | Request headers |

---

### 4. Schema Binding

#### 4.1 Request Body Typing

Request bodies are parsed according to OpenAPI schemas:

```yaml
components:
  schemas:
    CreateUserRequest:
      type: object
      properties:
        name:
          type: string
          minLength: 1
        email:
          type: string
          format: email
      required:
        - name
        - email
```

```aro
(createUser: User API) {
    <Extract> the <data> from the <request: body>.
    (* data is parsed and validated against CreateUserRequest schema *)
    (* data.name and data.email are available *)
}
```

#### 4.2 Validation

Schema validation includes:
- Required properties
- Type checking (string, number, boolean, array, object)
- Format validation (email, date-time, uuid)
- Constraints (minLength, maxLength, minimum, maximum, pattern)

---

### 5. HTTP Server Behavior

#### 5.1 With Contract

```
$ aro run ./MyApp
Loading openapi.yaml...
Validating contract against feature sets...
  ✓ listUsers -> GET /users
  ✓ createUser -> POST /users
  ✓ getUser -> GET /users/{id}
HTTP Server started on port 8080
```

#### 5.2 Without Contract

```
$ aro run ./MyApp
No openapi.yaml found - HTTP server disabled
Application running (no HTTP routes available)
```

---

### 6. Route Matching

#### 6.1 Path Patterns

| OpenAPI Path | Matches | Path Parameters |
|--------------|---------|-----------------|
| `/users` | `/users` | none |
| `/users/{id}` | `/users/123` | `{id: "123"}` |
| `/users/{id}/orders/{orderId}` | `/users/123/orders/456` | `{id: "123", orderId: "456"}` |

#### 6.2 Method Mapping

| HTTP Method | OpenAPI Field | Example operationId |
|-------------|---------------|---------------------|
| GET | `get` | `listUsers`, `getUser` |
| POST | `post` | `createUser` |
| PUT | `put` | `updateUser` |
| PATCH | `patch` | `patchUser` |
| DELETE | `delete` | `deleteUser` |

---

### 7. Complete Example

#### 7.1 openapi.yaml

```yaml
openapi: 3.0.3
info:
  title: User Service API
  version: 1.0.0

paths:
  /users:
    get:
      operationId: listUsers
      summary: List all users
      responses:
        '200':
          description: List of users
          content:
            application/json:
              schema:
                type: array
                items:
                  $ref: '#/components/schemas/User'
    post:
      operationId: createUser
      summary: Create a user
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/CreateUserRequest'
      responses:
        '201':
          description: User created
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/User'

  /users/{id}:
    parameters:
      - name: id
        in: path
        required: true
        schema:
          type: string
    get:
      operationId: getUser
      summary: Get user by ID
      responses:
        '200':
          description: User found
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/User'
        '404':
          description: User not found

components:
  schemas:
    User:
      type: object
      properties:
        id:
          type: string
        name:
          type: string
        email:
          type: string
      required:
        - id
        - name
        - email

    CreateUserRequest:
      type: object
      properties:
        name:
          type: string
        email:
          type: string
      required:
        - name
        - email
```

#### 7.2 users.aro

```aro
(* Feature sets named after operationIds *)

(listUsers: User API) {
    <Retrieve> the <users> from the <user-repository>.
    <Return> an <OK: status> with <users>.
}

(getUser: User API) {
    <Extract> the <id> from the <pathParameters: id>.
    <Retrieve> the <user> from the <user-repository> where id = <id>.

    if <user> is empty then {
        <Return> a <NotFound: status> for the <request>.
    }

    <Return> an <OK: status> with <user>.
}

(createUser: User API) {
    <Extract> the <data> from the <request: body>.
    <Create> the <user> with <data>.
    <Store> the <user> into the <user-repository>.
    <Emit> a <UserCreated: event> with <user>.
    <Return> a <Created: status> with <user>.
}
```

---

### 8. Implementation Notes

#### 8.1 Runtime Types

```swift
public struct OpenAPISpec: Sendable, Codable {
    let openapi: String
    let info: OpenAPIInfo
    let paths: [String: PathItem]
    let components: Components?
}

public struct OpenAPIRouteRegistry: Sendable {
    func match(method: String, path: String) -> RouteMatch?
}

public struct RouteMatch: Sendable {
    let operationId: String
    let pathParameters: [String: String]
    let operation: Operation
}
```

#### 8.2 Event Flow

```
HTTP Request
     ↓
[OpenAPIRouteRegistry.match()]
     ↓
[HTTPOperationEvent emitted]
     ↓
[Feature set with matching operationId executes]
     ↓
HTTP Response
```

---

## Backward Compatibility

Applications without `openapi.yaml` continue to work but cannot use HTTP server features. This is a **breaking change** for applications that relied on implicit HTTP routing.

Migration path:
1. Create `openapi.yaml` defining your routes
2. Rename feature sets from HTTP paths (`GET /users`) to operationIds (`listUsers`)
3. Update parameter extraction to use `pathParameters`

---

## Alternatives Considered

1. **Code-first routing**: Define routes in ARO, generate OpenAPI. Rejected because it defeats contract-first purpose.
2. **Annotation-based mapping**: Add annotations to feature sets. Rejected because it duplicates route definitions.
3. **Convention-based mapping**: Map feature set names to routes by convention. Rejected because it's implicit and error-prone.

---

## Implementation Location

The OpenAPI contract-first system is implemented in:

- `Sources/ARORuntime/OpenAPI/OpenAPISpec.swift` - Complete OpenAPI 3.0 data structures (`OpenAPISpec`, `PathItem`, `Operation`, `Parameter`, `Schema`, etc.)
- `Sources/ARORuntime/OpenAPI/OpenAPIRouteRegistry.swift` - Route matching with path parameter extraction (`PathPattern`, `RouteMatch`)
- `Sources/ARORuntime/OpenAPI/OpenAPILoader.swift` - YAML/JSON loading using Yams library
- `Sources/ARORuntime/OpenAPI/OpenAPIHTTPHandler.swift` - HTTP request handling via `HTTPOperationEvent`
- `Sources/ARORuntime/OpenAPI/ContractValidator.swift` - Validates operationIds match feature set names
- `Sources/ARORuntime/OpenAPI/SchemaBinding.swift` - Binds request body to context using OpenAPI schemas

Examples:
- `Examples/HelloWorldAPI/` - Simple Hello World API with contract
- `Examples/UserService/` - Full CRUD user service

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-01 | Initial specification |
| 1.1 | 2024-12 | Implemented with full OpenAPI 3.0 support |
