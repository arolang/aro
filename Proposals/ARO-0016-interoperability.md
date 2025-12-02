# ARO-0016: Interoperability

* Proposal: ARO-0016
* Author: ARO Language Team
* Status: **Draft**
* Requires: ARO-0001, ARO-0006, ARO-0007

## Abstract

This proposal defines how ARO interoperates with external systems, including Swift code, REST APIs, databases, and other languages.

## Motivation

Real-world applications require:

1. **Swift Integration**: Call Swift libraries, use Swift types
2. **External APIs**: Consume REST/GraphQL services
3. **Databases**: Query SQL/NoSQL stores
4. **FFI**: Interface with C/C++ libraries

---

### 1. Swift Interoperability

#### 1.1 Import Swift Modules

```ebnf
swift_import = "import" , "swift" , module_path , 
               [ "{" , import_list , "}" ] , ";" ;
```

**Example:**
```
import swift Foundation;
import swift Vapor.{ Request, Response };
import swift MyApp.Services.{ UserService, PaymentService };
```

#### 1.2 Use Swift Types

```
import swift Foundation.{ URL, Data, Date };
import swift MyApp.Models.{ User, Order };

(API Integration: External) {
    <Create> the <url: URL> from "https://api.example.com/users".
    <Create> the <date: Date> from Date().
    <Retrieve> the <user: User> from the <swift-repository>.
}
```

#### 1.3 Call Swift Functions

```
import swift CryptoKit.{ SHA256 };
import swift MyApp.Utilities.{ formatCurrency, validateEmail };

(Security: Crypto) {
    <Compute> the <hash: String> from SHA256.hash(data: <password>.data).
    <Compute> the <formatted: String> from formatCurrency(<amount>).
    <Compute> the <valid: Bool> from validateEmail(<email>).
}
```

#### 1.4 Implement Swift Protocols

```
@implements(swift: Hashable, Codable)
type User {
    id: String;
    email: String;
    name: String;
}

@implements(swift: AsyncSequence)
type EventStream<T> {
    // ...
}
```

#### 1.5 Swift Extensions

```
extend swift String {
    func isValidEmail() -> Bool {
        <Return> self matches "^[^@]+@[^@]+\\.[^@]+$".
    }
}

// Usage
if <email>.isValidEmail() then { ... }
```

---

### 2. External Type Mappings

#### 2.1 Type Mapping Declaration

```ebnf
type_mapping = "map" , aro_type , "to" , "swift" , swift_type , 
               [ mapping_options ] , ";" ;
```

**Example:**
```
// Built-in mappings
map String to swift Swift.String;
map Int to swift Swift.Int;
map Float to swift Swift.Double;
map Bool to swift Swift.Bool;
map List<T> to swift Swift.Array<T>;
map Map<K, V> to swift Swift.Dictionary<K, V>;

// Custom mappings
map Money to swift Decimal {
    toSwift: <m> => Decimal(<m>.amount),
    fromSwift: <d> => Money { amount: <d>, currency: .USD }
};

map DateTime to swift Foundation.Date {
    toSwift: <dt> => Date(timeIntervalSince1970: <dt>.timestamp),
    fromSwift: <d> => DateTime.fromTimestamp(<d>.timeIntervalSince1970)
};
```

#### 2.2 Automatic Codable

```
@codable
type OrderRequest {
    customerId: String;
    items: List<OrderItem>;
    shippingAddress: Address;
}

// Generates:
// extension OrderRequest: Codable { ... }
```

---

### 3. REST API Integration

#### 3.1 API Client Definition

```ebnf
api_client = "api" , client_name , "{" ,
             "baseUrl" , ":" , string_literal , ";" ,
             { api_endpoint } ,
             "}" ;

api_endpoint = http_method , path , [ request_config ] , 
               "->" , response_type , ";" ;
```

**Example:**
```
api UserAPI {
    baseUrl: "https://api.example.com/v1";
    
    headers: {
        "Content-Type": "application/json",
        "Authorization": "Bearer ${token}"
    };
    
    GET "/users" -> List<User>;
    GET "/users/{id}" -> User?;
    POST "/users" with body: CreateUserRequest -> User;
    PUT "/users/{id}" with body: UpdateUserRequest -> User;
    DELETE "/users/{id}" -> Void;
    
    GET "/users/{id}/orders" 
        with query: { status: OrderStatus?, limit: Int? }
        -> List<Order>;
}

// Usage
(User Management: API) {
    <Require> <api: UserAPI> from framework.
    
    <Call> the <users: List<User>> from <api>.GET("/users").
    <Call> the <user: User?> from <api>.GET("/users/${userId}").
    <Call> the <newUser: User> from <api>.POST("/users", body: <request>).
}
```

#### 3.2 Error Handling

```
api PaymentAPI {
    baseUrl: "https://payments.example.com";
    
    errors: {
        400: ValidationError,
        401: AuthenticationError,
        404: NotFoundError,
        500: ServerError
    };
    
    POST "/charge" with body: ChargeRequest -> ChargeResponse
        throws PaymentError;
}

(Payment: Processing) {
    try {
        <Call> the <r> from <PaymentAPI>.POST("/charge", body: <charge>).
    } catch <PaymentError> as <e> {
        <Log> the <e> for <monitoring>.
        <Return> a <failed-response> for the <request>.
    }
}
```

