# plugin-c-hash

A C plugin for ARO that provides various hash functions.
Implements the **ARO-0073 ABI**.

> **Note:** For new C plugins, use the [ARO Plugin SDK for C](https://github.com/arolang/aro-plugin-sdk-c) which provides helpers and boilerplate for the ARO-0073 ABI.

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

## ARO-0073 ABI

The plugin exposes the following C functions:

| Function | Signature | Required |
|----------|-----------|----------|
| `aro_plugin_info` | `char* (void)` | Yes |
| `aro_plugin_init` | `void (void)` | Yes (lifecycle) |
| `aro_plugin_shutdown` | `void (void)` | Yes (lifecycle) |
| `aro_plugin_execute` | `char* (const char* action, const char* input_json)` | Yes |
| `aro_plugin_free` | `void (char* ptr)` | Yes |

### Input JSON shape (ARO-0073)

```json
{
  "result":      { "base": "simple-result", "specifiers": [] },
  "source":      { "base": "test-string",   "specifiers": [] },
  "preposition": "from",
  "_with":       { "test-string": "Hello, ARO!" },
  "_context":    { "featureSet": "Application-Start", "activity": "Hash Plugin Demo" }
}
```

The plugin resolves the value to hash from (in priority order):

1. First string value inside `_with`
2. Top-level `source` string
3. Legacy `data` / `object` keys (backwards compat)

## Actions

### Hash.Hash (verb: `Hash.Hash` or `hash`)

Computes a simple 32-bit polynomial hash of the input string.

**Output fields:**
- `hash`: 8-character hex string
- `algorithm`: `"simple"`
- `input`: original input string

### Hash.DJB2 (verb: `Hash.DJB2` or `djb2`)

Computes a DJB2 64-bit hash of the input string.

**Output fields:**
- `hash`: 16-character hex string
- `algorithm`: `"djb2"`
- `input`: original input string

### Hash.FNV1a (verb: `Hash.FNV1a` or `fnv1a`)

Computes an FNV-1a 64-bit hash of the input string.

**Output fields:**
- `hash`: 16-character hex string
- `algorithm`: `"fnv1a"`
- `input`: original input string

## Example Usage in ARO

```aro
(Application-Start: Hash Plugin Demo) {
    Create the <test-string> with "Hello, ARO!".

    Hash.Hash  the <simple-result> from the <test-string>.
    Hash.DJB2  the <djb2-result>   from the <test-string>.
    Hash.FNV1a the <fnv-result>    from the <test-string>.

    Extract the <simple-hash> from the <simple-result: hash>.
    Extract the <djb2-hash>   from the <djb2-result:   hash>.
    Extract the <fnv-hash>    from the <fnv-result:    hash>.

    Log <simple-hash> to the <console>.
    Log <djb2-hash>   to the <console>.
    Log <fnv-hash>    to the <console>.

    Return an <OK: status> for the <startup>.
}
```

## License

MIT
