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

    if <config> is empty then {
        <Log> the <warning> for the <console> with "Config not found, using defaults".
        <Create> the <config> with {
            port: 8080,
            debug: false
        }.
    }

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

## File Watching

### Starting a Watcher

Watch directories for changes:

```aro
(Application-Start: File Processor) {
    <Watch> the <directory: "./inbox"> as <inbox-watcher>.
    <Watch> the <directory: "./uploads"> as <upload-watcher>.
    <Return> an <OK: status> for the <startup>.
}
```

### File Events

Watchers emit events when files change:

| Event | When Triggered |
|-------|----------------|
| `FileCreated` | New file created |
| `FileModified` | Existing file modified |
| `FileDeleted` | File deleted |
| `FileRenamed` | File renamed |

### Event Handlers

```aro
(* New file created *)
(Process New File: FileCreated Handler) {
    <Extract> the <path> from the <event: path>.
    <Log> the <message> for the <console> with "New file: ${path}".
    <Read> the <content> from the <file: path>.
    <Process> the <result> from the <content>.
    <Return> an <OK: status> for the <processing>.
}

(* File modified *)
(Handle Modified: FileModified Handler) {
    <Extract> the <path> from the <event: path>.
    <Log> the <message> for the <console> with "Modified: ${path}".
    <Read> the <content> from the <file: path>.
    (* Process updated content *)
    <Return> an <OK: status> for the <update>.
}

(* File deleted *)
(Handle Deleted: FileDeleted Handler) {
    <Extract> the <path> from the <event: path>.
    <Log> the <message> for the <console> with "Deleted: ${path}".
    (* Clean up related data *)
    <Return> an <OK: status> for the <cleanup>.
}

(* File renamed *)
(Handle Renamed: FileRenamed Handler) {
    <Extract> the <old-path> from the <event: oldPath>.
    <Extract> the <new-path> from the <event: newPath>.
    <Log> the <message> for the <console> with "Renamed: ${old-path} -> ${new-path}".
    <Return> an <OK: status> for the <rename>.
}
```

## Common Patterns

### Config Hot-Reload

```aro
(Application-Start: Hot Reload App) {
    (* Load initial config *)
    <Read> the <config: JSON> from the <file: "./config.json">.
    <Publish> as <app-config> <config>.

    (* Watch for changes *)
    <Watch> the <directory: "."> as <config-watcher>.

    <Start> the <http-server> on port <config: port>.
    <Return> an <OK: status> for the <startup>.
}

(Reload Config: FileModified Handler) {
    <Extract> the <path> from the <event: path>.

    if <path> is "./config.json" then {
        <Log> the <message> for the <console> with "Reloading configuration...".
        <Read> the <new-config: JSON> from the <file: "./config.json">.
        <Publish> as <app-config> <new-config>.
        <Log> the <message> for the <console> with "Configuration reloaded".
    }

    <Return> an <OK: status> for the <reload>.
}
```

### File Upload Processing

```aro
(Application-Start: Upload Processor) {
    <Watch> the <directory: "./uploads"> as <upload-watcher>.
    <Start> the <http-server> on port 8080.
    <Return> an <OK: status> for the <startup>.
}

(POST /upload: Upload API) {
    <Extract> the <file-data> from the <request: body>.
    <Extract> the <filename> from the <request: headers filename>.

    <Write> the <file-data> to the <file: "./uploads/${filename}">.

    <Return> a <Created: status> with { filename: <filename> }.
}

(Process Upload: FileCreated Handler) {
    <Extract> the <path> from the <event: path>.

    (* Only process files in uploads directory *)
    if <path> starts with "./uploads/" then {
        <Read> the <content> from the <file: path>.
        <Transform> the <processed> from the <content>.
        <Write> the <processed> to the <file: "./processed/${filename}">.
        <Delete> the <file: path>.
        <Log> the <message> for the <console> with "Processed: ${path}".
    }

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

    if <data> is empty then {
        (* Handle missing file *)
        <Create> the <data> with { items: [] }.
        <Write> the <data: JSON> to the <file: "./data.json">.
    }

    <Publish> as <app-data> <data>.
    <Return> an <OK: status> for the <loading>.
}
```

### Validate File Types

```aro
(POST /upload: Upload API) {
    <Extract> the <filename> from the <request: headers filename>.
    <Extract> the <content-type> from the <request: headers Content-Type>.

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

- [Sockets](Sockets.md) - TCP communication
- [Events](Events.md) - Event-driven architecture
- [Application Lifecycle](ApplicationLifecycle.md) - Startup and shutdown
