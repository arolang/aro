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
=> OK
```

Three statements. Three variables. All alive in the session.

## Inspection

To see what you've created, use `:vars`:

```
aro> :vars
Name     | Type    | Value
-------- | ------- | ---------------------
sum      | Integer | 30
terminal | Object  | { rows, is_tty, ... }
x        | Integer | 10
y        | Integer | 20
```

A table of your world: every variable, its type, its value, sorted by name.

`terminal` is not yours. The runtime binds it for every feature set — screen
size, TTY status, colour support — and the REPL is a feature set like any
other, so it shows up here from the first statement you run. Ignore it.

## Deep Inspection

For complex objects, inspect them individually:

```
aro> Create the <user> with { name: "Alice", age: 30 }.
=> OK

aro> :vars user
user
  Type:  Object
  Value: {
    age: 30
    name: "Alice"
  }
```

The `:vars` command with a name dives deeper. Fields come back in alphabetical
order, not the order you wrote them.

## Type Checking

Curious about a type? Use `:type`:

```
aro> :type user
Object { age: Integer, name: String }
```

The structure revealed.

## Building Up

The REPL is perfect for building complexity gradually:

```
aro> Set the <base-price> to 100.
=> OK

aro> Compute the <tax> from <base-price> * 0.2.
=> OK

aro> Compute the <total> from <base-price> + <tax>.
=> OK

aro> :vars
Name       | Type    | Value
---------- | ------- | ----------------------
base-price | Integer | 100
tax        | Double  | 20.0
terminal   | Object  | { width, is_tty, ... }
total      | Double  | 120.0
```

Step by step, your data grows — and the type column earns its keep here. One
`Integer` times `0.2` gave a `Double`, and that `Double` carried into `total`.
Nothing announced the conversion; `:vars` is where you notice it.

## Starting Fresh

Sometimes you want to start over:

```
aro> :clear
Session cleared

aro> :vars
No variables defined
```

A blank slate. The conversation begins anew. `:clear` also drops every feature
set you defined and unsubscribes their event handlers — it is the whole
session, not just the variables.

---

**Next: Chapter 4 — Define**
