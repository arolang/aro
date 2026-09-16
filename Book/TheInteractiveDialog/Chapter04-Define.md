# Chapter 4: Define

*"Sometimes you need more than one statement."*

---

## Feature Sets

ARO programs are made of feature sets—groups of statements that work together. In a file, they look like this:

```aro
(Calculate Area: Geometry) {
    Compute the <area> from <width> * <height>.
    Return an <OK: status> with { area: <area> }.
}
```

The REPL supports this too.

## Entering Feature Set Mode

Start typing a feature set header, and the REPL shifts modes:

```
aro> (Calculate Area: Geometry) {
Defining feature set: Calculate Area
(Calculate Area)>
```

The prompt changes. You're now inside the feature set. Each statement you type becomes part of it:

```
(Calculate Area)> Compute the <area> from <width> * <height>.
  +
(Calculate Area)> Return an <OK: status> with { area: <area> }.
  +
```

The `+` confirms each statement was added.

## Closing the Feature Set

Close with a brace:

```
(Calculate Area)> }
Feature set 'Calculate Area' defined
```

You're back in direct mode. The feature set is registered.

## Listing Feature Sets

See what you've defined:

```
aro> :fs
Feature Sets:
  - Calculate Area (Geometry)
```

## Invoking Feature Sets

Run your feature set with `:invoke`, passing a JSON object:

```
aro> :invoke Calculate Area {"width": 3, "height": 4}
=> 12
```

Write the JSON as you would anywhere else — the argument is taken verbatim from
the opening `{`, so the quotes need no escaping. It used to strip them, which
made `{\"width\": 3}` the only spelling that worked; that form is still
accepted, so an old note of yours will not break (GitLab #578).

The keys arrive **both** ways, so the same feature-set body works at the prompt
and in a file:

```aro
Extract the <w> from the <input: width>.   (* ARO-0081's shape, as in a file *)
Compute the <d> from <width> * 2.          (* and the keys bound directly     *)
```

The `input` record is the one to prefer: it is what a user-defined action reads
(ARO-0081), so a prototype moves into a file unchanged. The direct bindings are
kept because `:invoke` has always offered them.

It has to be JSON, though — ARO's own object-literal spelling with unquoted
keys is not accepted.

You can also seed a variable first and invoke with no input at all:

```
aro> :set width 3
=> OK
aro> :set height 4
=> OK
```

`:set` parses its value as JSON, then as a number, then as a boolean, and
finally keeps it as a string — so `:set width 3` binds an `Integer` and
`:set label hello` binds a `String`.

## Multi-Line Objects

Feature sets aren't the only multi-line construct. Objects work too:

```
aro> Create the <config> with {
...>   host: "localhost",
...>   port: 8080,
...>   debug: true
...> }.
=> OK
```

The `...>` continuation prompt appears whenever a bracket, brace, parenthesis
or string is still open. It does *not* appear for a missing period — see
chapter 2.

## When to Use Feature Sets

Direct statements are great for exploration. Feature sets are for reusable logic:

| Use Case | Approach |
|----------|----------|
| Quick calculation | Direct statement |
| Testing an idea | Direct statement |
| Reusable operation | Feature set |
| HTTP handler | Feature set |
| Event handler | Feature set |

The REPL supports both. Use what fits.

---

**Next: Chapter 5 — Command**
