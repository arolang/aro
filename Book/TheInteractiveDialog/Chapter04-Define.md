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

Run your feature set with `:invoke`. Input is a JSON object, and its keys
arrive as ordinary bindings inside the feature set — `width` and `height`, not
fields of an `input` record:

```
aro> :invoke Calculate Area {\"width\": 3, \"height\": 4}
=> 12
```

Two things about that line are unlovely, and both are worth knowing before
they cost you ten minutes.

**The quotes need escaping.** `:invoke`'s argument parser strips bare `"`
characters before the JSON parser ever sees them, so `{"width": 3}` arrives as
`{width: 3}` and is rejected as `Invalid JSON input`. Writing `\"` gets a real
quote through. ARO's own object-literal spelling — unquoted keys — is not
accepted either; it has to be JSON (GitLab issue #578).

**Input is not `input`.** A feature set written for a file, reading
`Extract the <width> from the <input: width>.`, will fail here: the keys are
bound directly, so the statement to write at the prompt is the one above, using
`<width>` straight. Keep that in mind when you move a prototype into a file, or
a file's feature set into the prompt — this is the one place where a cell and a
feature-set body are *not* the same statements.

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
