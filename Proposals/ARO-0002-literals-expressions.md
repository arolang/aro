# ARO-0002: Literals and Expressions

* Proposal: ARO-0002
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001

## Abstract

This proposal introduces literal values and expressions to ARO, enabling conditions, comparisons, and computed values within specifications.

## Motivation

The core language (ARO-0001) only allows references to variables. Real-world specifications need:

1. **Literal values**: Numbers, strings, booleans for comparisons
2. **Expressions**: Combining values with operators
3. **Interpolation**: Embedding values in strings

## Proposed Solution

### 1. Literal Types

#### 1.1 String Literals

```ebnf
string_literal = '"' , { string_char } , '"' 
               | "'" , { string_char } , "'" ;

string_char    = any_char - ('"' | "'" | "\\" | newline)
               | escape_sequence ;

escape_sequence = "\\" , ( "n" | "r" | "t" | "\\" | '"' | "'" | "0" ) 
                | "\\u{" , hex_digit , { hex_digit } , "}" ;
```

**Examples:**
```
"hello world"
'single quotes also work'
"line one\nline two"
"unicode: \u{1F600}"
```

#### 1.2 Number Literals

```ebnf
number_literal  = integer_literal | float_literal ;

integer_literal = [ "-" ] , digit , { digit } 
                | "0x" , hex_digit , { hex_digit }
                | "0b" , binary_digit , { binary_digit } ;

float_literal   = [ "-" ] , digit , { digit } , "." , digit , { digit } , 
                  [ exponent ] ;

exponent        = ( "e" | "E" ) , [ "+" | "-" ] , digit , { digit } ;

hex_digit       = digit | "a" ... "f" | "A" ... "F" ;
binary_digit    = "0" | "1" ;
```

**Examples:**
```
42
-17
3.14159
2.5e10
0xFF
0b1010
```

#### 1.3 Boolean Literals

```ebnf
boolean_literal = "true" | "false" ;
```

#### 1.4 Null Literal

```ebnf
null_literal = "null" | "nil" | "none" ;
```

#### 1.5 Collection Literals

```ebnf
list_literal  = "[" , [ expression , { "," , expression } ] , "]" ;
map_literal   = "{" , [ map_entry , { "," , map_entry } ] , "}" ;
map_entry     = ( string_literal | identifier ) , ":" , expression ;
```

**Examples:**
```
[1, 2, 3]
["apple", "banana", "cherry"]
{ name: "John", age: 30 }
{ "key-with-hyphen": true }
```

---

### 2. Expressions

#### 2.1 Primary Expressions

```ebnf
primary_expression = literal
                   | variable_reference
                   | grouped_expression
                   | collection_literal ;

literal            = string_literal 
                   | number_literal 
                   | boolean_literal 
                   | null_literal ;

variable_reference = "<" , qualified_noun , ">" ;

grouped_expression = "(" , expression , ")" ;
```

#### 2.2 Member Access

```ebnf
member_expression = primary_expression , { member_access } ;

member_access     = "." , identifier
                  | "[" , expression , "]" ;
```

**Examples:**
```
<user>.name
<user>.address.city
<items>[0]
<map>["key"]
```

#### 2.3 Operators

##### Comparison Operators

```ebnf
comparison_op = "==" | "!=" | "is" | "is not"
              | "<" | ">" | "<=" | ">=" ;
```

| Operator | Meaning |
|----------|---------|
| `==`, `is` | Equal |
| `!=`, `is not` | Not equal |
| `<` | Less than |
| `>` | Greater than |
| `<=` | Less than or equal |
| `>=` | Greater than or equal |

##### Logical Operators

```ebnf
logical_op = "and" | "or" | "not" ;
```

##### Arithmetic Operators

```ebnf
arithmetic_op = "+" | "-" | "*" | "/" | "%" ;
```

##### String Operators

```ebnf
string_op = "++" ;  (* concatenation *)
```

#### 2.4 Expression Grammar

```ebnf
expression       = logical_or ;

logical_or       = logical_and , { "or" , logical_and } ;

logical_and      = logical_not , { "and" , logical_not } ;

logical_not      = [ "not" ] , comparison ;

comparison       = arithmetic , [ comparison_op , arithmetic ] ;

arithmetic       = term , { ( "+" | "-" ) , term } ;

term             = factor , { ( "*" | "/" | "%" ) , factor } ;

factor           = [ "-" ] , member_expression ;
```

#### 2.5 Operator Precedence

| Precedence | Operators | Associativity |
|------------|-----------|---------------|
| 1 (highest) | `.` `[]` | Left |
| 2 | unary `-` `not` | Right |
| 3 | `*` `/` `%` | Left |
| 4 | `+` `-` `++` | Left |
| 5 | `<` `>` `<=` `>=` | Left |
| 6 | `==` `!=` `is` `is not` | Left |
| 7 | `and` | Left |
| 8 (lowest) | `or` | Left |

---

### 3. String Interpolation

Embed expressions within strings:

```ebnf
interpolated_string = '"' , { string_char | interpolation } , '"' ;

interpolation = "${" , expression , "}" 
              | "$" , identifier ;
```

**Examples:**
```
"Hello, ${<user>.name}!"
"Total: $total items"
"Result: ${<count> + 1}"
```

---

### 4. Existence and Type Checks

#### 4.1 Existence Check

```ebnf
existence_check = expression , "exists"
                | expression , "is" , "defined" ;
```

