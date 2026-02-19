# ARO-0001: Language Fundamentals

* Proposal: ARO-0001
* Author: ARO Language Team
* Status: **Implemented**

## Abstract

This proposal defines the foundational syntax and semantics of ARO (Action-Result-Object), a declarative domain-specific language for expressing business features as structured statements. ARO combines natural language readability with formal precision, enabling specifications that read like English sentences while remaining machine-parseable.

## Introduction

ARO follows the Feature Driven Development methodology where business features are expressed as Action-Result-Object statements. Each statement describes what action to perform, what result to produce, and what object to operate upon.

### Design Goals

1. **Readability**: Specifications read like natural English sentences
2. **Formality**: Precise syntax enables machine parsing and code generation
3. **Simplicity**: Minimal syntax with maximum expressiveness
4. **Traceability**: Direct mapping between specification and implementation

### Program Structure

An ARO program consists of feature sets, each containing statements:

```
+----------------------------------------------------------+
|                    ARO Program                            |
|                                                           |
|  +------------------------+  +------------------------+   |
|  |  Feature Set           |  |  Feature Set           |   |
|  |  (Name: Activity)      |  |  (Name: Activity)      |   |
|  |                        |  |                        |   |
|  |  +------------------+  |  |  +------------------+  |   |
|  |  | Statement 1      |  |  |  | Statement 1      |  |   |
|  |  +------------------+  |  |  +------------------+  |   |
|  |  | Statement 2      |  |  |  | Statement 2      |  |   |
|  |  +------------------+  |  |  +------------------+  |   |
|  |  | ...              |  |  |  | ...              |  |   |
|  |  +------------------+  |  |  +------------------+  |   |
|  +------------------------+  +------------------------+   |
+----------------------------------------------------------+
```

---

## Lexical Structure

### 1. Character Set

ARO source files are encoded in UTF-8:

```ebnf
letter          = "A" ... "Z" | "a" ... "z" ;
digit           = "0" ... "9" ;
alphanumeric    = letter | digit ;
whitespace      = " " | "\t" | "\n" | "\r" ;
```

### 2. Identifiers

Identifiers name variables, feature sets, and other program elements:

```ebnf
identifier          = letter , { alphanumeric } ;
compound_identifier = identifier , { "-" , identifier } ;
```

**Examples:**
```
user
incoming-request
password-hash
OAuth2-token
```

**Conventions:**
- Use lowercase with hyphens for multi-word identifiers
- Start with a letter (not a number)
- Case-sensitive: `User` and `user` are different identifiers

### 3. Keywords

Reserved words:
```
as          (* publish statement *)
true false  (* boolean literals *)
null        (* null literal *)
and or not  (* logical operators *)
is          (* type/equality check *)
exists      (* existence check *)
contains    (* containment check *)
matches     (* pattern matching *)
```

### 4. Articles

English articles enhance readability:

```ebnf
article = "a" | "an" | "the" ;
```

Articles are syntactic elements for readability and do not affect semantics.

### 5. Prepositions

Prepositions connect ARO components and carry semantic meaning:

```ebnf
preposition = "from" | "for" | "against" | "to" | "into"
            | "via" | "with" | "on" | "at" | "by" ;
```

| Preposition | Semantic Meaning |
|-------------|------------------|
| `from` | Source/origin (external input) |
| `for` | Purpose/target |
| `against` | Comparison target |
| `to` | Destination |
| `into` | Transformation target |
| `via` | Through/using |
| `with` | Accompaniment/using |
| `on` | Location/attachment (e.g., "on port 8080") |
| `at` | Location/path (e.g., "at the path") |
| `by` | Delimiter/criterion (e.g., "by /pattern/") |

### 6. Delimiters

```ebnf
left_paren   = "(" ;
right_paren  = ")" ;
left_brace   = "{" ;
right_brace  = "}" ;
left_angle   = "<" ;
right_angle  = ">" ;
left_bracket = "[" ;
right_bracket = "]" ;
colon        = ":" ;
dot          = "." ;
hyphen       = "-" ;
comma        = "," ;
```

