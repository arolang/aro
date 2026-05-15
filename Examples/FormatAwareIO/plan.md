# Build a format-aware file I/O demo

Create a single-file ARO application that demonstrates automatic format detection when reading and writing files based on file extension.

In the `Application-Start` feature set:

1. **Create sample data** -- a list of user objects with id, name, and email fields.

2. **Write to multiple formats** -- Write the same data to JSON (`.json`), JSON Lines (`.jsonl`), YAML (`.yaml`), CSV (`.csv`), TSV (`.tsv`), Markdown (`.md`), XML (`.xml`), SQL (`.sql`), TOML (`.toml`), and HTML (`.html`) files in an `./output/` directory. ARO auto-detects the format from the extension. Also write a config object to `.txt` (key=value format) and a nested config to `.env` (uppercase keys, nested entries become PARENT_CHILD format).

3. **Read data back** -- Read the JSON, JSONL, CSV, YAML, and .env files back and log them, showing that ARO auto-parses each format.

4. **Raw qualifier opt-out** -- Demonstrate the `:raw` qualifier to bypass format detection. Write a log line to a `.txt` file using `<log-line: raw>`, then read it back with `<boot-text: raw>` to get plain string content. Also show forcing a specific format with `<forced-json: json>`.

Log progress throughout and return OK.
