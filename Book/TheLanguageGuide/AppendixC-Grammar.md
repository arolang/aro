# Appendix C: Grammar Specification

This appendix provides the complete formal grammar specification for ARO using Extended Backus-Naur Form (EBNF).

## Notation

| Symbol | Meaning |
|--------|---------|
| `=` | Definition |
| `,` | Concatenation |
| `\|` | Alternative |
| `[ ]` | Optional (0 or 1) |
| `{ }` | Repetition (0 or more) |
| `( )` | Grouping |
| `" "` | Terminal string |
| `' '` | Terminal character |
| `(* *)` | Comment |

## Program Structure

```ebnf
(* Top-level program *)
program = { feature_set } ;

(* Feature set definition *)
feature_set = "(" , feature_name , ":" , business_activity , ")" , block ;

feature_name = identifier | route_pattern ;
business_activity = identifier , { identifier } ;

(* Route patterns for HTTP handlers *)
route_pattern = http_method , route_path ;
http_method = "GET" | "POST" | "PUT" | "DELETE" | "PATCH" ;
route_path = "/" , { path_segment , "/" } , [ path_segment ] ;
path_segment = identifier | path_parameter ;
path_parameter = "{" , identifier , "}" ;

(* Block of statements *)
block = "{" , { statement } , "}" ;
```

## Statements

```ebnf
(* Statement types *)
statement = aro_statement
          | publish_statement
          | conditional_statement
          | guard_statement
          | match_statement ;

(* Core ARO statement: Action-Result-Object *)
aro_statement = action , [ article ] , result , preposition , [ article ] , object , [ modifiers ] , "." ;

(* Publish statement *)
publish_statement = "<Publish>" , "as" , alias , variable , "." ;

(* Conditional statements *)
conditional_statement = "if" , condition , "then" , block , [ "else" , block ] ;

(* Guard statements *)
guard_statement = "when" , condition , block ;

(* Match statements *)
match_statement = "match" , variable , "{" , { match_case } , [ default_case ] , "}" ;
match_case = "case" , pattern , block ;
pattern = literal | regex_literal | variable ;
default_case = "default" , block | "otherwise" , block ;
```

## Actions and Objects

```ebnf
(* Action - the verb *)
action = "<" , action_verb , ">" ;
action_verb = identifier ;

(* Result - what is produced *)
result = variable | typed_variable ;

(* Object - the source or target *)
object = variable
       | typed_variable
       | literal
       | file_reference
       | api_reference
       | repository_reference ;

(* Modifiers *)
modifiers = where_clause | with_clause | on_clause ;
where_clause = "where" , condition , { "and" , condition } ;
with_clause = "with" , ( variable | object_literal | literal ) ;
on_clause = "on" , "port" , number ;
```

## Variables and Types

```ebnf
(* Variable forms *)
variable = "<" , identifier , ">" ;
typed_variable = "<" , identifier , ":" , type_hint , ">" ;
qualified_variable = "<" , identifier , ":" , qualifier , ">" ;

(* Type hints *)
type_hint = "JSON" | "bytes" | "List" | "String" | "Number" | "Boolean" | "Date" | identifier ;

(* Qualifier for accessing properties *)
qualifier = identifier , { identifier } ;

(* Alias for publishing *)
alias = "<" , identifier , ">" ;
```

## References

```ebnf
(* File reference *)
file_reference = "<" , "file:" , ( string_literal | variable ) , ">" ;

(* Directory reference *)
directory_reference = "<" , "directory:" , string_literal , ">" ;

(* API reference *)
api_reference = "<" , api_name , ":" , [ http_method ] , route_path , ">" ;
api_name = identifier ;

(* Repository reference *)
repository_reference = "<" , identifier , "-repository" , ">" ;

(* Host reference *)
host_reference = "<" , "host:" , string_literal , ">" ;
```

## Conditions

```ebnf
(* Condition expressions *)
condition = comparison | existence_check | boolean_condition ;

(* Comparisons *)
comparison = variable , comparison_op , ( variable | literal | regex_literal ) ;
comparison_op = "is" | "is not" | ">" | "<" | ">=" | "<=" | "matches" | "contains" ;

(* Existence checks *)
existence_check = variable , ( "is empty" | "is not empty" ) ;

(* Boolean combinations *)
boolean_condition = condition , boolean_op , condition ;
boolean_op = "and" | "or" ;

(* Negation *)
negation = "not" , condition ;
```

## Literals