**Example:**
```
<user: email> exists
<optional-field> is defined
```

#### 4.2 Type Check

```ebnf
type_check = expression , "is" , type_name
           | expression , "is" , "a" , type_name
           | expression , "is" , "an" , type_name ;

type_name  = "String" | "Number" | "Boolean" | "List" | "Map" | identifier ;
```

**Example:**
```
<value> is a Number
<items> is a List
<user> is an Admin
```

#### 4.3 Pattern Matching

```ebnf
contains_check = expression , "contains" , expression ;
matches_check  = expression , "matches" , pattern ;
pattern        = string_literal ;  (* regex pattern *)
```

**Examples:**
```
<roles> contains "admin"
<email> matches ".*@company\\.com"
```

---

### 5. Usage in ARO Statements

Expressions can appear in:

#### 5.1 Object Clauses (as values)

```
<Set> the <timeout> to 30.
<Set> the <name> to "default".
<Set> the <enabled> to true.
```

#### 5.2 With Computed Values

```
<Compute> the <total> from <price> * <quantity>.
<Compute> the <full-name> from <first-name> ++ " " ++ <last-name>.
```

#### 5.3 In Conditions (see ARO-0004)

```
<Return> an <OK> for the <request> when <user>.role == "admin".
```

---

### 6. Complete Grammar Extension

```ebnf
(* Extends ARO-0001 *)

(* Literals *)
literal             = string_literal 
                    | number_literal 
                    | boolean_literal 
                    | null_literal
                    | list_literal
                    | map_literal ;

string_literal      = '"' , { string_content } , '"' ;
string_content      = string_char | interpolation ;
string_char         = any - ( '"' | "\\" | "${" ) | escape_seq ;
escape_seq          = "\\" , ( "n" | "r" | "t" | "\\" | '"' | "$" ) ;
interpolation       = "${" , expression , "}" ;

number_literal      = integer | float ;
integer             = [ "-" ] , digit , { digit } ;
float               = [ "-" ] , digit , { digit } , "." , digit , { digit } ;

boolean_literal     = "true" | "false" ;
null_literal        = "null" ;

list_literal        = "[" , [ expr_list ] , "]" ;
map_literal         = "{" , [ entry_list ] , "}" ;
expr_list           = expression , { "," , expression } ;
entry_list          = map_entry , { "," , map_entry } ;
map_entry           = ( string_literal | identifier ) , ":" , expression ;

(* Expressions *)
expression          = logical_or ;
logical_or          = logical_and , { "or" , logical_and } ;
logical_and         = logical_not , { "and" , logical_not } ;
logical_not         = [ "not" ] , comparison ;
comparison          = additive , [ comp_op , additive ] ;
additive            = multiplicative , { add_op , multiplicative } ;
multiplicative      = unary , { mult_op , unary } ;
unary               = [ "-" | "not" ] , postfix ;
postfix             = primary , { "." , identifier | "[" , expression , "]" } ;
primary             = literal 
                    | variable_ref 
                    | "(" , expression , ")" ;

variable_ref        = "<" , qualified_noun , ">" ;

comp_op             = "==" | "!=" | "<" | ">" | "<=" | ">=" 
                    | "is" | "is" , "not" ;
add_op              = "+" | "-" | "++" ;
mult_op             = "*" | "/" | "%" ;

(* Type and Existence *)
existence_expr      = expression , "exists" ;
type_expr           = expression , "is" , [ "a" | "an" ] , type_name ;
type_name           = "String" | "Number" | "Boolean" | "List" | "Map" 
                    | identifier ;
```

---

## Examples

### Using Literals in Statements

```
(Configuration: System Setup) {
    <Set> the <max-retries> to 3.
    <Set> the <timeout: seconds> to 30.5.
    <Set> the <debug-mode> to false.
    <Set> the <api-endpoint> to "https://api.example.com".
    <Set> the <allowed-origins> to ["localhost", "example.com"].
    <Set> the <config> to { 
        timeout: 30,
        retries: 3,
        debug: false 
    }.
}
```

### Using Expressions

```
(Order Processing: E-Commerce) {
    <Extract> the <items> from the <shopping-cart>.
    <Compute> the <subtotal> from <items>.map(item => item.price * item.quantity).sum().
    <Compute> the <tax> from <subtotal> * 0.08.
    <Compute> the <total> from <subtotal> + <tax>.
    <Compute> the <discount> from <total> * 0.1 when <is-member> is true.
    <Set> the <message> to "Your total is $${<total>}".
}
```

### String Interpolation

```
(Notification: Communication) {
    <Compose> the <greeting> from "Hello, ${<user>.firstName}!".
    <Compose> the <summary> from "You have ${<count>} new messages".
    <Send> the <email: body> to the <user: address>.
}
```

---

## Implementation Notes

### Parser Changes

1. Add `LiteralExpression` AST node
2. Add `BinaryExpression` AST node
3. Add `UnaryExpression` AST node
4. Add `MemberExpression` AST node
5. Extend lexer for new token types

### Type Inference

The semantic analyzer should infer types:

| Literal | Inferred Type |
|---------|---------------|
| `"string"` | `String` |
| `42` | `Integer` |
| `3.14` | `Float` |
| `true`/`false` | `Boolean` |
| `null` | `Null` |
| `[...]` | `List<T>` |
| `{...}` | `Map<String, T>` |

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2025-12 | Initial specification |
