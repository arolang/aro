# ARO-0006: Type System

* Proposal: ARO-0006
* Author: ARO Language Team
* Status: **Draft**
* Requires: ARO-0001, ARO-0002

## Abstract

This proposal introduces a static type system to ARO, enabling compile-time type checking, better tooling support, and clearer specifications.

## Motivation

A type system provides:

1. **Safety**: Catch type errors at compile time
2. **Documentation**: Types describe data shapes
3. **Tooling**: Enable autocomplete, refactoring
4. **Code Generation**: Generate typed code

## Proposed Solution

A gradual type system that is optional but encouraged, with inference where possible.

---

### 1. Built-in Types

#### 1.1 Primitive Types

| Type | Description | Literal Examples |
|------|-------------|-----------------|
| `String` | Text | `"hello"`, `'world'` |
| `Int` | Integer | `42`, `-17`, `0xFF` |
| `Float` | Decimal | `3.14`, `2.5e10` |
| `Bool` | Boolean | `true`, `false` |
| `Null` | Null value | `null` |

#### 1.2 Collection Types

| Type | Description | Literal Examples |
|------|-------------|-----------------|
| `List<T>` | Ordered collection | `[1, 2, 3]` |
| `Set<T>` | Unique elements | `Set(1, 2, 3)` |
| `Map<K, V>` | Key-value pairs | `{ key: value }` |

#### 1.3 Special Types

| Type | Description |
|------|-------------|
| `Any` | Any type (opt-out of checking) |
| `Never` | Never returns (throws/exits) |
| `Void` | No value |
| `Optional<T>` or `T?` | Nullable type |

---

### 2. Type Annotations

#### 2.1 Variable Type Annotation

```ebnf
typed_variable = "<" , identifier , ":" , type_annotation , ">" ;

type_annotation = type_name , [ "?" ] ;

type_name = primitive_type 
          | collection_type 
          | custom_type
          | "Any" ;

primitive_type = "String" | "Int" | "Float" | "Bool" | "Null" ;

collection_type = "List" , "<" , type_annotation , ">"
                | "Set" , "<" , type_annotation , ">"
                | "Map" , "<" , type_annotation , "," , type_annotation , ">" ;

custom_type = identifier ;
```

#### 2.2 Examples

```
<user: User>                    // Custom type
<count: Int>                    // Primitive
<name: String?>                 // Optional string
<items: List<Product>>          // List of products
<settings: Map<String, Any>>    // Map with string keys
```

---

### 3. Type Definitions

#### 3.1 Record Types (Structs)

```ebnf
type_definition = "type" , type_name , "{" , 
                  { field_definition } ,
                  "}" ;

field_definition = field_name , ":" , type_annotation , 
                   [ "=" , default_value ] , ";" ;
```

**Example:**
```
type User {
    id: String;
    email: String;
    name: String?;
    age: Int = 0;
    roles: List<String> = [];
    createdAt: DateTime;
}
```

#### 3.2 Enum Types

```ebnf
enum_definition = "enum" , type_name , "{" ,
                  enum_case , { "," , enum_case } ,
                  "}" ;

enum_case = case_name , [ "(" , field_list , ")" ] ;
```

**Example:**
```
enum Status {
    Active,
    Inactive,
    Suspended(reason: String),
    Pending(until: DateTime)
}

enum Result<T, E> {
    Success(value: T),
    Failure(error: E)
}
```

#### 3.3 Type Aliases

```ebnf
type_alias = "type" , type_name , "=" , type_annotation , ";" ;
```

**Example:**
```
type UserId = String;
type UserList = List<User>;
type Callback = (Request) -> Response;
```

---

### 4. Type Inference

The compiler infers types when not explicitly annotated:

#### 4.1 From Literals

```
<Set> the <count> to 42.           // count: Int
<Set> the <name> to "John".        // name: String
<Set> the <active> to true.        // active: Bool
<Set> the <items> to [1, 2, 3].    // items: List<Int>
```

#### 4.2 From Actions

```
// If UserRepository.find returns User?
<Retrieve> the <user> from the <user-repository>.
// user: User?
```

#### 4.3 From Expressions