### 7. Comments

ARO supports two comment styles:

```ebnf
block_comment = "(*" , { any_character } , "*)" ;
line_comment  = "//" , { any_character - newline } , newline ;
```

**Examples:**
```aro
(* This is a block comment
   spanning multiple lines *)

// This is a line comment
```

### 8. Whitespace

Whitespace separates tokens but is otherwise insignificant. Multiple whitespace characters are equivalent to one.

---

## ARO Statement Syntax

The fundamental construct of ARO is the Action-Result-Object statement:

```ebnf
aro_statement = action_clause , result_clause , object_clause , "." ;

action_clause = "<" , action_verb , ">" ;
result_clause = [ article ] , "<" , qualified_noun , ">" ;
object_clause = preposition , [ article ] , "<" , qualified_noun , ">" ;
```

**Syntax:**
```
Action [article] <result: qualifier> preposition [article] <object: qualifier>.
```

**Example:**
```aro
Extract the <user: identifier> from the <incoming-request: parameters>.
```

### Statement Components

| Component | Description |
|-----------|-------------|
| Action | Verb describing what to do |
| Result | What is produced (the output) |
| Object | What is operated upon (the input) |

### Result and Object Descriptors

Both result and object use the qualified noun syntax:

```ebnf
qualified_noun = noun_base , [ ":" , specifier_list ] ;
noun_base      = compound_identifier ;
specifier_list = specifier , { specifier } ;
specifier      = compound_identifier ;
```

**Syntax:**
```
<base: specifier1 specifier2 ...>
```

**Examples:**
```
<user>                          (* simple noun *)
<user: identifier>              (* with one specifier *)
<user: first-name last-name>    (* with multiple specifiers *)
<incoming-request: parameters>  (* compound base with specifier *)
```

**Semantics:**
- The `base` identifies the primary concept (becomes the variable name)
- Specifiers refine, qualify, or select an operation for the base

### Action Classification

Actions are classified by data flow direction:

#### Request Actions (External -> Internal)

Fetch data from external sources:

| Verb | Description |
|------|-------------|
| `Extract` | Pull data from a structured source |
| `Parse` | Interpret structured data |
| `Retrieve` | Fetch from a repository |
| `Fetch` | Get from a remote source |
| `Read` | Read from storage |
| `Receive` | Accept incoming data |
| `Get` | General acquisition |
| `Load` | Load into memory |

#### Own Actions (Internal -> Internal)

Process data internally:

| Verb | Description |
|------|-------------|
| `Compute` | Calculate a value |
| `Validate` | Check validity |
| `Compare` | Compare values |
| `Transform` | Convert format |
| `Filter` | Select subset |
| `Sort` | Order elements |
| `Merge` | Combine data |
| `Create` | Instantiate new |
| `Update` | Modify existing |
| `Delete` | Remove |

#### Response Actions (Internal -> External)

Output data externally:

| Verb | Description |
|------|-------------|
| `Return` | Send as response |
| `Throw` | Raise an error |
| `Send` | Transmit data |
| `Emit` | Publish event |
| `Write` | Write to storage |
| `Store` | Persist data |
| `Log` | Record for audit |
| `Notify` | Alert user/system |

#### Export Actions

Make available to other features:

| Verb | Description |
|------|-------------|
| `Publish` | Export variable |

---

## Feature Sets

A feature set groups related statements under a name and business activity:

```ebnf
feature_set = "(" , feature_set_name , ":" , business_activity , ")" ,
              "{" , { statement } , "}" ;

feature_set_name   = identifier_sequence ;
business_activity  = identifier_sequence ;
identifier_sequence = identifier , { identifier } ;
```

**Syntax:**
```aro
(Feature Set Name: Business Activity) {
    <statements>
}
```

**Example:**
```aro
(User Authentication: Security and Access Control) {
    Extract the <credentials> from the <request: body>.
    Validate the <credentials> for the <authentication>.
    Return an <OK: status> for the <authentication>.
}
```

### Business Activities and Triggers

The business activity determines how the feature set is triggered:

