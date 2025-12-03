# ARO-0004: Conditional Branching

* Proposal: ARO-0004
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0002, ARO-0003

## Abstract

This proposal introduces conditional execution to ARO using two constructs: guarded statements (`when`) and match expressions (`match/case`).

## Motivation

Real-world business logic requires conditional execution:

- Different paths based on user roles
- Validation results determining next steps
- Error handling for edge cases
- Multiple outcomes based on input

## Proposed Solution

Two complementary constructs:

1. **Guarded Statements** (`when`): Single-statement conditions
2. **Match Expressions** (`match/case/otherwise`): Pattern-based dispatch

---

### 1. Guarded Statements (When Clause)

#### 1.1 Syntax

```ebnf
guarded_statement = aro_statement_base , "when" , condition , "." ;
```

**Format:**
```
<Action> the <result> preposition the <object> when <condition>.
```

#### 1.2 Examples

```aro
(* Only return OK when authentication is valid *)
<Return> an <OK: status> for the <user> when <authentication> is <valid>.

(* Only send notification when user has email *)
<Send> the <notification> to the <user: email> when <user: email> exists.

(* Throw error when user not found *)
<Throw> a <NotFoundError> for the <user> when <user: record> is null.

(* Log admin access *)
<Log> the <admin-access> for the <audit> when <user: role> == "admin".
```

#### 1.3 Semantics

- The statement executes **only if** the condition is true
- If false, execution continues to the next statement
- No implicit else branch

---

### 2. Match Expressions

#### 2.1 Syntax

```ebnf
match_expression = "match" , "<" , qualified_noun , ">" , "{" ,
                   { case_clause } ,
                   [ otherwise_clause ] ,
                   "}" ;

case_clause      = "case" , pattern , [ "where" , condition ] , "{" , { statement } , "}" ;

otherwise_clause = "otherwise" , "{" , { statement } , "}" ;

pattern          = literal | "<" , qualified_noun , ">" | "_" ;
```

**Format:**
```aro
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

#### 2.2 Examples

##### Simple Value Matching

```aro
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

```aro
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
    otherwise {
        <Redirect> the <user> to the <subscription-page>.
    }
}
```

##### Status Code Handling

```aro
match <status-code> {
    case 200 {
        <Parse> the <response: body> from the <http-response>.
        <Return> the <data> for the <request>.
    }
    case 404 {
        <Return> a <NotFound: error> for the <request>.
    }
    case 500 {
        <Log> the <server-error> for the <monitoring>.
        <Return> a <ServerError> for the <request>.
    }
    otherwise {
        <Return> an <UnknownError> for the <request>.
    }
}
```

---

### 3. Conditions

#### 3.1 Condition Syntax

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

#### 3.2 Condition Examples

```aro
(* Simple comparisons *)
<user: age> >= 18
<status> is "active"
<count> is not 0
<price> < 100.00

(* Existence checks *)
<user: email> exists
<optional-field> is defined
<list> is not empty
<value> is null

(* Type checks *)
<input> is a Number
<data> is a List
<user> is an Admin

(* Logical combinations *)
<user: age> >= 18 and <user: verified> is true
<role> is "admin" or <role> is "moderator"
not <account: suspended>

(* Complex conditions *)
(<user: role> is "admin" or <user: is-owner> is true) and <resource: public> is false
```

---

### 4. Complete Grammar Extension

```ebnf
(* Extends ARO-0001, 0002, 0003 *)

(* Updated Statement *)
statement = aro_statement
          | guarded_statement
          | publish_statement
          | require_statement
          | match_expression ;

(* Guarded Statement *)
guarded_statement = action_clause , result_clause , object_clause ,
                    "when" , condition , "." ;

(* Match Expression *)
match_expression  = "match" , variable_reference , "{" ,
                    { case_clause } ,
                    [ otherwise_clause ] ,
                    "}" ;

case_clause       = "case" , pattern , [ guard_clause ] , "{" , { statement } , "}" ;
guard_clause      = "where" , condition ;
otherwise_clause  = "otherwise" , "{" , { statement } , "}" ;

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

(* Keywords *)
keyword          += "when" | "match" | "case" | "otherwise" | "where"
                  | "and" | "or" | "not"
                  | "exists" | "defined" | "null" | "empty"
                  | "true" | "false" ;
```

---

### 5. Complete Example

```aro
(User Authentication: Security) {
    <Require> the <request> from the <framework>.
    <Require> the <user-repository> from the <framework>.

    (* Extract credentials *)
    <Extract> the <username> from the <request: body>.
    <Extract> the <password> from the <request: body>.

    (* Validate input - guarded return *)
    <Return> a <BadRequest: error> for the <request>
        when <username> is empty or <password> is empty.

    (* Look up user *)
    <Retrieve> the <user> from the <user-repository>.

    (* Handle user not found - guarded return *)
    <Log> the <failed-login: attempt> for the <username> when <user> is null.
    <Return> an <Unauthorized: error> for the <request> when <user> is null.

    (* Check account status with match *)
    match <user: status> {
        case "locked" {
            <Return> an <AccountLocked: error> for the <request>.
        }
        case "pending" {
            <Send> the <verification-email> to the <user: email>.
            <Return> a <PendingVerification: status> for the <request>.
        }
        case "active" {
            (* Verify password *)
            <Compute> the <password-hash> for the <password>.

            match <password-hash> {
                case <user: password-hash> {
                    <Create> the <session-token> for the <user>.
                    <Log> the <successful-login> for the <user>.
                    <Return> an <OK: status> with the <session-token>.
                }
                otherwise {
                    <Increment> the <failed-attempts> for the <user>.
                    <Lock> the <user: account> for the <security-policy>
                        when <failed-attempts> >= 5.
                    <Return> an <Unauthorized: error> for the <request>.
                }
            }
        }
        otherwise {
            <Return> an <InvalidAccountStatus: error> for the <request>.
        }
    }
}
```

---

## Implementation Notes

### AST Nodes

```swift
public struct MatchExpression: Statement {
    let subject: QualifiedNoun
    let cases: [CaseClause]
    let otherwise: [Statement]?
    let span: SourceSpan
}

public struct CaseClause: Sendable {
    let pattern: Pattern
    let guardCondition: (any Expression)?
    let body: [Statement]
    let span: SourceSpan
}

public enum Pattern: Sendable {
    case literal(LiteralValue)
    case variable(QualifiedNoun)
    case wildcard
}
```

### Guarded Statements

Guarded statements extend `AROStatement` with an optional `when` condition:

```swift
public struct AROStatement: Statement {
    // ... existing fields ...
    let whenCondition: (any Expression)?  // ARO-0004
}
```

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-01 | Initial specification |
| 2.0 | 2025-12 | Simplified: removed if-else, kept match-case and when |
