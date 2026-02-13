# plugin-c-hash

A C plugin for ARO that provides various hash functions.

## Installation

```bash
aro add git@github.com:arolang/plugin-c-hash.git
```

## Building

```bash
make
```

Or manually:

```bash
clang -O2 -fPIC -dynamiclib -o libhash_plugin.dylib src/hash_plugin.c
```

## Actions

### hash (or simple)

Computes a simple 32-bit hash of the input string.

**Input:**
- `data` (string): String to hash

**Output:**
- `hash`: 8-character hex string
- `algorithm`: "simple"
- `input`: Original input string

### djb2

Computes a DJB2 64-bit hash of the input string.

**Input:**
- `data` (string): String to hash

**Output:**
- `hash`: 16-character hex string
- `algorithm`: "djb2"
- `input`: Original input string

### fnv1a

Computes an FNV-1a 64-bit hash of the input string.

**Input:**
- `data` (string): String to hash

**Output:**
- `hash`: 16-character hex string
- `algorithm`: "fnv1a"
- `input`: Original input string

## Example Usage in ARO

```aro
(* Hash a password *)
(Hash Password: Security) {
    <Extract> the <password> from the <request: password>.
    <Hash> the <hashed> with <password>.
    <Return> an <OK: status> with <hashed>.
}
```

## License

MIT
