# Appendix C: Grammar Specification

*Formal grammar of the ARO language.*

---

## Notation

This appendix uses Extended Backus-Naur Form (EBNF):

- `=` defines a rule
- `|` means "or"
- `[ ]` means optional (0 or 1)
- `{ }` means repetition (0 or more)
- `" "` encloses literal text
- `(* *)` is a comment

---

## Program Structure

```ebnf
program = { import_declaration } { feature_set } ;

import_declaration = "import" string_literal ;

feature_set = "(" feature_name ":" business_activity ")" "{" { statement } "}" ;

feature_name = identifier | compound_identifier ;

business_activity = identifier | compound_identifier ;
```

---

## Statements

```ebnf
statement = aro_statement | publish_statement | match_statement ;

match_statement = "match" expression "{" { case_clause } [ otherwise_clause ] "}" ;

case_clause = "case" pattern "{" { statement } "}" ;

otherwise_clause = "otherwise" "{" { statement } "}" ;

pattern = literal_value | variable_ref | wildcard | regex_literal ;

wildcard = "_" ;

aro_statement = action article result object_clause
                [ literal_value ]
                [ expression_clause ]
                [ aggregation_clause ]
                [ where_clause ]
                [ when_clause ]
                "." ;

publish_statement = "<Publish>" "as" identifier result "." ;

action = "<" verb ">" ;

verb = identifier ;

result = "<" qualified_noun ">" ;

object_clause = preposition article "<" qualified_noun ">" ;

qualified_noun = identifier [ ":" qualifier ] ;

qualifier = identifier { ":" identifier } ;
```

---

## Prepositions and Articles

```ebnf
preposition = "from" | "with" | "for" | "to" | "into"
            | "against" | "via" | "on" ;

article = "the" | "a" | "an" ;
```

---

## Clauses

```ebnf
literal_value = string_literal | number_literal | boolean_literal
              | array_literal | object_literal ;

expression_clause = expression ;

aggregation_clause = "with" aggregation_function ;

where_clause = "where" condition ;

when_clause = "when" condition ;

aggregation_function = identifier "(" [ identifier ] ")" ;
```

---

## Expressions

```ebnf
expression = logical_or_expr ;

logical_or_expr = logical_and_expr { "or" logical_and_expr } ;

logical_and_expr = equality_expr { "and" equality_expr } ;

equality_expr = comparison_expr { ( "==" | "!=" | "is" ) comparison_expr } ;

comparison_expr = additive_expr { ( "<" | ">" | "<=" | ">=" ) additive_expr } ;

additive_expr = multiplicative_expr { ( "+" | "-" ) multiplicative_expr } ;

multiplicative_expr = unary_expr { ( "*" | "/" | "%" ) unary_expr } ;

unary_expr = [ "not" | "-" ] primary_expr ;

primary_expr = variable_ref
             | literal_value
             | function_call
             | "(" expression ")" ;

variable_ref = "<" qualified_noun ">" ;

function_call = identifier "(" [ expression { "," expression } ] ")" ;
```

---

## Conditions

```ebnf
condition = expression
          | comparison
          | existence_check
          | containment_check ;

comparison = variable_ref comparison_op expression ;

comparison_op = "is" | "==" | "!=" | "<" | ">" | "<=" | ">=" ;

existence_check = variable_ref "exists"
                | variable_ref "is" "defined" ;

containment_check = variable_ref "contains" expression
                  | variable_ref "matches" expression ;
```

---

## Literals

```ebnf
string_literal = '"' { character } '"' ;

number_literal = integer_literal | float_literal ;

integer_literal = [ "-" ] digit { digit } ;

float_literal = [ "-" ] digit { digit } "." digit { digit } ;

boolean_literal = "true" | "false" ;

array_literal = "[" [ expression { "," expression } ] "]" ;

object_literal = "{" [ object_field { "," object_field } ] "}" ;

object_field = identifier ":" expression
             | identifier ":" variable_ref ;

regex_literal = "/" regex_body "/" [ regex_flags ] ;

regex_body = { regex_char | escape_sequence } ;

regex_char = ? any character except "/" and newline ? ;

escape_sequence = "\\" ? any character ? ;

regex_flags = { "i" | "s" | "m" | "g" } ;
```

