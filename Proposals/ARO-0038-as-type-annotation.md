# ARO-0038: Optional Type Annotations with `as`

* Proposal: ARO-0038
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0006, ARO-0018

## Abstract

This proposal introduces an alternative syntax for type annotations using the `as` keyword, making type annotations more readable and clearly distinguishing them from other uses of the colon qualifier syntax.

## Motivation

The colon syntax `<name: qualifier>` has multiple meanings in ARO:

| Context | Meaning | Example |
|---------|---------|---------|
| Compute (ARO-0035) | Operation selector | `<len: length>` |
| Extract | Field navigation | `<event: user>` |
| Filter/Reduce | Type annotation | `<users: List>` |

This overloading can lead to confusion. For type annotations specifically, an explicit `as` keyword makes intent clearer and aligns with common programming patterns (TypeScript's `as`, Kotlin's `as`, etc.).

Additionally, type annotations are **optional** in most cases since ARO infers types from the action's result. Making the type annotation syntactically distinct with `as` emphasizes this optionality.

## Design

### New Syntax

Type annotations can now use `as Type` after the result descriptor:

```aro
(* New syntax: as Type *)
<Filter> the <active-users> as List from the <users> where <active> is true.
<Reduce> the <total> as Float from the <orders> with sum(<amount>).
<Map> the <names> as List from the <users: name>.

(* Old syntax still works *)
<Filter> the <active-users: List> from the <users> where <active> is true.
<Reduce> the <total: Float> from the <orders> with sum(<amount>).
```

### When to Use Type Annotations

Type annotations are **optional** because ARO infers result types:

| Action | Inferred Type | Annotation Needed? |
|--------|---------------|-------------------|
| Filter | List (same as input) | Rarely |
| Reduce | Number (for sum/avg/count) | Sometimes for precision |
| Map | List | Rarely |

Use explicit annotations when:
1. You need a specific numeric type (Float vs Integer)
2. Documentation purposes
3. Overriding default inference

### Grammar

```ebnf
result_clause = "<" qualified_noun ">" [ "as" type_annotation ]
type_annotation = identifier [ "<" type_annotation { "," type_annotation } ">" ]
```

## Implementation

The parser checks for the `as` keyword after the result's closing `>`:

```swift
// Parse result
try expect(.leftAngle, message: "'<'")
var result = try parseQualifiedNoun()
try expect(.rightAngle, message: "'>'")

// ARO-0038: Check for optional 'as Type' annotation
if check(.as) {
    advance()
    let typeAnnotation = try parseTypeAnnotation()
    result = QualifiedNoun(
        base: result.base,
        typeAnnotation: typeAnnotation,
        span: result.span
    )
}
```

## Examples

### Filter with Type Annotation

```aro
(* Without type - inferred as List *)
<Filter> the <active-users> from the <users> where <active> is true.

(* With explicit type *)
<Filter> the <active-users> as List<User> from the <users> where <active> is true.
```

### Reduce with Type Annotation

```aro
(* Without type - inferred as number *)
<Reduce> the <total> from the <orders> with sum(<amount>).

(* With explicit Float type for precision *)
<Reduce> the <total> as Float from the <orders> with sum(<amount>).
```

### Map with Type Annotation

```aro
(* Extract names into a list *)
<Map> the <names> from the <users: name>.

(* With explicit type annotation *)
<Map> the <names> as List<String> from the <users: name>.
```

## Backward Compatibility

This change is fully backward compatible:

- The colon syntax `<result: Type>` continues to work
- The `as Type` syntax is an additional option
- Both syntaxes produce identical AST structures

## Alternatives Considered

### 1. Replace Colon Syntax Entirely

Considered deprecating `<result: Type>` in favor of only `<result> as Type`.

Rejected: Would break existing code unnecessarily. Both syntaxes serve the same purpose.

### 2. Use Double Colon (Haskell-style)

```aro
<Filter> the <users :: List> from the <data>.
```

Rejected: Introduces a new operator and is less readable than `as`.

## References

- ARO-0006: Data Types
- ARO-0018: Data Pipelines (Filter, Map, Reduce)
- ARO-0035: Qualifier-as-Name Syntax
- Discussion #53: Disambiguate Qualifier Syntax Semantics
