# ARO-0003: Type System

* Proposal: ARO-0003
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0002

## Abstract

This proposal defines ARO's type system, which follows a minimalist philosophy: simple built-in primitives, collection types, and all complex types defined externally in OpenAPI specifications. ARO embraces a "no optionals" approach where values either exist or operations fail with descriptive error messages.

## Introduction

ARO's type system is designed around three core principles:

1. **Simplicity**: Four primitive types and two collection types cover most needs
2. **External Definitions**: Complex types come from OpenAPI, not from ARO code
3. **Fail Fast**: No null checks or optional handling; errors are immediate and descriptive

```
+--------------------------------------------------+
|                   ARO Type System                |
+--------------------------------------------------+
|                                                  |
|   Built-in Types         External Types          |
|   +--------------+       +------------------+    |
|   | String       |       | openapi.yaml     |    |
|   | Integer      |       |   components:    |    |
|   | Float        |       |     schemas:     |    |
|   | Boolean      |       |       User       |    |
|   +--------------+       |       Order      |    |
|                          |       Product    |    |
|   +--------------+       +------------------+    |
|   | List<T>      |              |                |
|   | Map<K,V>     |              v                |
|   +--------------+       Available in ARO        |
|                          at runtime              |
+--------------------------------------------------+
```

---

## Primitive Types

ARO provides four built-in primitive types:

| Type | Description | Literal Examples |
|------|-------------|-----------------|
| `String` | Text values | `"hello"`, `'world'` |
| `Integer` | Whole numbers | `42`, `-17`, `0xFF` |
| `Float` | Decimal numbers | `3.14`, `2.5e10` |
| `Boolean` | True/False | `true`, `false` |

### Examples

```aro
(Primitives Demo: Type System) {
    Create the <name> with "Alice".           // name: String
    Create the <age> with 30.                  // age: Integer
    Create the <price> with 19.99.             // price: Float
    Create the <active> with true.             // active: Boolean

    Log "Name and age created" to the <console>.
    Return an <OK: status> for the <demo>.
}
```

---

## Collection Types

ARO provides two generic collection types:

| Type | Description | Literal Examples |
|------|-------------|-----------------|
| `List<T>` | Ordered collection | `[1, 2, 3]`, `["a", "b"]` |
| `Map<K,V>` | Key-value pairs | `{ name: "Alice", age: 30 }` |

### Type Inference for Collections

```aro
(Collections Demo: Type System) {
    Create the <numbers> with [1, 2, 3].                 // List<Integer>
    Create the <names> with ["Alice", "Bob"].            // List<String>
    Create the <config> with { port: 8080, host: "localhost" }.  // Map<String, Any>

    Return an <OK: status> for the <collections>.
}
```

---

## OpenAPI as Type Source

All complex types (records, enums, nested structures) are defined in `openapi.yaml`, not in ARO code. This applies whether or not your application has HTTP routes.

```
+------------------+      +------------------+      +------------------+
|                  |      |                  |      |                  |
|  openapi.yaml    | ---> |   ARO Runtime    | ---> |   Type-Safe      |
|  components:     |      |   Schema Loader  |      |   Variables      |
|    schemas:      |      |                  |      |                  |
|      User        |      |                  |      |   <user: User>   |
|      Order       |      |                  |      |   <order: Order> |
|                  |      |                  |      |                  |
+------------------+      +------------------+      +------------------+
```

### Defining Types in OpenAPI

```yaml
# openapi.yaml
openapi: 3.0.3
info:
  title: My Application
  version: 1.0.0

# paths: {} - Optional! No routes = no HTTP server, but types still available

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
        status:
          $ref: '#/components/schemas/UserStatus'
      required:
        - id
        - name
        - email

    UserStatus:
      type: string
      enum:
        - active
        - inactive
        - suspended

    Address:
      type: object
      properties:
        street:
          type: string
        city:
          type: string
        country:
          type: string
          default: "Germany"
      required:
        - street
        - city
```

### Using OpenAPI Types in ARO

```aro
(Create User: User Management) {
    Extract the <data> from the <request: body>.

    (* User type comes from openapi.yaml components/schemas/User *)
    Create the <user: User> with <data>.

    (* Access fields defined in the schema *)
    Log "Created user" to the <console>.

    Return a <Created: status> with <user>.
}
```

### OpenAPI Behavior Summary

| openapi.yaml | paths | components | HTTP Server | Types Available |
|--------------|-------|------------|-------------|-----------------|
| Missing | - | - | No | Primitives only |
| Present | Empty/None | Has schemas | No | Primitives + Schemas |
| Present | Has routes | Has schemas | Yes | Primitives + Schemas |

---

## Contract-First API Development

