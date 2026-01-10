# ARO-0006: Type System

* Proposal: ARO-0006
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0002, ARO-0027

## Abstract

This proposal defines ARO's type system: simple primitives built into the language, with all complex types defined externally in `openapi.yaml` components.

## Motivation

ARO's type system follows the "Code Is The Error Message" philosophy:

1. **No Null Checks**: Values exist or operations fail with descriptive errors
2. **Simple Primitives**: Four built-in types cover basic needs
3. **External Complex Types**: All records/enums defined in OpenAPI components
4. **Single Source of Truth**: OpenAPI defines both HTTP routes AND data types

## Design Principles

1. **No Optionals**: Every variable has a value. If retrieval fails, the runtime throws an error like `"Cannot retrieve the user from the user-repository where id = 123"`
2. **No Internal Type Definitions**: No `type` or `enum` keywords in ARO - all complex types come from OpenAPI
3. **OpenAPI as Type Source**: `openapi.yaml` components/schemas define all complex types
4. **Contract-First**: Types are designed before implementation

---

### 1. Primitive Types

| Type | Description | Literal Examples |
|------|-------------|-----------------|
| `String` | Text | `"hello"`, `'world'` |
| `Integer` | Whole numbers | `42`, `-17`, `0xFF` |
| `Float` | Decimal numbers | `3.14`, `2.5e10` |
| `Boolean` | True/False | `true`, `false` |

---

### 2. Collection Types

| Type | Description | Literal Examples |
|------|-------------|-----------------|
| `List<T>` | Ordered collection | `[1, 2, 3]` |
| `Map<K, V>` | Key-value pairs | `{ name: "Alice", age: 30 }` |

---

### 3. Complex Types from OpenAPI

All complex types (records, enums) are defined in `openapi.yaml` components/schemas. This applies even if your application has no HTTP routes.

#### 3.1 OpenAPI Schema Definition

```yaml
# openapi.yaml
openapi: 3.0.3
info:
  title: My Application
  version: 1.0.0

# paths: {} - Optional! No routes = no HTTP server

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

#### 3.2 Using OpenAPI Types in ARO

```aro
(Create User: User Management) {
    <Extract> the <data> from the <request: body>.

    (* User type comes from openapi.yaml components/schemas/User *)
    <Create> the <user: User> with <data>.

    (* Access fields defined in the schema *)
    <Log> <user: name> to the <console>.

    <Return> a <Created: status> with <user>.
}
```

---

### 4. Type Annotations

#### 4.1 Syntax

```ebnf
typed_variable = "<" , identifier , ":" , type_annotation , ">" ;

type_annotation = type_name ;

type_name = "String" | "Integer" | "Float" | "Boolean"
          | "List" , "<" , type_name , ">"
          | "Map" , "<" , type_name , "," , type_name , ">"
          | openapi_schema_name ;

openapi_schema_name = identifier ;  (* References components/schemas *)
```

#### 4.2 Examples

```aro
<name: String>                    // Primitive
<count: Integer>                  // Primitive
<items: List<String>>             // Collection of primitives
<user: User>                      // OpenAPI schema reference
<users: List<User>>               // Collection of OpenAPI types
<config: Map<String, Integer>>    // Map with primitives
```

---

### 5. Type Inference

Types are inferred from literals and expressions:

```aro
<Create> the <count> with 42.              // count: Integer
<Create> the <name> with "John".           // name: String
<Create> the <active> with true.           // active: Boolean
<Create> the <price> with 19.99.           // price: Float
<Create> the <items> with [1, 2, 3].       // items: List<Integer>
```

---

### 6. No Optionals - Error Handling

ARO has no optional types. When a value cannot be retrieved, the runtime throws a descriptive error.

#### What Other Languages Do (NOT ARO):

```typescript
// TypeScript - Optional handling
const user: User | null = await repository.find(id);
if (user === null) {
    throw new Error("User not found");
}
console.log(user.name);
```

#### What ARO Does:

```aro
(Get User: API) {
    <Extract> the <id> from the <pathParameters: id>.
    <Retrieve> the <user: User> from the <user-repository> where id = <id>.
    (* If user doesn't exist, runtime throws: *)
    (* "Cannot retrieve the user from the user-repository where id = 123" *)

    <Return> an <OK: status> with <user>.
}
```

The runtime error message IS the error handling. No null checks needed.

---

### 7. Type Checking Rules

#### 7.1 Assignment Compatibility

| From | To | Allowed |
|------|-----|---------|
| `T` | `T` | Yes |
| `Integer` | `Float` | Yes (widening) |
| `Float` | `Integer` | Warning (narrowing) |
| `List<T>` | `List<T>` | Yes |
| OpenAPI Schema | Same Schema | Yes |

#### 7.2 Type Errors

| Error | Message |
|-------|---------|
| Type mismatch | `Expected 'String', got 'Integer'` |
| Unknown schema | `Schema 'Foo' not found in openapi.yaml` |
| Missing field | `Schema 'User' has no field 'age'` |

---

### 8. OpenAPI Behavior

| openapi.yaml | paths | components | HTTP Server | Types Available |
|--------------|-------|------------|-------------|-----------------|
| Missing | - | - | No | Primitives only |
| Present | Empty/None | Has schemas | No | Primitives + Schemas |
| Present | Has routes | Has schemas | Yes | Primitives + Schemas |

**Key Point**: Even without HTTP routes, `openapi.yaml` can define types for your application.

---

### 9. Complete Grammar

```ebnf
(* Type System Grammar *)

(* Type Annotations in Variables *)
typed_qualified_noun = identifier , ":" , type_expr , [ specifier_list ] ;

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

### 10. Complete Example

#### openapi.yaml

```yaml
openapi: 3.0.3
info:
  title: E-Commerce Types
  version: 1.0.0

paths:
  /orders:
    post:
      operationId: createOrder
      requestBody:
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

#### orders.aro

```aro
(* Feature set named after operationId *)

(createOrder: E-Commerce) {
    <Require> the <user-repository> from the <framework>.
    <Require> the <order-repository> from the <framework>.

    <Extract> the <userId: String> from the <request: body>.
    <Extract> the <items: List<OrderItem>> from the <request: body>.

    (* This throws if user doesn't exist - no null check needed *)
    <Retrieve> the <user: User> from the <user-repository> where id = <userId>.

    (* Only active users can create orders *)
    match <user: status> {
        case "active" {
            <Compute> the <total: Float> from <items>.
            <Create> the <order: Order> with {
                id: <generated-id>,
                userId: <userId>,
                items: <items>,
                total: <total>
            }.
            <Store> the <order> in the <order-repository>.
            <Return> a <Created: status> with <order>.
        }
        case "inactive" {
            <Return> a <Forbidden: status> with "User is inactive".
        }
        case "suspended" {
            <Return> a <Forbidden: status> with "User is suspended".
        }
    }
}
```

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-01 | Initial specification |
| 2.0 | 2025-12 | Simplified: removed optionals, Null, Never, Void, protocols, function types. |
| 3.0 | 2025-12 | Removed internal type/enum definitions. All complex types from OpenAPI. |
