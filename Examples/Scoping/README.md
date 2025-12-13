# Scoping

Demonstrates variable visibility, scoping rules, and dependency declaration.

## What It Does

Shows how variables are scoped within feature sets, how to access nested object properties, and how to declare external dependencies using `<Require>`.

## Features Tested

- **Require action** - `<Require>` for explicit dependency declaration
- **Variable binding** - `<Create>` with string literals
- **Object literals** - Nested objects with `settings: { debug: true }`
- **Property access** - `<config: name>` for nested property extraction
- **Feature set scope** - Variables local to their feature set

## Related Proposals

- [ARO-0003: Variable Scoping](../../Proposals/ARO-0003-variable-scoping.md)

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
