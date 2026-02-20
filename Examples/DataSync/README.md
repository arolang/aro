# DataSync Example

This example demonstrates ARO-0052's unified URL I/O for data synchronization pipelines.

## Overview

The unified Read/Write syntax enables seamless data flow between local files and remote APIs:

```aro
(* Remote to local *)
Read the <data> from the <url: "https://api.example.com/export">.
Write the <data> to the <file: "./snapshot.json">.

(* Local to remote *)
Read the <report> from the <file: "./report.json">.
Write the <report> to the <url: "https://api.example.com/upload">.
```

## Pipeline Steps

1. **Fetch** - Download data from a remote API
2. **Cache** - Save to local file for persistence
3. **Read** - Load local data for processing
4. **Transform** - Modify data as needed
5. **Upload** - Send transformed data to remote endpoint

## Running

```bash
aro run ./Examples/DataSync
```

## Use Cases

- **Backup pipelines** - Sync remote data to local storage
- **ETL workflows** - Extract, Transform, Load patterns
- **Offline-first apps** - Cache remote data locally
- **Data migrations** - Move data between systems
