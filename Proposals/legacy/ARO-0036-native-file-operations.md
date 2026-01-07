# ARO-0036: Native File and Directory Operations

* Proposal: ARO-0036
* Author: ARO Language Team
* Status: **Proposed**
* Requires: ARO-0023

## Abstract

This proposal extends ARO's file system capabilities with comprehensive native file and directory operations that work seamlessly across macOS, Linux, and Windows.

## Motivation

While ARO-0023 established basic file I/O (read, write, append, watch), real-world applications need additional capabilities:

1. **Directory Listing**: List files in a directory with filtering
2. **File Metadata**: Get file size, modification time, permissions
3. **Existence Checks**: Verify files/directories exist before operating
4. **Directory Creation**: Explicitly create directories
5. **Copy Operations**: Duplicate files and directories
6. **Move Operations**: Rename and relocate files/directories
7. **Cross-Platform**: Consistent behavior on all platforms

---

## 1. List Action

List directory contents with optional pattern matching:

```aro
(* List all entries *)
<List> the <entries> from the <directory: "./uploads">.

(* List with glob pattern *)
<List> the <aro-files> from the <directory: "./src"> matching "*.aro".

(* List recursively *)
<List> the <all-files> from the <directory: "./project"> recursively.

(* Combine pattern and recursive *)
<List> the <sources> from the <directory: "./src"> matching "*.swift" recursively.
```

### Result Structure

Each entry in the result array contains:

```
{
    name: "filename.txt",
    path: "/full/path/to/filename.txt",
    isFile: true,
    isDirectory: false,
    size: 1024,
    modified: "2024-12-27T14:22:00Z"
}
```

### Behavior

- Includes hidden files by default (predictable behavior)
- Supports glob patterns: `*`, `?`, `[abc]`, `**`
- Recursive option traverses subdirectories
- Returns empty array for empty directories
- Runtime error for non-existent directories

---

## 2. Stat Action

Get detailed metadata for a file or directory:

```aro
(* Get file info *)
<Stat> the <info> for the <file: "./document.pdf">.

(* Get directory info *)
<Stat> the <dir-info> for the <directory: "./src">.

(* Access metadata *)
<Log> <info: size> to the <console>.
<Log> <info: modified> to the <console>.
```

### Result Structure

```
{
    name: "filename.txt",
    path: "/full/path/to/filename.txt",
    size: 1024,                        // bytes (0 for directories)
    isFile: true,
    isDirectory: false,
    created: "2024-01-15T10:30:00Z",   // ISO 8601 format
    modified: "2024-12-27T14:22:00Z",
    accessed: "2024-12-27T15:00:00Z",
    permissions: "rw-r--r--"           // Unix-style
}
```

### Cross-Platform Notes

| Field | macOS/Linux | Windows |
|-------|-------------|---------|
| `created` | Birth time (if available) | Creation time |
| `modified` | mtime | Last write time |
| `accessed` | atime | Last access time |
| `permissions` | Unix mode bits | Mapped from ACL |

---

## 3. Exists Action

Check if a file or directory exists:

```aro
(* Check file existence *)
<Exists> the <found> for the <file: "./config.json">.

<Log> "Config not found!" to the <console> when <found> is false.

(* Check directory existence *)
<Exists> the <dir-exists> for the <directory: "./output">.
```

### Result

Returns a boolean: `true` if the path exists and matches the expected type (file/directory), `false` otherwise.

---

## 4. Make Action

Create a file or directory at the specified path.

**Verbs:** `make` (canonical), `touch`, `createdirectory`, `mkdir`
**Prepositions:** `at`, `to`, `for`

```aro
(* Create a directory *)
<Make> the <directory> at the <path: "./output/reports/2024">.

(* Create or touch a file *)
<Touch> the <file> at the <path: "./logs/app.log">.

(* Legacy syntax still works *)
<CreateDirectory> the <output-dir> at the <path: "./output/reports/2024">.

(* Check and create *)
<Exists> the <exists> for the <directory: "./cache">.

<Make> the <cache-dir> at the <path: "./cache"> when <exists> is false.
```

### Behavior

- When result is `<directory>`: Creates all intermediate directories (like `mkdir -p`)
- When result is `<file>`: Creates empty file or updates modification time (like `touch`)
- Succeeds silently if path already exists
- Creates parent directories automatically
- Runtime error on permission failure

---

## 5. Copy Action

Copy files or directories:

```aro
(* Copy a file *)
<Copy> the <file: "./template.txt"> to the <destination: "./copy.txt">.

(* Copy a directory - recursive by default *)
<Copy> the <directory: "./src"> to the <destination: "./backup/src">.

(* Overwrite existing *)
<Copy> the <file: "./new.txt"> to the <destination: "./old.txt">.
```

### Behavior

- Files: creates destination file with same content
- Directories: recursively copies all contents (default)
- Overwrites existing destination without warning
- Creates destination parent directories automatically
- Preserves file permissions where supported

---

## 6. Move Action

Move or rename files and directories:

```aro
(* Rename a file *)
<Move> the <file: "./draft.txt"> to the <destination: "./final.txt">.

(* Move to different directory *)
<Move> the <file: "./inbox/report.pdf"> to the <destination: "./archive/report.pdf">.

(* Move a directory *)
<Move> the <directory: "./temp"> to the <destination: "./processed">.
```

### Behavior

- Atomic operation when source and destination are on same filesystem
- Falls back to copy+delete for cross-filesystem moves
- Directories are moved recursively (default)
- Creates destination parent directories automatically
- Runtime error if source doesn't exist

---

## 7. Append Action

Append data to a file (clearer alternative to Store for files):

```aro
(* Append text to log file *)
<Append> the <log-line> to the <file: "./logs/app.log">.

(* Append with newline *)
<Append> the <entry> to the <file: "./data.txt"> with "\nNew line".
```

### Behavior

- Creates file if it doesn't exist
- Creates parent directories automatically
- Appends at end of file
- Does not add newlines automatically

---

## 8. Path Handling

ARO normalizes paths for cross-platform compatibility:

| Aspect | Behavior |
|--------|----------|
| Separator | Always use `/` in ARO code |
| Translation | Converted to `\` on Windows automatically |
| Relative paths | Resolved from working directory |
| Absolute paths | Preserved as-is |

---

## 9. Complete Examples

### List Three Oldest Files

```aro
(Application-Start: Oldest Files Demo) {
    <Log> "=== Three Oldest Files ===" to the <console>.

    (* List all entries *)
    <List> the <entries> from the <directory: ".">.

    (* Filter to files only *)
    <Filter> the <files> from <entries> where <isFile> is true.

    (* Sort by modified date - oldest first *)
    <Sort> the <by-date> from <files> by <modified: ascending>.

    (* Take first 3 *)
    <Take> the <oldest> from <by-date> with count 3.

    (* Display each *)
    <ForEach> <file> in <oldest> {
        <Compute> the <size-kb> from <file: size> / 1024.
        <Log> "<file: name>: <size-kb> KB" to the <console>.
    }

    <Return> an <OK: status> for the <demo>.
}
```

### File Operations Demo

```aro
(Application-Start: File Operations Demo) {
    <Log> "=== File Operations ===" to the <console>.

    (* Check and create output directory *)
    <Exists> the <dir-exists> for the <directory: "./demo-output">.

    <CreateDirectory> the <output> at the <path: "./demo-output"> when <dir-exists> is false.
    <Log> "Created directory" to the <console> when <dir-exists> is false.

    (* Write a file *)
    <Write> the <content> to the <file: "./demo-output/hello.txt">
        with "Hello from ARO!".

    (* Append to it *)
    <Append> the <line> to the <file: "./demo-output/hello.txt">
        with "\nAppended line.".

    (* Get stats *)
    <Stat> the <info> for the <file: "./demo-output/hello.txt">.
    <Log> "Size: <info: size> bytes" to the <console>.

    (* Copy the file *)
    <Copy> the <file: "./demo-output/hello.txt">
        to the <destination: "./demo-output/hello-copy.txt">.

    (* List directory *)
    <List> the <files> from the <directory: "./demo-output">.

    <ForEach> <file> in <files> {
        <Log> "  - <file: name>" to the <console>.
    }

    (* Move/rename *)
    <Move> the <file: "./demo-output/hello-copy.txt">
        to the <destination: "./demo-output/renamed.txt">.

    <Log> "=== Complete ===" to the <console>.
    <Return> an <OK: status> for the <demo>.
}
```

---

## 10. Implementation Location

### New Files

- `Sources/ARORuntime/Actions/BuiltIn/FileActions.swift` - Action implementations
- `Tests/AROuntimeTests/FileActionsTests.swift` - Action tests
- `Tests/AROuntimeTests/FileSystemServiceTests.swift` - Service tests
- `Examples/FileOperations/main.aro` - Demo application
- `Examples/OldestFiles/main.aro` - Oldest files example

### Modified Files

- `Sources/ARORuntime/FileSystem/FileSystemService.swift` - Extended service
- `Sources/ARORuntime/Actions/ActionRegistry.swift` - Register new actions
- `Sources/ARORuntime/Bridge/ServiceBridge.swift` - Native compilation
- `Sources/ARORuntime/Bridge/ActionBridge.swift` - Action bridges
- `Sources/AROCompiler/LLVMCodeGenerator.swift` - Compiler support

---

## 11. Cross-Platform Support

| Platform | Status |
|----------|--------|
| macOS | Full support |
| Linux | Full support |
| Windows | Full support (path translation, ACL mapping) |

### Windows-Specific Handling

- Path separators: `/` converted to `\`
- Hidden files: `.` prefix + Hidden attribute
- Permissions: Simplified mapping from ACL to rwx
- Case sensitivity: Normalized to lowercase for comparisons

---

## 12. Error Handling

As per ARO's happy-path philosophy, errors are handled by the runtime:

| Error | Runtime Response |
|-------|------------------|
| File not found | `Cannot find file: ./path` |
| Directory not found | `Cannot find directory: ./path` |
| Permission denied | `Permission denied: ./path` |
| Path is wrong type | `Expected file but found directory: ./path` |
| Copy failed | `Cannot copy from ./src to ./dst` |

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-12 | Initial specification |
