# ARO-0047: Command-Line Parameters

## Summary

Add support for command-line parameters that ARO applications can extract using a dedicated `parameter` system object, enabling applications to receive configuration values at runtime without relying on environment variables.

## Motivation

Currently, ARO applications receive external configuration through environment variables:

```aro
Extract the <start-url> from the <env: CRAWL_URL>.
```

While environment variables work, they have limitations:
- Verbose to set: `CRAWL_URL=http://example.com aro run .`
- Platform-specific syntax differences (Windows vs Unix)
- Not self-documenting in application usage
- Awkward for ad-hoc invocation

Command-line parameters are the standard way applications receive configuration:

```bash
aro run . --url http://example.com
./crawler --url http://example.com --depth 3 --verbose
```

This proposal adds a `parameter` system object that provides access to command-line arguments passed to ARO applications.

## Specification

### Syntax

Extract parameters using the same pattern as environment variables:

```aro
Extract the <url> from the <parameter: url>.
Extract the <depth> from the <parameter: depth>.
Extract the <all-params> from the <parameter>.  (* Returns dictionary *)
```

### Parameter Passing

#### Interpreter Mode

Arguments after the path are passed to the application:

```bash
aro run ./MyApp --url http://example.com --count 5 --verbose
```

| Argument | Parameter Name | Value | Type |
|----------|---------------|-------|------|
| `--url http://example.com` | `url` | `"http://example.com"` | String |
| `--count 5` | `count` | `5` | Int |
| `--verbose` | `verbose` | `true` | Bool |

#### Compiled Binary Mode

The compiled binary receives arguments directly:

```bash
./MyApp --url http://example.com --count 5 --verbose
```

### Argument Parsing Rules

#### Long Options (`--`)

| Pattern | Interpretation |
|---------|----------------|
| `--key value` | Named parameter with value |
| `--key=value` | Named parameter with value (equals syntax) |
| `--flag` | Boolean flag (value = `true`) |

#### Short Options (`-`)

| Pattern | Interpretation |
|---------|----------------|
| `-f` | Boolean flag `f` = `true` |
| `-abc` | Combined flags: `a`, `b`, `c` each = `true` |

Short options are boolean-only. For values, use long options.

### Type Coercion

Values are automatically converted to appropriate types:

| Pattern | Type | Example |
|---------|------|---------|
| Integer (`^\d+$`) | `Int` | `--count 5` → `5` |
| Float (`^\d+\.\d+$`) | `Double` | `--rate 1.5` → `1.5` |
| Boolean (`true`/`false`) | `Bool` | `--enabled true` → `true` |
| Boolean flag (no value) | `Bool` | `--verbose` → `true` |
| Otherwise | `String` | `--url http://...` → `"http://..."` |

### Error Handling

Missing parameters follow ARO's happy-path philosophy:

```aro
(* If --url was not provided, this fails with a descriptive error: *)
(* "Could not extract the url from the parameter: url" *)
Extract the <url> from the <parameter: url>.
```

### All Parameters

Extract all parameters as a dictionary:

```aro
Extract the <params> from the <parameter>.
(* Returns: { "url": "http://...", "count": 5, "verbose": true } *)
```

## Examples

### Basic Usage

```aro
(Application-Start: Greeter) {
    Extract the <name> from the <parameter: name>.
    Log "Hello, ${<name>}!" to the <console>.
    Return an <OK: status> for the <greeting>.
}
```

```bash
aro run . --name Alice
# Output: Hello, Alice!
```

### Multiple Parameters

```aro
(Application-Start: Web Crawler) {
    Extract the <url> from the <parameter: url>.
    Extract the <depth> from the <parameter: depth>.
    Extract the <verbose> from the <parameter: verbose>.

    when <verbose> is true {
        Log "Starting crawl of ${<url>} to depth ${<depth>}" to the <console>.
    }

    Emit a <CrawlPage: event> with { url: <url>, depth: <depth> }.
    Return an <OK: status> for the <startup>.
}
```

```bash
aro run ./Crawler --url http://example.com --depth 3 --verbose
```

### Optional Parameters with Defaults

```aro
(Application-Start: Server) {
    (* Extract all parameters *)
    Extract the <params> from the <parameter>.

    (* Use parameter or default *)
    Create the <port> with <params: port> or 8080.
    Create the <host> with <params: host> or "0.0.0.0".

    Log "Starting server on ${<host>}:${<port>}" to the <console>.
    Return an <OK: status> for the <startup>.
}
```

```bash
aro run . --port 3000  # Uses port 3000, host defaults to 0.0.0.0
```

### Combined Flags

```aro
(Application-Start: Tool) {
    Extract the <params> from the <parameter>.

    when <params: v> is true {
        Log "Verbose mode enabled" to the <console>.
    }

    when <params: f> is true {
        Log "Force mode enabled" to the <console>.
    }

    Return an <OK: status> for the <tool>.
}
```

```bash
aro run . -vf  # Both verbose and force enabled
```

## Implementation

### Runtime Components

1. **ParameterStorage** - Thread-safe singleton storing parsed parameters
2. **ParameterObject** - System object conforming to `SystemObject` protocol
3. **ExtractAction** - Extended to handle `parameter` base identifier

### CLI Integration

The `aro run` command captures arguments after the path:

```
aro run <path> [application-arguments...]
```

### Compiled Binary Integration

The LLVM-generated `main()` function passes `argc`/`argv` to a bridge function that populates `ParameterStorage`.

## Alternatives Considered

### Using `--` Separator

```bash
aro run . --verbose -- --url http://example.com
```

Rejected because it adds complexity for users. Since `aro run` has well-defined options, treating everything after the path as application arguments is simpler.

### Prefix Syntax

```bash
aro run . -P url=http://example.com
```

Rejected because it diverges from standard CLI conventions. Users expect `--url value` syntax.

### Environment Variable Only

Keeping only `<env: VAR>` syntax.

Rejected because command-line parameters are more ergonomic for ad-hoc invocation and are the standard approach for CLI applications.

## Compatibility

This is a new feature with no breaking changes. Existing applications using environment variables continue to work unchanged.

## References

- ARO-0008: I/O Services (System Objects)
- POSIX argument conventions
- GNU long option conventions
