# Chapter 4: Define

*"Sometimes you need more than one statement."*

---

## Feature Sets

ARO programs are made of feature sets—groups of statements that work together. In a file, they look like this:

```aro
(Calculate Area: Geometry) {
    Extract the <width> from the <input: width>.
    Extract the <height> from the <input: height>.
    Compute the <area> from <width> * <height>.
    Return an <OK: status> with { area: <area> }.
}
```

The REPL supports this too.

## Entering Feature Set Mode

Start typing a feature set header, and the REPL shifts modes:

```
aro> (Calculate Area: Geometry) {
(Calculate Area)>
```

The prompt changes. You're now inside the feature set. Each statement you type becomes part of it:

```
(Calculate Area)> Extract the <width> from the <input: width>.
  +
(Calculate Area)> Extract the <height> from the <input: height>.
  +
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

Run your feature set with `:invoke`:

```
aro> :set input { width: 5, height: 10 }
=> OK

aro> :invoke Calculate Area
=> { area: 50 }
```

Or provide input inline:

```
aro> :invoke Calculate Area { width: 3, height: 4 }
=> { area: 12 }
```

## Multi-Line Objects

Feature sets aren't the only multi-line construct. Objects work too:

```
aro> Create the <config> with {
...>   host: "localhost",
...>   port: 8080,
...>   debug: true
...> }.
=> { host: "localhost", port: 8080, debug: true }
```

The `...>` continuation prompt appears whenever input is incomplete.

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
