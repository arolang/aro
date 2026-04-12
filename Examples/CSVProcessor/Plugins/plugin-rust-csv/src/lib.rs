//! ARO Plugin - Rust CSV Parser
//!
//! This plugin provides CSV parsing and formatting functionality for ARO.
//! It implements the ARO native plugin interface (C ABI) using the ARO Plugin SDK.
//!
//! See: https://github.com/arolang/aro-plugin-sdk-rust

use std::os::raw::c_char;

use aro_plugin_sdk::prelude::*;

/// Get plugin information
///
/// Returns JSON string with plugin metadata and custom action definitions.
/// Caller must free the returned string using `aro_plugin_free`.
#[no_mangle]
pub extern "C" fn aro_plugin_info() -> *mut c_char {
    ffi::to_c_string(json!({
        "name": "plugin-rust-csv",
        "version": "1.0.0",
        "handle": "CSV",
        "actions": [
            {
                "name": "ParseCSV",
                "verbs": ["parsecsv", "readcsv"],
                "role": "own",
                "prepositions": ["from", "with"],
                "description": "Parse a CSV string into an array of rows"
            },
            {
                "name": "FormatCSV",
                "verbs": ["formatcsv", "writecsv"],
                "role": "own",
                "prepositions": ["from", "with"],
                "description": "Format an array of rows as a CSV string"
            },
            {
                "name": "CSVToJSON",
                "verbs": ["csvtojson"],
                "role": "own",
                "prepositions": ["from"],
                "description": "Convert a CSV string to an array of JSON objects using the first row as headers"
            }
        ]
    }).to_string())
}

/// Lifecycle hook called once when the plugin is loaded
#[no_mangle]
pub extern "C" fn aro_plugin_init() {}

/// Lifecycle hook called once when the plugin is unloaded
#[no_mangle]
pub extern "C" fn aro_plugin_shutdown() {}

/// Execute a plugin action
///
/// # Arguments
/// * `action` - The action name (e.g., "parse-csv")
/// * `input_json` - JSON string with input parameters
///
/// # Returns
/// JSON string with the result. Caller must free using `aro_plugin_free`.
#[no_mangle]
pub extern "C" fn aro_plugin_execute(
    action: *const c_char,
    input_json: *const c_char,
) -> *mut c_char {
    ffi::wrap_execute(action, input_json, |action, input| {
        match action {
            "parse-csv" | "parsecsv" | "readcsv" => parse_csv(&input),
            "format-csv" | "formatcsv" | "writecsv" => format_csv(&input),
            "csv-to-json" | "csvtojson" => csv_to_json(&input),
            _ => Err(PluginError::internal(format!("Unknown action: {action}"))),
        }
    })
}

/// Free memory allocated by the plugin
#[no_mangle]
pub extern "C" fn aro_plugin_free(ptr: *mut c_char) {
    ffi::free_c_string(ptr);
}

// MARK: - Actions

/// Parse CSV string into array of arrays
fn parse_csv(input: &Input) -> PluginResult<Output> {
    let csv_data = input
        .string("data")
        .ok_or_else(|| PluginError::missing("data"))?;

    let has_headers = input.bool("headers").unwrap_or(true);

    let mut reader = csv::ReaderBuilder::new()
        .has_headers(has_headers)
        .from_reader(csv_data.as_bytes());

    let mut rows: Vec<Vec<String>> = Vec::new();

    // Include headers if present
    if has_headers {
        let headers: Vec<String> = reader
            .headers()
            .map_err(|e| PluginError::internal(format!("Failed to read headers: {e}")))?
            .iter()
            .map(|s| s.to_string())
            .collect();
        rows.push(headers);
    }

    // Read data rows
    for result in reader.records() {
        let record =
            result.map_err(|e| PluginError::internal(format!("Failed to read record: {e}")))?;
        let row: Vec<String> = record.iter().map(|s| s.to_string()).collect();
        rows.push(row);
    }

    let row_count = rows.len();
    Ok(Output::new()
        .set("rows", json!(rows))
        .set("row_count", json!(row_count)))
}

/// Format array of arrays as CSV string
fn format_csv(input: &Input) -> PluginResult<Output> {
    let rows = input
        .array("rows")
        .ok_or_else(|| PluginError::missing("rows"))?;

    let delimiter = input
        .string("delimiter")
        .unwrap_or(",")
        .chars()
        .next()
        .unwrap_or(',');

    let mut writer = csv::WriterBuilder::new()
        .delimiter(delimiter as u8)
        .from_writer(vec![]);

    for row in rows {
        let fields: Vec<String> = row
            .as_array()
            .ok_or_else(|| PluginError::invalid_type("row", "an array"))?
            .iter()
            .map(|v| match v {
                Value::String(s) => s.clone(),
                _ => v.to_string(),
            })
            .collect();

        writer
            .write_record(&fields)
            .map_err(|e| PluginError::internal(format!("Failed to write record: {e}")))?;
    }

    let data = writer
        .into_inner()
        .map_err(|e| PluginError::internal(format!("Failed to finalize CSV: {e}")))?;

    let csv_string = String::from_utf8(data)
        .map_err(|e| PluginError::internal(format!("Invalid UTF-8 in output: {e}")))?;

    Ok(Output::new().set("csv", json!(csv_string)))
}

/// Convert CSV to JSON array of objects
fn csv_to_json(input: &Input) -> PluginResult<Output> {
    let csv_data = input
        .string("data")
        .ok_or_else(|| PluginError::missing("data"))?;

    let mut reader = csv::ReaderBuilder::new()
        .has_headers(true)
        .from_reader(csv_data.as_bytes());

    let headers: Vec<String> = reader
        .headers()
        .map_err(|e| PluginError::internal(format!("Failed to read headers: {e}")))?
        .iter()
        .map(|s| s.to_string())
        .collect();

    let mut objects: Vec<Value> = Vec::new();

    for result in reader.records() {
        let record =
            result.map_err(|e| PluginError::internal(format!("Failed to read record: {e}")))?;
        let mut obj = serde_json::Map::new();

        for (i, field) in record.iter().enumerate() {
            if let Some(header) = headers.get(i) {
                obj.insert(header.clone(), Value::String(field.to_string()));
            }
        }

        objects.push(Value::Object(obj));
    }

    let count = objects.len();
    Ok(Output::new()
        .set("objects", json!(objects))
        .set("count", json!(count)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_csv() {
        let input = Input::new(json!({
            "data": "name,age\nAlice,30\nBob,25",
            "headers": true
        }));

        let result = parse_csv(&input).unwrap().to_value();
        assert_eq!(result["row_count"], 3);
    }

    #[test]
    fn test_csv_to_json() {
        let input = Input::new(json!({
            "data": "name,age\nAlice,30\nBob,25"
        }));

        let result = csv_to_json(&input).unwrap().to_value();
        assert_eq!(result["count"], 2);
    }

    #[test]
    fn test_input_with_fallback() {
        // SDK Input handles _with flattening natively
        let input = Input::new(json!({
            "top": "direct",
            "_with": {
                "data": "csv,content",
                "headers": false
            }
        }));
        assert_eq!(input.string("data"), Some("csv,content"));
        assert_eq!(input.bool("headers"), Some(false));
        assert_eq!(input.string("top"), Some("direct"));
    }

    #[test]
    fn test_input_top_level_precedence() {
        // Top-level key should win over _with key
        let input = Input::new(json!({
            "data": "override",
            "_with": {
                "data": "from_with"
            }
        }));
        assert_eq!(input.string("data"), Some("override"));
    }
}
