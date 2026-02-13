# plugin-rust-csv

A Rust plugin for ARO that provides CSV parsing and formatting functionality.

## Installation

```bash
aro add git@github.com:arolang/plugin-rust-csv.git
```

## Building

Requires Rust 1.75 or later.

```bash
cargo build --release
```

## Actions

### parse-csv

Parses a CSV string into an array of arrays.

**Input:**
- `data` (string): CSV data to parse
- `headers` (boolean, optional): Whether the first row contains headers. Default: true

**Output:**
- `rows`: Array of arrays containing the parsed data
- `row_count`: Number of rows (including header if present)

### format-csv

Formats an array of arrays as a CSV string.

**Input:**
- `rows` (array): Array of arrays to format
- `delimiter` (string, optional): Field delimiter. Default: ","

**Output:**
- `csv`: The formatted CSV string

### csv-to-json

Converts CSV data to an array of JSON objects.

**Input:**
- `data` (string): CSV data with headers in the first row

**Output:**
- `objects`: Array of JSON objects
- `count`: Number of objects

## Example Usage in ARO

```aro
(* Parse CSV data *)
(Parse CSV Data: Data Processing) {
    <Extract> the <csv-data> from the <request: body>.
    <ParseCsv> the <parsed> with <csv-data>.
    <Return> an <OK: status> with <parsed>.
}
```

## License

MIT
