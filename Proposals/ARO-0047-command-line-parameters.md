# ARO-0047: Command-Line Parameters

* Proposal: ARO-0047
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0008

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

### Positional Arguments

A flag is not how a single-argument tool is invoked. `./crawler --url https://example.com`
reads as configuration; `./crawler https://example.com` reads as the thing the
program is for. Until GitLab #857 only the first was possible, and every CLI
example in the books taught the workaround.

An application declares the positionals it reads in its entry point's header,
with the `takes` clause ARO-0081 already uses for user-defined actions:

```aro
(Application-Start: Crawler takes <url> <depth>) {
    Extract the <site> from the <parameter: url>.
    Extract the <levels> from the <parameter: depth>.
    Return an <OK: status> for the <startup>.
}
```

```bash
aro run ./Crawler https://example.com 3
./crawler https://example.com 3
```

One header form, two meanings, because the declaration is the same thing in
both: the inputs this unit is called with. The names may be written
juxtaposed or comma-separated — `takes <url> <depth>` and `takes <url>, <depth>`
are the same header.

A declared name is read exactly like a flag, through `<parameter: name>`. That
is deliberate: a program should not have to care which spelling the caller used,
and a tool that grows a `--url` flag later keeps working. **A flag wins over a
positional of the same name** — `--url` is explicit, a position is inferred.

Positionals are also readable as a whole, declared or not:

```aro
Extract the <files> from the <parameter: arguments>.   (* every positional, in order *)
```

`arguments` is a list of strings in command-line order, which is what a
variadic tool wants — `./wc a.txt b.txt c.txt` cannot name its inputs in a
header. Declared names are additionally type-coerced by the table above;
`arguments` is not, because a list whose elements changed type individually
would be worse than useless.

A declared positional the caller did not supply is simply absent, and reading
it fails the way any missing parameter does:

```
Could not extract the depth from the parameter: depth
```

#### Parsing rules

| Argument | Read as |
|----------|---------|
| `--key value`, `--key=value`, `--flag`, `-f`, `-abc` | as the tables above |
| anything else | a positional, appended in order |
| `--` | end of flags; **everything** after it is positional |

The `--` terminator is how a positional that begins with `-` is passed at all,
and it is the answer to the one ambiguity in this grammar: `--key value`
consumes the token after it, so

```bash
./crawler --verbose https://example.com     # verbose = "https://example.com", no positional
./crawler --verbose=true https://example.com
./crawler -- --verbose https://example.com  # two positionals
```

The first line is the trap. Nothing in `argv` says whether `--verbose` takes a
value, and a declaration that settled it per flag is a bigger change than this
one; `--key=value`, or `--`, says it unambiguously. The behaviour predates
positionals and is unchanged by them.

#### Compiled binaries

Identical. The entry point's `takes` clause is baked into the binary at build
time — the AST is gone by the time it runs — and the names reach
`ParameterStorage` before `argv` is parsed. Names and values are stored apart
and joined on read, so neither mode depends on the order the two arrive in.

#### Why the header, and not `aro.yaml`

Declaring positionals in a configuration file would be more consistent with
how ARO treats HTTP (a contract in `openapi.yaml`, ARO-0003). It was rejected
here because the two cases are not alike: an OpenAPI contract is a document
other people build against, while a command line is read in one place by one
program, and putting its declaration in a second file means the reader of
`Extract the <url> from the <parameter: url>.` cannot see where `url` comes
from. `takes` keeps the declaration next to the only code that reads it, and
reuses a spelling ARO-0081 already taught.

Indexed access — `<parameter: 1>` — was rejected for a narrower reason: a
numeric specifier on a list already means something else in ARO. ARO-0038
counts numeric indices **from the end**, so `<parameter: 1>` would be either
the second argument or the second-from-last depending on which rule a reader
had in mind, and one of those readers would be wrong.

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

    (* Use the parameter when it was passed, the fallback otherwise *)
    Create the <port> with <params: port> default 8080.
    Create the <host> with <params: host> default "0.0.0.0".

    Log "Starting server on ${<host>}:${<port>}" to the <console>.
    Return an <OK: status> for the <startup>.
}
```

```bash
aro run . --port 3000  # Uses port 3000, host defaults to 0.0.0.0
```

`default` is the defaulting operator (ARO-0001 §Expressions and Operators): it
returns the parameter when it was passed and the fallback when it was not. It
is *not* `or` — `or` is a boolean operator, so `<params: port> or 8080` binds
`true` rather than a port number. This section taught the `or` spelling until
GitLab #547; programs written from it bound `true` and failed later, wherever
the value was used.

A parameter that was passed empty (`--prefix ""`) counts as present and wins
over the fallback: the default fires on absence, never on falsiness.

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
4. **`FeatureSet.positionalParameters`** - the entry point's `takes` clause,
   read by `Application.run()` (interpreter) and baked in by
   `LLVMCodeGenerator` via `aro_declare_positional_parameters` (compiled)

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

Rejected **as a separator between `aro run`'s own options and the
application's**: it adds complexity for users, and since `aro run` has
well-defined options, treating everything after the path as application
arguments is simpler.

`--` does exist *inside* the application's own arguments, where it separates
flags from positionals — see §Positional Arguments. The two are different
boundaries and only the second earns the token.

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
