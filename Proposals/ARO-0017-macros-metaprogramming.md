# ARO-0017: Macros and Metaprogramming

* Proposal: ARO-0017
* Author: ARO Language Team
* Status: **Draft**
* Requires: ARO-0001, ARO-0006

## Abstract

This proposal introduces compile-time metaprogramming capabilities to ARO, enabling code generation, domain-specific extensions, and reducing boilerplate.

## Motivation

Metaprogramming enables:

1. **Code Generation**: Generate repetitive code
2. **DSL Creation**: Domain-specific syntax extensions
3. **Compile-Time Validation**: Verify constraints at compile time
4. **Abstraction**: Higher-level abstractions without runtime cost

---

### 1. Macro Definition

#### 1.1 Basic Macro

```ebnf
macro_definition = "macro" , macro_name , 
                   [ "(" , param_list , ")" ] ,
                   "{" , macro_body , "}" ;

macro_body = { macro_rule } ;
macro_rule = pattern , "=>" , expansion ;
```

**Example:**
```
macro log(level, message) {
    <Log> the <message: $message> at <level: $level> 
        with { timestamp: now(), source: #file, line: #line }.
}

// Usage
log(info, "User logged in")

// Expands to:
<Log> the <message: "User logged in"> at <level: info>
    with { timestamp: now(), source: "auth.aro", line: 42 }.
```

#### 1.2 Pattern Matching Macros

```
macro retry(attempts, body) {
    pattern: retry($n:expr) { $($body:stmt)* }
    
    => {
        <Set> the <__attempts> to 0.
        <Set> the <__success> to false.
        
        while <__attempts> < $n and not <__success> {
            <Increment> <__attempts>.
            try {
                $($body)*
                <Set> <__success> to true.
            } catch <_> {
                if <__attempts> >= $n then {
                    <Throw> the caught error.
                }
            }
        }
    }
}

// Usage
retry(3) {
    <Call> the <external-api>.
}
```

---

### 2. Expression Macros

#### 2.1 Inline Expansion

```
macro min(a, b) {
    if $a < $b then $a else $b
}

macro max(a, b) {
    if $a > $b then $a else $b
}

macro clamp(value, low, high) {
    min(max($value, $low), $high)
}

// Usage
<Set> the <result> to clamp(<input>, 0, 100).
```

#### 2.2 Conditional Compilation

```
macro debug(message) {
    #if DEBUG
        <Log> the <message: $message> at <level: debug>.
    #endif
}

macro assert(condition, message) {
    #if DEBUG
        if not ($condition) then {
            <Throw> an <AssertionError> with { message: $message }.
        }
    #endif
}
```

---

### 3. Procedural Macros

#### 3.1 Custom Derive

```
#[derive(Equatable)]
type User {
    id: String;
    email: String;
    name: String;
}

// Generates:
extend User {
    func equals(other: User) -> Bool {
        <Return> <id> == <other>.id 
            and <email> == <other>.email 
            and <name> == <other>.name.
    }
}
```

#### 3.2 Derive Implementations

```
// Define derive macro
derive_macro Equatable for type {
    let fields = type.fields;
    
    emit {
        extend $type {
            func equals(other: $type) -> Bool {
                <Return> $(
                    for field in fields {
                        emit { <$field> == <other>.$field }
                        if not last { emit { and } }
                    }
                ).
            }
        }
    }
}

derive_macro Hashable for type {
    emit {
        extend $type {
            func hash() -> Int {
                <Set> the <h> to 0.
                $(
                    for field in type.fields {
                        emit { <Combine> <$field>.hash() into <h>. }
                    }
                )
                <Return> <h>.
            }
        }
    }
}

derive_macro Builder for type {
    emit {
        type ${type.name}Builder {
            $(
                for field in type.fields {
                    emit { $field.name: $field.type?; }
                }
            )
            
            $(
                for field in type.fields {
                    emit {
                        func with${field.name.capitalized}(value: $field.type) -> Self {
                            <Set> <$field.name> to <value>.
                            <Return> self.
                        }
                    }
                }
            )
            
            func build() -> $type {
                <Return> $type {
                    $(
                        for field in type.fields {
                            emit { $field.name: <$field.name>! }
                            if not last { emit { , } }
                        }
                    )
                }.
            }
        }
    }
}
```

---

### 4. Attribute Macros

#### 4.1 Definition

```
attribute_macro cached(ttl: Duration = 60.seconds) for func {
    let original_name = func.name;
    let cache_key = "${func.name}_cache";
    
    emit {
        private <$cache_key: Map<String, CacheEntry>> = {};
        
        func $original_name($func.params) -> $func.returnType {
            <Set> the <key> to computeCacheKey($func.params).
            
            if <$cache_key>[<key>] exists 
               and <$cache_key>[<key>].expiresAt > now() then {
                <Return> <$cache_key>[<key>].value.
            }
            
            $(func.body)
            
            <Set> <$cache_key>[<key>] to CacheEntry {
                value: <result>,
                expiresAt: now() + $ttl
            }.
            
            <Return> <result>.
        }
    }
}

// Usage
@cached(ttl: 5.minutes)
func getUser(id: String) -> User? {
    <Retrieve> the <result: User?> from <database>.
}
```

