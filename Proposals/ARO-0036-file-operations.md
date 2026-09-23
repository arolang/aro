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
Exists the <result> for "./path".
```

The bare-string form takes the path directly, the same way Write and Read
accept one. It checks plain existence; only the `<file: …>` / `<directory: …>`
spellings additionally require the entry to be of that type.

### 1.2 Result

Returns a boolean: `true` if exists, `false` otherwise. All three spellings
bind a real boolean — usable in `when` guards — and agree with each other
(GitLab #494).

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
Copy the <name: source> to the <destination: target>.
```

The result slot is a **binding whose name the author picks**, and `source` is
read from its specifier. `file` and `directory` are the conventional names, not
required ones:

```aro
Copy the <file: source> to the <destination: target>.        (* conventional *)
Copy the <backup: source> to the <destination: target>.      (* binds `backup` *)
```

Requiring the literal word meant two copies in one feature set both rebound
`file`, which immutability refuses — so the documented workaround was to split
them across feature sets (GitLab #830). `Move` reads identically.

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

(* Two copies in one feature set, each binding its own result *)
Copy the <template-backup: "./template.txt"> to the <destination: "./bak/template.txt">.
Copy the <config-backup: "./config.yaml"> to the <destination: "./bak/config.yaml">.
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
List the <result> from the <directory: path> matching <pattern-variable>.
```

The pattern is a POSIX `fnmatch(3)` glob, evaluated with no flags:

| Form | Matches |
|------|---------|
| `*` | any run of characters, including none |
| `?` | exactly one character |
| `[abc]`, `[a-z]` | one character from the set or range |
| `[!abc]`, `[^abc]` | one character *not* in the set |
| `\*`, `\?` | a literal `*` or `?` |

Four properties the glob has, and the `Filter … contains` workaround it
replaces does not:

- **It is anchored.** The whole name must match, so `"*.csv"` keeps `a.csv`
  and rejects `report.csvx` — the substring filter kept both.
- **It matches the entry *name*, not the path.** Only the last component is
  ever tested, so `"*.csv"` behaves the same at any depth under
  `recursively`.
- **It is case-sensitive** (POSIX default): `"*.md"` does not match
  `README.MD`.
- **It filters entries, so it filters directories too.** A glob is not a
  file test; `"s*"` keeps a subdirectory named `sub`.

A leading dot is not special (no `FNM_PERIOD`), so `"*.csv"` also keeps
`.hidden.csv`. A pattern that matches nothing yields an empty listing —
never the unfiltered directory.

`matching` is a List clause. On any other verb it is a check-time error
rather than a clause the action would quietly ignore.

### 6.3 Recursive Listing

```aro
List the <result> from the <directory: path> recursively.
```

The older qualifier spelling — `List the <all-files: recursively> from the
<directory: path>.` — remains valid.

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

(* The glob may come from a variable — a config file can drive it *)
Extract the <glob> from the <config: pattern>.
List the <exports> from the <directory: "./out"> matching <glob>.
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
Delete the <result> from the <file: path>.
Delete the <result> from the <directory: path>.
Delete the <result> from "./path".
```

The bare-string form takes the path directly, the same way Write and Read
accept one. A string variable in object position is also treated as a path.

### 7.2 Behavior

- **Files**: Removes the file
- **Directories**: Recursively removes directory and contents
- A missing path is an error, matching Copy and Move on a missing source
  (ARO-0006: the runtime reports the failed statement). Deleting a file that
  is already gone — for example on a rerun — fails loudly rather than
  answering ok.
- Deletion emits a `file.deleted` event on success

### 7.3 Examples

```aro
(* Delete a file *)
Delete the <cleared> from the <file: "./temp/cache.json">.

(* Delete a directory *)
Delete the <removed> from the <directory: "./build">.

(* Bare string path *)
Delete the <gone> from "./scratch-probe.txt".
```

---

## 8. Error Handling

File operations follow ARO's error philosophy—errors are descriptive and automatic:

| Operation | Error Condition | Error Message |
|-----------|-----------------|---------------|
| Stat | File not found | `Cannot stat the info for the file: "./missing.txt"` |
| Copy | Source not found | `Cannot copy the file: "./missing.txt" to the destination` |
| Move | Permission denied | `Cannot move the file: "./locked.txt" to the destination` |
| Delete | Path not found | `Cannot delete the gone from "./missing.txt"` |

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
| **Delete** | Remove file/dir | `Delete the <r> from the <file: p>.` |

`Make` accepts `to`, `at` **and** `for` (`MakeAction.validPrepositions`), so the
`at` spelling used throughout ARO-0008 §4 and the `to` spelling used here are
both valid — they looked like a contradiction (GitLab #831) and are not. `to` is
the spelling this proposal uses; either parses.

---

## References

- `Sources/ARORuntime/Actions/BuiltIn/` - Action implementations
- ARO-0008: I/O Services - Base file system operations
- `Examples/FileOperations/` - File operation examples
