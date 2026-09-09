# Chapter 3: Using Plugins in ARO

*"A good API is one you can use without reading the documentation. A great API is one you want to read the documentation for."*

---

Before writing plugins, let's master using them. This chapter covers the complete workflow: finding plugins, installing them, and using their functionality. Even if you're eager to start building, understanding the user experience will make you a better plugin author.

## 3.1 Finding Plugins

The ARO plugin ecosystem is distributed across Git repositories. Currently, plugins are discovered through:

- **The official ARO GitHub organization**: `github.com/arolang/plugin-*`
- **Community repositories**: Shared through documentation and word of mouth
- **Private repositories**: For organization-internal plugins

To see what's available in your application, use the CLI:

```bash
aro plugins list
```

This shows all installed plugins:

```
Managed Plugins (from Plugins/):
──────────────────────────────────────────────────────────────────
 Name                   Version   Source        Provides
 plugin-crypto          1.0.0     github.com    1 rust
 plugin-csv             1.0.0     github.com    1 rust
 plugin-transformer     1.0.0     github.com    1 python
──────────────────────────────────────────────────────────────────
 3 managed plugins
```

The `Provides` column counts `provides` entries and names their type — it is
about how the plugin is built, not what it exposes. For the verbs and
qualifiers, use `aro actions` and `aro actions --qualifiers`.

For detailed information about a specific plugin:

```bash
aro plugins list --verbose
```

