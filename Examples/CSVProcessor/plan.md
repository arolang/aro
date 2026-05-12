# Build a CSV processing demo using a Rust plugin

Create an ARO application that uses custom CSV actions provided by a Rust plugin.

- `main.aro` -- The `Application-Start` feature set. Create sample CSV data as a string with newlines. Use three custom actions:
  1. `ParseCSV the <parsed> from the <csv-data> with { headers: true }` -- Parse CSV to structured data, extract row count.
  2. `CSVToJSON the <json-result> from the <csv-data>` -- Convert CSV to JSON objects, extract count.
  3. Create a list of lists (rows) and use `FormatCSV the <formatted> from the <rows> with { delimiter: ";" }` to format as semicolon-delimited CSV. Extract and log the CSV output.

- `Plugins/plugin-rust-csv/plugin.yaml` -- Plugin manifest with name `plugin-rust-csv`, providing a `rust-plugin` type with cargo release target.
