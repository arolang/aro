# Chapter 16B: Format-Aware File I/O

*"Structured data in, structured data out."*

---

## 16B.1 The Format Detection Pattern

When you write data to a file, ARO examines the file extension and automatically serializes your data to the appropriate format. When you read a file, ARO parses the content back into structured data. This eliminates the boilerplate of manual serialization and deserialization.

<div style="text-align: center; margin: 2em 0;">
<svg width="500" height="120" viewBox="0 0 500 120" xmlns="http://www.w3.org/2000/svg">
  <!-- Object box -->
  <rect x="20" y="35" width="80" height="50" rx="5" fill="#e0e7ff" stroke="#6366f1" stroke-width="2"/>
  <text x="60" y="55" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#4338ca">Structured</text>
  <text x="60" y="70" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#4338ca">Data</text>

  <!-- Arrow to detector -->
  <line x1="100" y1="60" x2="150" y2="60" stroke="#6b7280" stroke-width="2"/>
  <polygon points="150,60 142,55 142,65" fill="#6b7280"/>

  <!-- Format detector -->
  <rect x="150" y="30" width="100" height="60" rx="5" fill="#fef3c7" stroke="#f59e0b" stroke-width="2"/>
  <text x="200" y="55" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#92400e">Format</text>
  <text x="200" y="70" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#92400e">Detector</text>

  <!-- Arrow to serializer -->
  <line x1="250" y1="60" x2="300" y2="60" stroke="#6b7280" stroke-width="2"/>
  <polygon points="300,60 292,55 292,65" fill="#6b7280"/>

  <!-- Serializer -->
  <rect x="300" y="30" width="80" height="60" rx="5" fill="#dcfce7" stroke="#22c55e" stroke-width="2"/>
  <text x="340" y="55" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#166534">Format</text>
  <text x="340" y="70" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#166534">Serializer</text>

  <!-- Arrow to file -->
  <line x1="380" y1="60" x2="430" y2="60" stroke="#6b7280" stroke-width="2"/>
  <polygon points="430,60 422,55 422,65" fill="#6b7280"/>

  <!-- File icon -->
  <rect x="430" y="35" width="50" height="50" rx="3" fill="#f3e8ff" stroke="#8b5cf6" stroke-width="2"/>
  <text x="455" y="65" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#6b21a8">.json</text>

  <!-- Extension label -->
  <text x="200" y="110" text-anchor="middle" font-family="sans-serif" font-size="9" fill="#6b7280">Extension determines format</text>
</svg>
</div>

The file extension is the key. Write to `users.json` and get JSON. Write to `users.csv` and get CSV. Write to `users.yaml` and get YAML. The same data, formatted appropriately for each destination.

```aro
(* Same data, three different formats *)
<Write> the <users> to "./output/users.json".
<Write> the <users> to "./output/users.csv".
<Write> the <users> to "./output/users.yaml".
```

This pattern follows ARO's philosophy of reducing ceremony. The file path already tells you the intended format. Making you specify it again would be redundant.

---

## 16B.2 Supported Formats

ARO supports thirteen file formats out of the box. Each format has specific characteristics that make it suitable for different use cases.

| Extension | Format | Best For |
|-----------|--------|----------|
| `.json` | JSON | APIs, configuration, data exchange |
| `.jsonl`, `.ndjson` | JSON Lines | Streaming, logging, large datasets |
| `.yaml`, `.yml` | YAML | Human-readable configuration |
| `.toml` | TOML | Application configuration |
| `.xml` | XML | Legacy systems, enterprise integration |
| `.csv` | CSV | Spreadsheets, data import/export |
| `.tsv` | TSV | Tab-delimited data |
| `.md` | Markdown | Documentation tables |
| `.html`, `.htm` | HTML | Web output, reports |
| `.txt` | Plain Text | Simple key-value data |
| `.sql` | SQL | Database backup, migration |
| `.log` | Log | Application logs, audit trails |
| `.obj` or unknown | Binary | Raw data, unknown formats |

---

## 16B.3 Writing Structured Data

The Write action serializes your data according to the file extension. Each format has its own serialization rules.

### JSON and JSON Lines

JSON is the most common format for structured data. ARO produces pretty-printed JSON with sorted keys for consistency and readability.

```aro
<Create> the <users> with [
    { "id": 1, "name": "Alice", "email": "alice@example.com" },
    { "id": 2, "name": "Bob", "email": "bob@example.com" }
].

<Write> the <users> to "./output/users.json".
```

**Output (users.json):**
```json
[
  {
    "email": "alice@example.com",
    "id": 1,
    "name": "Alice"
  },
  {
    "email": "bob@example.com",
    "id": 2,
    "name": "Bob"
  }
]
```

JSON Lines (`.jsonl` or `.ndjson`) writes one JSON object per line with no extra whitespace. This format is ideal for streaming and logging because each line is independently parseable.

```aro
<Write> the <events> to "./logs/events.jsonl".
```

**Output (events.jsonl):**
```
{"email":"alice@example.com","id":1,"name":"Alice"}
{"email":"bob@example.com","id":2,"name":"Bob"}
```

