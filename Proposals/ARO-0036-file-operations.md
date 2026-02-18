# ARO-0036: Extended File Operations

* Proposal: ARO-0036
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0004, ARO-0008

## Abstract

This proposal defines extended file system operations beyond basic Read and Write: checking file existence, retrieving metadata, creating directories, and copying/moving files. These operations complement the I/O services defined in ARO-0008.

---

## 1. Exists Action

Check if a file or directory exists.

### 1.1 Syntax

```aro
Exists the <result> for the <file: path>.
Exists the <result> for the <directory: path>.
```

### 1.2 Result

Returns a boolean: `true` if exists, `false` otherwise.

### 1.3 Examples

```aro
(* Check file existence *)
Exists the <config-exists> for the <file: "./config.json">.
Log "Config found" to the <console> when <config-exists> = true.

(* Check directory existence *)
Exists the <output-exists> for the <directory: "./output">.
Make the <output-dir> to the <path: "./output"> when <output-exists> = false.
```

---

## 2. Stat Action

Retrieve file or directory metadata.

### 2.1 Syntax

```aro
Stat the <result> for the <file: path>.
Stat the <result> for the <directory: path>.
```

### 2.2 Result Properties

| Property | Type | Description |
|----------|------|-------------|
| `name` | String | File or directory name |
| `path` | String | Full path |
| `size` | Integer | Size in bytes |
| `isFile` | Boolean | `true` if file |
| `isDirectory` | Boolean | `true` if directory |
| `created` | String | Creation date (ISO 8601) |
| `modified` | String | Modification date (ISO 8601) |
| `permissions` | String | Unix-style permissions |
| `owner` | String | Owner name |
| `group` | String | Group name |

### 2.3 Examples

```aro
(* Get file metadata *)
Stat the <info> for the <file: "./document.pdf">.
Extract the <size> from the <info: size>.
Extract the <modified> from the <info: modified>.
Log "File size: ${size} bytes, modified: ${modified}" to the <console>.

(* Check if path is directory *)
Stat the <info> for the <directory: "./src">.
Extract the <is-dir> from the <info: isDirectory>.
```

---

## 3. Make Action

Create a directory with all intermediate directories.

### 3.1 Syntax

```aro
Make the <result> to the <path: directory-path>.
```

### 3.2 Behavior

- Creates the directory at the specified path
- Creates all intermediate directories (like `mkdir -p`)
- Returns the created path
- No error if directory already exists

### 3.3 Examples

```aro
(* Create nested directory structure *)
Make the <output-dir> to the <path: "./output/reports/2024">.

(* Create directory for file output *)
Make the <logs-dir> to the <path: "./logs">.
Write the <content> to the <file: "./logs/app.log">.
```

---

## 4. Copy Action

Copy files or directories.

### 4.1 Syntax

```aro
Copy the <file: source> to the <destination: target>.
Copy the <directory: source> to the <destination: target>.
```

### 4.2 Behavior

- **Files**: Copies file content to destination
- **Directories**: Recursively copies entire directory tree
- Overwrites destination if it exists
- Creates parent directories if needed

### 4.3 Examples

```aro
(* Copy a file *)
Copy the <file: "./template.txt"> to the <destination: "./output/copy.txt">.

(* Copy a directory *)
Copy the <directory: "./src"> to the <destination: "./backup/src">.

(* Copy with variable paths *)
Create the <source-path> with "./data/input.json".
Create the <dest-path> with "./archive/input.json".
Copy the <file: source-path> to the <destination: dest-path>.
```

---

## 5. Move Action

Move or rename files and directories.

### 5.1 Syntax

```aro
Move the <file: source> to the <destination: target>.
Move the <directory: source> to the <destination: target>.
```

### 5.2 Behavior

- Moves the source to destination
- Effectively a rename if same directory
- Creates parent directories if needed
- Removes source after successful move

### 5.3 Examples

```aro
(* Rename a file *)
Move the <file: "./draft.txt"> to the <destination: "./final.txt">.

(* Move to different directory *)
Move the <file: "./temp/data.json"> to the <destination: "./processed/data.json">.

(* Move a directory *)
Move the <directory: "./uploads/pending"> to the <destination: "./uploads/completed">.
```

---

## 6. List Action Extensions

List directory contents with filtering and recursion.

### 6.1 Basic Syntax

```aro
List the <result> from the <directory: path>.
```

### 6.2 With Pattern Matching

```aro
List the <result> from the <directory: path> matching "pattern".
```

### 6.3 Recursive Listing

```aro
List the <result> from the <directory: path> recursively.
```

### 6.4 Examples

```aro
(* List all files in directory *)
List the <entries> from the <directory: "./src">.

(* List only .aro files *)
List the <aro-files> from the <directory: "./src"> matching "*.aro".

(* Recursive listing *)
List the <all-files> from the <directory: "./project"> recursively.

(* Combine pattern and recursion *)
List the <all-tests> from the <directory: "."> matching "*_test.aro" recursively.
```

### 6.5 Result Properties

Each entry in the result array has:

| Property | Type | Description |
|----------|------|-------------|
| `name` | String | Entry name |
| `path` | String | Full path |
| `isFile` | Boolean | `true` if file |
| `isDirectory` | Boolean | `true` if directory |

---

## 7. Delete Action for Files

Remove files and directories.

### 7.1 Syntax

```aro
Delete the <file: path>.
Delete the <directory: path>.
```

### 7.2 Behavior

- **Files**: Removes the file
- **Directories**: Recursively removes directory and contents
- No error if path doesn't exist

### 7.3 Examples

```aro
(* Delete a file *)
Delete the <file: "./temp/cache.json">.

(* Delete a directory *)
Delete the <directory: "./build">.
```

---

## 8. Error Handling

File operations follow ARO's error philosophy—errors are descriptive and automatic:

| Operation | Error Condition | Error Message |
|-----------|-----------------|---------------|
| Stat | File not found | `Cannot stat the info for the file: "./missing.txt"` |
| Copy | Source not found | `Cannot copy the file: "./missing.txt" to the destination` |
| Move | Permission denied | `Cannot move the file: "./locked.txt" to the destination` |

---

## Summary

| Action | Purpose | Syntax |
|--------|---------|--------|
| **Exists** | Check existence | `Exists the <r> for the <file: p>.` |
| **Stat** | Get metadata | `Stat the <r> for the <file: p>.` |
| **Make** | Create directory | `Make the <r> to the <path: p>.` |
| **Copy** | Copy file/dir | `Copy the <file: s> to the <destination: d>.` |
| **Move** | Move/rename | `Move the <file: s> to the <destination: d>.` |
| **List** | List directory | `List the <r> from the <directory: p>.` |
| **Delete** | Remove file/dir | `Delete the <file: p>.` |

---

## References

- `Sources/ARORuntime/Actions/BuiltIn/` - Action implementations
- ARO-0008: I/O Services - Base file system operations
- `Examples/FileOperations/` - File operation examples