ARO uses a contract-first approach: the OpenAPI specification defines HTTP routes, and feature sets are named after `operationId` values.

### Core Principle

**No contract = No server**: Without an `openapi.yaml` file, the HTTP server does NOT start and no port is opened.

### Application Structure

```
MyApp/
+-- openapi.yaml          <-- Required for HTTP server
+-- main.aro              <-- Contains Application-Start
+-- users.aro             <-- Feature sets named after operationIds
+-- events.aro            <-- Event handlers
```

### operationId to Feature Set Mapping

```yaml
# openapi.yaml
paths:
  /users:
    get:
      operationId: listUsers     # -> ARO feature set "listUsers"
    post:
      operationId: createUser    # -> ARO feature set "createUser"
  /users/{id}:
    get:
      operationId: getUser       # -> ARO feature set "getUser"
```

```aro
(* Feature sets named after operationIds *)

(listUsers: User API) {
    Retrieve the <users> from the <user-repository>.
    Return an <OK: status> with <users>.
}

(createUser: User API) {
    Extract the <data> from the <request: body>.
    Create the <user> with <data>.
    Emit a <UserCreated: event> with <user>.
    Return a <Created: status> with <user>.
}

(getUser: User API) {
    Extract the <id> from the <pathParameters: id>.
    Retrieve the <user> from the <user-repository> where id = <id>.
    Return an <OK: status> with <user>.
}
```

### Path Parameters

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
    Extract the <user-id> from the <pathParameters: id>.
    (* user-id contains the path parameter value *)
}
```

### Available Context Variables

| Variable | Description |
|----------|-------------|
| `pathParameters` | Dictionary of path parameters |
| `pathParameters.{name}` | Individual parameter |
| `queryParameters` | Dictionary of query parameters |
| `request.body` | Parsed request body |
| `request.headers` | Request headers |

### Request Body Typing

Request bodies are parsed and validated according to OpenAPI schemas:

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

Validation includes:
- Required properties
- Type checking (string, number, boolean, array, object)
- Format validation (email, date-time, uuid)
- Constraints (minLength, maxLength, minimum, maximum, pattern)

### Startup Validation

Missing handlers cause startup failure:

```
Error: Missing ARO feature set handlers for the following operations:
  - GET /users requires feature set named 'listUsers'
  - POST /users requires feature set named 'createUser'

Create feature sets with names matching the operationIds in your OpenAPI contract.
```

---

## Type Annotations

ARO supports two syntaxes for explicit type annotations.

### Colon Syntax

```aro
<name: String>                    // Primitive
<count: Integer>                  // Primitive
<items: List<String>>             // Collection of primitives
<user: User>                      // OpenAPI schema reference
<users: List<User>>               // Collection of OpenAPI types
<config: Map<String, Integer>>    // Map with primitives
```

### The `as` Syntax

For clarity, especially when disambiguating from qualifier syntax, use `as`:

```aro
(* Using 'as' for type annotations *)
Filter the <active-users> as List<User> from the <users> where <active> is true.
Reduce the <total> as Float from the <orders> with sum(<amount>).
Map the <names> as List<String> from the <users: name>.
```

### When to Use Type Annotations

Type annotations are **optional** because ARO infers types from context:

```aro
(* Types are inferred - no annotation needed *)
Create the <count> with 42.              // count: Integer
Create the <name> with "John".           // name: String
Create the <active> with true.           // active: Boolean
Create the <items> with [1, 2, 3].       // items: List<Integer>
```

Use explicit annotations when:

1. **Specifying numeric precision**: `<total> as Float` when you need decimals
2. **Documentation**: Making types explicit for readability
3. **Overriding inference**: When the default type is not what you need

### Grammar

```ebnf
(* Colon syntax *)
typed_variable = "<" , identifier , ":" , type_annotation , ">" ;

(* As syntax *)
result_clause = "<" , qualified_noun , ">" , [ "as" , type_annotation ] ;

type_annotation = type_name ;

type_name = "String" | "Integer" | "Float" | "Boolean"
          | "List" , "<" , type_name , ">"
          | "Map" , "<" , type_name , "," , type_name , ">"
          | openapi_schema_name ;
