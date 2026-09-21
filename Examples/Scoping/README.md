# Scoping

Demonstrates every scoping mechanism ARO has, in one HTTP application.

## What It Does

`Application-Start` publishes a configuration object and starts the HTTP
server, then stays alive with `Keepalive`. Two route handlers and an event
handler show which published values each one can see, and why.

## Features Tested

- **Local scope** — variables are private to the feature set that creates them
- **Published variables** — `Publish as <alias> <var>` reaches every feature set
  with the **same business activity**, and no others
- **Business activity** — the second half of the header decides both when a
  feature set runs and which published variables it can read
- **Framework-injected variables** — `<event>` is bound by the runtime, not by
  any statement in the body
- **Transformation pipeline** — each step produces a new name, because values
  are immutable
- **Loop variable isolation** — the loop variable and anything created in the
  body exist only for that iteration

This README described a console application using `Require` and a nested config
object; the example has been an HTTP application with `Publish` and `Keepalive`
for some time (GitLab #818).

## Related Proposals

- [ARO-0001: Language Fundamentals](../../Proposals/ARO-0001-language-fundamentals.md)

## Usage

```bash
# Interpreted
aro run ./Examples/Scoping

# Compiled
aro build ./Examples/Scoping
./Examples/Scoping/Scoping
```

## Example Output

```
Starting application...
Scoping Demo
1.0
Configuration:
Scoping Demo
1.0
```

---

*Explicit dependencies, local scope. What you see in a feature set is what it has access to.*
