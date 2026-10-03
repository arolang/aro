# ARO-0089: Ranges

- **Status:** Implemented ([Issue #546](https://git.ausdertechnik.de/arolang/aro/-/issues/546)) — with the two deviations §10 records
- **Author:** ARO Language Team
- **Created:** 2026-09-18
- **Related:** ARO-0002 (Control Flow), ARO-0051 (Streaming Execution), ARO-0001 (Language Fundamentals), ARO-0003 (Type System), ARO-0019 (Standard Library), ARO-0038 (List Element Access), ARO-0082 (Numeric Separators), ARO-0041 (Date/Time Ranges)

## Abstract

> A range is a **value**, not a loop.
> `1..10` is a thing you can name, pass and measure; counting is what you then
> do with it.

ARO can already count — `for <n> from 1 to 10 { … }` — but it cannot *hold* a
span of integers. There is no way to hand "1 through 10" to `Filter`, `Map`,
`Compute … length`, or a user-defined action, because nothing in the language
produces a range value. This proposal adds one.

Two spellings, borrowed from Swift because most readers of this codebase
already carry them: `1..10` includes both ends, `1..<10` excludes the upper
one. The value is lazy where laziness is what matters — iterating one does not
materialise it, in either execution mode — so `for each <n> in
1..10_000_000` costs O(1) memory. §10 records where that holds and where the
implementation falls back to a list.

## 1. Motivation

### 1.1 What exists

`for <n> from 1 to 10 { … }` parses and runs today, and
[ARO-0002 §4.3](ARO-0002-control-flow.md) documents it — it had no production
and no prose there until GitLab #546, which is the other half of this issue —
including the part that surprises everyone:

```aro
for <n> from 1 to 3 {
    Log <n> to the <console>.
}
(* 1
   2   — the upper bound is EXCLUSIVE *)
```

That is the whole of the language's counting story. It is a statement, so it
cannot appear where a value is wanted.

### 1.2 What is missing

```aro
Create the <decade> with 1..10.                  (* no range value exists *)
Compute the <len: length> from 1..10.            (* nothing to measure *)
Filter the <picks> from 1..100 where … .         (* nothing to filter *)
Application.Histogram the <h> from 0..<24.       (* nothing to pass *)
```

Today every one of these is a parse error, and the diagnostics are poor
because the lexer reads `1..10` as two numbers with something between them:

```
2:28: error: Expected action verb (e.g., Extract, Filter, Return), but got int(10)
```

In a `for each` header it cascades into four errors, the last two pointing at
the *following* statement:

```
2:22: error: Expected '{', but got .
2:23: error: Expected action verb …, but got .
2:24: error: Expected action verb …, but got int(10)
2:33: error: Expected action verb …, but got <
```

### 1.3 Why a range and not a list

`[1, 2, 3]` already exists, and for three elements it is the better spelling.
The argument for ranges is the large and the computed case: `[1, 2, …, 10000]`
cannot be written, and `<lo>..<hi>` cannot be written as a literal at all. A
range also carries its intent — a contiguous ascending span — which a list of
integers only implies.

## 2. Syntax

```
range_expression = expression , range_operator , expression ;
range_operator   = ".." | "..<" ;
```

`..` is **inclusive** of both endpoints; `..<` excludes the upper endpoint.

```aro
1..10        (* 1 2 3 4 5 6 7 8 9 10 *)
1..<10       (* 1 2 3 4 5 6 7 8 9    *)
<lo>..<hi>   (* endpoints are expressions *)
```

### 2.1 Why two operators

Borrowing only `..` and picking one meaning saves a token and buys a footgun:
a reader who guesses wrong is off by one and the program still runs, producing
a wrong answer rather than an error. Two operators make the choice visible at
the call site, which is the same reason `..<` exists in Swift.

### 2.2 Precedence

A range binds **looser than arithmetic and tighter than comparison**:

```
 low                                                     high
 or  →  and  →  comparison  →  RANGE  →  additive  →  multiplicative
```

So `1..<n> + 1` is `1..(<n> + 1)`, which is what it reads like. A range is not
a comparison operand, so `1..10 = x` is a check-time error rather than a
silent parse.

Ranges do not chain: `1..5..10` is an error, not a nested range.

## 3. Semantics

### 3.1 Endpoints

Integer endpoints only. A non-integer endpoint is a check-time error naming
the offending side:

```aro
Create the <r> with 1..2.5.
(* error: a range endpoint must be an Int, but the upper endpoint is a Float
     hint: round it first — Compute the <hi: fixed> from 2.5. *)
```

`Date` endpoints are deliberately **not** part of this proposal:
[ARO-0041](ARO-0041-datetime-ranges.md) already specifies date ranges and
recurrence, with its own semantics for what "between two dates" means.
Conflating the two would make `..` mean one thing for numbers and another for
dates.

Endpoints are evaluated **once**, when the range value is produced — never per
element, matching the rule [ARO-0002](ARO-0002-control-flow.md) already states
for the `for each` collection slot.

### 3.2 A descending range is empty

```aro
for each <n> in 10..1 { … }     (* zero iterations *)
```

Empty, not reversed, and not an error. Reversing is an action — `Reverse the
<r> for the <1..10>.` — so a range has exactly one direction and there is no
second way to spell a descending sequence. This also means `<lo>..<hi>` with
computed endpoints degrades quietly to "nothing to do" instead of running
backwards, which is what a program that filtered its data down to nothing
wants.

`1..1` has one element; `1..<1` has none.

### 3.3 Ranges are lazy

A range does not build a list. It is a stream in the sense of
[ARO-0051](ARO-0051-streaming-execution.md), so:

```aro
for each <n> in 1..10_000_000 { … }      (* O(1) memory *)
Compute the <len: length> from 1..10_000_000.   (* 10000000 — but see §10.3 *)
```

`length` on a range is arithmetic — `max(0, hi - lo + 1)` for `..`, `max(0, hi
- lo)` for `..<` — not a traversal. Numeric separators come free, since
[ARO-0082](ARO-0082-numeric-separators.md) already applies to Int literals.

As implemented, the O(1) guarantee covers the `for each` collection slot in
both execution modes; a range used anywhere else materialises first. §10
records what that costs and why.

### 3.4 What a range is accepted as

A range is an expression, so it goes where expressions go, which after
[#519](https://git.ausdertechnik.de/arolang/aro/-/issues/519) includes the
`for each` collection slot:

| Position | Example | Status |
|---|---|---|
| `for each` collection | `for each <n> in 1..10 { … }` | yes |
| `Create … with` | `Create the <decade> with 1..10.` | yes |
| Compute qualifier input | `Compute the <len: length> from 1..10.` | yes |
| Pipeline source | `Filter the <p> from 1..100 where … .` | yes |
| Action argument | `Application.H the <h> from 0..<24.` | yes |
| `where` clause | `where <n> in 1..10` | **no** — see §6 |
| Pattern / `match` arm | `match <n> { 1..10 → … }` | **no** — see §6 |

### 3.5 Type

A range's type is `Range`, an opaque ordered Int sequence. It is iterable and
measurable; it is not a `List`. `Convert the <l> from <r> to "list"`
materialises one when a program genuinely needs indexing
([ARO-0038](ARO-0038-list-element-access.md)).

**Not implemented** — see §10.2. A range that is bound to a name is a `List`
today, and `Convert` is therefore unnecessary.

## 4. Lexing

Three hazards, each of which the sketch in #546 flagged as needing an answer
before implementation. These are the answers.

### 4.1 `1..10` must not lex as `1.` `.10`

The number scanner currently accepts a trailing `.` as the start of a
fractional part, so `1..10` would read as `1.0` followed by `.10`. The rule is
**maximal munch with one character of lookahead**: while scanning a numeric
literal, a `.` begins a fractional part only if the character after it is a
digit *and not itself followed by another `.`*.

```
  1.5      →  Float(1.5)          '.' then digit          → fraction
  1..10    →  Int(1) Range Int(10) '.' then '.'            → not a fraction
  1...10   →  error: unknown operator '...'
  1.       →  Int(1) '.'          unchanged — the dot ends the statement
```

The number scanner already had that lookahead, so it needed no change; what
needed stating is that it *is* the rule.

### 4.1a A run of dots is a range only when an endpoint follows

The dot is the busiest character in ARO: it ends every statement, and it
spells a parent directory in the one place a path appears in source. Two
existing behaviours therefore constrain the range operator, and both were
found by the test suite rather than by reading:

<!-- aro-check: skip — two lines from different files, shown for the lexer rule -->
```aro
Log "hi" to the <console>..          (* GitLab #372: a double-tapped
                                        terminator is one terminator *)
import ../ModuleA                   (* ARO-0005 §3: a relative path *)
```

So the rule is positional. A run of two or more dots is a **range operator**
only when what follows it can begin an endpoint:

- a `<` **immediately** after the dots, or
- a digit, `(`, `-`, `+` or a quote, skipping spaces and tabs but never
  looking past a newline.

Anything else (a newline, `}`, `/`, a letter) leaves the run as the dots it
always was, one terminator token each.

A bare identifier is not an expression in ARO (a variable is `<name>`), which
is what makes the letter case safe: `Log "a" to the <console>.. Log "b" …` is
two statements, not a range. The `<` is required to be adjacent for the same
reason one step further on: a statement may begin with its verb in brackets
(`<Resize> the <thumbnail> …`), so `.. <Resize>` has to stay a terminator.
`1.. <hi>` is therefore not a spelling — `1..<hi>` and `1..< <hi>` both say
it, and neither needs the space before the bracket.

### 4.1b The `->` alternative is still open

[#546](https://git.ausdertechnik.de/arolang/aro/-/issues/546) carries a later
comment proposing a different spelling — `1->10`, one operator, both ends
always included, no `..<` at all — on the grounds that an arrow cannot collide
with the character ARO spends on sentence structure and reads as direction.

This document specifies `..` / `..<`, and the implementation follows this
document, because `Proposals/` is the project's source of truth (CLAUDE.md).
The decision is recorded as open here rather than settled silently, with the
facts the choice turns on:

- The collision the arrow avoids is handled by §4.1a, at a cost of two
  characters of lookahead, and the suite covers both behaviours it touches.
- `->` lexes today as `TokenKind.arrow`, which the parser never consumes, so
  nothing currently claims it.
- Changing the spelling later is mechanical: the two token kinds, one lexer
  case, and the diagnostics that quote the operator. Nothing in the AST, the
  evaluator, the serializer or the bridge mentions dots.
- Dropping `..<` is not mechanical. The exclusive bound would have to be
  written `1->(<n> - 1)` at every call site, and §2.1 is the argument for
  keeping it visible instead.

```
        ┌─────────────┐   digit    ┌──────────────┐
   ───► │  int digits │ ─────────► │  int digits  │
        └──────┬──────┘            └──────┬───────┘
               │ '.'                      │ '.'
               ▼                          ▼
        ┌─────────────┐            ┌──────────────┐
        │ peek next   │            │  peek next   │
        └──┬───────┬──┘            └──┬────────┬──┘
     digit │       │ '.'        digit │        │ '.'
           ▼       ▼                  ▼        ▼
       fraction   emit Int         fraction   emit Int
                  + range op                  + range op
```

### 4.2 `0..<<count>` is rejected, and `<lo>..<hi>` is inclusive

`..<` immediately followed by `<` opening a variable reference is ambiguous to
a reader, whatever the lexer decides. The proposal **requires a space**:

```aro
for each <i> in 0..< <count> { … }      (* accepted *)
for each <i> in 0..<<count> { … }       (* error *)
(* error: write `..< <count>` — `..<<` reads as two operators
     hint: a space after ..< separates the operator from the reference *)
```

Deciding it silently either way would produce a program whose meaning depends
on a lexer subtlety nobody can see. The diagnostic names the fix, which is
cheaper than the ambiguity.

The reason the space is required is the form §2 already promises:
`<lo>..<hi>`, a range of two references, contains the characters `..<`. Both
cannot be read the same way, so a `<` that opens a variable reference — a `<`
followed by a letter or `_` — belongs to the reference and the operator is the
inclusive one:

<!-- aro-check: skip — bare expressions, one of which is deliberately an error -->
```aro
<lo>..<hi>        (* inclusive: lo … hi *)
<lo>..< <hi>      (* exclusive: lo … hi-1 *)
0..<10            (* exclusive: the `<` is followed by a digit *)
0..<<count>       (* error, per the diagnostic above *)
```

### 4.3 The qualifier slot excludes ranges

`<a: 1..10>` does not parse as a range: the qualifier grammar splits on `.`
for chained qualifiers (`<x: a|b>`, date offsets, `handle.qualifier`), so a
`.` inside a qualifier slot already means something. A range in a qualifier
slot is a check-time error pointing at the colon form:

```
error: a range cannot appear in a qualifier — <a: 1..10>
  hint: the qualifier slot selects an operation; pass the range as the object
        instead — Compute the <a: length> from 1..10.
```

## 5. `[1..10]` is an error

The spelling the original issue reached for is, under this design, a
one-element list *containing* a range. That is almost certainly not what the
author meant, so it is rejected at check time rather than defined as sugar:

```
error: [1..10] is a list holding one range, not a range of ten values
  hint: drop the brackets — for each <n> in 1..10 { … }
```

Defining it as sugar would make `[1..10]` and `[1..10, 20]` mean
systematically different things, which is worse than a diagnostic.

## 6. Deliberately excluded

**Membership.** `where <n> in 1..10` is a *test*, not a sequence, and `in`
already means iteration in a `for each` header. Giving it a second meaning in
a `where` clause is a separate feature with its own ambiguity to settle, and
this proposal does not settle it. Until then: `where <n> >= 1 and <n> <= 10`.

**Pattern matching.** `match <n> { 1..10 → … }` needs a story for overlapping
and non-exhaustive arms that [ARO-0002](ARO-0002-control-flow.md) does not
have.

**Strides.** No `by 2`. A strided sequence is `for each … where` with a
modulo, or a `Filter`, until there is evidence the sugar is needed.

**Float and Date ranges.** §3.1.

## 7. The two counting forms

The language will have two ways to count, and they disagree about their upper
bound:

```aro
for <n> from 1 to 10 { … }        (* 1 … 9   — exclusive *)
for each <n> in 1..10 { … }       (* 1 … 10  — inclusive *)
for each <n> in 1..<10 { … }      (* 1 … 9   — same as the first form *)
```

This is the least comfortable part of the proposal, and pretending otherwise
would be worse than naming it. Three options were considered:

1. **Make `..` exclusive**, matching `from … to …`. Rejected: it makes the
   common case (`1..10` meaning ten things) the wrong one, and `..<` then has
   no job.
2. **Change `from … to …` to be inclusive.** Rejected: it is implemented,
   documented and in use; silently changing what a working loop binds is the
   worst outcome available.
3. **Keep both, document the split, prefer ranges.** Chosen.

`for <n> from … to …` stays valid and documented. It is not deprecated in this
proposal — it works, and removing it would break programs — but ranges are the
form to reach for, because the value composes and the bound is explicit at the
call site. `aro check` emits no warning for the older form; if the split proves
to be a real source of error in practice, a lint is a smaller, separate change
than a breaking one.

## 8. Implementation notes

Ordered so each step is independently testable:

1. **Lexer** — `..` and `..<` tokens, plus the numeric-literal lookahead in
   §4.1. Tests: `1..10`, `1..<10`, `1.5`, `1.`, `1...10`, `1_000..2_000`.
2. **AST + parser** — `RangeExpression(lower, upper, inclusive)` at the
   precedence in §2.2; the `..<<` diagnostic from §4.2; the `[1..10]`
   diagnostic from §5.
3. **Check-time** — endpoint type rule (§3.1) and the qualifier-slot rule
   (§4.3), both in `CodeQualityValidator` so `aro check` catches them without
   the runtime.
4. **Interpreter** — a lazy `Range` value on the ARO-0051 stream path;
   `length` as arithmetic (§3.3).
5. **Compiler** — the same via the C-ABI bridge, so `aro run` and `aro build`
   agree. A range in compiled code is a loop over two registers, not an
   allocation.
6. **Docs** — ARO-0002's "There is no range literal" paragraph points here;
   the Book's iteration chapter gains the value form; `Book/Reference`.

## 9. Open question

One thing this proposal does not settle: whether `Compute the <len: length>
from 1..10` should answer `10` by arithmetic (as §3.3 says) or whether
`length` on a lazy sequence should be refused outright to keep "lazy" honest.
Arithmetic is specified here because the answer is exact and free. If a later
proposal makes streams uniformly refuse `length`, this should follow it rather
than keep a special case.

As implemented, `length` answers — never refuses — and the number is right in
every case. Whether it arrives by arithmetic or by counting a list depends on
where the range sits, which is §10.2.

## 10. Implementation status (GitLab #546)

Implemented as specified, in both execution modes, with the two deviations
below. `Examples/Ranges` exercises every row of §3.4 that says "yes" and runs
under both `aro run` and `aro build` with byte-identical output.

### 10.1 Where the range lives

A range is a value in the source and a list in memory, **except** in the
`for each` collection slot, which is driven straight off the two endpoints:

| Position | Memory |
|---|---|
| `for each <n> in 1..300_000 { … }` | two integers |
| `Create the <decade> with 1..10.` | ten boxed Ints |
| `Compute the <len: length> from 1..10.` | ten boxed Ints |
| `Filter the <p> from 1..100 where … .` | a hundred boxed Ints |
| `Application.H the <h> with { hours: 0..<24 }.` | twenty-four boxed Ints |

The rule is decided at the one place that knows the slot — the interpreter's
`FeatureSetExecutor` and, for a compiled binary, `LLVMCodeGenerator` setting
`"lazy": true` on the serialised node — so the two modes cannot drift into
disagreeing about it. `AROIntRange` does the counting for both.

The reason the exception is only the loop is that every collection action in
the runtime reads `[any Sendable]`. A lazy value reaching `Sort`, `Group` or
`Return` would be a value those actions silently pass through unchanged, which
is a worse outcome than an eager list — ARO-0051's stream path has the same
shape and the same boundary.

### 10.2 Deviation: a materialised range is a `List`

§3.5 gives a range an opaque `Range` type that "is not a `List`", with
`Convert … to "list"` as the way across. Not implemented: once a range leaves
the loop slot it *is* a list, so `<decade> is a List` is true and `Convert` is
unnecessary. §3.5's distinction would need a type the runtime does not have,
and nothing in §3.4's accepted positions needs it.

### 10.3 Deviation: `length` of a range literal counts

§3.3 says `length` on a range is arithmetic. That holds where the range is
still a span (the loop slot, and `AROIntRange.count` itself, which is
`hi - lo + 1` and clamps rather than trapping on `Int.min..Int.max`). For
`Compute the <len: length> from 1..10_000_000.` the value has already
materialised by the time `length` is asked, so the answer is a count of ten
million Ints: correct, O(n) memory. Both modes do the same thing, which is why
this is a performance limitation rather than a divergence.

Making it arithmetic needs the consuming verb to be known at the point the
expression is bound — available in both modes, in two different places — and
that is a second rule to keep in sync for one qualifier. Deliberately not
taken here.

### 10.4 What a large range costs today

`for each <n> in 1..1_000_000` with a body, measured on an idle laptop:

| | interpreted | compiled |
|---|---|---|
| `for each <n> in 1..1_000_000` | 85 MB peak RSS | 6.4 GB peak RSS |
| `Create` a list, then iterate it | 125 MB peak RSS | 6.4 GB peak RSS |

The interpreted column is the property this proposal asked for. The compiled
column is a pre-existing cost of the compiled for-each itself — the same for
a range and for a list, so the range contributes nothing to it — and is worth
its own issue; nothing in the range path allocates per element.
