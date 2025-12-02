# ARO-0029: Native File Monitoring

## Summary

This proposal adds native file system monitoring support to compiled ARO binaries, ensuring feature parity between `aro run` (interpreter) and `aro build` (native compilation).

## Motivation

Currently, the `<Watch>` action works in the interpreter using Swift's FileMonitor library with FSEvents, but compiled binaries only emit events without actually monitoring the file system. This creates a feature disparity where:

- `aro run ./Examples/FileWatcher` - Works correctly, detects file changes
- `./Examples/FileWatcher/FileWatcher` - Runs but doesn't detect any file changes

Users expect compiled binaries to have the same functionality as interpreted execution.

## Proposed Solution

Implement native file monitoring in the C runtime bridge using platform-specific APIs:

- **macOS**: FSEvents API
- **Linux**: inotify (future)
- **Windows**: ReadDirectoryChangesW (future)

### API Design

```c
// File monitor handle
typedef void* AROFileMonitor;

// Create a file monitor for a directory
AROFileMonitor aro_file_monitor_create(const char* path);

// Start monitoring (non-blocking, uses callbacks)
int aro_file_monitor_start(AROFileMonitor monitor, AROContext ctx);

// Stop monitoring
void aro_file_monitor_stop(AROFileMonitor monitor);

// Destroy the monitor
void aro_file_monitor_destroy(AROFileMonitor monitor);
```

### Event Handling

When file changes are detected, the native runtime will:
1. Print the event to console (matching interpreter behavior)
2. Store events in a queue for potential future event routing

### Integration with Watch Action

The `aro_action_watch` function will:
1. Create an FSEvents stream for the specified path
2. Register callbacks that print file change events
3. Start the stream on a background thread

## Implementation

### Phase 1: macOS FSEvents Support
- Implement `FileMonitorBridge.swift` using FSEvents
- Update `aro_action_watch` to use the new file monitor
- Ensure proper cleanup on SIGINT/SIGTERM

### Phase 2: Cross-Platform (Future)
- Add inotify support for Linux
- Add ReadDirectoryChangesW for Windows

## Example

```aro
(Application-Start: File Watcher) {
    <Watch> the <file-monitor> for the <directory> with ".".
    <Keepalive> the <application> for the <events>.
    <Return> an <OK: status> for the <startup>.
}
```

Both interpreter and native binary will output:
```
[FileMonitor] Created: ./newfile.txt
[FileMonitor] Modified: ./newfile.txt
[FileMonitor] Deleted: ./newfile.txt
```

## Compatibility

This is an additive change that brings native binaries to feature parity with the interpreter. No breaking changes.

## Alternatives Considered

1. **Polling-based monitoring**: Simpler but inefficient and misses rapid changes
2. **Swift runtime linking**: Would work but increases binary size significantly
3. **No native support**: Unacceptable feature disparity

## Timeline

- Phase 1 (macOS): Immediate implementation
- Phase 2 (Linux/Windows): Future releases