| Business Activity Pattern | Triggered By |
|---------------------------|--------------|
| `operationId` (e.g., `listUsers`) | HTTP route match via OpenAPI contract |
| `{EventName} Handler` | Custom domain events |
| `{repository-name} Observer` | Repository changes |
| `File Event Handler` | File system events |
| `Socket Event Handler` | Socket events |

### Application Lifecycle

Special feature sets manage application lifecycle:

```aro
(* Entry point - exactly one per application *)
(Application-Start: My App) {
    Log "Starting application..." to the <console>.
    Start the <http-server> with <contract>.
    Return an <OK: status> for the <startup>.
}

(* Exit handler for graceful shutdown - optional *)
(Application-End: Success) {
    Log "Shutting down..." to the <console>.
    Stop the <http-server> with <application>.
    Return an <OK: status> for the <shutdown>.
}

(* Exit handler for errors - optional *)
(Application-End: Error) {
    Extract the <error> from the <shutdown: error>.
    Log "Error occurred" to the <console>.
    Return an <OK: status> for the <error-handling>.
}
```

---

## Literals

### String Literals

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

### Number Literals

```ebnf
number_literal  = integer_literal | float_literal ;

integer_literal = [ "-" ] , digit , { digit }
                | "0x" , hex_digit , { hex_digit }
                | "0b" , binary_digit , { binary_digit } ;

float_literal   = [ "-" ] , digit , { digit } , "." , digit , { digit } ,
                  [ exponent ] ;

exponent        = ( "e" | "E" ) , [ "+" | "-" ] , digit , { digit } ;
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

### Boolean Literals

```ebnf
boolean_literal = "true" | "false" ;
```

### Null Literal

```ebnf
null_literal = "null" ;
```

### Array Literals

```ebnf
array_literal = "[" , [ expression , { "," , expression } ] , "]" ;
```

**Examples:**
```
[1, 2, 3]
["apple", "banana", "cherry"]
[]
```

### Object Literals

```ebnf
object_literal = "{" , [ entry , { "," , entry } ] , "}" ;
entry          = ( string_literal | identifier ) , ":" , expression ;
```

**Examples:**
```
{ name: "John", age: 30 }
{ "key-with-hyphen": true }
{}
```

### String Interpolation

Embed expressions within strings:

```ebnf
interpolated_string = '"' , { string_char | interpolation } , '"' ;
interpolation       = "${" , expression , "}" ;
```

**Examples:**
```
"Hello, ${<user>.name}!"
"Total: ${<count>} items"
"Result: ${<price> * <quantity>}"
```

---

## Expressions and Operators

### Primary Expressions

```ebnf
primary_expression = literal
                   | variable_reference
                   | grouped_expression
                   | array_literal
                   | object_literal ;

variable_reference = "<" , qualified_noun , ">" ;
grouped_expression = "(" , expression , ")" ;
```

### Member Access

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

### Arithmetic Operators

```ebnf
arithmetic_op = "+" | "-" | "*" | "/" | "%" ;
```

| Operator | Description |
|----------|-------------|
| `+` | Addition |
| `-` | Subtraction |
| `*` | Multiplication |
| `/` | Division |
| `%` | Modulo |

### Comparison Operators

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

### Logical Operators

```ebnf
logical_op = "and" | "or" | "not" ;
```

| Operator | Description |
|----------|-------------|
| `and` | Logical AND |
| `or` | Logical OR |
| `not` | Logical NOT |

### String Concatenation

```ebnf
string_concat = "++" ;
```

### Operator Precedence

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

### Existence and Type Checks

```ebnf
existence_check = expression , "exists"
                | expression , "is" , "defined" ;

