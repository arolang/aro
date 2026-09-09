# Appendix B: Grammar Specification

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
program = { import_declaration } , { feature_set } ;

import_declaration = "import" , import_path ;
import_path = path_segment , { "/" , path_segment | "." | "-" } ;
path_segment = identifier | "." | ".." ;

(* Feature set definition.  The optional guard filters event handlers. *)
feature_set = "(" , feature_name , ":" , business_activity , ")" ,
              [ ( "when" | "where" ) , expression ] , block ;

feature_name = identifier , { identifier } ;
business_activity = identifier , { identifier } ;

(* Block of statements *)
block = "{" , { statement } , "}" ;
```

## Statements

```ebnf
(* Statement types *)
statement = aro_statement
          | guarded_statement
          | publish_statement
          | require_statement
          | match_statement
          | for_each_loop
          | range_loop
          | while_loop
          | break_statement
          | pipeline_statement ;

(* Core ARO statement: Action-Result-Object.
   The action verb is a BARE identifier — angle brackets mark nouns,
   never verbs. *)
aro_statement = action , [ article ] , result , preposition , [ article ] , object , [ modifiers ] , "." ;

(* Publish statement *)
publish_statement = "Publish" , "as" , alias , variable , "." ;

(* Require statement (ARO-0003) *)
require_statement = "Require" , [ article ] , variable , preposition , [ article ] , object , "." ;

(* Guarded statement - ARO statement with conditional suffix *)
guarded_statement = aro_statement_base , "when" , condition , "." ;
aro_statement_base = action , [ article ] , result , preposition , [ article ] , object , [ modifiers ] ;

(* Match statements *)
match_statement = "match" , variable , "{" , { match_case } , [ default_case ] , "}" ;
match_case = "case" , pattern , block ;
pattern = literal | regex_literal | variable ;
default_case = "otherwise" , block ;

(* For-each loop — collection iteration.  `parallel` and the concurrency
   limit are ARO-0088; `at <index>` and the `when` filter are ARO-0005. *)
for_each_loop = [ "parallel" ] , "for" , "each" , variable ,
                [ "at" , variable ] , "in" , variable ,
                [ "when" , condition ] ,
                [ "with" , "<" , "concurrency" , ":" , number , ">" ] , block ;

(* Range loop — numeric iteration (ARO 0.7) *)
range_loop = "for" , variable , "from" , expression , "to" , expression , block ;

(* While loop — condition-based iteration (ARO 0.7) *)
while_loop = "while" , condition , block ;

(* Break statement — exit innermost loop (ARO 0.7) *)
break_statement = "Break" , "." ;

(* Pipeline statement — chained actions (ARO-0067) *)
pipeline_statement = aro_statement , { "|>" , aro_statement } , "." ;
```

## Actions and Objects

```ebnf
(* Action - the verb.  A bare identifier, optionally namespaced for
   plugin actions (`Markdown.ToHTML`) and user-defined actions
   (`Application.SumAndDouble`, ARO-0081). *)
action = [ identifier , "." ] , action_verb ;
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

(* String literal.  A newline inside "..." is content: plain strings span
   lines (GitLab #523).  Triple-quoted strings were removed (GitLab #524). *)
string_literal = '"' , { string_char | interpolation } , '"' ;
string_char = (* any character except " and $ *) | escape_sequence ;
escape_sequence = "\\" , ( '"' | "'" | "\\" | "n" | "t" | "r" | "0" | "$" | unicode_escape ) ;
unicode_escape = "u" , "{" , hex_digit , { hex_digit } , "}" ;
interpolation = "${" , expression , "}" ;

(* Raw string literal (ARO-0060).  The quote character selects the mode;
   there is no `r` prefix.  Only \' is an escape. *)
raw_string_literal = "'" , { raw_char } , "'" ;

(* Number literal.  Underscores are permitted as separators in decimal
   literals (ARO-0082); hex and binary forms carry a prefix. *)
number = decimal | hex_number | binary_number ;
decimal = [ "-" ] , digit , { digit | "_" } , [ "." , digit , { digit | "_" } ] ;
hex_number = "0x" , hex_digit , { hex_digit } ;
binary_number = "0b" , ( "0" | "1" ) , { "0" | "1" } ;

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

(* Preposition — exactly ten, and `as` is not one of them: it is a
   keyword introducing a result type. *)
preposition = "from" | "for" | "against" | "to" | "into"
            | "via" | "with" | "on" | "at" | "by" ;

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
            "Return" , "an" , "<OK: status>" , "for" , "the" , "<startup>" , "." ,
          "}"
```

### ARO Statement Parse

```
"Extract the <user-id> from the <request: parameters>."

= aro_statement
= action , article , result , preposition , article , object , "."
= "Extract" , "the" , "<user-id>" , "from" , "the" , "<request: parameters>" , "."
```

### Guarded Statement Parse

```
"Return a <NotFound: status> for the <user> when <user> is empty."

= guarded_statement
= aro_statement_base , "when" , condition , "."
= action , result , preposition , object , "when" , existence_check , "."
= "Return" , "a" , "<NotFound: status>" , "for" , "the" , "<user>" , "when" , "<user>" , "is empty" , "."
```

## Precedence

Operator precedence (highest to lowest):

1. Parentheses `( )`, member access `.`, subscript `[ ]`
2. Unary `-`, `not`
3. `*`, `/`, `%`
4. `+`, `-`, `++`
5. Comparisons (`<`, `>`, `<=`, `>=`)
6. Equality (`==`, `!=`, `is`, `is not`, `contains`, `matches`)
7. `and`
8. `or`

`not` is a *prefix* operator at level 2, which binds tighter than any
comparison: `not <n> >= 3` groups as `(not <n>) >= 3`. Parenthesize when
you mean to negate a comparison.

## Reserved Words

The following identifiers are reserved:

**Articles:** `a`, `an`, `the`

**Prepositions:** `from`, `for`, `against`, `to`, `into`, `via`, `with`, `on`, `at`, `by`

**Core:** `publish`, `require`, `import`, `as`

**Control Flow:** `if`, `then`, `else`, `when`, `match`, `case`, `otherwise`, `where`

**Iteration:** `each`, `in`, `parallel`, `concurrency`, `while`, `break`
(`for` and `at` are tokenized as prepositions and accepted in both roles)

**Types:** `type`, `enum`, `protocol`

**Error handling:** `error`, `guard`, `defer`, `assert`, `precondition`

**Operators:** `and`, `or`, `not`, `is`, `exists`, `defined`, `contains`, `matches`

**Literals:** `true`, `false`, `empty`, `nil`, `null`, `none`

**Status Codes:** `OK`, `Created`, `Accepted`, `NoContent`, `BadRequest`, `Unauthorized`, `Forbidden`, `NotFound`, `Conflict`, `InternalError`, `ServiceUnavailable`

**Special:** `Application-Start`, `Application-End`, `Success`, `Error`, `Handler`

## File Encoding

ARO source files must be encoded in UTF-8. The `.aro` file extension is required.
