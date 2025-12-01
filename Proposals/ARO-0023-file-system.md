# ARO-0023: File System and Monitoring

* Proposal: ARO-0023
* Author: ARO Language Team
* Status: **Draft**
* Requires: ARO-0020, ARO-0012

## Abstract

This proposal defines file system operations and file monitoring capabilities for ARO applications using the FileMonitor library.

## Motivation

Applications often need to:

1. **Read/Write Files**: Basic file I/O operations
2. **Watch Directories**: React to file system changes
3. **Event Integration**: Publish file events to the event system
4. **Process Files**: Transform and process file contents

## Proposed Solution

### 1. File Reading

```aro
(* Read file contents *)
<Read> the <contents> from the <file: "./data/config.json">.

(* Read as specific type *)
<Read> the <config: JSON> from the <file: "./config.json">.

(* Read binary data *)
<Read> the <data: bytes> from the <file: "./image.png">.
```

### 2. File Writing

```aro
(* Write text to file *)
<Write> the <content> to the <file: "./output.txt">.

(* Append to file *)
<Store> the <log-entry> into the <file: "./logs/app.log">.

(* Write JSON *)
<Write> the <config: JSON> to the <file: "./config.json">.
```

### 3. File Monitoring

Watch directories for changes:

```aro
(Application-Start: File Watcher) {
    <Watch> the <directory: "./watched"> as <file-monitor>.
    <Return> an <OK: status> for the <startup>.
}
```

### 4. File Events

File changes emit events:

```swift
public struct FileCreatedEvent: RuntimeEvent {
    public let path: String
}

public struct FileModifiedEvent: RuntimeEvent {
    public let path: String
}

public struct FileDeletedEvent: RuntimeEvent {
    public let path: String
}

public struct FileRenamedEvent: RuntimeEvent {
    public let oldPath: String
    public let newPath: String
}
```

### 5. Event Handlers

Handle file events in feature sets:

```aro
(Handle File Created: File Event) {
    <Extract> the <path> from the <event: path>.
    <Read> the <content> from the <file: path>.
    <Log> the <new-file: message> for the <console> with <path>.
    <Return> an <OK: status> for the <event>.
}

(Handle File Modified: File Event) {
    <Extract> the <path> from the <event: path>.
    <Log> the <modified: message> for the <console> with <path>.
    <Return> an <OK: status> for the <event>.
}
```

### 6. FileMonitor Integration

```swift
public final class AROFileSystemService: FileSystemService, FileMonitorService {
    private var monitors: [String: FileMonitor] = [:]

    public func watch(path: String) async throws {
        let url = URL(fileURLWithPath: path)
        let monitor = FileMonitor(url: url) { [weak self] event in
            self?.handleFileEvent(event)
        }
        monitors[path] = monitor
        monitor.start()
    }

    private func handleFileEvent(_ event: FileMonitor.Event) {
        switch event {
        case .created(let url):
            eventBus.publish(FileCreatedEvent(path: url.path))
        case .modified(let url):
            eventBus.publish(FileModifiedEvent(path: url.path))
        case .deleted(let url):
            eventBus.publish(FileDeletedEvent(path: url.path))
        case .renamed(let old, let new):
            eventBus.publish(FileRenamedEvent(oldPath: old.path, newPath: new.path))
        }
    }
}
```

---

## Grammar Extension

```ebnf
(* File operations *)
file_reference = "file:" , ( string_literal | variable ) ;
watch_statement = "<Watch>" , "the" , file_reference , "as" , identifier ;
```

---

## Complete Example

```aro
(* File Processing Application *)

(Application-Start: File Processor) {
    <Log> the <startup: message> for the <console> with "Starting file processor".
    <Watch> the <directory: "./inbox"> as <file-monitor>.
    <Return> an <OK: status> for the <startup>.
}

(Process New File: File Handler) {
    <Extract> the <path> from the <event: path>.
    <Read> the <content> from the <file: path>.

    (* Process the content *)
    <Transform> the <processed> from the <content>.

    (* Write to output *)
    <Write> the <processed> to the <file: "./outbox/${filename}">.

    (* Delete original *)
    <Delete> the <file: path>.

    <Log> the <processed: message> for the <console> with <path>.
    <Return> an <OK: status> for the <processing>.
}

(Handle File Deleted: Cleanup Handler) {
    <Extract> the <path> from the <event: path>.
    <Log> the <deleted: message> for the <console> with <path>.
    <Return> an <OK: status> for the <event>.
}
```

---

## Implementation Notes

- Uses FileMonitor library for cross-platform file watching
- File operations are async for non-blocking I/O
- Supports UTF-8 text and binary data
- Directory creation is automatic for write operations

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-12 | Initial specification |