type_check = expression , "is" , [ "a" | "an" ] , type_name ;
type_name  = "String" | "Number" | "Boolean" | "List" | "Map" | identifier ;
```

**Examples:**
```
<user: email> exists
<optional-field> is defined
<value> is a Number
<items> is a List
```

### Pattern Matching

```ebnf
contains_check = expression , "contains" , expression ;
matches_check  = expression , "matches" , pattern ;
```

**Examples:**
```
<roles> contains "admin"
<email> matches ".*@company\\.com"
```

---

## Variable Scoping

### Scope Hierarchy

ARO has two scope levels:

```
+---------------------------------------------------------------+
|                        Global Scope                            |
|            (external dependencies, published variables)        |
|                                                                |
|  +---------------------------+  +---------------------------+  |
|  | Feature Set Scope         |  | Feature Set Scope         |  |
|  | (local variables)         |  | (local variables)         |  |
|  |                           |  |                           |  |
|  | - extracted values        |  | - extracted values        |  |
|  | - computed results        |  | - computed results        |  |
|  | - created objects         |  | - created objects         |  |
|  +---------------------------+  +---------------------------+  |
+---------------------------------------------------------------+
```

### Visibility Levels

| Visibility | Description | Accessible From |
|------------|-------------|-----------------|
| `internal` | Default, private to feature set | Same feature set only |
| `published` | Exported via `<Publish>` | Feature sets in same business activity |
| `external` | Provided by runtime/environment | Any feature set |

### Variable Definition

Variables are implicitly defined by ARO statements. The **result** of an action creates a new variable:

```aro
Extract the <user> from the <request>.
           ^^^^
           Creates variable "user" with visibility "internal"
```

**Rules:**
1. The result of an ARO statement creates a new variable
2. The variable is bound to the value produced by the action
3. Default visibility is `internal`
4. Variables are **immutable** - once bound, they cannot be rebound

### Definition Semantics by Action Type

| Action Type | Result Variable | Object Variable |
|-------------|-----------------|-----------------|
| Request | Creates new | Must exist (external or internal) |
| Own | Creates new | Must exist (internal) |
| Response | - (no variable) | Must exist |
| Export | Creates alias | Must exist |

### Publishing Variables

The Publish statement exports a variable for other feature sets:

```ebnf
publish_statement = "<Publish>" , "as" , "<" , external_name , ">" ,
                    "<" , internal_variable , ">" , "." ;
```

**Syntax:**
```aro
Publish as <external-name> <internal-variable>.
```

**Example:**
```aro
Publish as <authenticated-user> <user>.
```

**Semantics:**
1. `internal-variable` must be defined in the current feature set
2. `external-name` becomes accessible to feature sets in the same business activity
3. Both names can be used (alias created)

### Cross-Feature-Set Access

Published variables are only accessible within the **same business activity**:

```aro
(* Both feature sets share "User Management" business activity *)

(Authentication: User Management) {
    Extract the <user> from the <request>.
    Publish as <authenticated-user> <user>.
}

(Profile Service: User Management) {
    (* Can access - same business activity *)
    Retrieve the <profile> for the <authenticated-user>.
}

(Order Processing: Commerce) {
    (* ERROR - different business activity *)
    Retrieve the <orders> for the <authenticated-user>.
}
```

### Framework-Provided Variables

Some variables are provided by the runtime:

| Variable | Description |
|----------|-------------|
| `<request>` | Incoming HTTP request |
| `<context>` | Execution context |
| `<pathParameters>` | URL path parameters |
| `<environment>` | Environment variables |

---

## Variable Immutability

### Overview

Variables in ARO are **immutable**. Once bound, they cannot be rebound to a different value.

**Rationale:**
- Makes data flow explicit and traceable
- Prevents accidental mutation bugs
- Enables functional programming patterns
- Simplifies reasoning about program behavior

### Enforcement

**Compile-time**: The semantic analyzer detects duplicate bindings and reports an error:

```
error: Cannot rebind variable 'value' - variables are immutable
  at line 4, column 13

  Variable 'value' was already defined at line 1, column 13

  Hint: Create a new variable with a different name instead
  Example: Create the <value-updated> with "second"
```

**Runtime**: A safety check prevents rebinding (should never trigger if compiler works correctly):

```swift
fatalError("Runtime Error: Cannot rebind immutable variable '\(name)'")
```

### Creating Transformed Values

To transform existing values, create new variables with descriptive names:

```aro
(* ❌ Invalid - attempts to rebind *)
Create the <value> with 10.
Compute the <value> from <value> + 5.  (* Error: Cannot rebind 'value' *)

