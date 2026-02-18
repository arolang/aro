# ARO-0040: Format-Aware File I/O

* Proposal: ARO-0040
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0008

## Abstract

This proposal defines automatic file format detection and conversion for Read and Write operations. ARO automatically detects file formats from extensions and handles serialization/deserialization, eliminating manual format handling.

---

## 1. Automatic Format Detection

### 1.1 Mechanism

When reading or writing files, ARO detects the format from the file extension:

```aro
Read the <data> from the <file: "./config.json">.
(* Automatically parsed as JSON → dictionary/array *)

Read the <settings> from the <file: "./settings.yaml">.
(* Automatically parsed as YAML → dictionary *)

Read the <records> from the <file: "./data.csv">.
(* Automatically parsed as CSV → array of rows *)
```

### 1.2 No Manual Parsing

Without format-aware I/O:
```aro
(* Manual approach - verbose and error-prone *)
Read the <raw-content> from the <file: "./config.json">.
Parse the <data: JSON> from the <raw-content>.
```

With format-aware I/O:
```aro
(* Automatic approach - clean and concise *)
Read the <data> from the <file: "./config.json">.
```

---

## 2. Supported Formats

### 2.1 Structured Data Formats

| Extension | Format | Read Result | Write Input |
|-----------|--------|-------------|-------------|
| `.json` | JSON | Dictionary/Array | Any serializable |
| `.jsonl`, `.ndjson` | JSON Lines | Array of objects | Array |
| `.yaml`, `.yml` | YAML | Dictionary/Array | Any serializable |
| `.xml` | XML | Dictionary | Dictionary |
| `.toml` | TOML | Dictionary | Dictionary |

### 2.2 Tabular Formats

| Extension | Format | Read Result | Write Input |
|-----------|--------|-------------|-------------|
| `.csv` | CSV | Array of arrays/dicts | Array |
| `.tsv` | TSV | Array of arrays/dicts | Array |

### 2.3 Text Formats

| Extension | Format | Read Result | Write Input |
|-----------|--------|-------------|-------------|
| `.txt` | Plain text | String | String |
| `.md`, `.markdown` | Markdown | String | String |
| `.html`, `.htm` | HTML | String | String |
| `.sql` | SQL | String | String |
| `.log` | Log file | String/Array | String |

### 2.4 Special Formats

| Extension | Format | Read Result | Write Input |
|-----------|--------|-------------|-------------|
| `.env` | Environment | Dictionary | Dictionary |
| (other) | Binary | Data | Data |

---

## 3. Reading Files

### 3.1 JSON Files

```aro
Read the <config> from the <file: "./config.json">.
(* config is now a dictionary *)
Extract the <port> from the <config: server.port>.
```

### 3.2 YAML Files

```aro
Read the <settings> from the <file: "./settings.yaml">.
Extract the <database-url> from the <settings: database.url>.
```

### 3.3 CSV Files

```aro
Read the <records> from the <file: "./data.csv">.
(* records = [{"name": "Alice", "age": "30"}, ...] *)

for each <record> in <records> {
    Extract the <name> from the <record: name>.
    Log <name> to the <console>.
}
```

### 3.4 JSON Lines (JSONL)

```aro
Read the <logs> from the <file: "./events.jsonl">.
(* logs = [{...}, {...}, {...}] - one object per line *)
```

### 3.5 Environment Files

```aro
Read the <env> from the <file: "./.env">.
(* env = {"DATABASE_URL": "...", "API_KEY": "..."} *)
Extract the <api-key> from the <env: API_KEY>.
```

---

## 4. Writing Files

### 4.1 JSON Output

```aro
Create the <data> with { name: "Alice", age: 30 }.
Write the <data> to the <file: "./output.json">.
(* Writes: {"age":30,"name":"Alice"} *)
```

### 4.2 YAML Output

```aro
Create the <config> with { server: { port: 8080, host: "localhost" } }.
Write the <config> to the <file: "./config.yaml">.
```

### 4.3 CSV Output

```aro
Create the <records> with [
    { name: "Alice", age: 30 },
    { name: "Bob", age: 25 }
].
Write the <records> to the <file: "./users.csv">.
(* Writes:
   name,age
   Alice,30
   Bob,25
*)
```

---

## 5. CSV/TSV Handling

### 5.1 Header Detection

CSV files with headers are parsed into dictionaries:

```csv
name,age,city
Alice,30,NYC
Bob,25,LA
```

```aro
Read the <data> from the <file: "./users.csv">.
(* data = [
     {"name": "Alice", "age": "30", "city": "NYC"},
     {"name": "Bob", "age": "25", "city": "LA"}
   ]
*)
```

### 5.2 No Header Mode

Files without clear headers are parsed as arrays:

```csv
Alice,30,NYC
Bob,25,LA
```

```aro
Read the <data> from the <file: "./users.csv">.
(* data = [["Alice", "30", "NYC"], ["Bob", "25", "LA"]] *)
```

### 5.3 TSV (Tab-Separated)

Same behavior with tab delimiters:

```aro
Read the <data> from the <file: "./data.tsv">.
```

---

## 6. Format Override

### 6.1 Explicit Format Specifier

Override auto-detection with explicit format:

```aro
Read the <data: JSON> from the <file: "./data.txt">.
(* Force JSON parsing even though extension is .txt *)
```

### 6.2 Available Specifiers

| Specifier | Format |
|-----------|--------|
| `JSON` | JSON |
| `YAML` | YAML |
| `CSV` | CSV |
| `TSV` | TSV |
| `XML` | XML |
| `TOML` | TOML |
| `TEXT` | Plain text |
| `BYTES` | Binary data |

---

## 7. Error Handling

Format errors produce descriptive messages:

```
Cannot read the data from the file: "./config.json"
  → JSON parsing failed at line 5: unexpected comma
```

```
Cannot write the data to the file: "./output.yaml"
  → YAML serialization failed: circular reference detected
```

---

## 8. Implementation

### 8.1 FileFormat Enum

```swift
public enum FileFormat: String, Sendable {
    case json, jsonl, yaml, xml, toml
    case csv, tsv
    case markdown, html, text, sql, log
    case env
    case binary

    public static func detect(from path: String) -> FileFormat
}
```

### 8.2 FormatSerializer / FormatDeserializer

```swift
public struct FormatSerializer {
    public static func serialize(_ value: any Sendable, as format: FileFormat) throws -> Data
}

public struct FormatDeserializer {
    public static func deserialize(_ data: Data, as format: FileFormat) throws -> any Sendable
}
```

---

## Summary

| Feature | Description |
|---------|-------------|
| **Detection** | Automatic from file extension |
| **Structured** | JSON, YAML, XML, TOML, JSONL |
| **Tabular** | CSV, TSV with header detection |
| **Text** | TXT, MD, HTML, SQL, LOG |
| **Special** | ENV files, binary fallback |
| **Override** | Explicit format specifier |

---

## References

- `Sources/ARORuntime/FileSystem/FileFormat.swift` - Format detection
- `Sources/ARORuntime/FileSystem/FormatSerializer.swift` - Serialization
- `Sources/ARORuntime/FileSystem/FormatDeserializer.swift` - Deserialization
- `Examples/FormatAwareIO/` - Format examples