### YAML and TOML

YAML produces human-readable output that is easy to edit by hand. It uses indentation to show structure and avoids the visual noise of brackets and quotes.

```aro
<Write> the <config> to "./settings.yaml".
```

**Output (settings.yaml):**
```yaml
-   email: alice@example.com
    id: 1
    name: Alice
-   email: bob@example.com
    id: 2
    name: Bob
```

TOML is similar but uses explicit section headers. It is particularly popular for application configuration files.

```aro
<Write> the <users> to "./config/users.toml".
```

**Output (users.toml):**
```toml
[[users]]
id = 1
name = "Alice"
email = "alice@example.com"

[[users]]
id = 2
name = "Bob"
email = "bob@example.com"
```

### CSV and TSV

Comma-separated values (CSV) is the universal format for spreadsheet data. ARO writes a header row with field names, followed by data rows.

```aro
<Write> the <report> to "./export/report.csv".
```

**Output (report.csv):**
```
email,id,name
alice@example.com,1,Alice
bob@example.com,2,Bob
```

Tab-separated values (TSV) works the same way but uses tabs instead of commas. This is useful when your data contains commas.

Values containing the delimiter character, quotes, or newlines are automatically escaped with quotes.

### XML

XML output uses the variable name from your Write statement as the root element. This provides meaningful document structure without requiring additional configuration.

```aro
<Write> the <users> to "./data/users.xml".
```

**Output (users.xml):**
```xml
<?xml version="1.0" encoding="UTF-8"?>
<users>
  <item>
    <id>1</id>
    <name>Alice</name>
    <email>alice@example.com</email>
  </item>
  <item>
    <id>2</id>
    <name>Bob</name>
    <email>bob@example.com</email>
  </item>
</users>
```

Notice how `<users>` becomes the root element because that was the variable name in the Write statement.

### Markdown and HTML

Markdown produces pipe-delimited tables suitable for documentation. HTML produces properly structured tables with thead and tbody elements.

```aro
<Write> the <summary> to "./docs/summary.md".
<Write> the <report> to "./output/report.html".
```

**Markdown output:**
```markdown
| id | name | email |
|----|------|-------|
| 1 | Alice | alice@example.com |
| 2 | Bob | bob@example.com |
```

### SQL

SQL output produces INSERT statements for database migration or backup. The table name comes from the variable name.

```aro
<Write> the <users> to "./backup/users.sql".
```

**Output (users.sql):**
```sql
INSERT INTO users (id, name, email) VALUES (1, 'Alice', 'alice@example.com');
INSERT INTO users (id, name, email) VALUES (2, 'Bob', 'bob@example.com');
```

String values are properly escaped to prevent SQL injection in the output.

### Log

Log output produces date-prefixed entries, ideal for application logs and audit trails. Each entry receives an ISO8601 timestamp.

```aro
<Write> the <message> to "./app.log" with "Server started".
<Append> the <entry> to "./app.log" with "User logged in".
```

**Output (app.log):**
```
2025-12-29T10:30:45Z: Server started
2025-12-29T10:30:46Z: User logged in
```

When writing an array, each element becomes a separate log entry:

```aro
<Create> the <events> with ["Startup complete", "Listening on port 8080"].
<Write> the <events> to "./events.log".
```

**Output:**
```
2025-12-29T10:30:45Z: Startup complete
2025-12-29T10:30:45Z: Listening on port 8080
```

### Plain Text

Plain text output produces key=value pairs, one per line. Nested objects use dot notation.

```aro
<Create> the <config> with { "host": "localhost", "port": 8080, "debug": true }.
<Write> the <config> to "./output/config.txt".
```

**Output (config.txt):**
```
host=localhost
port=8080
debug=true
```

---

## 16B.4 Reading Structured Data

Reading files reverses the process. ARO examines the file extension and parses the content into structured data that you can work with.

<div style="text-align: center; margin: 2em 0;">
<svg width="500" height="120" viewBox="0 0 500 120" xmlns="http://www.w3.org/2000/svg">
  <!-- File icon -->
  <rect x="20" y="35" width="50" height="50" rx="3" fill="#f3e8ff" stroke="#8b5cf6" stroke-width="2"/>
  <text x="45" y="65" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#6b21a8">.csv</text>

  <!-- Arrow to detector -->
  <line x1="70" y1="60" x2="120" y2="60" stroke="#6b7280" stroke-width="2"/>
  <polygon points="120,60 112,55 112,65" fill="#6b7280"/>

  <!-- Format detector -->
  <rect x="120" y="30" width="100" height="60" rx="5" fill="#fef3c7" stroke="#f59e0b" stroke-width="2"/>
  <text x="170" y="55" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#92400e">Format</text>
  <text x="170" y="70" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#92400e">Detector</text>

  <!-- Arrow to parser -->
  <line x1="220" y1="60" x2="270" y2="60" stroke="#6b7280" stroke-width="2"/>
  <polygon points="270,60 262,55 262,65" fill="#6b7280"/>

  <!-- Parser -->
  <rect x="270" y="30" width="80" height="60" rx="5" fill="#dcfce7" stroke="#22c55e" stroke-width="2"/>
  <text x="310" y="55" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#166534">Format</text>
  <text x="310" y="70" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#166534">Parser</text>

  <!-- Arrow to object -->
  <line x1="350" y1="60" x2="400" y2="60" stroke="#6b7280" stroke-width="2"/>
  <polygon points="400,60 392,55 392,65" fill="#6b7280"/>

  <!-- Object box -->
  <rect x="400" y="35" width="80" height="50" rx="5" fill="#e0e7ff" stroke="#6366f1" stroke-width="2"/>
  <text x="440" y="55" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#4338ca">Structured</text>
  <text x="440" y="70" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#4338ca">Data</text>

  <!-- Extension label -->
  <text x="170" y="110" text-anchor="middle" font-family="sans-serif" font-size="9" fill="#6b7280">Extension determines parser</text>