#### 3.3 Pagination

```
api ProductAPI {
    GET "/products" 
        with query: { page: Int, limit: Int }
        -> Paginated<Product>;
}

(List Products: Catalog) {
    <Set> the <all-products> to [].
    <Set> the <page> to 1.
    
    repeat {
        <Call> the <r> from <ProductAPI>.GET("/products", 
            query: { page: <page>, limit: 100 }).
        <Add> <r>.items to <all-products>.
        <Increment> <page>.
    } until <r>.hasMore is false
}
```

---

### 4. GraphQL Integration

```
graphql UserGraphQL {
    endpoint: "https://api.example.com/graphql";
    
    query GetUser(id: ID!) -> User {
        user(id: $id) {
            id
            email
            name
            orders {
                id
                total
            }
        }
    }
    
    mutation CreateUser(input: CreateUserInput!) -> User {
        createUser(input: $input) {
            id
            email
        }
    }
}

(User Query: API) {
    <Query> the <user: User> from <UserGraphQL>.GetUser(id: "123").
    <Mutate> the <newUser: User> from <UserGraphQL>.CreateUser(input: <data>).
}
```

---

### 5. Database Integration

#### 5.1 SQL Databases

```
database UserDB: PostgreSQL {
    connection: env("DATABASE_URL");
    
    table users {
        id: UUID primary key;
        email: String unique;
        name: String;
        created_at: DateTime default now();
    }
    
    table orders {
        id: UUID primary key;
        user_id: UUID references users(id);
        total: Decimal;
        status: String;
    }
}

(User Data: Persistence) {
    <Require> <db: UserDB> from framework.
    
    // Query
    <Query> the <user: User?> from <db>.users
        where email = <email>.
    
    <Query> the <orders: List<Order>> from <db>.orders
        where user_id = <user>.id
        order by created_at desc
        limit 10.
    
    // Insert
    <Insert> <new-user> into <db>.users.
    
    // Update
    <Update> <db>.users
        set name = <new-name>
        where id = <user-id>.
    
    // Transaction
    transaction {
        <Insert> <order> into <db>.orders.
        <Update> <db>.inventory set quantity = quantity - 1.
    }
}
```

#### 5.2 NoSQL (MongoDB)

```
database ProductDB: MongoDB {
    connection: env("MONGO_URL");
    
    collection products {
        _id: ObjectId;
        name: String;
        price: Decimal;
        tags: List<String>;
        metadata: Map<String, Any>;
    }
}

(Product Search: Catalog) {
    <Query> the <products: List<Product>> from <ProductDB>.products
        where { 
            tags: { $in: ["electronics", "sale"] },
            price: { $lt: 100 }
        }
        sort { price: 1 }
        limit 20.
}
```

---

### 6. Message Queues

```
queue OrderQueue: RabbitMQ {
    connection: env("RABBITMQ_URL");
    
    exchange orders {
        type: topic;
        durable: true;
    }
    
    queue order-processing {
        bindings: ["orders.created", "orders.updated"];
    }
}

(Order Events: Messaging) {
    // Publish
    <Publish> OrderCreated { orderId: <id> } 
        to <OrderQueue>.orders 
        with routingKey "orders.created".
    
    // Subscribe
    <Subscribe> to <OrderQueue>.order-processing as <messages>.
    
    for await <msg> in <messages> {
        <Process> the <msg>.
        <Acknowledge> the <msg>.
    }
}
```

---

### 7. gRPC Integration

```
grpc UserService {
    proto: "protos/user.proto";
    
    rpc GetUser(GetUserRequest) returns (User);
    rpc ListUsers(ListUsersRequest) returns (stream User);
    rpc CreateUser(CreateUserRequest) returns (User);
}

(User gRPC: Integration) {
    <Require> <client: UserService> from framework.
    
    <Call> the <user: User> from <client>.GetUser({ id: "123" }).
    
    for await <user> in <client>.ListUsers({ limit: 100 }) {
        <Process> the <user>.
    }
}
```

---

### 8. FFI (C/C++)

```
extern "C" {
    func openssl_encrypt(data: Pointer<UInt8>, len: Int) -> Pointer<UInt8>;
    func openssl_decrypt(data: Pointer<UInt8>, len: Int) -> Pointer<UInt8>;
}

(Encryption: Security) {
    <Convert> the <data-ptr: Pointer<UInt8>> from <data>.
    <Call> the <encrypted-ptr> from openssl_encrypt(<data-ptr>, <data>.length).
    <Convert> the <encrypted: Data> from <encrypted-ptr>.
}
```

---

### 9. Complete Grammar Extension

