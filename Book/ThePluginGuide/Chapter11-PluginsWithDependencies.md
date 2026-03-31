# Chapter 10: Plugins with Dependencies

*"Standing on the shoulders of giants—one package at a time."*

---

Real-world plugins rarely exist in isolation. They depend on libraries, frameworks, and system services. This chapter shows you how to manage dependencies across all plugin types: Swift packages, Cargo crates, system libraries, and Python packages.

## 10.1 The Dependency Challenge

Dependencies introduce complexity:

- **Version conflicts**: Different plugins may need different versions
- **Build requirements**: Some dependencies need compilers, toolchains, or system libraries
- **Platform differences**: A dependency might work on macOS but not Linux
- **Size**: Dependencies can balloon a simple plugin into gigabytes

But dependencies also enable incredible functionality. SQLite gives you a full database. FFmpeg handles any media format. NumPy powers numerical computing. The trick is managing them well.

## 10.2 Swift Package Manager Dependencies

Swift plugins use SPM for dependency management. Let's build a SQLite database plugin.

### Project Structure

```
Plugins/
└── plugin-swift-sqlite/
    ├── plugin.yaml
    ├── Package.swift
    └── Sources/
        └── SQLitePlugin/
            └── SQLitePlugin.swift
```

### Package.swift

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SQLitePlugin",
    platforms: [.macOS(.v12)],
    products: [
        // CRITICAL: type: .dynamic creates a .dylib ARO can load
        .library(name: "SQLitePlugin", type: .dynamic, targets: ["SQLitePlugin"])
    ],
    dependencies: [
        // SQLite.swift - A type-safe SQLite wrapper
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", exact: "0.14.1")
    ],
    targets: [
        .target(
            name: "SQLitePlugin",
            dependencies: [
                .product(name: "SQLite", package: "SQLite.swift")
            ]
        )
    ]
)
```

Key points:

- **`type: .dynamic`**: Essential for ARO plugins. Without this, SPM builds a static library that can't be loaded at runtime.
- **`exact: "0.14.1"`**: Pins to a specific version for reproducibility.
- **`platforms`**: Specifies minimum OS versions.

### Implementation

```swift
// SQLitePlugin.swift
import Foundation
import SQLite

// Database connection management
private var databases: [String: Connection] = [:]
private let dbLock = NSLock()

// MARK: - Plugin Interface

@_cdecl("aro_plugin_init")
public func pluginInit() -> UnsafePointer<CChar> {
    let metadata = """
    {
        "services": [{
            "name": "sqlite",
            "symbol": "sqlite_call",
            "methods": ["open", "close", "execute", "query", "insert"]
        }]
    }
    """
    return strdup(metadata)!
}

@_cdecl("sqlite_call")
public func sqliteCall(
    _ methodPtr: UnsafePointer<CChar>,
    _ argsPtr: UnsafePointer<CChar>,
    _ resultPtr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32 {
    let method = String(cString: methodPtr)
    let argsJSON = String(cString: argsPtr)

    guard let argsData = argsJSON.data(using: .utf8),
          let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] else {
        return setError(resultPtr, "Invalid JSON")
    }

    do {
        let result: [String: Any]

        switch method {
        case "open":
            result = try openDatabase(args)
        case "close":
            result = try closeDatabase(args)
        case "execute":
            result = try executeStatement(args)
        case "query":
            result = try queryDatabase(args)
        case "insert":
            result = try insertRow(args)
        default:
            return setError(resultPtr, "Unknown method: \(method)")
        }

        let resultData = try JSONSerialization.data(withJSONObject: result)
        let resultJSON = String(data: resultData, encoding: .utf8)!
        resultPtr.pointee = strdup(resultJSON)
        return 0

    } catch {
        return setError(resultPtr, error.localizedDescription)
    }
}

// MARK: - Database Operations

private func openDatabase(_ args: [String: Any]) throws -> [String: Any] {
    guard let path = args["path"] as? String else {
        throw PluginError.missingParameter("path")
    }

    let name = args["name"] as? String ?? path

    dbLock.lock()
    defer { dbLock.unlock() }

    // Open or create database
    let db = try Connection(path)
    databases[name] = db

    return [
        "success": true,
        "name": name,
        "path": path
    ]
}

