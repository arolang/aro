# Wiki Update Notes for ARO-0072 (Iteration & Collection Improvements)

This document lists the wiki pages that need to be updated to reflect the new language features added in ARO-0072.

## Summary of New Features

1. **Indexed for-each** — `for each <item> at <idx> in <collection>` (already existed, documenting now)
2. **Numeric range loop** — `for <var> from <low> to <high>` — iterate integers low..<high
3. **Optional retrieve with default** — `Retrieve ... default <expr>` — fallback when where-filter returns no results
4. **Join action** — `Join the <result> from <collection> with "sep"` — join array to string

---

## Wiki Pages to Update

### 1. Language Reference / Control Flow

Add **Iteration** section covering all loop forms:

#### Collection Iteration (for-each)
```aro
for each <item> in <items> {
    Log <item> to the <console>.
}
```

#### Indexed Iteration (at <idx>)
```aro
for each <line> at <idx> in <lines> {
    Compute the <numbered> from <idx> ++ ": " ++ <line>.
}
```
- `<idx>` is zero-based
- Eliminates counter-repository pattern for indexed access

#### Numeric Range Loop
```aro
for <i> from 0 to 10 {
    Log <i> to the <console>.
}
```
- `from` value is inclusive, `to` value is exclusive (0..<10 → 0,1,...,9)
- Replaces the `"x"*N split /x/` workaround
- Useful for fixed-height display panels, grid rendering, numeric sequences

#### Reserved Words in Variable Names
The following words cannot appear in variable names:
`on`, `in`, `is`, `with`, `at`, `for`, `from`, `to`
Use alternatives: `<active>` not `<is-active>`, `<start-date>` not `<from-date>`.

---

### 2. Language Reference / Actions — OWN Actions

Add **Join** action:

```aro
Join the <result> from <collection> with "separator".
```

- Joins array elements into a single string
- Complement of `Split`
- `with ""` produces concatenation without separator
- Round-trip: `Split → transform → Join`

Examples:
```aro
Join the <csv> from <fields> with ",".
Join the <sentence> from <words> with " ".
Join the <text> from <lines> with "\n".
```

---

### 3. Language Reference / Repositories

Add **Optional Retrieve with Default** subsection under "Filtered Retrieval":

```aro
(* Before: verbose match *)
Retrieve the <results> from the <repo> where <key> = <k>.
Compute the <found> from <results: length> > 0.
match <found> {
    case true  { Extract the <entry> from the <results: 0>. }
    case false { Create the <entry> with "fallback". }
}

(* After: one line with default *)
Retrieve the <entry> from the <repo> where <key> = <k> default "fallback".
```

- Default can be any expression: string, number, object literal, list
- Only used when where-filtered result is empty
- When where clause returns ≥1 result, default is ignored
- Works with object defaults for dict-keyed repositories:
  ```aro
  Retrieve the <row> from the <preview-repository> where <key> = <idx> default { key: -1, line: "" }.
  ```

---

### 4. Action Developer Guide / Action Reference

Add Join to the action table:

| Action | Role | Preposition | Description |
|--------|------|-------------|-------------|
| Join | OWN | from (with separator) | Join collection elements into a string |

---

### 5. Examples to Add / Update

- Update `Examples/Iteration/` to show all three loop forms
- Add `Examples/JoinExample/` showing Split-transform-Join roundtrip
- Update any examples using the `"x"*N split /x/` pattern to use range loops
