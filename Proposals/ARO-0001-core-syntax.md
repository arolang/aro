# ARO-0001: Core Language Syntax

* Proposal: ARO-0001
* Author: ARO Language Team
* Status: **Implemented**
* Version: 1.0

## Abstract

This proposal defines the foundational syntax of the ARO (Feature Driven Development - Action Result Object) domain-specific language. It establishes the basic grammar, lexical structure, and core constructs that all subsequent proposals build upon.

## Introduction

ARO is a declarative domain-specific language for specifying business features in a human-readable format that can be compiled to executable code. The language follows the Feature Driven Development methodology where features are expressed as Action-Result-Object (ARO) statements.

### Design Goals

1. **Readability**: Specifications should read like natural English sentences
2. **Formality**: Precise enough for machine parsing and code generation
3. **Simplicity**: Minimal syntax with maximum expressiveness
4. **Traceability**: Direct mapping between specification and implementation

## Lexical Structure

### 1. Character Set

ARO source files are encoded in UTF-8. The language uses the following character classes:

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

The following words are reserved and cannot be used as identifiers:

```
as          (* publish statement *)
```

Future proposals may add additional keywords.

### 4. Articles

English articles are recognized as distinct tokens:

```ebnf
article = "a" | "an" | "the" ;
```

Articles are syntactic sugar for readability and do not affect semantics.

### 5. Prepositions

Prepositions connect ARO components and carry semantic meaning:

```ebnf
preposition = "from" | "for" | "against" | "to" | "into" | "via" | "with" ;
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

### 6. Delimiters

```ebnf
left_paren   = "(" ;
right_paren  = ")" ;
left_brace   = "{" ;
right_brace  = "}" ;
left_angle   = "<" ;
right_angle  = ">" ;
colon        = ":" ;
dot          = "." ;
hyphen       = "-" ;
```

### 7. Comments

ARO supports two comment styles:

```ebnf
block_comment = "(*" , { any_character } , "*)" ;
line_comment  = "//" , { any_character - newline } , newline ;
```

**Examples:**
```
(* This is a block comment
   spanning multiple lines *)

// This is a line comment
```

### 8. Whitespace

Whitespace separates tokens but is otherwise insignificant. Multiple whitespace characters are equivalent to one.

---

## Grammar

### 1. Program Structure

A program consists of one or more feature sets:

```ebnf
program = { feature_set } ;
```

### 2. Feature Set

A feature set groups related features under a name and business activity:

```ebnf
feature_set = "(" , feature_set_name , ":" , business_activity , ")" ,
              "{" , { statement } , "}" ;

feature_set_name   = identifier_sequence ;
business_activity  = identifier_sequence ;
identifier_sequence = identifier , { identifier } ;
```

**Syntax:**
```
(FeatureSetName: Business Activity) {
    <statements>
}
```

**Example:**
```
(User Authentication: Security and Access Control) {
    (* statements go here *)
}
```

**Semantics:**
- `feature_set_name`: Unique identifier for the feature set
- `business_activity`: Describes the business domain
- The body contains zero or more statements

### 3. Statements

The core language supports two statement types:

```ebnf
statement = aro_statement | publish_statement ;
```

### 4. ARO Statement (Action-Result-Object)

The fundamental construct of ARO:

```ebnf
aro_statement = action_clause , result_clause , object_clause , "." ;

action_clause = "<" , action_verb , ">" ;
action_verb   = identifier ;

result_clause = [ article ] , "<" , qualified_noun , ">" ;

object_clause = preposition , [ article ] , "<" , qualified_noun , ">" ;
```

**Syntax:**
```
<Action> [article] <result: specifiers> preposition [article] <object: specifiers>.
```

**Example:**
```
<Extract> the <user: identifier> from the <incoming-request: parameters>.
```

**Components:**

| Component | Description |
|-----------|-------------|
| Action | Verb describing what to do |
| Result | What is produced (the output) |
| Object | What is operated upon (the input) |

### 5. Qualified Noun

A noun with optional specifiers for precision:

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
<user: first-name.last-name>    (* with multiple specifiers *)
<incoming-request: parameters>  (* compound base with specifier *)
```

**Semantics:**
- The `base` identifies the primary concept
- Specifiers refine or qualify the base
- Multiple specifiers are dot-separated

