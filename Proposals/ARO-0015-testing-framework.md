# ARO-0015: Testing Framework

* Proposal: ARO-0015
* Author: ARO Language Team
* Status: **Draft**
* Requires: ARO-0001, ARO-0010

## Abstract

This proposal introduces a built-in testing framework to ARO, enabling BDD-style specifications, mocking, and comprehensive test coverage.

## Motivation

Testing is essential for:

1. **Verification**: Ensure features work correctly
2. **Documentation**: Tests as executable specifications
3. **Regression**: Prevent bugs from returning
4. **Design**: TDD/BDD workflows

---

### 1. Test Suites

#### 1.1 Test Suite Definition

```ebnf
test_suite = "tests" , suite_name , [ "for" , target ] ,
             "{" , { test_member } , "}" ;

test_member = test_case | setup | teardown | helper ;
```

**Example:**
```
tests "User Authentication" for UserAuthenticationFeature {
    setup {
        <Create> the <test-db> as InMemoryDatabase.
        <Create> the <user-repo> with <test-db>.
        <Create> the <test-user> with {
            id: "user-1",
            email: "test@example.com",
            passwordHash: hash("password123")
        }.
        <Save> <test-user> to <user-repo>.
    }
    
    teardown {
        <Clear> the <test-db>.
    }
    
    test "should authenticate valid credentials" {
        // ...
    }
    
    test "should reject invalid password" {
        // ...
    }
}
```

---

### 2. Test Cases

#### 2.1 Basic Test

```ebnf
test_case = [ annotation_list ] ,
            "test" , string_literal , block ;
```

**Example:**
```
test "should create user with valid email" {
    <Given> the <request> with {
        email: "new@example.com",
        password: "SecurePass123"
    }.
    
    <When> the <CreateUser> feature is executed with <request>.
    
    <Then> the <response>.status should be 201.
    <Then> the <response>.body.email should be "new@example.com".
}
```

#### 2.2 BDD Style (Given/When/Then)

```ebnf
given_clause = "<Given>" , setup_statement ;
when_clause = "<When>" , action_statement ;
then_clause = "<Then>" , assertion ;
```

**Example:**
```
test "complete order flow" {
    <Given> the <customer> with { id: "c1", loyaltyTier: .gold }.
    <Given> the <product> with { sku: "P1", price: Money(100, USD) }.
    <Given> the <inventory> with { sku: "P1", quantity: 10 }.
    
    <When> the <customer> adds <product> to cart with quantity 2.
    <When> the <customer> proceeds to checkout.
    <When> the <customer> confirms payment.
    
    <Then> the <order>.status should be .placed.
    <Then> the <order>.total should be Money(180, USD).  // 10% loyalty discount
    <Then> the <inventory>.quantity should be 8.
    <Then> the <customer> should receive <order-confirmation-email>.
}
```

---

### 3. Assertions

#### 3.1 Assertion Syntax

```ebnf
assertion = expression , "should" , assertion_matcher ;

assertion_matcher = "be" , expression
                  | "be" , type_name
                  | "equal" , expression
                  | "contain" , expression
                  | "match" , pattern
                  | "throw" , error_type
                  | "be" , "null"
                  | "exist"
                  | "be" , "empty"
                  | "have" , "length" , number
                  | "be" , "greater" , "than" , expression
                  | "be" , "less" , "than" , expression
                  | "satisfy" , predicate ;
```

**Examples:**
```
// Equality
<result> should equal 42.
<user>.name should be "John".

// Type checking
<response> should be a SuccessResponse.
<error> should be an AuthenticationError.

// Existence
<user>.email should exist.
<optional-field> should be null.

// Collections
<list> should contain "item".
<list> should have length 5.
<list> should be empty.

// Comparisons
<count> should be greater than 0.
<age> should be less than 120.

// Patterns
<email> should match "^[^@]+@[^@]+$".

// Errors
{ <divide>(10, 0) } should throw DivisionByZeroError.

// Custom predicates
<user> should satisfy <u> => <u>.age >= 18.
```

#### 3.2 Negation

```
<result> should not be null.
<list> should not contain "forbidden".
<response> should not throw.
```

#### 3.3 Soft Assertions

Continue test after failure:

```
test "validate user fields" {
    soft {
        <user>.name should not be empty.
        <user>.email should match email-pattern.
        <user>.age should be greater than 0.
    }
    // All assertions run even if some fail
}
```

---

### 4. Mocking

#### 4.1 Mock Definition

```ebnf
mock_statement = "@mock" , "(" , mock_target , mock_config , ")" ;
mock_config = "returns" , expression
            | "throws" , expression
            | "calls" , lambda ;
```

**Example:**
```
test "should handle external service failure" {
    @mock(PaymentService.process, throws: NetworkError("Connection refused"))
    
    <Given> the <order> with { total: Money(100, USD) }.
    
    <When> the <checkout> is attempted.
    
    <Then> the <response> should be a PaymentFailedResponse.
    <Then> the <order>.status should be .paymentFailed.
}

test "should use cached user when available" {
    @mock(UserRepository.find, returns: cachedUser)
    @mock(UserCache.get, returns: cachedUser)
    
    <When> the <GetUser> is executed with { id: "user-1" }.
    
    <Then> <UserRepository.find> should not have been called.
    <Then> <UserCache.get> should have been called once.
}
```