(* ✅ Valid - creates new variables *)
Create the <value> with 10.
Compute the <value-incremented> from <value> + 5.
Compute the <value-doubled> from <value-incremented> * 2.
```

Variable names should reflect their state in the transformation pipeline:
- `value` → `value-incremented` → `value-doubled`

### Loop Variables

Loop variables are immutable **per iteration**. Each iteration creates fresh bindings in a child execution context:

```aro
for each <item> in <items> {
    (* ❌ Cannot rebind loop variable within iteration *)
    Compute the <item> from <item> + 1.  (* Error *)

    (* ✅ Create new variable from loop variable *)
    Compute the <item-incremented> from <item> + 1.
}
```

**Implementation**: Loop execution creates a child `RuntimeContext` for each iteration, providing fresh variable bindings.

### Framework Variables

Variables with `_` prefix are framework-internal and exempt from immutability checks:

```aro
(* Framework variables can be rebound *)
Create the <_internal> with "first".
Create the <_internal> with "second".  (* Allowed *)
```

**User code should not use `_` prefixed names.**

---

## Qualifier-as-Name Syntax

For computed values, the qualifier determines the operation while the base becomes the variable name:

### Syntax Pattern

```
<variable-name: operation>
     ^              ^
     |              |
     |              +-- Selects what computation to perform
     +-- Name of the resulting variable
```

### Motivation

Without this feature, computing multiple values of the same type overwrites previous results:

```aro
(* Problem: Both bind to 'length', second overwrites first *)
Compute the <length> from the <first-message>.
Compute the <length> from the <second-message>.  (* overwrites! *)
```

### Solution

Use the qualifier to specify the operation:

```aro
(* Solution: Distinct variable names, same operation *)
Compute the <first-len: length> from the <first-message>.
Compute the <second-len: length> from the <second-message>.

(* Both values available for comparison *)
Compare the <first-len> against the <second-len>.
```

### Backward Compatibility

Legacy syntax continues to work when the base identifier matches a known operation:

```aro
(* Legacy syntax: 'length' is both variable name AND operation *)
Compute the <length> from the <message>.

(* New syntax: variable name and operation are separate *)
Compute the <msg-length: length> from the <message>.
```

### Supported Operations

| Action | Operations |
|--------|------------|
| Compute | `hash` (SHA256 - for checksums/data integrity only), `length`, `count`, `uppercase`, `lowercase` |
| Validate | `required`, `exists`, `nonempty`, `email`, `numeric` |
| Transform | `string`, `int`, `double`, `bool`, `json` |
| Sort | `ascending`, `descending` |

### Examples

| Statement | Variable | Operation |
|-----------|----------|-----------|
| `Compute the <msg-len: length> from <msg>.` | msg-len | length |
| `Compute the <length> from <msg>.` | length | length |
| `Compute the <upper-name: uppercase> from <name>.` | upper-name | uppercase |
| `Validate the <email-valid: email> for <input>.` | email-valid | email |

### Security Note: Hash Operation

⚠️ **WARNING**: The `hash` operation uses SHA256, which is suitable for:
- ✅ Checksums and data integrity verification
- ✅ Deterministic content hashing
- ✅ Non-security-critical hashing

**NOT suitable for:**
- ❌ Password storage (use PBKDF2, bcrypt, or Argon2 instead)
- ❌ Cryptographic signatures (use HMAC or digital signatures)

SHA256 without salt and key stretching is vulnerable to rainbow table and brute force attacks when used for passwords.

---

## Complete Example

```aro
(*
 * File Integrity Verification Example
 * Demonstrates core ARO syntax and features
 *)