`aro plugins` has more subcommands than this chapter uses: `update`,
`rebuild`, `validate`, `check` (compatibility and lockfile integrity),
`docs` (generate a plugin's documentation), and `export` / `restore`, which
write and replay an `.aro-sources` file so a checkout can rebuild its plugin
set. Run `aro plugins --help` for the current set.

## 3.2 Installing Plugins

Installing a plugin is a single command:

```bash
aro add https://github.com/arolang/plugin-crypto
```

This command:

1. Clones the repository to a temporary location
2. Reads the `plugin.yaml` manifest
3. Resolves any dependencies
4. Copies files to your `Plugins/` directory
5. Compiles native plugins if needed
6. Registers the plugin's actions for use

You can specify a particular version:

```bash
aro add https://github.com/arolang/plugin-csv --ref v1.2.0
```

Or track a specific branch:

```bash
aro add https://github.com/arolang/plugin-transformer --branch develop
```

The installation output shows what's happening:

```
📦 Resolving package: plugin-crypto
   Cloning from https://github.com/arolang/plugin-crypto...
   ✓ Cloned (ref: main, commit: e1ea086)

📂 Reading plugin.yaml:
   Name:    plugin-crypto
   Version: 1.0.0
   Actions: Hash, Encrypt, Decrypt

🔗 Installing to Plugins/plugin-crypto/
   ✓ Rust plugin built
   ✓ Registered actions: Hash, Encrypt, Decrypt

✅ Package "plugin-crypto" v1.0.0 installed successfully.
```

### Editor and AI-agent visibility

Plugin actions, qualifiers, and their metadata are exposed to tooling automatically. The Language Server (`aro lsp`) loads plugins from `<workspace>/Plugins/` on `initialized` and surfaces them in completion, hover, and diagnostics. The MCP server (`aro mcp`) ships the same information through the `aro_actions` and `aro_qualifiers` tools, each of which accepts a `directory:` argument so an AI agent can see workspace-local plugins. The richer your `description`, `role`, `prepositions`, and `since` fields are, the better that downstream experience.

### How plugins ship with compiled binaries

`aro build` discovers every plugin under `Plugins/` (and the legacy `plugins/`), compiles each one, and statically links the result into the application binary — including Rust plugins, which are linked through `.a` archives extracted with `llvm-ar` and renamed with `llvm-objcopy` to avoid symbol collisions. The compiled binary is self-contained: there is no next-to-binary `Plugins/` to ship.

## 3.3 Using Plugin Actions

Plugins provide **custom actions** that work like built-in ARO verbs. Once installed, you use them with natural ARO syntax:

```aro
(* Plugin actions feel native *)
Crypto.Hash the <digest> from the <password>.
Crypto.Encrypt the <ciphertext> from the <secret-data> with { key: <key> }.
Csv.Parse the <records> from the <csv-file>.
Llm.Summarize the <summary> from the <document> with { maxLength: 200 }.
```

This is the primary way to use plugins. Each action follows the standard ARO pattern:

```
Handle.Action the <result> preposition the <object>.
```

### Handles: the plugin's namespace

`Crypto`, `Csv` and `Llm` above are **handles** — the PascalCase namespace each
plugin declares in its `plugin.yaml`:

```yaml
name: plugin-crypto
handle: Crypto
```

Two things follow, and the asymmetry between them trips people up:

**Actions work with or without the handle.** A native plugin (C, C++, Rust or
Swift) registers each verb twice, so `Hash the <digest> from the <password>.`
also resolves. Prefer the namespaced form anyway — it says where the verb came
from, and it is the only spelling that survives two plugins wanting `Hash`.
Python plugins register *only* the namespaced form, so there the handle is not
optional.

**Qualifiers only work with the handle.** There is no bare form:

```aro
Compute the <sorted: Collections.sort> from the <numbers>.   (* resolves *)
Compute the <sorted: sort> from the <numbers>.               (* error *)
```

```
error: Unknown Compute qualifier 'sort'
hint: Plugin qualifiers are namespaced: <sorted: handle.sort>
hint: Run `aro actions --qualifiers` for the full set
```

A plugin whose `plugin.yaml` omits `handle` therefore ships qualifiers nobody
can reach. Chapter 4 covers declaring one, including the deprecated `handler:`
form you will meet in older plugins.

`aro actions` and `aro actions --qualifiers`, run from your application
directory, print everything that actually registered — the fastest way to find
out what a freshly installed plugin gave you.

### Example: Crypto Plugin

```aro
(Secure Password: User Registration) {
    Extract the <password> from the <request: body.password>.

    (* Hash the password using the plugin's Hash action *)
    Crypto.Hash the <password-hash> from the <password> with { algorithm: "argon2" }.

    (* Store the hashed password *)
    Create the <user> with {
        email: <request: body.email>,
        passwordHash: <password-hash>
    }.
    Store the <user> into the <user-repository>.

    Return a <Created: status> with { id: <user: id> }.
}
```

### Example: CSV Plugin

```aro
(Ingest Data: Data Handler) {
    Read the <csv-content> from the <file: "./data/users.csv">.

    (* Parse CSV using the plugin's Parse action *)
    Csv.Parse the <records> from the <csv-content> with {
        headers: true,
        delimiter: ","
    }.

    (* Process each record *)
    for each <record> in <records> {
        Create the <user> with <record>.
        Store the <user> into the <user-repository>.
    }

    Return an <OK: status> with { imported: <records: length> }.
}
```

### Example: LLM Transformer Plugin

```aro
(Analyze Feedback: Feedback Handler) {
    Extract the <text> from the <feedback: content>.

    (* Use plugin actions for AI analysis *)
    Llm.Summarize the <summary> from the <text> with { maxLength: 100 }.
    Llm.Classify the <sentiment> from the <text> with {
        labels: ["positive", "negative", "neutral"]
    }.
    Llm.Embed the <embedding> from the <text>.

    Create the <analysis> with {
        original: <text>,
        summary: <summary>,
        sentiment: <sentiment>,
        embedding: <embedding>
    }.

    Return an <OK: status> with <analysis>.
}
```

## 3.4 Action Qualifiers and Options

Plugin actions support qualifiers and options for fine-grained control.

### Qualifiers

A plugin can also register **qualifiers**, which transform a value in place
rather than introducing a verb. These are always reached through the handle:

```aro
(* Qualifiers registered by a plugin with handle: Crypto *)
Compute the <md5-hash: Crypto.md5> from the <data>.
Compute the <sha256-hash: Crypto.sha256> from the <data>.

(* Chain them with | *)
Compute the <fingerprint: Crypto.sha256|Crypto.base32> from the <data>.
```

The base name on the left is the variable; the qualifier on the right selects
the operation. That is how you get several results of the same kind in one
feature set without colliding on names.

### Options with `with { }`

Pass additional parameters using the `with` clause:

```aro
(* Options for encryption *)
Encrypt the <ciphertext> from the <plaintext> with {
    key: <encryption-key>,
    algorithm: "aes-256-gcm",
    encoding: "base64"
}.

(* Options for text generation *)
Generate the <response> from the <prompt> with {
    maxTokens: 500,
    temperature: 0.7,
    model: "gpt-4"
}.

(* Options for image processing *)
Resize the <thumbnail> from the <image> with {
    width: 200,
    height: 200,
    quality: 85
}.
```

## 3.5 The Call Action (Fallback)

For plugins that expose multiple related methods as a service API, use the `<Call>` action:

```aro
Call the <result> from the <service: method> with <arguments>.
```

This is useful when:
- A plugin provides many methods under one service name
- You're working with a plugin that doesn't register custom verbs
- You need explicit control over which service handles the request

### When to Use Call vs Custom Actions

| Scenario | Preferred Approach |
|----------|-------------------|
| Single-purpose operation | Custom action: `<Hash>`, `<Encrypt>` |
| Clear, focused functionality | Custom action: `<Summarize>`, `<Resize>` |
| Multi-method API | Call: `Call ... from <db: query>` |
| Legacy plugin compatibility | Call |
| CRUD operations on a resource | Call: `Call ... from <users: create>` |

### Call Example

```aro
(Database Query: Data Handler) {
    (* When a plugin exposes a multi-method database service *)
    Call the <users> from the <postgres: query> with {
        sql: "SELECT * FROM users WHERE active = true",
        params: []
    }.

    Call the <count> from the <postgres: count> with {
        table: "users",
        filter: { active: true }
    }.

    Return an <OK: status> with { users: <users>, total: <count> }.
}
```

## 3.6 Extracting Results

Plugin results are typically structured data. Use `Extract` to pull out specific fields:

```aro
Hash the <result> from the <password>.

(* Extract specific fields from the result *)
Extract the <hash-value> from the <result: hash>.
Extract the <algorithm> from the <result: algorithm>.
```

For nested results:

```aro
Classify the <analysis> from the <text>.

(* Access nested data *)
Extract the <label> from the <analysis: prediction.label>.
Extract the <confidence> from the <analysis: prediction.confidence>.
```

## 3.7 Error Handling

When a plugin action fails, ARO follows its "code is the error message" philosophy—the failed statement describes what went wrong:

```
Cannot Hash the <digest> from the <input>.
  Plugin error: Unsupported algorithm 'sha999'
```

For controlled error handling, check for error fields:

```aro
Encrypt the <result> from the <data> with <key>.

(* Inspect the result for an error field with a `when` guard *)
Log "Encryption failed: " ++ <result: error> to the <console> when <result: error> exists.
Return a <Failed: status> with <result> when <result: error> exists.

(* Continue with successful result *)
Extract the <ciphertext> from the <result: encrypted>.
```

## 3.8 Practical Patterns

### Pattern: Transform Pipeline

Chain multiple plugin actions:

```aro
(Process Document: Document Handler) {
    Read the <content> from the <file: document-path>.

    (* Chain of plugin actions *)
    ExtractText the <text> from the <content>.
    Summarize the <summary> from the <text> with { maxLength: 200 }.
    Translate the <translated> from the <summary> with { target: "es" }.

    Return an <OK: status> with {
        original: <text>,
        summary: <summary>,
        translated: <translated>
    }.
}
```

### Pattern: Conditional Processing

Choose actions based on input:

```aro
(Process File: File Handler) {
    Extract the <extension> from the <file: extension>.

    match <extension> {
        case "csv" {
            ParseCSV the <data> from the <file: content>.
        }
        case "json" {
            Parse the <data> from the <file: content>.
        }
        case "xml" {
            ParseXML the <data> from the <file: content>.
        }
        otherwise {
            Return an <UnsupportedFormat: error> with <extension>.
        }
    }

    Return an <OK: status> with <data>.
}
```

### Pattern: Batch Operations

Process multiple items efficiently:

```aro
(Analyze Batch: Batch Handler) {
    Retrieve the <documents> from the <document-repository>.

    (* Some plugins support batch operations *)
    EmbedBatch the <embeddings> from the <documents> with {
        model: "text-embedding-ada-002"
    }.

    (* Or iterate with individual actions *)
    for each <doc> in <documents> {
        Summarize the <summary> from the <doc: content>.
        Merge the <updated-doc: doc> with { summary: <summary> }.
        Store the <updated-doc> into the <document-repository>.
    }

    Return an <OK: status> with { processed: <documents: length> }.
}
```

### Pattern: Secure Data Handling

```aro
(Store Secret: Security Handler) {
    Extract the <api-key> from the <request: body.apiKey>.

    (* Encrypt before storage *)
    Encrypt the <encrypted-key> from the <api-key> with <master-key>.

    (* Hash for indexing *)
    Hash the <key-hash: sha256> from the <api-key>.

    Create the <secret> with {
        hash: <key-hash>,
        encrypted: <encrypted-key>
    }.
    Store the <secret> into the <secrets-repository>.

    Return a <Created: status> for the <secret>.
}
```

## 3.9 Updating and Removing Plugins

### Update a Plugin

```bash
aro plugins update plugin-crypto
```

Or update all plugins:

```bash
aro plugins update
```

### Remove a Plugin

```bash
aro remove plugin-old-stuff
```

## 3.10 Troubleshooting

### Action Not Found

```
Error: Unknown action 'Hashh'
```

**Solutions:**
- Check spelling of the action verb
- Verify the plugin is installed: `aro plugins list`
- Confirm it registered: `aro actions` lists every verb the runtime knows
- For a qualifier, remember it must be namespaced: `<value: Handle.name>`, and
  check `aro actions --qualifiers`

### Plugin Not Loaded

```
Error: Plugin 'plugin-crypto' failed to load
```

**Solutions:**
- Check plugin compilation: `aro plugins rebuild plugin-crypto`
- Verify language toolchain is installed
- Look at detailed error output

### Invalid Arguments

```
Error: Missing required argument 'key' for <Encrypt>
```

**Solutions:**
- Check plugin documentation for required arguments
- Verify argument names and types

## 3.11 Summary

Using plugins in ARO is straightforward:

1. **Install** with `aro add <repository-url>`
2. **Use actions** with native syntax: `<Hash>`, `<Encrypt>`, `<Summarize>`
3. **Pass options** with qualifiers and `with { }` clauses
4. **Extract results** from returned data
5. **Fall back to `<Call>`** for multi-method service APIs

Plugin actions are the preferred way to extend ARO—they feel native, read naturally, and integrate seamlessly with ARO's syntax. The next chapter covers the `plugin.yaml` manifest that defines what actions your plugin provides.