#### 4.2 Spy

```
test "should call notification service" {
    @spy(NotificationService)
    
    <When> the <CreateUser> is executed.
    
    <Then> <NotificationService.send> should have been called with {
        to: <user>.email,
        template: "welcome"
    }.
    <Then> <NotificationService.send> should have been called 1 time.
}
```

#### 4.3 Mock Sequences

```
test "should retry on failure" {
    @mock(ExternalAPI.call, sequence: [
        throws: NetworkError,
        throws: NetworkError,
        returns: SuccessResponse
    ])
    
    <When> the <resilient-call> is executed.
    
    <Then> <ExternalAPI.call> should have been called 3 times.
    <Then> the <result> should be a SuccessResponse.
}
```

---

### 5. Test Data

#### 5.1 Fixtures

```
fixture User {
    default {
        id: "user-${uuid()}",
        email: "user-${random.int}@test.com",
        name: "Test User",
        status: .active,
        createdAt: now()
    }
    
    admin: default {
        roles: [.admin],
        email: "admin@test.com"
    }
    
    inactive: default {
        status: .inactive
    }
}

test "admin access" {
    <Given> the <user> as User.admin.
    // user has admin role
}
```

#### 5.2 Builders

```
builder OrderBuilder for Order {
    default {
        id: OrderId.random(),
        status: .draft,
        items: []
    }
    
    func withItem(productId: ProductId, quantity: Int) -> Self {
        <Add> OrderItem {
            productId: <productId>,
            quantity: <quantity>
        } to <items>.
        <Return> self.
    }
    
    func placed() -> Self {
        <Set> <status> to .placed.
        <Return> self.
    }
}

test "order with items" {
    <Given> the <order> as OrderBuilder
        .withItem("P1", 2)
        .withItem("P2", 1)
        .placed()
        .build().
}
```

#### 5.3 Random Data

```
test "fuzz test email validation" {
    for each <_> in range(1, 100) {
        <Given> the <email> as random.email().
        <When> the <validation> is run on <email>.
        <Then> the <result> should be valid.
    }
}
```

---

### 6. Parameterized Tests

```
@parameterized([
    { input: 0, expected: "zero" },
    { input: 1, expected: "one" },
    { input: 2, expected: "two" },
    { input: -1, expected: "negative" }
])
test "number to word conversion" (input: Int, expected: String) {
    <When> the <result> is computed from numberToWord(<input>).
    <Then> <result> should equal <expected>.
}

@parameterized(csvFile: "test-cases.csv")
test "from CSV file" (email: String, valid: Bool) {
    <When> the <result> is validated for <email>.
    <Then> <result> should equal <valid>.
}
```

---

### 7. Async Tests

```
@timeout(5.seconds)
test "async operation completes" {
    <Given> the <future> as async <longRunningOperation>.
    
    <When> the <result> is awaited from <future>.
    
    <Then> <result> should exist.
}

test "should timeout gracefully" {
    @mock(SlowService.call, delays: 10.seconds)
    
    <When> the <operation> with timeout 1.second is executed.
    
    <Then> the <result> should be a TimeoutError.
}
```

---

### 8. Integration Tests

```
@integration
@database("test-db")
@http("mock-server")
tests "Order API Integration" {
    
    setup {
        <Start> the <mock-server>.
        <Migrate> the <test-db>.
    }
    
    teardown {
        <Stop> the <mock-server>.
        <Rollback> the <test-db>.
    }
    
    test "POST /orders creates order" {
        <Given> the <http-request> as POST "/orders" with {
            body: { customerId: "c1", items: [...] },
            headers: { Authorization: "Bearer ${token}" }
        }.
        
        <When> the <response> is received from <http-request>.
        
        <Then> <response>.status should be 201.
        <Then> <response>.body.id should exist.
        
        // Verify in database
        <Query> the <order> from <test-db> 
            where id = <response>.body.id.
        <Then> <order> should exist.
    }
}
```

---

### 9. Snapshot Testing

```
test "order summary matches snapshot" {
    <Given> the <order> with complex structure.
    
    <When> the <summary> is generated from <order>.
    
    <Then> <summary> should match snapshot "order-summary-v1".
}

// Updating snapshots: aro test --update-snapshots
```

---

### 10. Coverage

```
@coverage(minimum: 80%)
tests "User Service" for UserService {
    // Tests...
}

// Run with coverage: aro test --coverage
// Output:
//   UserService: 87% covered
//   - createUser: 100%
//   - updateUser: 75%
//   - deleteUser: 85%
```

---

### 11. Complete Grammar Extension

