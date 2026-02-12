//! ARO Plugin - Rust CSV Parser
//!
//! This plugin provides CSV parsing and formatting functionality for ARO.
//! It implements the ARO native plugin interface (C ABI).

use std::ffi::{CStr, CString};
use std::os::raw::c_char;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

/// Action definition for plugin metadata
#[derive(Serialize)]
struct ActionDef {
    name: &'static str,
    role: &'static str,
    verbs: Vec<&'static str>,
    prepositions: Vec<&'static str>,
}

/// Plugin info structure
#[derive(Serialize)]
struct PluginInfo {
    name: &'static str,
    version: &'static str,
    actions: Vec<ActionDef>,
}

/// Get plugin information
///
/// Returns JSON string with plugin metadata and custom action definitions.
/// Caller must free the returned string using `aro_plugin_free`.
#[no_mangle]
pub extern "C" fn aro_plugin_info() -> *mut c_char {
    let info = PluginInfo {
        name: "plugin-rust-csv",
        version: "1.0.0",
        actions: vec![
            ActionDef {
                name: "ParseCSV",
                role: "own",
                verbs: vec!["parsecsv", "readcsv"],
                prepositions: vec!["from", "with"],
            },
            ActionDef {
                name: "FormatCSV",
                role: "own",
                verbs: vec!["formatcsv", "writecsv"],
                prepositions: vec!["from", "with"],
            },
            ActionDef {
                name: "CSVToJSON",
                role: "own",
                verbs: vec!["csvtojson"],
                prepositions: vec!["from"],
            },
        ],
    };

    match serde_json::to_string(&info) {
        Ok(json) => CString::new(json).unwrap().into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

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
    // Safety: We trust the caller to provide valid C strings
    let action = unsafe {
        if action.is_null() {
            return error_result("Action is null");
        }
        match CStr::from_ptr(action).to_str() {
            Ok(s) => s,
            Err(_) => return error_result("Invalid action string"),
        }
    };

    let input = unsafe {
        if input_json.is_null() {
            return error_result("Input is null");
        }
        match CStr::from_ptr(input_json).to_str() {
            Ok(s) => s,
            Err(_) => return error_result("Invalid input string"),
        }
    };

    // Parse input JSON
    let input_value: Value = match serde_json::from_str(input) {
        Ok(v) => v,
        Err(e) => return error_result(&format!("Invalid JSON input: {}", e)),
    };

    // Dispatch to the appropriate action
    // Support both hyphenated (parse-csv) and normalized (parsecsv) forms
    let result = match action {
        "parse-csv" | "parsecsv" | "readcsv" => parse_csv(&input_value),
        "format-csv" | "formatcsv" | "writecsv" => format_csv(&input_value),
        "csv-to-json" | "csvtojson" => csv_to_json(&input_value),
        _ => Err(format!("Unknown action: {}", action)),
    };

    // Convert result to JSON string
    match result {
        Ok(value) => CString::new(value.to_string()).unwrap().into_raw(),
        Err(e) => error_result(&e),
    }
}

/// Free memory allocated by the plugin
#[no_mangle]
pub extern "C" fn aro_plugin_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe {
            let _ = CString::from_raw(ptr);
        }
    }
}

// Helper to create error result
fn error_result(message: &str) -> *mut c_char {
    let error = json!({ "error": message });
    CString::new(error.to_string()).unwrap().into_raw()
}

// MARK: - Actions

/// Parse CSV string into array of arrays
fn parse_csv(input: &Value) -> Result<Value, String> {
    let csv_data = input
        .get("data")
        .and_then(|v| v.as_str())
        .ok_or("Missing 'data' field")?;

    let has_headers = input
        .get("headers")
        .and_then(|v| v.as_bool())
        .unwrap_or(true);

    let mut reader = csv::ReaderBuilder::new()
        .has_headers(has_headers)
        .from_reader(csv_data.as_bytes());

    let mut rows: Vec<Vec<String>> = Vec::new();

    // Include headers if present
    if has_headers {
        let headers: Vec<String> = reader
            .headers()
            .map_err(|e| format!("Failed to read headers: {}", e))?
            .iter()
            .map(|s| s.to_string())
            .collect();
        rows.push(headers);
    }

    // Read data rows
    for result in reader.records() {
        let record = result.map_err(|e| format!("Failed to read record: {}", e))?;
        let row: Vec<String> = record.iter().map(|s| s.to_string()).collect();
        rows.push(row);
    }

    Ok(json!({
        "rows": rows,
        "row_count": rows.len()
    }))
}

/// Format array of arrays as CSV string
fn format_csv(input: &Value) -> Result<Value, String> {
    let rows = input
        .get("rows")
        .and_then(|v| v.as_array())
        .ok_or("Missing 'rows' field")?;

    let delimiter = input
        .get("delimiter")
        .and_then(|v| v.as_str())
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
            .ok_or("Row must be an array")?
            .iter()
            .map(|v| match v {
                Value::String(s) => s.clone(),
                _ => v.to_string(),
            })
            .collect();

        writer
            .write_record(&fields)
            .map_err(|e| format!("Failed to write record: {}", e))?;
    }

    let data = writer
        .into_inner()
        .map_err(|e| format!("Failed to finalize CSV: {}", e))?;

    let csv_string =
        String::from_utf8(data).map_err(|e| format!("Invalid UTF-8 in output: {}", e))?;

    Ok(json!({
        "csv": csv_string
    }))
}

/// Convert CSV to JSON array of objects
fn csv_to_json(input: &Value) -> Result<Value, String> {
    let csv_data = input
        .get("data")
        .and_then(|v| v.as_str())
        .ok_or("Missing 'data' field")?;

    let mut reader = csv::ReaderBuilder::new()
        .has_headers(true)
        .from_reader(csv_data.as_bytes());

    let headers: Vec<String> = reader
        .headers()
        .map_err(|e| format!("Failed to read headers: {}", e))?
        .iter()
        .map(|s| s.to_string())
        .collect();

    let mut objects: Vec<Value> = Vec::new();

    for result in reader.records() {
        let record = result.map_err(|e| format!("Failed to read record: {}", e))?;
        let mut obj = serde_json::Map::new();

        for (i, field) in record.iter().enumerate() {
            if let Some(header) = headers.get(i) {
                obj.insert(header.clone(), Value::String(field.to_string()));
            }
        }

        objects.push(Value::Object(obj));
    }

    Ok(json!({
        "objects": objects,
        "count": objects.len()
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_csv() {
        let input = json!({
            "data": "name,age\nAlice,30\nBob,25",
            "headers": true
        });

        let result = parse_csv(&input).unwrap();
        assert_eq!(result["row_count"], 3);
    }

    #[test]
    fn test_csv_to_json() {
        let input = json!({
            "data": "name,age\nAlice,30\nBob,25"
        });

        let result = csv_to_json(&input).unwrap();
        assert_eq!(result["count"], 2);
    }
}
