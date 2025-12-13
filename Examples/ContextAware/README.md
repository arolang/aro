# ContextAware

Demonstrates how ARO automatically formats output based on execution context.

## What It Does

Creates structured data (users, orders, tags) and returns it. The same code produces different output formats depending on how it's executed: human-readable for CLI, diagnostic tables for debug mode, and JSON for HTTP APIs.

## Features Tested

- **Context detection** - Runtime determines output format automatically
- **Human context** - Clean, readable output for `aro run`
- **Developer context** - Type-annotated tables for `aro run --debug`
- **Machine context** - JSON responses for HTTP API calls
- **Nested object literals** - Complex data structures with objects and arrays

## Related Proposals

- [ARO-0031: Context-Aware Response Formatting](../../Proposals/ARO-0031-context-aware-formatting.md)
- [ARO-0002: Expressions](../../Proposals/ARO-0002-expressions.md)

## Usage

```bash
# Human-readable output
aro run ./Examples/ContextAware

# Developer diagnostic output
aro run ./Examples/ContextAware --debug

# Compiled binary
aro build ./Examples/ContextAware
./Examples/ContextAware/ContextAware
```

## Example Output (Human Context)

```
[OK] context-demo
  order.customer: Alice Smith
  order.items: 3
  summary: Demo of context-aware formatting
  tags: featured, premium, verified
  user.active: true
  user.name: Alice Smith
```

---

*One codebase, many audiences. The runtime adapts presentation to whoever is listening.*