```ebnf
(* Testing Grammar *)

(* Test Suite *)
test_suite = "tests" , string_literal , [ "for" , identifier ] ,
             "{" , { test_member } , "}" ;

test_member = test_case | setup_block | teardown_block | helper_def ;

setup_block = "setup" , block ;
teardown_block = "teardown" , block ;
helper_def = "helper" , identifier , block ;

(* Test Case *)
test_case = [ annotation_list ] , "test" , string_literal , 
            [ "(" , param_list , ")" ] , block ;

(* BDD Clauses *)
given_clause = "<Given>" , ( assignment | setup_expr ) , "." ;
when_clause = "<When>" , action_expr , "." ;
then_clause = "<Then>" , assertion , "." ;

(* Assertions *)
assertion = expression , "should" , [ "not" ] , matcher ;

matcher = "be" , expression
        | "equal" , expression
        | "be" , ( "a" | "an" ) , type_name
        | "contain" , expression
        | "match" , string_literal
        | "throw" , [ type_name ]
        | "be" , ( "null" | "empty" | "true" | "false" )
        | "exist"
        | "have" , "length" , expression
        | "be" , ( "greater" | "less" ) , "than" , expression
        | "satisfy" , lambda_expression
        | "have" , "been" , "called" , [ call_count ] ;

call_count = number , ( "time" | "times" )
           | "once" | "never" | "at" , "least" , number , "times" ;

(* Mocking *)
mock_annotation = "@mock" , "(" , identifier , "," , mock_behavior , ")" ;
mock_behavior = "returns" , ":" , expression
              | "throws" , ":" , expression
              | "sequence" , ":" , list_literal ;

spy_annotation = "@spy" , "(" , identifier , ")" ;

(* Fixtures *)
fixture_def = "fixture" , identifier , "{" , { fixture_variant } , "}" ;
fixture_variant = [ identifier , ":" ] , ( "default" | identifier ) , 
                  inline_object ;

(* Builder *)
builder_def = "builder" , identifier , "for" , type_name ,
              "{" , { builder_member } , "}" ;

builder_member = "default" , inline_object | func_def ;

(* Parameterized *)
param_annotation = "@parameterized" , "(" , 
                   ( list_literal | "csvFile" , ":" , string_literal ) , ")" ;
```

---

### 12. Complete Example

```
tests "Order Processing" for OrderService {
    // Fixtures
    fixture Product {
        default {
            sku: "SKU-${uuid()}",
            name: "Test Product",
            price: Money(10, USD),
            inStock: true
        }
        
        expensive: default {
            price: Money(1000, USD)
        }
        
        outOfStock: default {
            inStock: false
        }
    }
    
    fixture Customer {
        default {
            id: "cust-${uuid()}",
            email: "customer@test.com",
            loyaltyTier: .standard
        }
        
        gold: default {
            loyaltyTier: .gold
        }
    }
    
    // Setup/Teardown
    setup {
        <Create> the <db> as InMemoryDatabase.
        <Create> the <orderRepo> with <db>.
        <Create> the <productRepo> with <db>.
        <Create> the <inventoryService> as MockInventoryService.
    }
    
    teardown {
        <Clear> the <db>.
    }
    
    // Tests
    test "should create order with valid items" {
        <Given> the <customer> as Customer.default.
        <Given> the <product> as Product.default.
        @mock(InventoryService.checkStock, returns: true)
        
        <When> the <order> is created for <customer> with [
            { productId: <product>.sku, quantity: 2 }
        ].
        
        <Then> <order>.status should be .draft.
        <Then> <order>.items should have length 1.
        <Then> <order>.items[0].quantity should equal 2.
        <Then> <order>.total should equal Money(20, USD).
    }
    
    test "should apply gold member discount" {
        <Given> the <customer> as Customer.gold.
        <Given> the <product> as Product.expensive.
        @mock(InventoryService.checkStock, returns: true)
        
        <When> the <order> is created for <customer> with [
            { productId: <product>.sku, quantity: 1 }
        ].
        <When> the <order> is placed.
        
        <Then> <order>.discount should equal Money(100, USD).  // 10%
        <Then> <order>.total should equal Money(900, USD).
    }
    
    test "should reject out of stock items" {
        <Given> the <customer> as Customer.default.
        <Given> the <product> as Product.outOfStock.
        @mock(InventoryService.checkStock, returns: false)
        
        <When> creating order with <product>.
        
        <Then> it should throw InsufficientStockError.
    }
    
    @parameterized([
        { quantity: 1, expectedTotal: 10 },
        { quantity: 5, expectedTotal: 50 },
        { quantity: 10, expectedTotal: 100 }
    ])
    test "should calculate correct total" (quantity: Int, expectedTotal: Int) {
        <Given> the <product> as Product.default.
        
        <When> the <order> is created with quantity <quantity>.
        
        <Then> <order>.total.amount should equal <expectedTotal>.
    }
    
    @integration
    @timeout(10.seconds)
    test "full checkout flow" {
        <Given> the <customer> in database.
        <Given> the <products> in database.
        <Given> the <inventory> is stocked.
        
        <When> <customer> creates order with <products>.
        <When> <customer> adds payment method.
        <When> <customer> confirms checkout.
        
        <Then> <order>.status should be .placed.
        <Then> <inventory> should be reduced.
        <Then> <customer> should receive confirmation email.
        <Then> <payment> should be processed.
    }
}
```

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-01 | Initial specification |
