# ARO-0004: Conditional Branching

* Proposal: ARO-0004
* Author: ARO Language Team
* Status: **Draft**
* Requires: ARO-0001, ARO-0002, ARO-0003

## Abstract

This proposal introduces conditional execution to ARO, allowing specifications to express decision logic while maintaining the declarative ARO style.

## Motivation

Real-world business logic requires conditional execution:

- Different paths based on user roles
- Validation results determining next steps
- Error handling for edge cases
- Multiple outcomes based on input

Without conditionals, every statement executes unconditionally, which is unrealistic.

## Proposed Solution

Three complementary constructs:

1. **Guarded Statements** (`when`): Single-statement conditions
2. **Conditional Blocks** (`if/then/else`): Multi-statement branches
3. **Match Expressions** (`match`): Pattern-based dispatch

---

### 1. Guarded Statements (When Clause)

#### 1.1 Syntax

```ebnf
guarded_statement = aro_statement_base , "when" , condition , "." ;

aro_statement_base = action_clause , result_clause , object_clause ;
```

**Format:**
```
<Action> the <result> preposition the <object> when <condition>.
```

#### 1.2 Examples

```
// Only return OK when authentication is valid
<Return> an <OK: status> for the <user> when <authentication> is <valid>.

// Only send notification when user has email
<Send> the <notification> to the <user: email> when <user: email> exists.

// Throw error when user not found
<Throw> a <NotFoundError> for the <user> when <user: record> is null.
```

#### 1.3 Semantics

- The statement executes **only if** the condition is true
- If false, execution continues to the next statement
- No implicit else branch

---

### 2. Conditional Blocks (If/Then/Else)

#### 2.1 Syntax

```ebnf
conditional_block = "if" , condition , "then" , block ,
                    { "else" , "if" , condition , "then" , block } ,
                    [ "else" , block ] ;

block = "{" , { statement } , "}" ;
```

**Format:**
```
if <condition> then {
    <statements>
} else if <condition> then {
    <statements>
} else {
    <statements>
}
```

#### 2.2 Examples

##### Simple If-Then-Else

```
if <user: role> is "admin" then {
    <Grant> the <full-access> for the <resource>.
} else {
    <Grant> the <read-only-access> for the <resource>.
}
```

##### Chained Conditions

```
if <status-code> is 200 then {
    <Parse> the <response: body> from the <http-response>.
    <Return> the <data> for the <request>.
} else if <status-code> is 404 then {
    <Return> a <NotFound: error> for the <request>.
} else if <status-code> is 500 then {
    <Log> the <server-error> for the <monitoring>.
    <Return> a <ServerError> for the <request>.
} else {
    <Return> an <UnknownError> for the <request>.
}
```

##### Nested Conditions

```
if <user> exists then {
    if <user: is-verified> is true then {
        <Grant> the <access> for the <user>.
    } else {
        <Send> the <verification-email> to the <user>.
        <Return> a <PendingVerification: status> for the <user>.
    }
} else {
    <Return> a <NotFound: error> for the <user-id>.
}
```

---

### 3. Match Expressions

#### 3.1 Syntax

```ebnf
match_expression = "match" , "<" , qualified_noun , ">" , "{" ,
                   { case_clause } ,
                   [ otherwise_clause ] ,
                   "}" ;

case_clause      = "case" , pattern , [ "where" , condition ] , block ;

otherwise_clause = "otherwise" , block ;

pattern          = "<" , qualified_noun , ">"
                 | literal
                 | "_" ;  (* wildcard *)
```

**Format:**
```
match <variable> {
    case <pattern> {
        <statements>
    }
    case <pattern> where <condition> {
        <statements>
    }
    otherwise {
        <statements>
    }
}
```

#### 3.2 Examples

##### Simple Value Matching

```
match <http: method> {
    case "GET" {
        <Retrieve> the <resource> from the <database>.
    }
    case "POST" {
        <Create> the <resource> in the <database>.
    }
    case "PUT" {
        <Update> the <resource> in the <database>.
    }
    case "DELETE" {
        <Remove> the <resource> from the <database>.
    }
    otherwise {
        <Return> a <MethodNotAllowed: error> for the <request>.
    }
}
```

##### Pattern Matching with Guards

```
match <user: subscription> {
    case <premium> where <user: credits> > 0 {
        <Grant> the <premium-features> for the <user>.
        <Deduct> the <credit> from the <user: account>.
    }
    case <premium> {
        <Notify> the <user> about the <low-credits>.
        <Grant> the <basic-features> for the <user>.
    }
    case <basic> {
        <Grant> the <basic-features> for the <user>.
    }
    case <trial> where <trial: days-remaining> > 0 {
        <Grant> the <trial-features> for the <user>.
    }
    otherwise {
        <Redirect> the <user> to the <subscription-page>.
    }
}
```

