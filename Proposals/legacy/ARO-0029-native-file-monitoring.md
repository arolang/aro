# ARO-0029: Native File Monitoring

* Proposal: ARO-0029
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0023

## Abstract

This proposal adds native file system monitoring support to compiled ARO binaries, ensuring feature parity between `aro run` (interpreter) and `aro build` (native compilation).

## Motivation

The `<Watch>` action must work identically whether running via interpreter or as a compiled binary:

- `aro run ./Examples/FileWatcher` - Interpreter mode
- `./FileWatcher` - Compiled binary

Users expect compiled binaries to have the same functionality as interpreted execution.

---

## Implementation

Native file monitoring is implemented using platform-specific APIs:

| Platform | API | Implementation |
|----------|-----|----------------|
| macOS | FSEvents | `ServiceBridge.swift` lines 453-627 |
| Linux | inotify | `ServiceBridge.swift` lines 629-795 |
| Other | Polling | `ServiceBridge.swift` lines 797-943 |

### C Bridge API

```c
// Create a file monitor for a directory
AROFileMonitor aro_file_watcher_create(const char* path);

// Start monitoring (non-blocking, uses callbacks)
int aro_file_watcher_start(AROFileMonitor monitor);

// Stop monitoring
void aro_file_watcher_stop(AROFileMonitor monitor);

// Destroy the monitor
void aro_file_watcher_destroy(AROFileMonitor monitor);
```

### Watch Action Integration

The `aro_action_watch` function in `ActionBridge.swift`:
1. Creates a platform-specific file watcher
2. Starts monitoring on a background thread
3. Prints file change events to console
4. Stores watchers for cleanup on shutdown

---

## Usage

```aro
(Application-Start: File Watcher) {
    <Log> "Starting file watcher" to the <console>.

    (* Watch the current directory *)
    <Watch> the <file-monitor> for the <directory> with ".".

    (* Keep running until Ctrl+C *)
    <Keepalive> the <application> for the <events>.

    <Return> an <OK: status> for the <startup>.
}

(Handle File Created: File Event Handler) {
    <Extract> the <path> from the <event: path>.
    <Log> <path> to the <console>.
    <Return> an <OK: status> for the <event>.
}

(Handle File Modified: File Event Handler) {
    <Extract> the <path> from the <event: path>.
    <Log> <path> to the <console>.
    <Return> an <OK: status> for the <event>.
}

(Handle File Deleted: File Event Handler) {
    <Extract> the <path> from the <event: path>.
    <Log> <path> to the <console>.
    <Return> an <OK: status> for the <event>.
}
```

Both interpreter and native binary output:
```
[FileMonitor] Created: ./newfile.txt
[FileMonitor] Modified: ./newfile.txt
[FileMonitor] Deleted: ./newfile.txt
```

---

## Implementation Location

- `Sources/AROCRuntime/ServiceBridge.swift` - Platform-specific file watchers
- `Sources/AROCRuntime/ActionBridge.swift` - Watch action C bridge
- `Sources/ARORuntime/FileSystem/FileSystemService.swift` - Interpreter file monitoring

Examples:
- `Examples/FileWatcher/` - Complete file watching example

---

## Platform Notes

### macOS (FSEvents)
- Native kernel-level file system events
- Low latency (~0.5s)
- Recursive directory watching
- Full event type detection (create, modify, delete, rename)

### Linux (inotify)
- Kernel-based file notification
- Per-directory watches (recursive via application logic)
- Events: IN_CREATE, IN_DELETE, IN_MODIFY, IN_MOVED_FROM, IN_MOVED_TO

### Fallback (Polling)
- 1-second polling interval
- Tracks file modification times
- Works on any platform
- Higher latency, more CPU usage

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-12 | Initial specification |
| 2.0 | 2024-12 | Implemented: macOS FSEvents, Linux inotify, polling fallback |