#### 4.2 Validation Attributes

```
attribute_macro validate(rules: List<ValidationRule>) for field {
    emit {
        invariant $(
            for rule in rules {
                match rule {
                    .notEmpty => emit { <$field.name> is not empty }
                    .email => emit { <$field.name> matches email_pattern }
                    .minLength(n) => emit { <$field.name>.length >= $n }
                    .maxLength(n) => emit { <$field.name>.length <= $n }
                    .pattern(p) => emit { <$field.name> matches $p }
                }
                if not last { emit { and } }
            }
        ) : "$field.name validation failed";
    }
}

// Usage
type UserInput {
    @validate([.notEmpty, .email])
    email: String;
    
    @validate([.minLength(8), .maxLength(100)])
    password: String;
}
```

---

### 5. Code Generation

#### 5.1 Generate from Schema

```
generate_from "schema/openapi.yaml" {
    for endpoint in schema.paths {
        emit_file "generated/${endpoint.operationId}.aro" {
            $(
                if endpoint.method == "GET" {
                    emit {
                        (${endpoint.operationId}: API) {
                            <Call> the <response> from 
                                <api>.GET("${endpoint.path}").
                            <Return> <response>.
                        }
                    }
                }
            )
        }
    }
}
```

#### 5.2 Template-Based Generation

```
template CRUDFeatures(entity: Type, repository: Type) {
    emit {
        (Create ${entity.name}: ${entity.name} Management) {
            <Validate> the <input: Create${entity.name}Request>.
            <Create> the <${entity.name.lower}: ${entity.name}> from <input>.
            <Save> <${entity.name.lower}> to <$repository>.
            <Return> the <${entity.name.lower}>.
        }
        
        (Get ${entity.name}: ${entity.name} Management) {
            <Retrieve> the <${entity.name.lower}: ${entity.name}?> 
                from <$repository> with { id: <id> }.
            guard <${entity.name.lower}> exists else {
                <Throw> a <NotFoundError>.
            }
            <Return> the <${entity.name.lower}>.
        }
        
        (Update ${entity.name}: ${entity.name} Management) {
            <Retrieve> the <${entity.name.lower}: ${entity.name}> 
                from <$repository> with { id: <id> }.
            <Apply> the <updates> to <${entity.name.lower}>.
            <Save> <${entity.name.lower}> to <$repository>.
            <Return> the <${entity.name.lower}>.
        }
        
        (Delete ${entity.name}: ${entity.name} Management) {
            <Delete> from <$repository> where id = <id>.
            <Return> <success>.
        }
    }
}

// Usage
CRUDFeatures(User, UserRepository)
CRUDFeatures(Product, ProductRepository)
CRUDFeatures(Order, OrderRepository)
```

---

### 6. Compile-Time Functions

```
comptime func pluralize(word: String) -> String {
    if word.endsWith("y") {
        return word.dropLast() + "ies"
    } else if word.endsWith("s") or word.endsWith("x") {
        return word + "es"
    } else {
        return word + "s"
    }
}

comptime func camelToSnake(name: String) -> String {
    return name.replace(/([A-Z])/g, "_$1").toLowerCase().dropFirst()
}

// Usage
type User {
    // Table name computed at compile time
    @table(camelToSnake("User"))  // = "user"
    id: String;
}

(List #pluralize("User"): API) {  // = "List Users"
    // ...
}
```

---

### 7. Reflection

#### 7.1 Type Introspection

```
comptime func generateToJSON(t: Type) -> String {
    var result = "{"
    
    for (index, field) in t.fields.enumerated() {
        result += "\"\(field.name)\": \(field.name)"
        if index < t.fields.count - 1 {
            result += ", "
        }
    }
    
    result += "}"
    return result
}

#[derive(ToJSON)]
type User {
    id: String;
    name: String;
}

// Generates:
extend User {
    func toJSON() -> String {
        return "{\"id\": \(id), \"name\": \(name)}"
    }
}
```

#### 7.2 Runtime Reflection

```
(Dynamic Handler: Framework) {
    <Get> the <type-info> from reflect(<entity>).
    
    for each <field> in <type-info>.fields {
        <Log> "Field: ${<field>.name}, Type: ${<field>.type}".
    }
    
    // Dynamic field access
    <Get> the <value> from <entity>.field(<field-name>).
    <Set> <entity>.field(<field-name>) to <new-value>.
}
```

---

### 8. DSL Creation

```
// Define a routing DSL
dsl routes {
    syntax: route_def = method, path, "->", handler ;
    
    transform(route_def) {
        emit {
            <Register> the <${route_def.handler}> 
                at "${route_def.path}" 
                for ${route_def.method}.
        }
    }
}

// Usage with custom DSL
routes {
    GET  "/users"      -> ListUsers
    GET  "/users/{id}" -> GetUser
    POST "/users"      -> CreateUser
    PUT  "/users/{id}" -> UpdateUser
}

// Expands to:
<Register> the <ListUsers> at "/users" for GET.
<Register> the <GetUser> at "/users/{id}" for GET.
<Register> the <CreateUser> at "/users" for POST.
<Register> the <UpdateUser> at "/users/{id}" for PUT.
```