##### Destructuring (Future Extension)

```
match <result> {
    case <Success: value> {
        <Return> the <value> for the <response>.
    }
    case <Failure: error> {
        <Log> the <error> for the <monitoring>.
        <Return> an <error-response> for the <request>.
    }
}
```

---

### 4. Conditions

#### 4.1 Condition Syntax

```ebnf
condition        = condition_or ;

condition_or     = condition_and , { "or" , condition_and } ;

condition_and    = condition_not , { "and" , condition_not } ;

condition_not    = [ "not" ] , condition_primary ;

condition_primary = comparison
                  | existence_check
                  | type_check
                  | "(" , condition , ")" ;

comparison       = expression , comparison_op , expression ;

comparison_op    = "is" | "is not" | "==" | "!=" 
                 | "<" | ">" | "<=" | ">=" 
                 | "equals" | "contains" | "matches" ;

existence_check  = expression , "exists"
                 | expression , "is" , "defined"
                 | expression , "is" , "null"
                 | expression , "is" , "empty" ;

type_check       = expression , "is" , [ "a" | "an" ] , type_name ;
```

#### 4.2 Condition Examples

```
// Simple comparisons
<user: age> >= 18
<status> is "active"
<count> is not 0
<price> < 100.00

// Existence checks
<user: email> exists
<optional-field> is defined
<list> is not empty
<value> is null

// Type checks
<input> is a Number
<data> is a List
<user> is an Admin

// Logical combinations
<user: age> >= 18 and <user: verified> is true
<role> is "admin" or <role> is "moderator"
not <account: suspended>

// Complex conditions
(<user: role> is "admin" or <user: is-owner> is true) and <resource: public> is false
```

---

### 5. Definite Assignment

#### 5.1 Rules

Variables defined in conditional blocks have **conditional availability**:

| Pattern | Variable Availability |
|---------|----------------------|
| Defined in both `then` and `else` | Definitely available after |
| Defined only in `then` | Conditionally available |
| Defined only in `else` | Conditionally available |
| Match with `otherwise` covering all | Available if in all branches |

#### 5.2 Examples

```
// VALID: Defined in both branches
if <condition> then {
    <Set> the <result> to "yes".
} else {
    <Set> the <result> to "no".
}
<Use> the <result> in the <response>.  // OK: result always defined

// WARNING: Conditionally defined
if <condition> then {
    <Set> the <optional> to "value".
}
<Use> the <optional> in the <response>.  // Warning: may be undefined

// VALID with guard
if <condition> then {
    <Set> the <value> to "something".
}
if <value> is defined then {
    <Use> the <value> in the <operation>.  // OK: guarded
}
```

#### 5.3 All-Paths Return

When using `<Return>` or `<Throw>`, all paths must terminate:

```
// VALID: All paths return
if <valid> then {
    <Return> an <OK> for the <request>.
} else {
    <Return> an <Error> for the <request>.
}

// INVALID: Missing return path
if <valid> then {
    <Return> an <OK> for the <request>.
}
// Error: Not all paths return a value
```

---

### 6. Short-Circuit Evaluation

Logical operators use short-circuit evaluation:

```
// <expensive-check> only evaluated if <quick-check> is true
if <quick-check> is true and <expensive-check> is true then {
    ...
}

// <fallback> only evaluated if <primary> is null
<Set> the <value> to <primary> or <fallback>.
```

---

### 7. Control Flow Graph

The compiler builds a CFG for analysis:

```
                    ┌─────────────┐
                    │   Entry     │
                    └──────┬──────┘
                           │
                    ┌──────▼──────┐
                    │  Evaluate   │
                    │  Condition  │
                    └──────┬──────┘
                           │
              ┌────────────┴────────────┐
         true │                         │ false
       ┌──────▼──────┐           ┌──────▼──────┐
       │ Then Block  │           │ Else Block  │
       │             │           │ (optional)  │
       └──────┬──────┘           └──────┬──────┘
              │                         │
              └────────────┬────────────┘
                           │
                    ┌──────▼──────┐
                    │    Join     │
                    └──────┬──────┘
                           │
                    ┌──────▼──────┐
                    │    Exit     │
                    └─────────────┘
```

---

### 8. Complete Grammar Extension