```

---

## No Optionals Philosophy

ARO has no optional types and no null values. This is a deliberate design choice that eliminates an entire category of bugs.

### The Problem with Optionals

Traditional languages require defensive coding:

```typescript
// TypeScript - defensive null handling
const user: User | null = await repository.find(id);
if (user === null) {
    throw new Error("User not found");
}
console.log(user.name);
```

### ARO's Approach: Fail Fast

In ARO, values either exist or the operation fails with a descriptive error:

```aro
(Get User: API) {
    Extract the <id> from the <pathParameters: id>.
    Retrieve the <user> from the <user-repository> where id = <id>.

    (* If user doesn't exist, runtime throws: *)
    (* "Cannot retrieve the user from the user-repository where id = 123" *)

    Return an <OK: status> with <user>.
}
```

### Error Messages Are The Code

The runtime error message directly reflects the ARO statement:

| ARO Statement | Error When Fails |
|---------------|------------------|
| `Retrieve the <user> from the <user-repository>...` | `Cannot retrieve the user from the user-repository where id = 123` |
| `Extract the <email> from the <user>...` | `Cannot extract the email from the user` |
| `Compute the <hash> from the <password>...` | `Cannot compute the hash from the password` |

### Benefits

1. **No null checks**: Code stays clean and focused on the happy path
2. **Self-documenting errors**: Error messages match the code that failed
3. **Fail fast**: Problems are detected immediately, not propagated
4. **Less code**: No defensive coding, optional unwrapping, or null guards

---

## Type Checking Rules

### Assignment Compatibility

| From | To | Allowed |
|------|-----|---------|
| `T` | `T` | Yes |
| `Integer` | `Float` | Yes (widening) |
| `Float` | `Integer` | Warning (narrowing) |
| `List<T>` | `List<T>` | Yes |
| OpenAPI Schema | Same Schema | Yes |

### Type Errors

| Error | Message |
|-------|---------|
| Type mismatch | `Expected 'String', got 'Integer'` |
| Unknown schema | `Schema 'Foo' not found in openapi.yaml` |
| Missing field | `Schema 'User' has no field 'age'` |

---

## Complete Example

### openapi.yaml

```yaml
openapi: 3.0.3
info:
  title: E-Commerce API
  version: 1.0.0

paths:
  /orders:
    post:
      operationId: createOrder
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/CreateOrderRequest'
      responses:
        '201':
          description: Order created
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/Order'

components:
  schemas:
    User:
      type: object
      properties:
        id:
          type: string
        email:
          type: string
        name:
          type: string
        status:
          $ref: '#/components/schemas/UserStatus'
      required:
        - id
        - email
        - name

    UserStatus:
      type: string
      enum:
        - active
        - inactive
        - suspended

    Order:
      type: object
      properties:
        id:
          type: string
        userId:
          type: string
        items:
          type: array
          items:
            $ref: '#/components/schemas/OrderItem'
        total:
          type: number
      required:
        - id
        - userId
        - items
        - total

    OrderItem:
      type: object
      properties:
        productId:
          type: string
        quantity:
          type: integer
        price:
          type: number
      required:
        - productId
        - quantity
        - price

    CreateOrderRequest:
      type: object
      properties:
        userId:
          type: string
        items:
          type: array
          items:
            $ref: '#/components/schemas/OrderItem'
      required:
        - userId
        - items
```

### orders.aro

```aro
(* Feature set named after operationId *)

(createOrder: E-Commerce) {
    Extract the <userId: String> from the <request: body>.
    Extract the <items> as List<OrderItem> from the <request: body>.

    (* This throws if user doesn't exist - no null check needed *)
    Retrieve the <user: User> from the <user-repository> where id = <userId>.

    (* Compute order total *)
    Reduce the <total> as Float from the <items> with sum(<price>).

    (* Create and store the order *)
    Create the <order: Order> with {
        id: <generated-id>,
        userId: <userId>,
        items: <items>,
        total: <total>
    }.
    Store the <order> into the <order-repository>.

    Log "Order created successfully" to the <console>.
    Return a <Created: status> with <order>.
}
```

---

## Complete Grammar

```ebnf
(* ============================================
   ARO Type System Grammar
   ============================================ *)

(* Type Annotations in Variables *)
typed_qualified_noun = identifier , ":" , type_expr , [ specifier_list ] ;

(* Result with optional as-annotation *)
result_clause = "<" , qualified_noun , ">" , [ "as" , type_expr ] ;

(* Type Expressions *)
type_expr = primitive_type
          | collection_type
          | openapi_type ;

primitive_type = "String" | "Integer" | "Float" | "Boolean" ;

collection_type = "List" , "<" , type_expr , ">"
                | "Map" , "<" , type_expr , "," , type_expr , ">" ;

openapi_type = identifier ;  (* References openapi.yaml components/schemas *)

(* No type or enum definitions in ARO grammar *)
(* All complex types come from openapi.yaml *)
```

---

## Summary

ARO's type system is intentionally minimal:

- **Four primitives**: String, Integer, Float, Boolean
- **Two collections**: List<T>, Map<K,V>
- **Complex types from OpenAPI**: No type definitions in ARO code
- **Contract-first HTTP**: Routes defined in OpenAPI, feature sets match operationIds
- **No optionals**: Values exist or operations fail with clear errors
- **Type inference**: Annotations are optional and used only when needed