</svg>
</div>

```aro
(* JSON becomes object or array *)
<Read> the <config> from "./settings.json".

(* JSONL becomes array of objects *)
<Read> the <events> from "./logs/events.jsonl".

(* CSV becomes array with headers as keys *)
<Read> the <records> from "./data.csv".

(* YAML becomes object or array *)
<Read> the <settings> from "./config.yaml".
```

Each format parses to an appropriate data structure:

| Format | Parses To |
|--------|-----------|
| JSON | Object or Array |
| JSON Lines | Array of Objects |
| YAML | Object or Array |
| TOML | Object |
| XML | Object (nested) |
| CSV | Array of Objects |
| TSV | Array of Objects |
| Plain Text | Object |
| Binary | Raw Data |

### Bypassing Format Detection

Sometimes you want to read a file as raw text without parsing. Use the `String` qualifier to bypass format detection:

```aro
(* Parse JSON to structured data *)
<Read> the <config> from "./settings.json".

(* Read raw JSON as string - no parsing *)
<Read> the <raw-json: String> from "./settings.json".
```

This is useful when you need to inspect the raw content or pass it to an external system without modification.

---

## 16B.5 CSV and TSV Options

CSV and TSV formats support additional configuration options. These options control how data is formatted when writing and how content is parsed when reading.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `delimiter` | String | `,` (CSV) / `\t` (TSV) | Field separator |
| `header` | Boolean | `true` | Include/expect header row |
| `quote` | String | `"` | Quote character |

### Custom Delimiter

Some systems use semicolons or other characters as field separators:

```aro
<Write> the <data> to "./export.csv" with { delimiter: ";" }.
```

### Header Row Control

You can suppress the header row when writing:

```aro
<Write> the <data> to "./export.csv" with { header: false }.
```

When reading, if your CSV has no header row, specify this so the parser knows to treat the first line as data:

```aro
<Read> the <data> from "./import.csv" with { header: false }.
```

---

## 16B.6 Round-Trip Patterns

A common pattern is reading data from one format and writing to another. ARO makes this seamless because the data structure is format-independent.

### Data Transformation Pipeline

```aro
(Application-Start: Data Transformer) {
    (* Read from CSV *)
    <Read> the <records> from "./input/data.csv".

    (* Process the data *)
    <Log> the <count> for the <console> with "Processing records...".

    (* Write to multiple formats *)
    <Write> the <records> to "./output/data.json".
    <Write> the <records> to "./output/data.yaml".
    <Write> the <records> to "./output/report.md".

    <Log> the <done> for the <console> with "Transformation complete!".
    <Return> an <OK: status> for the <transform>.
}
```

### Multi-Format Export

When you need to provide data in multiple formats for different consumers:

```aro
(exportData: Export API) {
    <Retrieve> the <users> from the <user-repository>.

    (* Web API consumers get JSON *)
    <Write> the <users> to "./export/users.json".

    (* Analysts get CSV for spreadsheets *)
    <Write> the <users> to "./export/users.csv".

    (* Documentation gets Markdown *)
    <Write> the <users> to "./docs/users.md".

    (* Archive gets SQL for database restore *)
    <Write> the <users> to "./backup/users.sql".

    <Return> an <OK: status> with "Exported to 4 formats".
}
```

---

## 16B.7 Best Practices

**Choose the right format for your use case.** JSON and YAML are best for configuration and API data. CSV is best for spreadsheet workflows. JSON Lines is best for logging and streaming. SQL is best for database backup.

**Use consistent extensions.** Stick to standard extensions like `.json`, `.yaml`, `.csv`. Avoid custom extensions unless you need binary format handling.

**Consider human readability.** YAML and Markdown are easy to read and edit by hand. JSON and XML preserve structure but are harder to edit manually.

**Handle round-trips carefully.** Some formats lose information during round-trips. Markdown tables become strings when read back. SQL output cannot be parsed back into objects. Plan your data flow accordingly.

**Use JSON Lines for large datasets.** Regular JSON must be fully loaded into memory. JSON Lines can be processed line by line, making it suitable for large files and streaming scenarios.

---

*Next: Chapter 17 — Custom Actions*
