# CSV Processor Example

This example demonstrates how to install and use a Rust FFI plugin for CSV processing.

## Plugin Used

- **plugin-rust-csv**: A Rust plugin for CSV parsing and formatting
  - Repository: https://github.com/arolang/plugin-rust-csv

## Actions Provided

| Action | Description | Input |
|--------|-------------|-------|
| `parse-csv` | Parse CSV string to array of rows | `{ data: "...", headers: true }` |
| `format-csv` | Format rows as CSV string | `{ rows: [...], delimiter: "," }` |
| `csv-to-json` | Convert CSV to JSON objects | `{ data: "..." }` |

## Installation

Install the plugin using the ARO package manager:

```bash
cd Examples/CSVProcessor
aro add https://github.com/arolang/plugin-rust-csv.git
```

## Requirements

- Rust 1.75 or later (for building the plugin)

## Expected Output

```
=== CSV Processor Demo ===

1. Parsing CSV data...
   Parsed rows: 4

2. Converting CSV to JSON objects...
   JSON objects:
   [{"name": "Alice", "age": "30", "city": "New York"}, ...]

3. Formatting as semicolon-delimited CSV...
   product;price;quantity
   Apple;1.50;100
   Banana;0.75;200
   Orange;2.00;50

CSV processing completed!
```