```ebnf
(* Literal values *)
literal = string_literal | number | boolean | object_literal ;

(* String literal *)
string_literal = '"' , { string_char | interpolation } , '"' ;
string_char = (* any character except " and $ *) | escape_sequence ;
escape_sequence = "\\" , ( '"' | "\\" | "n" | "t" | "r" ) ;
interpolation = "${" , ( identifier | qualified_variable ) , "}" ;

(* Number literal *)
number = [ "-" ] , digit , { digit } , [ "." , digit , { digit } ] ;

(* Boolean literal *)
boolean = "true" | "false" ;

(* Object literal *)
object_literal = "{" , [ property , { "," , property } ] , "}" ;
property = property_name , ":" , ( literal | variable ) ;
property_name = identifier | string_literal ;

(* Regex literal *)
regex_literal = "/" , regex_body , "/" , [ regex_flags ] ;
regex_body = { regex_char | regex_escape } ;
regex_char = (* any character except "/" and newline *) ;
regex_escape = "\\" , (* any character *) ;
regex_flags = { "i" | "s" | "m" | "g" } ;
```

### Regex Flags

| Flag | Description |
|------|-------------|
| `i` | Case insensitive matching |
| `s` | Dot matches newlines (dotall) |
| `m` | Multiline mode (^ and $ match line boundaries) |
| `g` | Global (reserved for future replace operations) |

## Lexical Elements

```ebnf
(* Identifier *)
identifier = letter , { letter | digit | "-" } ;

(* Article *)
article = "a" | "an" | "the" ;

(* Preposition *)
preposition = "from" | "to" | "for" | "with" | "into" | "against" | "via" | "on" | "as" ;

(* Basic character classes *)
letter = "a" | "b" | ... | "z" | "A" | "B" | ... | "Z" ;
digit = "0" | "1" | ... | "9" ;

(* Whitespace (ignored) *)
whitespace = " " | "\t" | "\n" | "\r" ;

(* Comment *)
comment = "(*" , { any_char } , "*)" ;
```

## Special Feature Sets

```ebnf
(* Application lifecycle *)
application_start = "(" , "Application-Start" , ":" , business_activity , ")" , block ;
application_end_success = "(" , "Application-End" , ":" , "Success" , ")" , block ;
application_end_error = "(" , "Application-End" , ":" , "Error" , ")" , block ;

(* Event handlers *)
event_handler = "(" , handler_name , ":" , event_type , "Handler" , ")" , block ;
handler_name = identifier , { identifier } ;
event_type = identifier ;
```

## API Definitions

```ebnf
(* API definition block *)
api_definition = "api" , identifier , "{" , { api_property } , "}" ;
api_property = property_name , ":" , ( string_literal | object_literal ) , ";" ;
```

## Complete Examples

### Minimal Program

```
program = feature_set
        = "(" , "Application-Start" , ":" , "Test" , ")" , block
        = "(" , "Application-Start" , ":" , "Test" , ")" , "{" , statement , "}"
        = "(" , "Application-Start" , ":" , "Test" , ")" , "{" , aro_statement , "}"
        = "(" , "Application-Start" , ":" , "Test" , ")" , "{" ,
            "<Return>" , "an" , "<OK: status>" , "for" , "the" , "<startup>" , "." ,
          "}"
```

### ARO Statement Parse

```
"<Extract> the <user-id> from the <request: parameters>."

= aro_statement
= action , article , result , preposition , article , object , "."
= "<Extract>" , "the" , "<user-id>" , "from" , "the" , "<request: parameters>" , "."
```

### Guarded Statement Parse

```
"<Return> a <NotFound: status> for the <user> when <user> is empty."

= guarded_statement
= aro_statement_base , "when" , condition , "."
= action , result , preposition , object , "when" , existence_check , "."
= "<Return>" , "a" , "<NotFound: status>" , "for" , "the" , "<user>" , "when" , "<user>" , "is empty" , "."
```

## Precedence

Operator precedence (highest to lowest):

1. Parentheses `( )`
2. `not`
3. Comparisons (`is`, `is not`, `>`, `<`, `>=`, `<=`)
4. `and`
5. `or`

## Reserved Words

The following identifiers are reserved:

**Articles:** `a`, `an`, `the`

**Prepositions:** `from`, `to`, `for`, `with`, `into`, `against`, `via`, `on`, `as`

**Control Flow:** `if`, `then`, `else`, `when`, `match`, `case`, `default`, `where`, `and`, `or`, `not`, `is`

**Literals:** `true`, `false`, `empty`

**Status Codes:** `OK`, `Created`, `Accepted`, `NoContent`, `BadRequest`, `Unauthorized`, `Forbidden`, `NotFound`, `Conflict`, `InternalError`, `ServiceUnavailable`

**Special:** `Application-Start`, `Application-End`, `Success`, `Error`, `Handler`

## File Encoding

ARO source files must be encoded in UTF-8. The `.aro` file extension is required.
