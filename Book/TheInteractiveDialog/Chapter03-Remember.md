# Chapter 3: Remember

*"The session remembers what you've said."*

---

## Persistence

Variables don't disappear between statements. The session remembers:

```
aro> Set the <x> to 10.
=> OK

aro> Set the <y> to 20.
=> OK

aro> Compute the <sum> from <x> + <y>.
=> 30
```

Three statements. Three variables. All alive in the session.

## Inspection

To see what you've created, use `:vars`:

```
aro> :vars
┌──────┬─────────┬───────┐
│ Name │ Type    │ Value │
├──────┼─────────┼───────┤
│ x    │ Integer │ 10    │
│ y    │ Integer │ 20    │
│ sum  │ Integer │ 30    │
└──────┴─────────┴───────┘
```

A table of your world. Every variable, its type, its value.

## Deep Inspection

For complex objects, inspect them individually:

```
aro> Create the <user> with { name: "Alice", age: 30 }.
=> { name: "Alice", age: 30 }

aro> :vars user
user
  Type:  Object
  Value: {
    name: "Alice",
    age: 30
  }
```

The `:vars` command with a name dives deeper.

## Type Checking

Curious about a type? Use `:type`:

```
aro> :type user
Object { name: String, age: Integer }
```

The structure revealed.

## Building Up

The REPL is perfect for building complexity gradually:

```
aro> Set the <base-price> to 100.
=> OK

aro> Compute the <tax> from <base-price> * 0.2.
=> 20

aro> Compute the <total> from <base-price> + <tax>.
=> 120

aro> :vars
┌────────────┬─────────┬───────┐
│ Name       │ Type    │ Value │
├────────────┼─────────┼───────┤
│ base-price │ Integer │ 100   │
│ tax        │ Double  │ 20.0  │
│ total      │ Double  │ 120.0 │
└────────────┴─────────┴───────┘
```

Step by step, your data grows.

## Starting Fresh

Sometimes you want to start over:

```
aro> :clear
Session cleared

aro> :vars
No variables defined
```

A blank slate. The conversation begins anew.

---

**Next: Chapter 4 — Define**
