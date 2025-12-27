# File System

ARO provides built-in file system operations for reading, writing, and watching files. This chapter covers file I/O and directory monitoring.

## Reading Files

### Text Files

```aro
<Read> the <content> from the <file: "./data.txt">.
<Read> the <readme> from the <file: "./README.md">.
```

### JSON Files

```aro
<Read> the <config: JSON> from the <file: "./config.json">.
<Read> the <data: JSON> from the <file: "./data.json">.
```

### Binary Files

```aro
<Read> the <image: bytes> from the <file: "./logo.png">.
<Read> the <document: bytes> from the <file: "./report.pdf">.
```

### Dynamic Paths

```aro
(GET /files/{name}: File API) {
    <Extract> the <filename> from the <request: parameters>.
    <Read> the <content> from the <file: "./uploads/${filename}">.
    <Return> an <OK: status> with <content>.
}
```

### Error Handling

```aro
(Load Config: Configuration) {
    <Read> the <config: JSON> from the <file: "./config.json">.

    <Log> the <warning> for the <console> with "Config not found, using defaults" when <config> is empty.
    <Create> the <config> with {
        port: 8080,
        debug: false
    } when <config> is empty.

    <Publish> as <app-config> <config>.
    <Return> an <OK: status> for the <loading>.
}
```

## Writing Files

### Text Files

```aro
<Write> the <content> to the <file: "./output.txt">.
<Write> the <report> to the <file: "./reports/daily.txt">.
```

### JSON Files

```aro
<Write> the <config: JSON> to the <file: "./config.json">.
<Write> the <data: JSON> to the <file: "./export.json">.
```

### Appending

```aro
<Store> the <log-entry> into the <file: "./logs/app.log">.
<Store> the <record> into the <file: "./data/records.csv">.
```

### Creating Directories

Directories are created automatically when writing:

```aro
(* ./reports/2024/01/ is created if it doesn't exist *)
<Write> the <report> to the <file: "./reports/2024/01/daily.txt">.
```

## Deleting Files

```aro
<Delete> the <file: "./temp/cache.json">.
<Delete> the <file: path>.
```

## Directory Operations

### Listing Directory Contents

List all files in a directory:

```aro
<Create> the <uploads-path> with "./uploads".
<List> the <entries> from the <directory: uploads-path>.
```

Filter with glob patterns:

```aro
<Create> the <src-path> with "./src".
<List> the <aro-files> from the <directory: src-path> matching "*.aro".
```

List recursively:

```aro
<Create> the <project-path> with "./project".
<List> the <all-files> from the <directory: project-path> recursively.
```

Each entry contains:
- `name` - file or directory name
- `path` - full path
- `size` - file size in bytes
- `isFile` - true if file
- `isDirectory` - true if directory
- `modified` - last modification date

### Checking Existence

Check if a file exists:

```aro
<Exists> the <found> for the <file: "./config.json">.

when <found> is false {
    <Log> the <warning> for the <console> with "Config not found!".
}
```

Check if a directory exists:

```aro
<Exists> the <dir-exists> for the <directory: "./output">.
```

### Creating Directories

Create a directory (including parent directories):

```aro
<CreateDirectory> the <output-dir> to the <path: "./output/reports/2024">.
```

### Getting File Stats

Get detailed metadata for a file:

```aro
<Stat> the <info> for the <file: "./document.pdf">.
<Log> the <size> for the <console> with <info: size>.
<Log> the <modified> for the <console> with <info: modified>.
```

Get directory metadata:

```aro
<Stat> the <dir-info> for the <directory: "./src">.
```

### Copying Files and Directories

Copy a file:

```aro
<Copy> the <file: "./template.txt"> to the <destination: "./copy.txt">.
```

Copy a directory (recursive by default):

```aro
<Copy> the <directory: "./src"> to the <destination: "./backup/src">.
```

### Moving and Renaming

Rename a file:

```aro
<Move> the <file: "./draft.txt"> to the <destination: "./final.txt">.
```

Move to a different directory:

```aro
<Move> the <file: "./inbox/report.pdf"> to the <destination: "./archive/report.pdf">.
```

Move a directory:

```aro
<Move> the <directory: "./temp"> to the <destination: "./processed">.
```

### Appending to Files

Append data to a file:

```aro
<Append> the <log-line> to the <file: "./logs/app.log">.
```

Creates the file if it doesn't exist.

## File Watching

### Starting a Watcher

Watch directories for changes using the `<Watch>` action:

```aro
(Application-Start: File Processor) {
    <Log> the <startup: message> for the <console> with "Starting file processor".

    (* Watch the inbox directory for new files *)
    <Watch> the <file-monitor> for the <directory> with "./inbox".

    (* Keep running until shutdown *)
    <Keepalive> the <application> for the <events>.

    <Return> an <OK: status> for the <startup>.
}
```

**Watch Syntax:**
```aro
<Watch> the <file-monitor> for the <directory> with "path".
```

The `<Watch>` action:
- Monitors the specified directory recursively
- Emits events when files are created, modified, or deleted
- Runs asynchronously (does not block execution)
- Continues until application shutdown

### File Events

Watchers emit events when files change:

| Event | When Triggered | Data |
|-------|----------------|------|
| `FileCreatedEvent` | New file created | `path` - file path |
| `FileModifiedEvent` | Existing file modified | `path` - file path |
| `FileDeletedEvent` | File deleted | `path` - file path |

### Event Handler Naming Convention

Feature sets with business activity `File Event Handler` receive file events. The feature set name determines which event type it handles:

| Feature Set Name | Handles Event |
|------------------|---------------|
| `Handle File Created` | `FileCreatedEvent` |
| `Handle File Modified` | `FileModifiedEvent` |
| `Handle File Deleted` | `FileDeletedEvent` |

### Event Handler Examples

```aro
(* Handle new files *)
(Handle File Created: File Event Handler) {
    <Extract> the <path> from the <event: path>.
    <Log> the <file-created: message> for the <console>.
    <Return> an <OK: status> for the <event>.
}

(* Handle modified files *)
(Handle File Modified: File Event Handler) {
    <Extract> the <path> from the <event: path>.
    <Log> the <file-modified: message> for the <console>.
    <Return> an <OK: status> for the <event>.
}

(* Handle deleted files *)
(Handle File Deleted: File Event Handler) {
    <Extract> the <path> from the <event: path>.
    <Log> the <file-deleted: message> for the <console>.
    <Return> an <OK: status> for the <event>.
}
```

## Common Patterns

### Config Hot-Reload

```aro
(Application-Start: Hot Reload App) {
    (* Load initial config *)
    <Read> the <config: JSON> from the <file: "./config.json">.
    <Publish> as <app-config> <config>.

    (* Watch for config changes *)
    <Watch> the <file-monitor> for the <directory> with ".".

    <Start> the <http-server> on port <config: port>.
    <Wait> for <shutdown-signal>.
    <Return> an <OK: status> for the <startup>.
}

(Handle File Modified: File Event Handler) {
    <Extract> the <path> from the <event: path>.

    <Log> the <message> for the <console> with "Reloading configuration..." when <path> is "./config.json".
    <Read> the <new-config: JSON> from the <file: "./config.json"> when <path> is "./config.json".
    <Publish> as <app-config> <new-config> when <path> is "./config.json".
    <Log> the <message> for the <console> with "Configuration reloaded" when <path> is "./config.json".

    <Return> an <OK: status> for the <reload>.
}
```

### File Upload Processing

