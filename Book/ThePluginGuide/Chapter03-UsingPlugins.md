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
───────────────────────────────────────────────────
 Name                   Version   Source        Provides
 plugin-crypto          1.0.0     github.com    Hash, Encrypt, Decrypt
 plugin-csv             1.0.0     github.com    ParseCSV, FormatCSV
 plugin-transformer     1.0.0     github.com    Summarize, Classify, Embed
───────────────────────────────────────────────────
 3 managed plugins
```

For detailed information about a specific plugin:

```bash
aro plugins list --verbose
```

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

## 3.3 Using Plugin Actions

Plugins provide **custom actions** that work like built-in ARO verbs. Once installed, you use them with natural ARO syntax:

```aro
(* Plugin actions feel native *)
Hash the <digest: sha256> from the <password>.
Encrypt the <ciphertext> with the <secret-data> using <key>.
ParseCSV the <records> from the <csv-file>.
Summarize the <summary> from the <document> with { maxLength: 200 }.
```

This is the primary way to use plugins. Each action follows the standard ARO pattern:

```
Action the <result> preposition the <object>.
```

### Example: Crypto Plugin

```aro
(Secure Password: User Registration) {
    Extract the <password> from the <request: body password>.

    (* Hash the password using the plugin's Hash action *)
    Hash the <password-hash: argon2> from the <password>.

    (* Store the hashed password *)
    Create the <user> with {
        email: <request: body email>,
        passwordHash: <password-hash>
    }.
    Store the <user> into the <user-repository>.

    Return a <Created: status> with { id: <user: id> }.
}
```

### Example: CSV Plugin

```aro
(Import Data: Data Handler) {
    Read the <csv-content> from the <file: "./data/users.csv">.

    (* Parse CSV using the plugin's ParseCSV action *)
    ParseCSV the <records> from the <csv-content> with {
        headers: true,
        delimiter: ","
    }.

    (* Process each record *)
    For each <record> in <records>:
        Create the <user> with <record>.
        Store the <user> into the <user-repository>.

    Return an <OK: status> with { imported: <records: length> }.
}
```

### Example: LLM Transformer Plugin

```aro
(Analyze Feedback: Feedback Handler) {
    Extract the <text> from the <feedback: content>.

    (* Use plugin actions for AI analysis *)
    Summarize the <summary> from the <text> with { maxLength: 100 }.
    Classify the <sentiment> from the <text> with {
        labels: ["positive", "negative", "neutral"]
    }.
    <Embed> the <embedding> from the <text>.

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

Use qualifiers to specify variants or algorithms:

```aro
(* Qualifier specifies the hash algorithm *)
Hash the <md5-hash: md5> from the <data>.
Hash the <sha256-hash: sha256> from the <data>.
Hash the <sha512-hash: sha512> from the <data>.

(* Qualifier specifies output format *)
Encode the <base64: base64> from the <binary-data>.
Encode the <hex: hex> from the <binary-data>.
```

### Options with `with { }`

Pass additional parameters using the `with` clause:

```aro
(* Options for encryption *)
Encrypt the <ciphertext> with the <plaintext> using {
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
Call the <result> from the <service: method> with { arguments }.
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
        where: { active: true }
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
Extract the <label> from the <analysis: prediction label>.
Extract the <confidence> from the <analysis: prediction confidence>.
```

## 3.7 Error Handling

When a plugin action fails, ARO follows its "code is the error message" philosophy—the failed statement describes what went wrong:

```
Cannot Hash the <digest> from the <input>.
  Plugin error: Unsupported algorithm 'sha999'
```

For controlled error handling, check for error fields:

```aro
Encrypt the <result> with the <data> using <key>.

When <result: error> exists:
    Log "Encryption failed: " ++ <result: error> to the <console>.
    Return a <Failed: status> with <result>.

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
    <ExtractText> the <text> from the <content>.
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

    Match <extension>:
        "csv" => ParseCSV the <data> from the <file: content>.
        "json" => Parse the <data> from the <file: content> as JSON.
        "xml" => <ParseXML> the <data> from the <file: content>.
        _ => Return an <UnsupportedFormat: error> with <extension>.

    Return an <OK: status> with <data>.
}
```

### Pattern: Batch Operations

Process multiple items efficiently:

```aro
(Analyze Batch: Batch Handler) {
    Retrieve the <documents> from the <document-repository>.

    (* Some plugins support batch operations *)
    <EmbedBatch> the <embeddings> from the <documents> with {
        model: "text-embedding-ada-002"
    }.

    (* Or iterate with individual actions *)
    For each <doc> in <documents>:
        Summarize the <summary> from the <doc: content>.
        Update the <document-repository> where id = <doc: id> with {
            summary: <summary>
        }.

    Return an <OK: status> with { processed: <documents: length> }.
}
```

### Pattern: Secure Data Handling

```aro
(Store Secret: Security Handler) {
    Extract the <api-key> from the <request: body apiKey>.

    (* Encrypt before storage *)
    Encrypt the <encrypted-key> with the <api-key> using <master-key>.

    (* Hash for indexing *)
    Hash the <key-hash: sha256> from the <api-key>.

    Store the <secret> with {
        hash: <key-hash>,
        encrypted: <encrypted-key>
    } into the <secrets-repository>.

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
- Ensure the plugin registers that action

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
