# HelloWorld

The simplest possible ARO application.

## What It Does

Creates a greeting string, logs it to the console, and exits. This is the starting point for understanding ARO's basic structure.

## Features Tested

- **Application-Start** - Entry point feature set
- **Create action** - Variable binding with type annotation
- **Log action** - Console output
- **Return action** - Application exit with status

## Related Proposals

- [ARO-0001: Language Fundamentals](../../Proposals/ARO-0001-language-fundamentals.md)
- [ARO-0004: Actions](../../Proposals/ARO-0004-actions.md)

## Usage

```bash
# Interpreted
aro run ./Examples/HelloWorld

# Compiled
aro build ./Examples/HelloWorld
./Examples/HelloWorld/HelloWorld
```

## Example Output

```
Hello, ARO World!
```

---

*Seven lines. One action per line. The essence of ARO in its purest form.*