private func closeDatabase(_ args: [String: Any]) throws -> [String: Any] {
    guard let name = args["name"] as? String else {
        throw PluginError.missingParameter("name")
    }

    dbLock.lock()
    defer { dbLock.unlock() }

    databases.removeValue(forKey: name)

    return ["success": true, "name": name]
}

private func executeStatement(_ args: [String: Any]) throws -> [String: Any] {
    guard let name = args["name"] as? String,
          let sql = args["sql"] as? String else {
        throw PluginError.missingParameter("name or sql")
    }

    dbLock.lock()
    let db = databases[name]
    dbLock.unlock()

    guard let db = db else {
        throw PluginError.databaseNotFound(name)
    }

    try db.execute(sql)

    return ["success": true, "sql": sql]
}

private func queryDatabase(_ args: [String: Any]) throws -> [String: Any] {
    guard let name = args["name"] as? String,
          let sql = args["sql"] as? String else {
        throw PluginError.missingParameter("name or sql")
    }

    dbLock.lock()
    let db = databases[name]
    dbLock.unlock()

    guard let db = db else {
        throw PluginError.databaseNotFound(name)
    }

    var rows: [[String: Any]] = []

    for row in try db.prepare(sql) {
        var rowData: [String: Any] = [:]
        for (index, name) in row.columnNames.enumerated() {
            rowData[name] = row[index]
        }
        rows.append(rowData)
    }

    return [
        "rows": rows,
        "count": rows.count
    ]
}

private func insertRow(_ args: [String: Any]) throws -> [String: Any] {
    guard let name = args["name"] as? String,
          let table = args["table"] as? String,
          let values = args["values"] as? [String: Any] else {
        throw PluginError.missingParameter("name, table, or values")
    }

    dbLock.lock()
    let db = databases[name]
    dbLock.unlock()

    guard let db = db else {
        throw PluginError.databaseNotFound(name)
    }

    let columns = values.keys.joined(separator: ", ")
    let placeholders = values.keys.map { _ in "?" }.joined(separator: ", ")
    let sql = "INSERT INTO \(table) (\(columns)) VALUES (\(placeholders))"

    let statement = try db.prepare(sql)
    try statement.run(Array(values.values))

    return [
        "success": true,
        "table": table,
        "lastInsertRowid": db.lastInsertRowid
    ]
}

// MARK: - Helpers

private func setError(_ ptr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
                      _ message: String) -> Int32 {
    ptr.pointee = strdup("{\"error\":\"\(message)\"}")
    return 1
}

private enum PluginError: LocalizedError {
    case missingParameter(String)
    case databaseNotFound(String)

    var errorDescription: String? {
        switch self {
        case .missingParameter(let name): return "Missing parameter: \(name)"
        case .databaseNotFound(let name): return "Database not found: \(name)"
        }
    }
}
```

### plugin.yaml

```yaml
name: plugin-swift-sqlite
version: 1.0.0
description: "SQLite database access for ARO"
aro-version: ">=0.1.0"

provides:
  - type: swift-plugin
    path: Sources/

build:
  swift:
    minimum-version: "5.9"
    targets:
      - name: SQLitePlugin
        path: Sources/
```

### Usage in ARO

```aro
(Database Demo: Application-Start) {
    (* Open database *)
    Call the <db> from the <sqlite: open> with {
        path: "users.db",
        name: "users"
    }.

    (* Create table *)
    Call the <_> from the <sqlite: execute> with {
        name: "users",
        sql: "CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, name TEXT, email TEXT)"
    }.

    (* Insert data *)
    Call the <inserted> from the <sqlite: insert> with {
        name: "users",
        table: "users",
        values: {
            name: "Alice",
            email: "alice@example.com"
        }
    }.
    Log "Inserted row: " with <inserted: lastInsertRowid> to the <console>.

    (* Query data *)
    Call the <results> from the <sqlite: query> with {
        name: "users",
        sql: "SELECT * FROM users"
    }.
    Log "Found " with <results: count> to the <console>.

    Return an <OK: status> for the <startup>.
}
```

## 10.3 Cargo Dependencies for Rust

Rust plugins use Cargo.toml for dependency management.

### Complete Cargo.toml

```toml
[package]
name = "image_plugin"
version = "1.0.0"
edition = "2021"