---

### 9. Complete Grammar Extension

```ebnf
(* Metaprogramming Grammar *)

(* Macro Definition *)
macro_definition = "macro" , identifier , 
                   [ "(" , param_list , ")" ] ,
                   "{" , macro_body , "}" ;

macro_body = { macro_rule | statement } ;
macro_rule = "pattern" , ":" , pattern , "=>" , expansion ;

(* Derive Macro *)
derive_macro = "derive_macro" , identifier , "for" , "type" , 
               "{" , derive_body , "}" ;

derive_body = { let_binding | emit_block } ;
emit_block = "emit" , "{" , { token | splice } , "}" ;
splice = "$(" , expression , ")" | "$" , identifier ;

(* Attribute Macro *)
attribute_macro = "attribute_macro" , identifier , 
                  [ "(" , param_list , ")" ] ,
                  "for" , target_kind ,
                  "{" , macro_body , "}" ;

target_kind = "type" | "func" | "field" | "feature" ;

(* Template *)
template_def = "template" , identifier , 
               "(" , param_list , ")" ,
               "{" , emit_block , "}" ;

(* DSL Definition *)
dsl_def = "dsl" , identifier , "{" ,
          "syntax" , ":" , grammar_rules , ";" ,
          "transform" , "(" , identifier , ")" , 
          "{" , emit_block , "}" ,
          "}" ;

(* Compile-Time Function *)
comptime_func = "comptime" , "func" , identifier , 
                "(" , param_list , ")" , "->" , type_annotation ,
                block ;

(* Generate From *)
generate_from = "generate_from" , string_literal , 
                "{" , generation_body , "}" ;

generation_body = { for_each_emit | emit_file } ;
emit_file = "emit_file" , string_literal , "{" , emit_block , "}" ;

(* Reflection *)
reflect_expr = "reflect" , "(" , expression , ")" ;

(* Built-in Macros *)
builtin_macro = "#file" | "#line" | "#column" | "#function" ;

(* Conditional Compilation *)
conditional_comp = "#if" , identifier , block , 
                   [ "#else" , block ] , "#endif" ;
```

---

### 10. Complete Example

```
// Derive macros
derive_macro Serializable for type {
    emit {
        extend $type {
            func toJSON() -> String {
                var parts: List<String> = [];
                $(
                    for field in type.fields {
                        emit {
                            <Add> "\"$field.name\": \(<$field.name>.toJSON())" 
                                to <parts>.
                        }
                    }
                )
                <Return> "{" + <parts>.joined(", ") + "}".
            }
            
            static func fromJSON(json: String) -> $type? {
                <Parse> the <data: Map<String, Any>> from <json>.
                <Return> $type {
                    $(
                        for field in type.fields {
                            emit { $field.name: <data>["$field.name"] as $field.type }
                            if not last { emit { , } }
                        }
                    )
                }.
            }
        }
    }
}

// Attribute macro for API endpoints
attribute_macro endpoint(method: String, path: String) for feature {
    emit {
        @route($method, $path)
        @doc("Auto-generated endpoint for $path")
        $(feature.body)
    }
}

// Template for CRUD
template RESTResource(name: String, entity: Type) {
    emit {
        @endpoint("GET", "/${name.lower}s")
        (List ${name}s: API) {
            <Retrieve> the <items: List<$entity>> from <repository>.
            <Return> the <items>.
        }
        
        @endpoint("GET", "/${name.lower}s/{id}")
        (Get ${name}: API) {
            <Retrieve> the <item: $entity?> from <repository> 
                where id = <id>.
            <Return> the <item>.
        }
        
        @endpoint("POST", "/${name.lower}s")
        (Create ${name}: API) {
            <Validate> the <input>.
            <Create> the <item: $entity> from <input>.
            <Save> <item> to <repository>.
            <Return> the <item>.
        }
        
        @endpoint("DELETE", "/${name.lower}s/{id}")
        (Delete ${name}: API) {
            <Delete> from <repository> where id = <id>.
            <Return> <success>.
        }
    }
}

// Usage
#[derive(Serializable, Equatable)]
type Product {
    id: String;
    name: String;
    price: Money;
}

RESTResource("Product", Product)

// Utility macros
macro measure(name, body) {
    <Set> the <__start> to now().
    $body
    <Set> the <__duration> to now() - <__start>.
    <Log> "$name took ${<__duration>.milliseconds}ms" at debug.
}

// Feature using macros
(Performance Test: Monitoring) {
    measure("database query") {
        <Retrieve> the <users> from <database>.
    }
    
    measure("api call") {
        <Call> the <response> from <external-api>.
    }
}
```

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-01 | Initial specification |