```
<Compute> the <total> from <price> * <quantity>.
// If price: Float, quantity: Int, then total: Float
```

---

### 5. Type Checking Rules

#### 5.1 Assignment Compatibility

| From | To | Allowed |
|------|-----|---------|
| `T` | `T` | ✅ |
| `T` | `T?` | ✅ |
| `T?` | `T` | ❌ (requires unwrap) |
| `Int` | `Float` | ✅ (widening) |
| `Float` | `Int` | ⚠️ (warning, narrowing) |
| `Any` | `T` | ✅ (unsafe) |
| `T` | `Any` | ✅ |

#### 5.2 Collection Covariance

```
// List<Cat> is compatible with List<Animal> for reading
<Process> the <animals: List<Animal>> from <cats: List<Cat>>.  // OK
```

#### 5.3 Optional Handling

```
// Direct use of optional requires unwrap
<user: User?> from <repository>.

if <user> exists then {
    // <user> is automatically narrowed to User (not optional)
    <Send> the <email> to <user>.email.  // OK
}

// Outside condition, still optional
<Use> the <user>.name.  // Error: user may be null
```

---

### 6. Generic Types

#### 6.1 Generic Type Parameters

```
type Response<T> {
    data: T;
    status: Int;
    message: String?;
}

type Pair<A, B> {
    first: A;
    second: B;
}
```

#### 6.2 Generic Constraints

```ebnf
constraint = "where" , type_param , ":" , constraint_type ;
constraint_type = type_name | protocol_name ;
```

**Example:**
```
type SortedList<T> where T: Comparable {
    items: List<T>;
}
```

---

### 7. Protocols (Interfaces)

#### 7.1 Protocol Definition

```ebnf
protocol_definition = "protocol" , protocol_name , "{" ,
                      { protocol_member } ,
                      "}" ;

protocol_member = field_requirement | action_requirement ;

field_requirement = field_name , ":" , type_annotation , ";" ;
action_requirement = action_name , ":" , action_signature , ";" ;
```

**Example:**
```
protocol Identifiable {
    id: String;
}

protocol Timestamped {
    createdAt: DateTime;
    updatedAt: DateTime?;
}

protocol Repository<T> {
    find: (id: String) -> T?;
    save: (entity: T) -> T;
    delete: (id: String) -> Bool;
}
```

#### 7.2 Protocol Conformance

```
type User: Identifiable, Timestamped {
    id: String;
    email: String;
    createdAt: DateTime;
    updatedAt: DateTime?;
}
```

---

### 8. Function Types

#### 8.1 Syntax

```ebnf
function_type = "(" , [ param_list ] , ")" , "->" , return_type ;

param_list = param_type , { "," , param_type } ;
param_type = [ param_name , ":" ] , type_annotation ;
```

**Examples:**
```
type Handler = (Request) -> Response;
type Callback = (error: Error?, data: Any?) -> Void;
type Reducer<T> = (accumulator: T, item: T) -> T;
```

---

### 9. Type Guards and Narrowing

#### 9.1 Automatic Narrowing

After type checks, variables are narrowed:

```
<Retrieve> the <value: Any> from the <storage>.

if <value> is a String then {
    // value is String here
    <Compute> the <length> from <value>.length.
}

if <value> is a Number then {
    // value is Number here
    <Compute> the <doubled> from <value> * 2.
}
```

#### 9.2 Type Assertions

```ebnf
type_assertion = expression , "as" , type_name
               | expression , "as!" , type_name ;  (* forced, may fail *)
```

**Example:**
```
<Compute> the <user> from <data> as User.      // Safe cast, returns User?
<Compute> the <user> from <data> as! User.     // Forced cast, may throw
```

---

### 10. Complete Grammar Extension