[lib]
name = "image_plugin"
crate-type = ["cdylib"]

[dependencies]
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
image = "0.24"                    # Image processing
base64 = "0.21"                   # Base64 encoding
rayon = "1.8"                     # Parallel processing

[profile.release]
lto = true
opt-level = 3
```

### Implementation with Dependencies

```rust
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::io::Cursor;

use image::{GenericImageView, ImageFormat, DynamicImage};
use serde_json::{json, Value};
use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64};

#[no_mangle]
pub extern "C" fn aro_plugin_info() -> *mut c_char {
    let info = json!({
        "name": "plugin-rust-image",
        "version": "1.0.0",
        "language": "rust",
        "actions": ["resize", "crop", "rotate", "thumbnail", "info"]
    });

    CString::new(info.to_string()).unwrap().into_raw()
}

#[no_mangle]
pub extern "C" fn aro_plugin_execute(
    action: *const c_char,
    input_json: *const c_char,
) -> *mut c_char {
    let action = unsafe { CStr::from_ptr(action).to_str().unwrap_or("") };
    let input = unsafe { CStr::from_ptr(input_json).to_str().unwrap_or("{}") };

    let input_value: Value = match serde_json::from_str(input) {
        Ok(v) => v,
        Err(e) => return error_result(&format!("Invalid JSON: {}", e)),
    };

    let result = match action {
        "resize" => resize_image(&input_value),
        "crop" => crop_image(&input_value),
        "rotate" => rotate_image(&input_value),
        "thumbnail" => create_thumbnail(&input_value),
        "info" => image_info(&input_value),
        _ => Err(format!("Unknown action: {}", action)),
    };

    match result {
        Ok(v) => CString::new(v.to_string()).unwrap().into_raw(),
        Err(e) => error_result(&e),
    }
}

fn resize_image(input: &Value) -> Result<Value, String> {
    let path = get_string(input, "path")?;
    let width = get_number(input, "width")? as u32;
    let height = get_number(input, "height")? as u32;
    let output_path = input.get("output")
        .and_then(|v| v.as_str())
        .unwrap_or("resized.png");

    let img = image::open(&path)
        .map_err(|e| format!("Failed to open image: {}", e))?;

    let resized = img.resize_exact(width, height, image::imageops::FilterType::Lanczos3);

    resized.save(output_path)
        .map_err(|e| format!("Failed to save image: {}", e))?;

    Ok(json!({
        "success": true,
        "output": output_path,
        "width": width,
        "height": height
    }))
}

fn create_thumbnail(input: &Value) -> Result<Value, String> {
    let path = get_string(input, "path")?;
    let max_size = get_number(input, "max_size").unwrap_or(200.0) as u32;

    let img = image::open(&path)
        .map_err(|e| format!("Failed to open image: {}", e))?;

    let thumbnail = img.thumbnail(max_size, max_size);

    // Encode to base64 for returning in JSON
    let mut buffer = Cursor::new(Vec::new());
    thumbnail.write_to(&mut buffer, ImageFormat::Png)
        .map_err(|e| format!("Failed to encode: {}", e))?;

    let base64_data = BASE64.encode(buffer.get_ref());

    Ok(json!({
        "thumbnail": base64_data,
        "width": thumbnail.width(),
        "height": thumbnail.height(),
        "format": "png",
        "encoding": "base64"
    }))
}

fn image_info(input: &Value) -> Result<Value, String> {
    let path = get_string(input, "path")?;

    let img = image::open(&path)
        .map_err(|e| format!("Failed to open image: {}", e))?;

    let (width, height) = img.dimensions();
    let color_type = format!("{:?}", img.color());

    Ok(json!({
        "path": path,
        "width": width,
        "height": height,
        "color_type": color_type,
        "aspect_ratio": width as f64 / height as f64
    }))
}