```aro
(Application-Start: Upload Processor) {
    <Watch> the <file-monitor> for the <directory> with "./uploads".
    <Start> the <http-server> on port 8080.
    <Wait> for <shutdown-signal>.
    <Return> an <OK: status> for the <startup>.
}

(POST /upload: Upload API) {
    <Extract> the <file-data> from the <request: body>.
    <Extract> the <filename> from the <request: headers.filename>.

    <Write> the <file-data> to the <file: "./uploads/${filename}">.

    <Return> a <Created: status> with { filename: <filename> }.
}

(Handle File Created: File Event Handler) {
    <Extract> the <path> from the <event: path>.

    (* Only process files in uploads directory *)
    <Read> the <content> from the <file: path> when <path> starts with "./uploads/".
    <Transform> the <processed> from the <content> when <path> starts with "./uploads/".
    <Write> the <processed> to the <file: "./processed/${filename}"> when <path> starts with "./uploads/".
    <Delete> the <file: path> when <path> starts with "./uploads/".
    <Log> the <message> for the <console> with "Processed: ${path}" when <path> starts with "./uploads/".

    <Return> an <OK: status> for the <processing>.
}
```

### Log File Management

```aro
(Application-Start: Logging App) {
    (* Create log directory if needed *)
    <Write> the <header> to the <file: "./logs/app.log">.
    <Return> an <OK: status> for the <startup>.
}

(Log Event: ApplicationEvent Handler) {
    <Extract> the <event-type> from the <event: type>.
    <Extract> the <event-data> from the <event: data>.

    <Create> the <log-entry> with {
        timestamp: <current-time>,
        type: <event-type>,
        data: <event-data>
    }.

    <Store> the <log-entry: JSON> into the <file: "./logs/app.log">.
    <Return> an <OK: status> for the <logging>.
}
```

### Batch File Processing

```aro
(Process Batch: Scheduled Task) {
    <List> the <files> from the <directory: "./inbox">.

    for each <file> in <files> {
        <Read> the <content> from the <file: file>.
        <Process> the <result> from the <content>.
        <Write> the <result> to the <file: "./outbox/${file.name}">.
        <Delete> the <file: file>.
    }

    <Return> an <OK: status> for the <batch>.
}
```

## File Paths

### Relative Paths

```aro
<Read> the <content> from the <file: "./config.json">.       (* Relative to app *)
<Read> the <content> from the <file: "../shared/data.json">. (* Parent directory *)
```

### Absolute Paths

```aro
<Read> the <content> from the <file: "/etc/myapp/config.json">.
```

### Path Construction

```aro
<Create> the <path> with "./uploads/${user-id}/${filename}".
<Write> the <data> to the <file: path>.
```

## Best Practices

### Always Handle Missing Files

```aro
(Load Data: Initialization) {
    <Read> the <data: JSON> from the <file: "./data.json">.

    (* Handle missing file *)
    <Create> the <data> with { items: [] } when <data> is empty.
    <Write> the <data: JSON> to the <file: "./data.json"> when <data> is empty.

    <Publish> as <app-data> <data>.
    <Return> an <OK: status> for the <loading>.
}
```

### Validate File Types

```aro
(POST /upload: Upload API) {
    <Extract> the <filename> from the <request: headers.filename>.
    <Extract> the <content-type> from the <request: headers.Content-Type>.

    (* Validate file type *)
    when <content-type> is not "image/png" and <content-type> is not "image/jpeg" {
        <Return> a <BadRequest: status> for the <invalid: file-type>.
    }

    <Write> the <data> to the <file: "./uploads/${filename}">.
    <Return> a <Created: status> with { filename: <filename> }.
}
```

### Use Appropriate Encodings

```aro
(* Text files *)
<Read> the <text> from the <file: "./data.txt">.

(* Binary files *)
<Read> the <binary: bytes> from the <file: "./image.png">.

(* JSON files *)
<Read> the <json: JSON> from the <file: "./config.json">.
```

### Clean Up Temporary Files

```aro
(Process File: Temporary Processing) {
    <Read> the <input> from the <file: "./input.txt">.
    <Write> the <temp> to the <file: "./temp/processing.tmp">.

    <Process> the <result> from the <temp>.

    <Write> the <result> to the <file: "./output.txt">.
    <Delete> the <file: "./temp/processing.tmp">.

    <Return> an <OK: status> for the <processing>.
}
```

## Next Steps

- [Sockets](sockets.html) - TCP communication
- [Events](events.html) - Event-driven architecture
- [Application Lifecycle](applicationlifecycle.html) - Startup and shutdown