```ebnf
(* Type System Grammar *)

(* Type Definitions *)
type_definition = record_type | enum_type | type_alias | protocol_def ;

record_type = "type" , type_name , [ generic_params ] , 
              [ conformance ] , "{" , { field_def } , "}" ;

enum_type = "enum" , type_name , [ generic_params ] , 
            "{" , enum_case , { "," , enum_case } , "}" ;

type_alias = "type" , type_name , "=" , type_expr , ";" ;

protocol_def = "protocol" , protocol_name , "{" , 
               { protocol_member } , "}" ;

(* Generic Parameters *)
generic_params = "<" , type_param , { "," , type_param } , ">" ;
type_param = identifier , [ ":" , constraint ] ;
constraint = type_name | protocol_name ;

(* Conformance *)
conformance = ":" , type_name , { "," , type_name } ;

(* Field Definition *)
field_def = identifier , ":" , type_expr , [ "=" , expression ] , ";" ;

(* Enum Cases *)
enum_case = identifier , [ "(" , field_list , ")" ] ;
field_list = field_def , { "," , field_def } ;

(* Type Expressions *)
type_expr = primitive_type
          | collection_type  
          | function_type
          | optional_type
          | identifier , [ generic_args ] ;

primitive_type = "String" | "Int" | "Float" | "Bool" 
               | "Null" | "Any" | "Never" | "Void" ;

collection_type = ( "List" | "Set" ) , "<" , type_expr , ">"
                | "Map" , "<" , type_expr , "," , type_expr , ">" ;

optional_type = type_expr , "?" ;

function_type = "(" , [ type_list ] , ")" , "->" , type_expr ;
type_list = type_expr , { "," , type_expr } ;

generic_args = "<" , type_expr , { "," , type_expr } , ">" ;

(* Type Annotation in Variables *)
typed_qualified_noun = identifier , ":" , type_expr , 
                       [ specifier_list ] ;
```

---

### 11. Complete Examples

#### Typed Feature Set

```
// Type definitions
type UserId = String;

type User {
    id: UserId;
    email: String;
    passwordHash: String;
    profile: UserProfile?;
    roles: List<Role>;
    status: UserStatus;
    createdAt: DateTime;
}

type UserProfile {
    firstName: String;
    lastName: String;
    avatar: String?;
}

enum Role {
    Admin,
    Editor,
    Viewer
}

enum UserStatus {
    Active,
    Pending(verificationToken: String),
    Suspended(reason: String, until: DateTime?)
}

type AuthResult {
    user: User;
    token: String;
    expiresAt: DateTime;
}

// Feature Set with typed variables
(User Authentication: Security) {
    <Require> <request: Request> from framework.
    <Require> <user-repository: Repository<User>> from framework.
    
    <Extract> the <credentials: Credentials> from the <request: body>.
    
    <Retrieve> the <user: User?> from the <user-repository>.
    
    if <user> is null then {
        <Return> an <Unauthorized: AuthError> for the <request>.
    }
    
    // user is now User (not optional) due to narrowing
    
    match <user>.status {
        case <Active> {
            <Verify> the <password: Bool> for the <credentials>.
            
            if <password> is true then {
                <Create> the <r: AuthResult> for the <user>.
                <Return> the <r> for the <request>.
            } else {
                <Return> an <Unauthorized: AuthError> for the <request>.
            }
        }
        case <Pending: p> {
            <Return> a <PendingVerification: AuthError> with <p>.verificationToken.
        }
        case <Suspended: s> {
            <Return> a <Suspended: AuthError> with <s>.reason.
        }
    }
}
```

---

## Implementation Notes

### Type Checker

```swift
public struct TypeChecker {
    let symbolTable: SymbolTable
    let typeRegistry: TypeRegistry
    
    func check(_ program: Program) -> [TypeDiagnostic]
    func infer(_ expression: Expression) -> TypeInfo
    func unify(_ expected: TypeInfo, _ actual: TypeInfo) -> Result<TypeInfo, TypeError>
}

public struct TypeInfo {
    let name: String
    let genericArgs: [TypeInfo]
    let isOptional: Bool
    let origin: TypeOrigin
}

public enum TypeOrigin {
    case builtin
    case userDefined(SourceSpan)
    case inferred
}
```

### Type Error Messages

| Error | Message |
|-------|---------|
| Type mismatch | `Expected 'String', got 'Int'` |
| Undefined type | `Type 'Foo' is not defined` |
| Missing field | `Type 'User' has no field 'age'` |
| Optional access | `Value of type 'User?' must be unwrapped` |
| Protocol conformance | `Type 'Foo' does not conform to 'Bar'` |

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-01 | Initial specification |