```ebnf
(* Extends ARO-0001, 0002, 0003 *)

(* Updated Statement *)
statement = aro_statement 
          | guarded_statement
          | publish_statement 
          | require_statement
          | conditional_block
          | match_expression ;

(* Guarded Statement *)
guarded_statement = action_clause , result_clause , object_clause , 
                    "when" , condition , "." ;

(* Conditional Block *)
conditional_block = "if" , condition , "then" , block ,
                    { else_if_clause } ,
                    [ else_clause ] ;

else_if_clause    = "else" , "if" , condition , "then" , block ;
else_clause       = "else" , block ;

block             = "{" , { statement } , "}" ;

(* Match Expression *)
match_expression  = "match" , variable_reference , "{" ,
                    { case_clause } ,
                    [ otherwise_clause ] ,
                    "}" ;

case_clause       = "case" , pattern , [ guard_clause ] , block ;
guard_clause      = "where" , condition ;
otherwise_clause  = "otherwise" , block ;

pattern           = variable_reference
                  | literal
                  | "_" ;

(* Conditions *)
condition         = condition_or ;
condition_or      = condition_and , { "or" , condition_and } ;
condition_and     = condition_not , { "and" , condition_not } ;
condition_not     = [ "not" ] , condition_atom ;
condition_atom    = comparison | existence | type_check 
                  | "(" , condition , ")" ;

comparison        = expression , comp_op , expression ;
comp_op           = "is" | "is" , "not" | "==" | "!=" 
                  | "<" | ">" | "<=" | ">=" 
                  | "equals" | "contains" | "matches" ;

existence         = expression , ( "exists" | "is" , "defined" 
                                 | "is" , "null" | "is" , "empty" ) ;

type_check        = expression , "is" , [ "a" | "an" ] , type_name ;

(* New Keywords *)
keyword          += "if" | "then" | "else" | "when" 
                  | "match" | "case" | "otherwise" | "where"
                  | "and" | "or" | "not"
                  | "exists" | "defined" | "null" | "empty"
                  | "true" | "false" ;
```

---

### 9. Complete Examples

#### Authentication with All Constructs

```
(User Authentication: Security and Access Control) {
    <Require> <request> from framework.
    <Require> <user-repository> from framework.
    
    // Extract credentials
    <Extract> the <username> from the <request: body>.
    <Extract> the <password> from the <request: body>.
    
    // Validate input
    <Return> a <BadRequest: error> for the <request> 
        when <username> is empty or <password> is empty.
    
    // Look up user
    <Retrieve> the <user> from the <user-repository>.
    
    // Handle missing user
    if <user> is null then {
        <Log> the <failed-login: attempt> for the <username>.
        <Return> an <Unauthorized: error> for the <request>.
    }
    
    // Check account status
    match <user: status> {
        case "locked" {
            <Return> an <AccountLocked: error> for the <request>.
        }
        case "pending" {
            <Send> the <verification-email> to the <user: email>.
            <Return> a <PendingVerification: status> for the <request>.
        }
        case "active" {
            // Continue with password check
        }
        otherwise {
            <Return> an <InvalidAccountStatus: error> for the <request>.
        }
    }
    
    // Verify password
    <Compute> the <password-hash> for the <password>.
    
    if <password-hash> is <user: password-hash> then {
        <Create> the <session-token> for the <user>.
        <Log> the <successful-login> for the <user>.
        <Return> an <OK: status> with the <session-token>.
    } else {
        <Increment> the <failed-attempts> for the <user>.
        
        if <failed-attempts> >= 5 then {
            <Lock> the <user: account> for the <security-policy>.
            <Notify> the <user> about the <account-locked>.
        }
        
        <Return> an <Unauthorized: error> for the <request>.
    }
}
```

---

## Implementation Notes

### AST Nodes

```swift
public struct GuardedStatement: Statement {
    let action: Action
    let result: QualifiedNoun
    let object: ObjectClause
    let condition: Condition
    let span: SourceSpan
}

public struct ConditionalBlock: Statement {
    let condition: Condition
    let thenBlock: [Statement]
    let elseIfClauses: [(Condition, [Statement])]
    let elseBlock: [Statement]?
    let span: SourceSpan
}

public struct MatchExpression: Statement {
    let subject: QualifiedNoun
    let cases: [CaseClause]
    let otherwise: [Statement]?
    let span: SourceSpan
}

public struct CaseClause {
    let pattern: Pattern
    let guard: Condition?
    let body: [Statement]
    let span: SourceSpan
}

public enum Pattern {
    case value(QualifiedNoun)
    case literal(Literal)
    case wildcard
}

public indirect enum Condition {
    case comparison(Expression, ComparisonOp, Expression)
    case existence(Expression, ExistenceKind)
    case typeCheck(Expression, TypeName)
    case and(Condition, Condition)
    case or(Condition, Condition)
    case not(Condition)
    case grouped(Condition)
}
```

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-01 | Initial specification |
