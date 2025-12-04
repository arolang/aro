# ARO-0023: File System and Monitoring

* Proposal: ARO-0023
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0020, ARO-0012

## Abstract

This proposal defines file system operations and file monitoring capabilities for ARO applications using the FileMonitor library.

## Motivation

Applications often need to:

1. **Read/Write Files**: Basic file I/O operations
2. **Watch Directories**: React to file system changes in real-time
3. **Event Integration**: Publish file events to the event system
4. **Process Files**: Transform and process file contents

---

## 1. File Monitoring

### Watch Action

The `<Watch>` action monitors a directory for file changes and emits events when files are created, modified, or deleted:

```aro
<Watch> the <file-monitor> for the <directory> with "./watched".
```

**Behavior:**
- Watches the specified directory recursively
- Emits events when file content changes (create, modify, delete)
- Runs asynchronously - does not block execution
- Continues monitoring until application shutdown

### Event Types

The file monitor emits three types of events:

| Event | Trigger | Data |
|-------|---------|------|
| `FileCreatedEvent` | New file created in watched directory | `path` - file path |
| `FileModifiedEvent` | Existing file content changed | `path` - file path |
| `FileDeletedEvent` | File removed from watched directory | `path` - file path |

---

## 2. Event Handlers

Feature sets with business activity `File Event Handler` receive file events. The feature set name determines which event type it handles:

### Handler Naming Convention

| Feature Set Name | Handles Event |
|------------------|---------------|
| `Handle File Created` | `FileCreatedEvent` |
| `Handle File Modified` | `FileModifiedEvent` |
| `Handle File Deleted` | `FileDeletedEvent` |

### Event Handler Examples

```aro
(Handle File Created: File Event Handler) {
    <Extract> the <path> from the <event: path>.
    <Log> the <created: message> for the <console> with <path>.
    <Return> an <OK: status> for the <event>.
}

(Handle File Modified: File Event Handler) {
    <Extract> the <path> from the <event: path>.
    <Log> the <modified: message> for the <console> with <path>.
    <Return> an <OK: status> for the <event>.
}

(Handle File Deleted: File Event Handler) {
    <Extract> the <path> from the <event: path>.
    <Log> the <deleted: message> for the <console> with <path>.
    <Return> an <OK: status> for the <event>.
}
```

### Event Data Access

Extract data from the event using the `<Extract>` action:

```aro
<Extract> the <path> from the <event: path>.
```

The `path` field contains the absolute path to the affected file.

---

## 3. File Reading

```aro
(* Read file contents as string *)
<Read> the <contents> from the <file-path>.

(* With path variable *)
<Create> the <config-path> with "./config.json".
<Read> the <config> from the <config-path>.
```

---

## 4. File Writing

```aro
(* Write text to file *)
<Write> the <content> to the <file-path>.

(* Append to file *)
<Store> the <log-entry> into the <log-file>.
```

---

## 5. Complete Example

A file watcher application that monitors a directory and logs all file changes:

```aro
(* File Watcher Application *)

(Application-Start: File Watcher) {
    <Log> the <startup: message> for the <console> with "Starting file watcher".

    (* Watch the current directory for changes *)
    <Watch> the <file-monitor> for the <directory> with ".".

    <Log> the <ready: message> for the <console> with "Watching for file changes... Press Ctrl+C to stop.".

    (* Keep the application running until Ctrl+C *)
    <Keepalive> the <application> for the <events>.

    <Return> an <OK: status> for the <startup>.
}

(Handle File Created: File Event Handler) {
    <Extract> the <path> from the <event: path>.
    <Log> the <file-created: message> for the <console>.
    <Return> an <OK: status> for the <event>.
}

(Handle File Modified: File Event Handler) {
    <Extract> the <path> from the <event: path>.
    <Log> the <file-modified: message> for the <console>.
    <Return> an <OK: status> for the <event>.
}

(Handle File Deleted: File Event Handler) {
    <Extract> the <path> from the <event: path>.
    <Log> the <file-deleted: message> for the <console>.
    <Return> an <OK: status> for the <event>.
}

(Application-End: Success) {
    <Log> the <shutdown: message> for the <console> with "File watcher stopped.".
    <Return> an <OK: status> for the <shutdown>.
}
```

---

## 6. File Processing Example

An application that processes files from an inbox directory:

```aro
(Application-Start: File Processor) {
    <Log> the <startup: message> for the <console> with "Starting file processor".
    <Watch> the <file-monitor> for the <directory> with "./inbox".
    <Keepalive> the <application> for the <events>.
    <Return> an <OK: status> for the <startup>.
}

(Process New File: File Event Handler) {
    <Extract> the <path> from the <event: path>.

    (* Read the new file *)
    <Read> the <content> from the <path>.

    (* Process the content *)
    <Transform> the <processed> from the <content> with uppercase.

    (* Write to output directory *)
    <Create> the <output-path> with "./outbox/processed.txt".
    <Write> the <processed> to the <output-path>.

    <Log> the <processed: message> for the <console> with <path>.
    <Return> an <OK: status> for the <processing>.
}
```

---

## Implementation Location

The file system service is implemented in:

- `Sources/ARORuntime/FileSystem/FileSystemService.swift` - File I/O and monitoring
- `Sources/ARORuntime/Events/EventTypes.swift` - File event types
- `Sources/ARORuntime/Actions/BuiltIn/ServerActions.swift` - Watch action

Examples:
- `Examples/FileWatcher/` - Complete file watching example

---

## Implementation Notes

- Uses FileMonitor library for cross-platform file watching
- File operations are async for non-blocking I/O
- Supports UTF-8 text and binary data
- Directory creation is automatic for write operations
- Available on macOS and Linux (not Windows)

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-12 | Initial specification |
| 2.0 | 2024-12 | Clarified Watch behavior, event handler conventions, consistent naming |