---

## Identifiers

```ebnf
identifier = letter { letter | digit | "_" } ;

compound_identifier = identifier { "-" identifier } ;

letter = "a" | "b" | ... | "z" | "A" | "B" | ... | "Z" ;

digit = "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" ;
```

---

## Comments

```ebnf
comment = "(*" { any_character } "*)" ;

any_character = (* any Unicode character *) ;
```

---

## Tokens

### Keywords

```
publish, require, import, as, when, match, case, otherwise,
where, for, each, in, at, parallel, concurrency, type, enum, protocol,
error, guard, defer, assert, precondition, and, or, not, is, exists,
defined, null, nil, none, empty, contains, matches, true, false
```

### Prepositions

```
from, for, against, to, into, via, with, on
```

### Articles

```
the, a, an
```

### Operators

```
+   -   *   /   %
==  !=  <   >   <=  >=
and or  not is
```

### Delimiters

```
<   >   (   )   {   }   [   ]
:   .   ,   "
```

---

## Example Parse Tree

For the statement:

```aro
<Extract> the <user-id: String> from the <pathParameters: id>.
```

<div style="text-align: center; margin: 2em 0;">
<svg width="420" height="220" viewBox="0 0 420 220" xmlns="http://www.w3.org/2000/svg">  <!-- Root node -->  <rect x="160" y="5" width="100" height="22" rx="4" fill="#1f2937" stroke="#1f2937" stroke-width="2"/>  <text x="210" y="20" text-anchor="middle" font-family="monospace" font-size="10" fill="#ffffff">aro_statement</text>  <!-- Level 1 connectors -->  <line x1="180" y1="27" x2="50" y2="55" stroke="#9ca3af" stroke-width="1"/>  <line x1="195" y1="27" x2="130" y2="55" stroke="#9ca3af" stroke-width="1"/>  <line x1="210" y1="27" x2="210" y2="55" stroke="#9ca3af" stroke-width="1"/>  <line x1="225" y1="27" x2="290" y2="55" stroke="#9ca3af" stroke-width="1"/>  <line x1="240" y1="27" x2="380" y2="55" stroke="#9ca3af" stroke-width="1"/>  <!-- Level 1 nodes -->  <!-- Action -->  <rect x="10" y="55" width="80" height="22" rx="3" fill="#dbeafe" stroke="#3b82f6" stroke-width="1.5"/>  <text x="50" y="70" text-anchor="middle" font-family="monospace" font-size="9" fill="#1e40af">&lt;Extract&gt;</text>  <text x="50" y="90" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#6b7280">action</text>  <!-- Article 1 -->  <rect x="100" y="55" width="55" height="22" rx="3" fill="#f3f4f6" stroke="#9ca3af" stroke-width="1"/>  <text x="127" y="70" text-anchor="middle" font-family="monospace" font-size="9" fill="#374151">"the"</text>  <text x="127" y="90" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#6b7280">article</text>  <!-- Result -->  <rect x="165" y="55" width="90" height="22" rx="3" fill="#dcfce7" stroke="#22c55e" stroke-width="1.5"/>  <text x="210" y="70" text-anchor="middle" font-family="monospace" font-size="9" fill="#166534">result</text>  <!-- Object clause -->  <rect x="265" y="55" width="90" height="22" rx="3" fill="#fce7f3" stroke="#ec4899" stroke-width="1.5"/>  <text x="310" y="70" text-anchor="middle" font-family="monospace" font-size="9" fill="#9d174d">object_clause</text>  <!-- Period -->  <rect x="365" y="55" width="40" height="22" rx="3" fill="#1f2937" stroke="#1f2937" stroke-width="1"/>  <text x="385" y="70" text-anchor="middle" font-family="monospace" font-size="12" fill="#ffffff">"."</text>  <text x="385" y="90" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#6b7280">terminator</text>  <!-- Result children -->  <line x1="210" y1="77" x2="210" y2="105" stroke="#22c55e" stroke-width="1"/>  <rect x="165" y="105" width="90" height="22" rx="3" fill="#dcfce7" stroke="#22c55e" stroke-width="1"/>  <text x="210" y="120" text-anchor="middle" font-family="monospace" font-size="8" fill="#166534">qualified_noun</text>  <line x1="190" y1="127" x2="165" y2="150" stroke="#22c55e" stroke-width="1"/>  <line x1="230" y1="127" x2="255" y2="150" stroke="#22c55e" stroke-width="1"/>  <rect x="120" y="150" width="90" height="20" rx="3" fill="#d1fae5" stroke="#10b981" stroke-width="1"/>  <text x="165" y="164" text-anchor="middle" font-family="monospace" font-size="8" fill="#047857">"user-id"</text>  <text x="165" y="182" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#6b7280">identifier</text>  <rect x="220" y="150" width="70" height="20" rx="3" fill="#d1fae5" stroke="#10b981" stroke-width="1"/>  <text x="255" y="164" text-anchor="middle" font-family="monospace" font-size="8" fill="#047857">"String"</text>  <text x="255" y="182" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#6b7280">qualifier</text>  <!-- Object clause children -->  <line x1="295" y1="77" x2="295" y2="95" stroke="#ec4899" stroke-width="1"/>  <line x1="310" y1="77" x2="340" y2="95" stroke="#ec4899" stroke-width="1"/>  <line x1="325" y1="77" x2="385" y2="95" stroke="#ec4899" stroke-width="1"/>  <text x="295" y="108" text-anchor="middle" font-family="monospace" font-size="7" fill="#9d174d">"from"</text>  <text x="340" y="108" text-anchor="middle" font-family="monospace" font-size="7" fill="#9d174d">"the"</text>  <rect x="355" y="115" width="60" height="18" rx="2" fill="#fce7f3" stroke="#ec4899" stroke-width="1"/>  <text x="385" y="128" text-anchor="middle" font-family="monospace" font-size="7" fill="#9d174d">qual_noun</text>  <line x1="370" y1="133" x2="350" y2="150" stroke="#ec4899" stroke-width="1"/>  <line x1="400" y1="133" x2="410" y2="150" stroke="#ec4899" stroke-width="1"/>  <text x="340" y="165" text-anchor="middle" font-family="monospace" font-size="7" fill="#be185d">"pathParameters"</text>  <text x="410" y="165" text-anchor="middle" font-family="monospace" font-size="7" fill="#be185d">"id"</text></svg>
</div>

---

## Operator Precedence

From lowest to highest:

| Precedence | Operators | Associativity |
|------------|-----------|---------------|
| 1 | `or` | Left |
| 2 | `and` | Left |
| 3 | `not` | Right (unary) |
| 4 | `is`, `==`, `!=` | Left |
| 5 | `<`, `>`, `<=`, `>=` | Left |
| 6 | `+`, `-` | Left |
| 7 | `*`, `/`, `%` | Left |
| 8 | `-` (unary) | Right |

---

## Lexical Conventions

### Whitespace

Whitespace (spaces, tabs, newlines) is ignored between tokens.

### Line Continuation

Statements can span multiple lines:

```aro
<Return> an <OK: status> with {
    data: <users>,
    total: <count>,
    page: <page>
}.
```

### String Escapes

Within string literals:

| Escape | Meaning |
|--------|---------|
| `\"` | Double quote |
| `\\` | Backslash |
| `\n` | Newline |
| `\t` | Tab |
| `\r` | Carriage return |

---

## Reserved for Future Use

These tokens are reserved and may not be used as identifiers:

```
class, struct, func, let, var, return, throw, try, catch, finally,
async, await, yield, break, continue, switch, default, private,
public, internal, static, self, super, init, deinit
```
