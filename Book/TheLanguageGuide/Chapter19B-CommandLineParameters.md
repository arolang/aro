# Chapter 19B: Command-Line Parameters

*"The simplest configuration is the one you type at the prompt."*

---

## 19B.1 Why Command-Line Parameters

Every ARO application can receive configuration when it starts — the server port, a target URL, whether to run in verbose mode. The question is how that configuration arrives.

ARO offers three mechanisms, each suited to different situations:

| Mechanism | Syntax | Best for |
|-----------|--------|----------|
| **Command-line parameters** | `--port 8080` | Ad-hoc invocation, scripts, tools |
| **Environment variables** | `PORT=8080 aro run .` | Deployment configuration, containers |
| **Hardcoded values** | `Create the <port> with 8080.` | Defaults, constants that never change |

Command-line parameters are the natural choice for values that change per-run: a URL to process, a file to read, a count to use. They are self-documenting — anyone who reads the invocation knows what the application received — and they follow the conventions users already know from other tools.

This chapter covers ARO's `parameter` system object, which gives feature sets direct access to arguments passed on the command line.

---

## 19B.2 The `parameter` System Object

`parameter` is a read-only system object. It exposes the arguments passed to the application when it was started. Like all system objects, you access it with the `Extract` action.

Extracting a named parameter:

```aro
Extract the <url> from the <parameter: url>.
```

This reads the value of `--url` from the command line. If no `--url` was provided, the runtime produces an error — matching ARO's happy-path philosophy where missing required input is an error, not a case to handle in code.

Extracting all parameters at once:

```aro
Extract the <params> from the <parameter>.
```

This produces a dictionary containing every argument that was passed, ready for qualified access with the `:<key>` syntax.

---

## 19B.3 Passing Arguments

### Interpreter Mode

Pass arguments after the application path:

```bash
aro run ./MyApp --name Alice --count 3 --verbose
```

Everything after `./MyApp` is treated as application arguments. The `aro run` tool's own options (`--verbose`, `--debug`) must appear before the path.

### Compiled Binary Mode

After `aro build`, the compiled binary receives arguments directly:

```bash
./MyApp --name Alice --count 3 --verbose
```

The argument parsing behavior is identical in both modes.

---

## 19B.4 Argument Syntax

ARO supports the argument conventions common to Unix tools.

### Named Parameters (Long Options)

The standard form passes a key and a value:

```bash
aro run ./App --url http://example.com
aro run ./App --count 5
aro run ./App --host=localhost    # Equals syntax also works
```

Inside the application, extract by name:

```aro
Extract the <url> from the <parameter: url>.
Extract the <count> from the <parameter: count>.
Extract the <host> from the <parameter: host>.
```

### Boolean Flags (Long)

A long option with no following value becomes a boolean `true`:

```bash
aro run ./App --verbose
aro run ./App --dry-run
```

```aro
Extract the <verbose> from the <parameter: verbose>.    (* true *)
Extract the <dry-run> from the <parameter: dry-run>.    (* true *)
```

Flags that were not provided produce an error when extracted directly. Use the all-parameters form with a default to handle optional flags safely (see section 19B.6).

### Short Flags

Single-character flags with a single dash:

```bash
aro run ./App -v
```

Combined short flags are split into individual boolean values:

```bash
aro run ./App -vf   # Sets v=true and f=true
```

Short flags are boolean only. For values, use long options.

### Summary

| Invocation | Parameter name | Value | Type |
|------------|----------------|-------|------|
| `--url http://...` | `url` | `"http://..."` | String |
| `--count 5` | `count` | `5` | Int |
| `--rate 1.5` | `rate` | `1.5` | Double |
| `--verbose` | `verbose` | `true` | Bool |
| `--enabled true` | `enabled` | `true` | Bool |
| `--enabled false` | `enabled` | `false` | Bool |
| `-v` | `v` | `true` | Bool |
| `-vf` | `v`, `f` | `true`, `true` | Bool, Bool |

---

## 19B.5 Type Coercion

ARO automatically converts argument strings to the appropriate type. You do not need to parse or cast the values:

- **Integer** — if the value matches `^\d+$`, it becomes an `Int`
- **Double** — if the value contains a decimal point and matches `^\d+\.\d+$`, it becomes a `Double`
- **Boolean** — the literal strings `"true"` and `"false"` become `Bool`
- **String** — everything else stays as `String`

This means a feature set that expects a count gets an integer it can use in arithmetic immediately:

```aro
Extract the <count> from the <parameter: count>.
Compute the <double-count> from <count> * 2.
```

And a feature set that expects a flag gets a boolean it can use in a guard:

```aro
Extract the <params> from the <parameter>.
Create the <verbose> with <params: verbose> or false.

when <verbose> is true {
    Log "Verbose mode enabled" to the <console>.
}
```

---

## 19B.6 Optional Parameters with Defaults

When a parameter may or may not be present, extract all parameters first, then use the `or` operator to provide a default:

```aro
Extract the <params> from the <parameter>.

Create the <port> with <params: port> or 8080.
Create the <host> with <params: host> or "0.0.0.0".
Create the <verbose> with <params: verbose> or false.
```

The `or` operator evaluates the right side when the left side is absent (the key does not exist in the dictionary). This is ARO's standard approach for optional values — it reads naturally and keeps the code linear.

Contrast with extracting a parameter directly, which fails if the parameter was not provided:

```aro
(* This requires --port to be present. Absent = error. *)
Extract the <port> from the <parameter: port>.

(* This is optional. Absent = 8080. *)
Extract the <params> from the <parameter>.
Create the <port> with <params: port> or 8080.
```

Choose whichever form matches the parameter's intent. Required parameters should use the direct form so the error message is immediate and clear. Optional parameters with sensible defaults should use the all-parameters form.

---

## 19B.7 Accessing All Parameters

Extracting the bare `parameter` object returns a dictionary of every argument:

```aro
Extract the <params> from the <parameter>.
```

Given `aro run ./App --url http://example.com --count 5 --verbose`, `params` will contain:

```json
{
  "url": "http://example.com",
  "count": 5,
  "verbose": true
}
```

You can then navigate it with qualified access:

```aro
Extract the <url> from the <params: url>.
Extract the <count> from the <params: count>.
```

Or pass the entire dictionary somewhere else:

```aro
Emit a <AppStarted: event> with <params>.
```

The two extraction styles are equivalent for required parameters but the all-parameters form is essential when you need to check for the presence of optional flags, or when you want to forward the full configuration to another part of the application.

---

## 19B.8 Parameters vs Environment Variables

Both `parameter` and `env` are source-only system objects with the same extraction syntax:

```aro
Extract the <port> from the <parameter: port>.   (* command-line *)
Extract the <port> from the <env: PORT>.          (* environment  *)
```

The choice between them is primarily ergonomic and conventional:

**Use `parameter` when:**
- The value is specific to one invocation
- You are building a CLI tool or script
- You want self-documenting invocations in shell history
- The value changes frequently across runs

**Use `env` when:**
- The value is set by the deployment environment (containers, CI, servers)
- The value is sensitive (passwords, API keys should stay in env, not in shell history)
- You want to avoid repeating long values on every invocation

Nothing prevents using both in the same application — for example, a server might take its port from `--port` when run by a developer locally, and from `$PORT` when deployed in a container. The convention is to check `parameter` first and fall back to `env`:

```aro
Extract the <all-params> from the <parameter>.
Extract the <all-env> from the <env>.

Create the <port> with <all-params: port> or <all-env: PORT> or 8080.
```

---

## 19B.9 Complete Example: File Processor

A CLI tool that reads a file, counts its words, and optionally shows verbose output:

```aro
(Application-Start: File Processor) {
    (* All parameters, with defaults for optional ones *)
    Extract the <params> from the <parameter>.
    Extract the <path> from the <parameter: path>.     (* required *)
    Create the <verbose> with <params: verbose> or false.
    Create the <format> with <params: format> or "text".

    when <verbose> is true {
        Log "Processing file:" to the <console>.
        Log <path> to the <console>.
    }

    Read the <content> from the <file: path>.
    Split the <words> from <content> with " ".
    Compute the <word-count: count> from <words>.

    match <format> {
        case "json" {
            Create the <result> with { file: <path>, words: <word-count> }.
            Log <result> to the <console>.
        }
        case "text" {
            Log "Word count:" to the <console>.
            Log <word-count> to the <console>.
        }
    }

    Return an <OK: status> with <word-count>.
}
```

Running the tool:

```bash
# Basic usage (path required)
aro run ./FileProcessor --path report.txt

# With optional flags
aro run ./FileProcessor --path report.txt --verbose

# JSON output
aro run ./FileProcessor --path report.txt --format json

# After compiling
aro build ./FileProcessor
./FileProcessor --path report.txt --verbose
```

The compiled binary accepts the exact same arguments as the interpreter, so development and production invocations are identical.

---

## 19B.10 Summary

The `parameter` system object provides clean access to command-line arguments:

1. **Named parameters** — `Extract the <name> from the <parameter: name>.` reads `--name value` directly.
2. **All parameters** — `Extract the <params> from the <parameter>.` returns a dictionary for optional access.
3. **Defaults** — `Create the <port> with <params: port> or 8080.` handles optional parameters with fallbacks.
4. **Type coercion** — integers, doubles, and booleans are automatically converted; no parsing needed.
5. **Short flags** — `-v` and combined `-vf` become boolean entries in the parameter dictionary.
6. **Both modes** — works identically in `aro run` and compiled binaries.

Command-line parameters are the right choice for values that change per-invocation. For deployment configuration, prefer environment variables. For constants, hardcode them. Together, these three mechanisms cover the full range of configuration needs without any special syntax or configuration files.

---

*Next: Chapter 20 — Custom Actions*
