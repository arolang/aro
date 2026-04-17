# Build a file system watcher

Create a single-file ARO application that monitors the current directory for file changes and handles create, modify, and delete events.

The `main.aro` file should contain:

- `Application-Start: File Watcher` -- Log a startup message, start the file monitor with "." (current directory), log that it's watching for changes, use Keepalive to keep running, and return OK.

- `Handle File Created: File Event Handler` -- Extract the path from `<event: path>`, log "File created", and return OK.

- `Handle File Modified: File Event Handler` -- Extract the path from `<event: path>`, log "File modified", and return OK.

- `Handle File Deleted: File Event Handler` -- Extract the path from `<event: path>`, log "File deleted", and return OK.

- `Application-End: Success` -- Log "File watcher stopped." and return OK.
