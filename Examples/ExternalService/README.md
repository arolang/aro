# ExternalService

Demonstrates the **Call action** with stateful plugin services that maintain persistent state across method invocations.

## What This Example Shows

This example answers: **"Why does Call exist when Request handles HTTP and Exec handles commands?"**

- **Request**: Stateless HTTP - each call is independent
- **Exec**: Command execution - no persistence between calls
- **Call**: Stateful services - maintain connections/state for application lifetime

## The Counter Service

Uses a simple counter service plugin that maintains an internal count variable. Each call to the service modifies or reads this persistent state:

1. `<Call> from <counter: increment>` - Increments count (0 → 1)
2. `<Call> from <counter: increment>` - Increments again (1 → 2)
3. `<Call> from <counter: get>` - Reads current count (2)

This demonstrates Call's unique purpose: **services that maintain state between method calls**.

Real-world examples: database connection pools, Redis caches, message queue channels, custom plugins with persistent state.

## Features Demonstrated

- **Stateful services** - Counter maintains state across multiple calls
- **Plugin system** - Custom service implemented as a dynamic library
- **Proper logging** - Each value logged separately with qualified statements
- **Deterministic output** - No external dependencies, stable test results

## Plugin Implementation

The CounterService plugin (`plugins/CounterPlugin/`) demonstrates:

- C-compatible plugin interface with `@_cdecl` functions
- Thread-safe state management with DispatchQueue
- Service registration via `aro_plugin_init`
- Method dispatch pattern (increment, get, reset)

## Related Proposals

- [ARO-0004: Actions](../../Proposals/ARO-0004-actions.md) - Action roles and Call action
- [ARO-0010: Advanced Features](../../Proposals/ARO-0010-advanced-features.md) - Plugin system

## Usage

```bash
# Build the plugin first
cd Examples/ExternalService/plugins/CounterPlugin
swift build -c release
cd ../../../..

# Run the example (interpreted)
aro run ./Examples/ExternalService

# Or compile to native binary
aro build ./Examples/ExternalService
./Examples/ExternalService/ExternalService
```

## Example Output

```
[Application-Start] === External Service Demo ===
[Application-Start] Demonstrating stateful service calls...
[Application-Start]
[Application-Start] Step 1: Increment counter
[Application-Start] Current count:
[Application-Start] 1
[Application-Start]
[Application-Start] Step 2: Increment counter again
[Application-Start] Current count:
[Application-Start] 2
[Application-Start]
[Application-Start] Step 3: Get current count
[Application-Start] Current count:
[Application-Start] 2
[Application-Start]
[Application-Start] State persisted across calls: 0 -> 1 -> 2
[Application-Start] This demonstrates why Call exists!
[OK] startup
[Application-End] External service demo completed.
[OK] shutdown
```

---

*Stateful services persist for the application lifetime - Call action enables patterns that Request and Exec cannot.*