### 6. Publish Statement

Exports a variable for use by other feature sets:

```ebnf
publish_statement = "<Publish>" , "as" , "<" , external_name , ">" ,
                    "<" , internal_variable , ">" , "." ;

external_name     = compound_identifier ;
internal_variable = compound_identifier ;
```

**Syntax:**
```
<Publish> as <external-name> <internal-variable>.
```

**Example:**
```
<Publish> as <authenticated-user> <user>.
```

**Semantics:**
- `internal_variable`: The variable defined within this feature set
- `external_name`: The name by which other feature sets can access it

---

## Action Verbs

Actions are classified by their semantic role:

### Request Actions (External → Internal)

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

### Own Actions (Internal → Internal)

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

### Response Actions (Internal → External)

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

### Export Actions

Make available to other features:

| Verb | Description |
|------|-------------|
| `Publish` | Export variable |
| `Export` | Alternative to Publish |
| `Expose` | Make accessible |

---

## Complete Example

```
(*
 * User Authentication Feature
 * Handles login and credential verification
 *)

(User Authentication: Security and Access Control) {
    // Extract user credentials from request
    <Extract> the <user: identifier> from the <incoming-request: parameters>.
    <Parse> the <signed: checksum> from the <request: headers>.
    
    // Retrieve user data
    <Retrieve> the <user: record> from the <user: repository>.
    
    // Handle missing user
    <Throw> a <NotFoundError> for a <missing: user>.
    
    // Verify credentials
    <Compute> the <password: hash> for the <user: credentials>.
    <Compare> the <signed: checksum> against the <computed: password-hash>.
    
    // Validate result
    <Validate> the <authentication: result> for the <user: request>.
    
    // Return response
    <Return> an <OK: status> for a <valid: authentication>.
    <Return> a <Forbidden: status> for an <invalid: authentication>.
    
    // Export for other features
    <Publish> as <authenticated-user> <user>.
}

(Audit Logging: Compliance) {
    <Log> the <access: attempt> for the <authenticated-user: session>.
    <Store> the <audit: record> into the <audit: repository>.
}
```

---

## Formal Grammar (Complete EBNF)

```ebnf
(* ============================================
   ARO Core Language Grammar
   Version 1.0
   ============================================ *)

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

object_clause       = preposition , [ article ] , "<" , qualified_noun , ">" ;

(* Qualified Noun *)
qualified_noun      = compound_identifier , [ ":" , specifier_list ] ;

specifier_list      = compound_identifier , { compound_identifier } ;

(* Publish Statement *)
publish_statement   = "<" , "Publish" , ">" , "as" , 
                      "<" , compound_identifier , ">" ,
                      "<" , compound_identifier , ">" , "." ;

(* Lexical Elements *)
compound_identifier = identifier , { "-" , identifier } ;

identifier          = letter , { alphanumeric } ;

article             = "a" | "an" | "the" ;

preposition         = "from" | "for" | "against" | "to" 
                    | "into" | "via" | "with" ;

(* Character Classes *)
letter              = "A" | "B" | ... | "Z" 
                    | "a" | "b" | ... | "z" ;

digit               = "0" | "1" | "2" | "3" | "4" 
                    | "5" | "6" | "7" | "8" | "9" ;

alphanumeric        = letter | digit ;

(* Comments (handled by lexer) *)
block_comment       = "(*" , { any_character } , "*)" ;
line_comment        = "//" , { any_character - newline } , newline ;
```

---

## Semantic Summary

| Construct | Creates Variable | Consumes Variable | Visibility |
|-----------|------------------|-------------------|------------|
| ARO (Request) | result | object | internal |
| ARO (Own) | result | object | internal |
| ARO (Response) | — | result, object | — |
| Publish | external_name | internal_variable | published |

---

## Future Extensions

This proposal establishes the foundation. The following proposals extend the language:

- **ARO-0002**: Literals and Expressions
- **ARO-0003**: Variable Scoping Rules
- **ARO-0004**: Conditional Branching
- **ARO-0005**: Iteration and Loops
- **ARO-0006**: Type System
- **ARO-0007**: Modules and Imports
- **ARO-0008**: Error Handling
- **ARO-0009**: Action Implementations
- **ARO-0010**: Annotations and Metadata

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2025-12 | Initial specification |
