# Chapter 7: Depart

*"Take your conversation with you."*

---

## Nothing Is Lost

Every statement you've typed, every variable you've created, every feature set you've defined—none of it has to disappear when you leave.

## Export Your Session

The `:export` command captures your session as a proper `.aro` file:

```
aro> Set the <base-price> to 100.
=> OK

aro> Compute the <tax> from <base-price> * 0.2.
=> 20

aro> Compute the <total> from <base-price> + <tax>.
=> 120

aro> :export
(* Generated from ARO REPL session *)
(* Date: 2026-02-14T10:30:00Z *)

(REPL Session: Interactive) {
    Set the <base-price> to 100.
    Compute the <tax> from <base-price> * 0.2.
    Compute the <total> from <base-price> + <tax>.
}
```

Your exploration becomes code.

## Save to File

```
aro> :export ./pricing.aro
Exported to ./pricing.aro
```

The file is ready. Run it with `aro run ./pricing.aro`.

## Export as Test

Turn your session into a test file with assertions:

```
aro> :export --test ./pricing-test.aro
Exported as test file
```

The result:

```aro
(* Generated test from ARO REPL session *)

(Pricing Test: Test) {
    Set the <base-price> to 100.
    Assert the <base-price> is 100.

    Compute the <tax> from <base-price> * 0.2.
    Assert the <tax> is 20.

    Compute the <total> from <base-price> + <tax>.
    Assert the <total> is 120.
}
```

Your experiments become guarantees.

## Save and Load

Save your session state for later:

```
aro> :save ./my-session.repl
Session saved

# Later...
aro> :load ./my-session.repl
Session restored (3 variables, 1 feature set)
```

Resume where you left off.

## The Goodbye

When you're ready:

```
aro> :quit
Goodbye!
```

Or press `Ctrl+D` on an empty line.

The prompt disappears. You return to your shell. But everything you learned stays with you.

---

## The End of the Beginning

You've learned to:

- **Enter** the REPL
- **Speak** in statements
- **Remember** with variables
- **Define** feature sets
- **Command** the REPL
- **Extend** with services and plugins
- **Depart** with your work saved

This is just the beginning. The REPL is your laboratory. Use it to explore ARO's full power—actions, events, HTTP, files, sockets, and more.

The prompt awaits.

```
aro> _
```

---

*"The Dialog is how I learned ARO. Not from documentation—from conversation."*