```ebnf
(* Interoperability Grammar *)

(* Swift Import *)
swift_import = "import" , "swift" , module_path , 
               [ "{" , identifier_list , "}" ] , ";" ;

(* Type Mapping *)
type_mapping = "map" , type_name , "to" , "swift" , swift_type ,
               [ "{" , mapping_funcs , "}" ] , ";" ;

mapping_funcs = "toSwift" , ":" , lambda , "," ,
                "fromSwift" , ":" , lambda ;

(* Swift Extension *)
swift_extension = "extend" , "swift" , swift_type , 
                  "{" , { func_def } , "}" ;

(* API Client *)
api_client = "api" , identifier , "{" ,
             "baseUrl" , ":" , string_literal , ";" ,
             [ "headers" , ":" , inline_object , ";" ] ,
             [ "errors" , ":" , inline_object , ";" ] ,
             { api_endpoint } ,
             "}" ;

api_endpoint = http_method , string_literal ,
               [ "with" , endpoint_config ] ,
               "->" , type_annotation ,
               [ "throws" , type_name ] , ";" ;

http_method = "GET" | "POST" | "PUT" | "PATCH" | "DELETE" ;

endpoint_config = "body" , ":" , type_name
                | "query" , ":" , inline_object
                | "body" , ":" , type_name , "," , 
                  "query" , ":" , inline_object ;

(* GraphQL *)
graphql_client = "graphql" , identifier , "{" ,
                 "endpoint" , ":" , string_literal , ";" ,
                 { graphql_operation } ,
                 "}" ;

graphql_operation = ( "query" | "mutation" ) , identifier ,
                    "(" , param_list , ")" , "->" , type_annotation ,
                    graphql_selection ;

(* Database *)
database_def = "database" , identifier , ":" , db_type , 
               "{" , { db_member } , "}" ;

db_type = "PostgreSQL" | "MySQL" | "SQLite" | "MongoDB" ;

db_member = "connection" , ":" , expression , ";"
          | table_def 
          | collection_def ;

table_def = "table" , identifier , "{" , { column_def } , "}" ;
collection_def = "collection" , identifier , "{" , { field_def } , "}" ;

(* Message Queue *)
queue_def = "queue" , identifier , ":" , queue_type ,
            "{" , { queue_member } , "}" ;

queue_type = "RabbitMQ" | "Kafka" | "SQS" ;

(* gRPC *)
grpc_def = "grpc" , identifier , "{" ,
           "proto" , ":" , string_literal , ";" ,
           { rpc_def } ,
           "}" ;

rpc_def = "rpc" , identifier , "(" , type_name , ")" ,
          "returns" , "(" , [ "stream" ] , type_name , ")" , ";" ;

(* FFI *)
extern_block = "extern" , string_literal , "{" , { extern_func } , "}" ;
extern_func = "func" , identifier , "(" , param_list , ")" ,
              [ "->" , type_annotation ] , ";" ;
```

---

### 10. Complete Example

```
import swift Foundation.{ URL, URLSession };
import swift Vapor.{ Request, Response };

// Type mappings
map UserId to swift String;
map Money to swift Decimal {
    toSwift: <m> => Decimal(string: String(<m>.amount))!,
    fromSwift: <d> => Money { amount: Double(truncating: <d> as NSNumber), currency: .USD }
};

// REST API
api OrderAPI {
    baseUrl: env("ORDER_API_URL");
    
    headers: {
        "Authorization": "Bearer ${env('API_TOKEN')}",
        "X-Request-ID": "${uuid()}"
    };
    
    errors: {
        400: ValidationError,
        401: AuthError,
        404: NotFoundError,
        500: ServerError
    };
    
    GET "/orders" 
        with query: { status: String?, page: Int?, limit: Int? }
        -> Paginated<Order>;
    
    GET "/orders/{id}" -> Order?;
    
    POST "/orders" with body: CreateOrderRequest -> Order
        throws OrderError;
}

// Database
database AppDB: PostgreSQL {
    connection: env("DATABASE_URL");
    
    table orders {
        id: UUID primary key default gen_random_uuid();
        customer_id: UUID not null;
        status: String not null default 'pending';
        total: Decimal not null;
        created_at: DateTime default now();
    }
}

// Feature using integrations
(Sync Orders: Integration) {
    <Require> <api: OrderAPI> from framework.
    <Require> <db: AppDB> from framework.
    
    // Fetch from API
    <Set> the <page> to 1.
    <Set> the <all-orders> to [].
    
    repeat {
        try {
            <Call> the <r: Paginated<Order>> from 
                <api>.GET("/orders", query: { 
                    status: "completed",
                    page: <page>,
                    limit: 100
                }).
            
            <Add> <r>.items to <all-orders>.
            <Increment> <page>.
            
        } catch <ServerError> as <e> {
            <Log> the <e> for <monitoring>.
            <Wait> for 5.seconds.
            <Continue>.
        }
    } until <r>.hasMore is false
    
    // Sync to database
    transaction {
        for each <order> in <all-orders> {
            <Query> the <existing: Order?> from <db>.orders
                where id = <order>.id.
            
            if <existing> is null then {
                <Insert> <order> into <db>.orders.
            } else {
                <Update> <db>.orders
                    set status = <order>.status, total = <order>.total
                    where id = <order>.id.
            }
        }
    }
    
    <Log> the <sync-complete> with { count: <all-orders>.count() }.
}
```

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-01 | Initial specification |