// ... other functions ...

fn get_string(value: &Value, field: &str) -> Result<String, String> {
    value.get(field)
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .ok_or_else(|| format!("Missing field: {}", field))
}

fn get_number(value: &Value, field: &str) -> Result<f64, String> {
    value.get(field)
        .and_then(|v| v.as_f64())
        .ok_or_else(|| format!("Missing field: {}", field))
}

fn error_result(message: &str) -> *mut c_char {
    CString::new(json!({"error": message}).to_string()).unwrap().into_raw()
}

#[no_mangle]
pub extern "C" fn aro_plugin_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe { let _ = CString::from_raw(ptr); }
    }
}
```

## 10.4 System Library Dependencies

Some plugins need system libraries that must be installed separately.

### C Plugin with libcurl

```yaml
# plugin.yaml
name: plugin-c-http
version: 1.0.0
description: "HTTP client using libcurl"
aro-version: ">=0.1.0"

provides:
  - type: c-plugin
    path: src/
    build:
      compiler: clang
      flags:
        - -O2
        - -fPIC
        - -shared
        - -I/usr/local/include
        - -I/opt/homebrew/include
      link:
        - -L/usr/local/lib
        - -L/opt/homebrew/lib
        - -lcurl
      output: libhttp_plugin.dylib
```

```c
// http_plugin.c
#include <curl/curl.h>
#include <stdlib.h>
#include <string.h>

// Response buffer
struct ResponseBuffer {
    char* data;
    size_t size;
};

static size_t write_callback(void* contents, size_t size, size_t nmemb, void* userp) {
    size_t real_size = size * nmemb;
    struct ResponseBuffer* buf = (struct ResponseBuffer*)userp;

    char* ptr = realloc(buf->data, buf->size + real_size + 1);
    if (!ptr) return 0;

    buf->data = ptr;
    memcpy(&(buf->data[buf->size]), contents, real_size);
    buf->size += real_size;
    buf->data[buf->size] = 0;

    return real_size;
}

char* aro_plugin_execute(const char* action, const char* input_json) {
    if (strcmp(action, "get") == 0) {
        char* url = extract_json_string(input_json, "url");
        if (!url) {
            return strdup("{\"error\":\"Missing 'url' field\"}");
        }

        CURL* curl = curl_easy_init();
        if (!curl) {
            free(url);
            return strdup("{\"error\":\"Failed to initialize curl\"}");
        }

        struct ResponseBuffer response = {0};

        curl_easy_setopt(curl, CURLOPT_URL, url);
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_callback);
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response);
        curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
        curl_easy_setopt(curl, CURLOPT_TIMEOUT, 30L);

        CURLcode res = curl_easy_perform(curl);
        long http_code = 0;
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);

        curl_easy_cleanup(curl);
        free(url);

        if (res != CURLE_OK) {
            free(response.data);
            char* error = malloc(256);
            snprintf(error, 256, "{\"error\":\"Curl error: %s\"}", curl_easy_strerror(res));
            return error;
        }

        // Build result (escaping body for JSON would be needed in production)
        char* result = malloc(response.size + 256);
        snprintf(result, response.size + 256,
                 "{\"status\":%ld,\"body_length\":%zu}",
                 http_code, response.size);

        free(response.data);
        return result;
    }

    return strdup("{\"error\":\"Unknown action\"}");
}
```

### Documenting System Requirements

Always document system dependencies in your README:

```markdown
# plugin-c-http

HTTP client plugin using libcurl.

## Requirements

This plugin requires libcurl to be installed on your system.

### macOS (Homebrew)
```bash
brew install curl
```

### Ubuntu/Debian
```bash
apt-get install libcurl4-openssl-dev
```

### RHEL/CentOS
```bash
yum install libcurl-devel
```

### Windows
Download from https://curl.se/windows/ and add to PATH.
```

## 10.5 Python Package Dependencies

Python plugins use `requirements.txt`:

### requirements.txt Best Practices

```
# Pin major versions for stability
transformers>=4.36.0,<5.0.0
torch>=2.0.0,<3.0.0

