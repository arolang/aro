# FileWatcher

Demonstrates file system monitoring with event-driven handlers.

## What It Does

Watches the current directory for file changes and logs when files are created, modified, or deleted. Uses the `<Keepalive>` action to run continuously until interrupted.

## Features Tested

- **File monitoring** - `<Watch>` action with `file-monitor`
- **File event handlers** - `File Event Handler` business activity pattern
- **Event types** - `Handle File Created`, `Handle File Modified`, `Handle File Deleted`
- **Path extraction** - Getting file path from events
- **Keepalive** - Long-running application with graceful shutdown
- **Application-End** - Cleanup handler on shutdown

## Related Proposals

- [ARO-0023: File System Operations](../../Proposals/ARO-0023-file-system.md)
- [ARO-0028: Long-Running Applications](../../Proposals/ARO-0028-keepalive.md)

## Usage

```bash
# Start the watcher
aro run ./Examples/FileWatcher

# In another terminal, create/modify/delete files
touch test.txt
echo "hello" >> test.txt
rm test.txt

# Press Ctrl+C to stop
```

## Example Output

```
Starting file watcher
Watching for file changes... Press Ctrl+C to stop.
File created: ./test.txt
File modified: ./test.txt
File deleted: ./test.txt
^C
File watcher stopped.
```

---

*Reactive file handling without polling. The filesystem tells you when something changes.*
