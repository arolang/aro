# ARO-0089: Ranges

- **Status:** Implemented ([Issue #546](https://git.ausdertechnik.de/arolang/aro/-/issues/546)) — operator settled as `->` (§4.3); two deviations recorded in §10
- **Author:** ARO Language Team
- **Created:** 2026-09-18
- **Related:** ARO-0002 (Control Flow), ARO-0051 (Streaming Execution), ARO-0001 (Language Fundamentals), ARO-0003 (Type System), ARO-0019 (Standard Library), ARO-0038 (List Element Access), ARO-0082 (Numeric Separators), ARO-0041 (Date/Time Ranges)

## Abstract

> A range is a **value**, not a loop.
> `1->10` is a thing you can name, pass and measure; counting is what you then
> do with it.

ARO can already count — `for <n> from 1 to 10 { … }` — but it cannot *hold* a
span of integers. There is no way to hand "1 through 10" to `Filter`, `Map`,
`Compute … length`, or a user-defined action, because nothing in the language
produces a range value. This proposal adds one.

One spelling, one meaning: `1->10` is the span from 1 to 10, **both ends
included**, and it reads aloud the way it is written. The value is lazy where
laziness is what matters — iterating one does not materialise it, in either
execution mode — so `for each <n> in 1->10_000_000` costs O(1) memory. §10
records where that holds and where the implementation falls back to a list.

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

<!-- aro-check: skip — statements that had no range value to use, shown as the gap -->
```aro
Create the <decade> with 1->10.                  (* no range value exists *)
Compute the <len: length> from 1->10.            (* nothing to measure *)
Filter the <picks> from 1->100 where … .         (* nothing to filter *)
Application.Histogram the <h> from 0->23.        (* nothing to pass *)
```

Without a range operator, every one of these is a parse error: `->` lexed to
a token nothing in the grammar consumed.

### 1.3 Why a range and not a list

`[1, 2, 3]` already exists, and for three elements it is the better spelling.
The argument for ranges is the large and the computed case: `[1, 2, …, 10000]`
cannot be written, and `<lo>-><hi>` cannot be written as a literal at all. A
range also carries its intent — a contiguous ascending span — which a list of
integers only implies.

## 2. Syntax

```
range_expression = expression , "->" , expression ;
```

Both endpoints are **included**:

<!-- aro-check: skip — bare expressions, not statements -->
```aro
1->10        (* 1 2 3 4 5 6 7 8 9 10 *)
<lo>-><hi>   (* endpoints are expressions *)
0->23        (* the twenty-four hours of a day *)
```

### 2.1 One operator, both ends included

A range says where it starts and where it ends, and reads that way aloud:
"one to ten". There is no exclusive-upper-bound form — `..<` or any other
spelling — and that is a deliberate exclusion rather than an omission:

- Half-open ranges exist in other languages mostly to index arrays from zero,
  which is not what ARO's ranges are for. ARO's element access is
  [ARO-0038](ARO-0038-list-element-access.md)'s specifiers, and its loops bind
  values rather than indices.
- Two operators make the reader check which one they are looking at every
  time. One spelling cannot be misread.

Where an exclusive bound is genuinely wanted, subtract — and the subtraction
is then visible at the call site:

<!-- aro-check: skip — bare expressions, not statements -->
```aro
for each <i> in 0->(<count> - 1) { … }
```

### 2.1a Why an arrow and not dots

`..` was the first sketch, and implementing it is what settled the question
against it (see §4.3). The dot is the busiest character in ARO: it ends every
statement, and it spells a parent directory in the one place a path appears in
source. `..` therefore cannot be lexed as an operator without a positional
rule deciding, character by character, whether a run of dots is an operator or
a terminator — and a reader has to carry that rule to know what a line means.

An arrow collides with none of it. `->` cannot be a statement terminator,
cannot appear in `../ModuleA`, and cannot be confused with the `<` that opens
a variable reference, so `<lo>-><hi>` needs no rule at all. It also reads as
direction, which is what a range is, and ARO's whole surface is meant to be
sayable.

### 2.2 Precedence

A range binds **looser than arithmetic and tighter than comparison**:

```
 low                                                     high
 or  →  and  →  comparison  →  RANGE  →  additive  →  multiplicative
```

So `1-><n> + 1` is `1->(<n> + 1)`, which is what it reads like. A range is not
a comparison operand, so `1->10 = x` is a check-time error rather than a
silent parse.

Ranges do not chain: `1->5->10` is an error, not a nested range.

## 3. Semantics

### 3.1 Endpoints

Integer endpoints only. A non-integer endpoint is a check-time error naming
the offending side:

<!-- aro-check: skip — a deliberate endpoint-type error, with the diagnostic beneath it -->
```aro
Create the <r> with 1->2.5.
(* error: a range endpoint must be an Int, but the upper endpoint is a Float
     hint: round it first — Compute the <hi: fixed> from 2.5. *)
```

`Date` endpoints are deliberately **not** part of this proposal:
[ARO-0041](ARO-0041-datetime-ranges.md) already specifies date ranges and
recurrence, with its own semantics for what "between two dates" means.
Conflating the two would make `->` mean one thing for numbers and another for
dates.

Endpoints are evaluated **once**, when the range value is produced — never per
element, matching the rule [ARO-0002](ARO-0002-control-flow.md) already states
for the `for each` collection slot.

### 3.2 A descending range is empty

<!-- aro-check: skip — a loop header with an elided body -->
```aro
for each <n> in 10->1 { … }     (* zero iterations *)
```

Empty, not reversed, and not an error. Reversing is an action — `Reverse the
<r> for the <1->10>.` — so a range has exactly one direction and there is no
second way to spell a descending sequence. This also means `<lo>-><hi>` with
computed endpoints degrades quietly to "nothing to do" instead of running
backwards, which is what a program that filtered its data down to nothing
wants.

`1->1` has one element; `1->0` has none.

### 3.3 Ranges are lazy

A range does not build a list. It is a stream in the sense of
[ARO-0051](ARO-0051-streaming-execution.md), so:

<!-- aro-check: skip — loop headers with elided bodies -->
```aro
for each <n> in 1->10_000_000 { … }      (* O(1) memory *)
Compute the <len: length> from 1->10_000_000.   (* 10000000 — but see §10.3 *)
```

`length` on a range is arithmetic — `max(0, hi - lo + 1)` — not a traversal.
Numeric separators come free, since
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
| `for each` collection | `for each <n> in 1->10 { … }` | yes |
| `Create … with` | `Create the <decade> with 1->10.` | yes |
| Compute qualifier input | `Compute the <len: length> from 1->10.` | yes |
| Pipeline source | `Filter the <p> from 1->100 where … .` | yes |
| Action argument | `Application.H the <h> from 0->23.` | yes |
| `where` clause | `where <n> in 1->10` | **no** — see §6 |
| Pattern / `match` arm | `match <n> { 1->10 … }` | **no** — see §6 |

### 3.5 Type

A range's type is `Range`, an opaque ordered Int sequence. It is iterable and
measurable; it is not a `List`. `Convert the <l> from <r> to "list"`
materialises one when a program genuinely needs indexing
([ARO-0038](ARO-0038-list-element-access.md)).

**Not implemented** — see §10.2. A range that is bound to a name is a `List`
today, and `Convert` is therefore unnecessary.

## 4. Lexing

The arrow needs almost nothing from the lexer, which is the argument for it
(§2.1a). `->` was already a token — `TokenKind.arrow`, produced and never
consumed by the parser — so the operator costs one precedence entry and one
infix case. What follows is the three places a dot is still involved.

### 4.1 Reaching for `..` is reported, not guessed

`1..10` is the spelling a reader of other languages tries first, and the
language has to answer it rather than cascade. A run of two or more dots
followed by something that can begin an endpoint is one error naming the
arrow:

```
error: '..' is not a range operator — a range is written with an arrow, as in 1->10
  hint: A range is written `1->10`, and both ends are included.
  hint: There is no exclusive-upper-bound operator — subtract instead: `1->(<n> - 1)`.
```

`1..<10`, `1...10`, `<lo>..<hi>` and `0..<<count>` all land on it, each
quoting what was written. The run — including a `..<`'s `<` — is consumed and
stands in for the operator, so one mistake earns one diagnostic instead of
four.

"Something that can begin an endpoint" means a `<` immediately after the dots,
or a digit, `(`, `-`, `+` or a quote after optional spaces and tabs, never
looking past a newline. The narrowness is what leaves the two legitimate
meanings of a dot alone:

<!-- aro-check: skip — two lines from different files, shown for the dot rule -->
```aro
Log "hi" to the <console>..          (* GitLab #372: a double-tapped
                                        terminator is one terminator *)
import ../ModuleA                   (* ARO-0005 §3: a relative path *)
```

A bare identifier is not an expression in ARO (a variable is `<name>`), so a
letter after a run of dots means a new statement, and
`Log "a" to the <console>.. Log "b" …` stays two statements. A statement may
begin with its verb in brackets (`<Resize> the <thumbnail> …`), which is why
the `<` must be adjacent to the dots to count.

Note what this rule can and cannot do. It decides whether to emit a
*diagnostic*; it no longer decides what a program means. A misjudgement here
produces a spurious error, never a program that compiles and counts something
else — which is exactly the difference between an arrow and a dotted operator.

### 4.1a Numeric literals need no change

The number scanner already required a digit *after* a `.` to start a
fraction, so nothing about ranges touches it:

```
  1.5      →  Float(1.5)     '.' then digit  → fraction
  1.       →  Int(1) '.'     the dot ends the statement
  1->10    →  Int(1) -> Int(10)
```

Numeric separators ([ARO-0082](ARO-0082-numeric-separators.md)) are scanned
inside the integer, before the arrow is reached: `1_001->2_000` works.

### 4.2 The qualifier slot excludes ranges

`<a: 1->10>` is not a range: the qualifier slot selects an *operation*
(`length`, `handle.qualifier`, a date offset, an element range like `1-3`).
A range there is a check-time error pointing at the object form:

```
error: a range cannot appear in a qualifier — <a: 1->10>
  hint: the qualifier slot selects an operation; pass the range as the object
        instead — Compute the <a: length> from 1->10.
  hint: an element range in a specifier is written with a hyphen —
        <items: 1-3> (ARO-0038).
```

### 4.3 How the spelling was settled

The first sketch in [#546](https://git.ausdertechnik.de/arolang/aro/-/issues/546)
used `..` and `..<`, borrowed from Swift. The issue's comment of **2026-09-07**
replaced that decision with `->`, one operator, both ends included, and asked
for it to be carried into the proposal; an earlier revision of this document
was written after that date and specified dots anyway, without saying so.

Implementing the dotted form is what turned the comment's prediction into
evidence. Two conflicts appeared immediately, neither visible from the
sketch, and both caught by the existing test suite rather than by reading:

1. **`..` is a double-tapped statement terminator** (GitLab #372). Making it
   an operator broke `Log "hi" to the <console>..`, which the language
   deliberately tolerates.
2. **`..` is the parent directory of an import path** (ARO-0005 §3). Making it
   an operator broke `import ../ModuleA`, and with it every multi-application
   project.

Both are *programs that compile today*. Keeping them working needed a
positional rule — a run of dots is an operator only when an endpoint-looking
character follows it on the same line — plus an adjacency rule for the `<`
that opens a reference, because `<lo>..<hi>` and `<lo>..<` + `<hi>` are the
same characters. That is three rules a reader has to carry to know what a line
means, and the comment of 2026-09-07 had predicted exactly that cost.

With `->` all three disappear. The question is settled: the operator is `->`,
there is no `..<`, and what remains of the dot rule is the §4.1 diagnostic.

## 5. `[1->10]` is an error

Brackets around a range make a one-element list *containing* a range. That is
almost certainly not what the author meant, so it is rejected at check time
rather than defined as sugar:

```
error: [1->10] is a list holding one range, not the values of 1->10
  hint: drop the brackets — for each <n> in 1->10 { … }
```

Defining it as sugar would make `[1->10]` and `[1->10, 20]` mean
systematically different things, which is worse than a diagnostic.

## 6. Deliberately excluded

**An exclusive upper bound.** No `..<` and no other spelling for it — §2.1.
Subtract: `0->(<count> - 1)`.

**Membership.** `where <n> in 1->10` is a *test*, not a sequence, and `in`
already means iteration in a `for each` header. Giving it a second meaning in
a `where` clause is a separate feature with its own ambiguity to settle, and
this proposal does not settle it. Until then: `where <n> >= 1 and <n> <= 10`.

**Pattern matching.** `match <n> { 1->10 … }` needs a story for overlapping
and non-exhaustive arms that [ARO-0002](ARO-0002-control-flow.md) does not
have.

**Strides.** No `by 2`. A strided sequence is `for each … where` with a
modulo, or a `Filter`, until there is evidence the sugar is needed.

**Float and Date ranges.** §3.1.

## 7. The two counting forms

The language has two ways to count, and they disagree about their upper bound:

<!-- aro-check: skip — loop headers with elided bodies -->
```aro
for <n> from 1 to 10 { … }        (* 1 … 9   — the upper bound is exclusive *)
for each <n> in 1->10 { … }       (* 1 … 10  — both ends *)
for each <n> in 1->9 { … }        (* 1 … 9   — the same span as the first *)
```

This is the least comfortable part of the proposal, and pretending otherwise
would be worse than naming it. Three options were considered:

1. **Make the range exclusive**, matching `from … to …`. Rejected: it makes
   the common case (`1->10` meaning ten things) the wrong one, and an arrow
   that excludes what it points at does not read as an arrow.
2. **Change `from … to …` to be inclusive.** Rejected: it is implemented,
   documented and in use; silently changing what a working loop binds is the
   worst outcome available.
3. **Keep both, document the split, prefer ranges.** Chosen.

`for <n> from … to …` stays valid and is now documented, production and all,
in [ARO-0002 §4.3](ARO-0002-control-flow.md) — it had neither until
GitLab #546. It is not deprecated: it works, and removing it would break
programs. Ranges are the form to reach for, because the value composes and
both ends are visible where they are written. `aro check` emits no warning for
the older form; if the split proves to be a real source of error in practice,
a lint is a smaller, separate change than a breaking one.

## 8. Implementation notes

Ordered so each step is independently testable, and this is the order it was
built in:

1. **Lexer** — none, beyond giving the existing `->` token a meaning. The
   numeric scanner is untouched (§4.1a). The `..` diagnostic of §4.1 is the
   one piece of dot handling that remains.
2. **AST + parser** — `RangeExpression(lower, upper)` at the precedence in
   §2.2, with no inclusivity flag to carry (§2.1); the chaining and `[1->10]`
   diagnostics.
3. **Check-time** — the endpoint-type rule (§3.1), the qualifier-slot rule
   (§4.2) and the comparison-operand rule (§2.2), so `aro check` catches all
   three without the runtime.
4. **Interpreter** — `AROIntRange`, and a for-each driver that walks it from
   the endpoints.
5. **Compiler** — the same `AROIntRange` through the C-ABI bridge, with the
   collection slot marked `"lazy"` at serialisation time so `aro run` and
   `aro build` agree by construction. A range in compiled code is a loop over
   an index and two integers, not an allocation.
6. **Docs** — ARO-0002 §4.1 (the collection slot) and §4.3 (the range loop,
   which had no production at all); the Book's control-flow chapter gains the
   value form.

## 9. Open question

One thing this proposal does not settle: whether `Compute the <len: length>
from 1->10` should answer `10` by arithmetic (as §3.3 says) or whether
`length` on a lazy sequence should be refused outright to keep "lazy" honest.
Arithmetic is specified here because the answer is exact and free. If a later
proposal makes streams uniformly refuse `length`, this should follow it rather
than keep a special case.

As implemented, `length` answers — never refuses — and the number is right in
every case. Whether it arrives by arithmetic or by counting a list depends on
where the range sits, which is §10.3.

## 10. Implementation status (GitLab #546)

Implemented as specified, in both execution modes, with the two deviations
below. `Examples/Ranges` exercises every row of §3.4 that says "yes" and runs
under both `aro run` and `aro build` with byte-identical output.

### 10.1 Where the range lives

A range is a value in the source and a list in memory, **except** in the
`for each` collection slot, which is driven straight off the two endpoints:

| Position | Memory |
|---|---|
| `for each <n> in 1->300_000 { … }` | two integers |
| `Create the <decade> with 1->10.` | ten boxed Ints |
| `Compute the <len: length> from 1->10.` | ten boxed Ints |
| `Filter the <p> from 1->100 where … .` | a hundred boxed Ints |
| `Application.H the <h> with { hours: 0->23 }.` | twenty-four boxed Ints |

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
`hi - lo + 1` and clamps rather than trapping on `Int.min->Int.max`). For
`Compute the <len: length> from 1->10_000_000.` the value has already
materialised by the time `length` is asked, so the answer is a count of ten
million Ints: correct, O(n) memory. Both modes do the same thing, which is why
this is a performance limitation rather than a divergence.

Making it arithmetic needs the consuming verb to be known at the point the
expression is bound — available in both modes, in two different places — and
that is a second rule to keep in sync for one qualifier. Deliberately not
taken here.

### 10.4 What a large range costs today

`for each <n> in 1->1_000_000` with a body, measured on an idle laptop:

| | interpreted | compiled |
|---|---|---|
| `for each <n> in 1->1_000_000` | 85 MB peak RSS | 6.4 GB peak RSS |
| `Create` a list, then iterate it | 125 MB peak RSS | 6.4 GB peak RSS |

The interpreted column is the property this proposal asked for. The compiled
column is a pre-existing cost of the compiled for-each itself — the same for
a range and for a list, so the range contributes nothing to it — and is worth
its own issue; nothing in the range path allocates per element.