# Pin exact versions for reproducibility
numpy==1.24.3
pandas==2.0.3

# Development dependencies (optional)
# pytest>=7.0.0

# Platform-specific dependencies
# torch-cpu; sys_platform == 'linux'
```

### Managing Virtual Environments

For isolated dependencies:

```bash
# Create environment in plugin directory
cd Plugins/plugin-python-transformer
python3 -m venv .venv

# Activate
source .venv/bin/activate  # Unix
.venv\Scripts\activate     # Windows

# Install
pip install -r requirements.txt

# Save exact versions
pip freeze > requirements.lock
```

### Handling Large Dependencies

PyTorch can be 2GB+. Strategies:

1. **CPU-only version** (smaller):
   ```
   torch --index-url https://download.pytorch.org/whl/cpu
   ```

2. **Lazy imports** (faster startup):
   ```python
   _torch = None
   def get_torch():
       global _torch
       if _torch is None:
           import torch
           _torch = torch
       return _torch
   ```

3. **Document requirements**:
   ```markdown
   ## Note
   This plugin requires ~3GB of disk space for PyTorch and models.
   First run will download models (~500MB).
   ```

## 10.6 Handling Dependency Conflicts

When multiple plugins need different versions of the same library:

### Swift: Package Resolution

SPM resolves to a single version. If plugins conflict:

1. **Update plugins** to use compatible versions
2. **Fork the dependency** with needed changes
3. **Use separate plugin processes** (future ARO feature)

### Rust: Cargo Features

Use features to enable/disable functionality:

```toml
[dependencies]
tokio = { version = "1", features = ["rt-multi-thread"], optional = true }

[features]
default = []
async = ["tokio"]
```

### Python: Virtual Environments

Each Python plugin can have its own virtual environment:

```
Plugins/
├── plugin-python-nlp/
│   ├── .venv/          # Isolated environment
│   └── requirements.txt
└── plugin-python-vision/
    ├── .venv/          # Different versions OK
    └── requirements.txt
```

## 10.7 Building Portable Plugins

For plugins that should work across systems:

### Static Linking (Rust)

```toml
# Cargo.toml
[target.x86_64-unknown-linux-musl]
rustflags = ["-C", "target-feature=+crt-static"]
```

```bash
# Build statically linked
cargo build --release --target x86_64-unknown-linux-musl
```

### Bundling Libraries (C/C++)

On macOS, use `install_name_tool`:

```bash
# Copy library
cp /opt/homebrew/lib/libcurl.dylib Plugins/plugin-c-http/lib/

# Update reference
install_name_tool -change /opt/homebrew/lib/libcurl.dylib @loader_path/lib/libcurl.dylib libhttp_plugin.dylib
```

### Python Wheels

Use platform-specific wheels:

```
# For distribution
pip download --platform manylinux2014_x86_64 --only-binary=:all: torch
```

## 10.8 Dependency Checklist

Before publishing a plugin with dependencies:

- [ ] **Document all system requirements**
- [ ] **Pin versions** in package files
- [ ] **Test on clean system** without your development environment
- [ ] **Provide installation instructions** for each platform
- [ ] **Check license compatibility** of all dependencies
- [ ] **Note disk/memory requirements** for large dependencies
- [ ] **Handle missing dependencies gracefully** with clear error messages

## 10.9 Summary

Managing dependencies requires attention but enables powerful plugins:

| Language | Tool | Key File |
|----------|------|----------|
| Swift | Swift Package Manager | `Package.swift` |
| Rust | Cargo | `Cargo.toml` |
| Python | pip | `requirements.txt` |
| C/C++ | Manual/CMake | `plugin.yaml` build section |

Key principles:

- **Pin versions** for reproducibility
- **Document system requirements** clearly
- **Test on clean systems** before publishing
- **Use `type: .dynamic`** for Swift plugins
- **Use `crate-type = ["cdylib"]`** for Rust plugins

The next chapter puts these concepts into practice with a complete FFmpeg integration example.