(File Integrity Verification: Security) {
    // Extract file content and expected checksum from request
    Extract the <content> from the <request: body content>.
    Extract the <expected-checksum> from the <request: body checksum>.

    // Compute file checksum for integrity verification
    Compute the <actual-checksum: hash> from the <content>.

    // Compare checksums
    Compare the <actual-checksum> against the <expected-checksum>.

    // Validate and respond
    Validate the <integrity> for the <comparison>.
    Return an <OK: status> for the <integrity>.

    // Publish verification result for other feature sets
    Publish as <verified-content> <content>.
}

(Content Processing: Security) {
    // Access published variable from same business activity
    Transform the <processed-data: uppercase> from the <verified-content>.
    Return an <OK: status> with <processed-data>.
}

(Audit Logging: Security) {
    Log "File integrity verified" to the <console>.
    Store the <audit-record> into the <audit-repository>.
}
```

---

## Formal Grammar

```ebnf
(* ===========================================
   ARO Language Fundamentals Grammar
   =========================================== *)

(* Program Structure *)
program             = { feature_set } ;

feature_set         = "(" , identifier_sequence , ":" , identifier_sequence , ")" ,
                      "{" , { statement } , "}" ;

identifier_sequence = identifier , { identifier } ;

(* Statements *)
statement           = aro_statement
                    | publish_statement ;

(* ARO Statement *)
aro_statement       = action_clause , result_clause , object_clause , "." ;

action_clause       = "<" , identifier , ">" ;

result_clause       = [ article ] , "<" , qualified_noun , ">" ;

object_clause       = preposition , [ article ] , "<" , qualified_noun , ">"
                    | "to" , [ article ] , "<" , qualified_noun , ">" ;

(* Qualified Noun *)
qualified_noun      = compound_identifier , [ ":" , specifier_list ] ;

specifier_list      = compound_identifier , { compound_identifier } ;

(* Publish Statement *)
publish_statement   = "<" , "Publish" , ">" , "as" ,
                      "<" , compound_identifier , ">" ,
                      "<" , compound_identifier , ">" , "." ;

(* Literals *)
literal             = string_literal
                    | number_literal
                    | boolean_literal
                    | null_literal
                    | array_literal
                    | object_literal ;

string_literal      = '"' , { string_content } , '"' ;
string_content      = string_char | interpolation ;
interpolation       = "${" , expression , "}" ;

number_literal      = integer | float ;
integer             = [ "-" ] , digit , { digit } ;
float               = [ "-" ] , digit , { digit } , "." , digit , { digit } ;

boolean_literal     = "true" | "false" ;
null_literal        = "null" ;

array_literal       = "[" , [ expr_list ] , "]" ;
object_literal      = "{" , [ entry_list ] , "}" ;
expr_list           = expression , { "," , expression } ;
entry_list          = entry , { "," , entry } ;
entry               = ( string_literal | identifier ) , ":" , expression ;

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

(* Lexical Elements *)
compound_identifier = identifier , { "-" , identifier } ;
identifier          = letter , { alphanumeric } ;
article             = "a" | "an" | "the" ;
preposition         = "from" | "for" | "against" | "to"
                    | "into" | "via" | "with" | "on" | "at" | "by" ;

(* Character Classes *)
letter              = "A" ... "Z" | "a" ... "z" ;
digit               = "0" ... "9" ;
alphanumeric        = letter | digit ;

(* Comments *)
block_comment       = "(*" , { any_character } , "*)" ;
line_comment        = "//" , { any_character - newline } , newline ;
```

---

## Semantic Summary

| Construct | Creates Variable | Consumes Variable | Visibility |
|-----------|------------------|-------------------|------------|
| ARO (Request) | result | object | internal |
| ARO (Own) | result | object | internal |
| ARO (Response) | - | result, object | - |
| Publish | external_name | internal_variable | published |

### Data Flow

```
            +-------------+
  External  |   REQUEST   |  Internal
   Input -->|   Actions   |-->  Variables
            +-------------+
                  |
                  v
            +-------------+
  Internal  |     OWN     |  Internal
 Variables->|   Actions   |->  Variables
            +-------------+
                  |
                  v
            +-------------+
  Internal  |  RESPONSE   |  External
 Variables->|   Actions   |-->  Output
            +-------------+
```
