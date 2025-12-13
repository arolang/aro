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

- [ARO-0001: Core Syntax](../../Proposals/ARO-0001-core-syntax.md)
- [ARO-0020: Action Framework](../../Proposals/ARO-0020-action-framework.md)

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
