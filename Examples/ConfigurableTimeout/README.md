# Configurable Timeout Example

This example demonstrates how to use the `<Configure>` action to set custom timeout values in ARO applications.

## Overview

The IDE plugins (VSCode and IntelliJ) use a default 5-second timeout for binary path validation. On slow systems or when validating remote binaries, this may not be sufficient.

## Using the Configure Action

The `<Configure>` action allows you to set configuration values that persist during application execution:

```aro
<Configure> the <validation: timeout> with 10.
```

This sets a timeout of 10 seconds.

## Application to IDE Plugin Validation

While the IDE plugin validation timeout is currently hardcoded, this example shows the pattern for how configurable timeouts could be implemented in your own ARO applications.

### Current IDE Plugin Behavior

**Java (IntelliJ):**
```java
private static final long VALIDATION_TIMEOUT_SECONDS = 5;
```

**TypeScript (VSCode):**
```typescript
const VALIDATION_TIMEOUT_MS = 5000;
```

### Future Enhancement

The plugins could be enhanced to read timeout configuration from an ARO config file in the workspace:

```aro
(* .aro/config.aro *)
(Plugin Configuration: IDE Settings) {
    <Configure> the <validation: timeout> with 10.
    <Configure> the <lsp: debug> with true.
}
```

## Running This Example

```bash
# Build and run
aro run ./Examples/ConfigurableTimeout

# Or compile to native binary
aro build ./Examples/ConfigurableTimeout
./Examples/ConfigurableTimeout/ConfigurableTimeout
```

## Expected Output

```
Application started with custom timeout configuration
10
```

## Key Concepts

1. **Configure Action**: Sets runtime configuration values
2. **Qualified Variables**: `<validation: timeout>` groups related config
3. **Type Safety**: Timeouts are numeric values
4. **Persistence**: Configuration persists for the application lifetime

## Related

- ARO-0001: Language Fundamentals (Configure action)
- ARO-0010: Advanced Features
- Editor plugin documentation in `Editor/*/README.md`
