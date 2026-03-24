# FileScannerApp

Recursively scans all files in the current working directory, collects their
metadata via separate parallel events, and reports the single most recently
modified file using a formatted template.

---

## Plan

### Goal

1. Walk the entire directory tree starting from `.`
2. Dispatch one independent event per file to fetch its stat metadata
3. Accumulate results in a repository while a growing-threshold observer
   periodically prunes the repository down to the latest file
4. After all file events are processed, render the surviving entry

---

### Architecture

```
Application-Start
  │  initialise scan-config-repository  { n: 8 }
  │  emit StartScan(".")
  ▼
StartScan Handler  (scanner.aro)
  │  List all entries recursively from root
  │  for each file entry → emit GetFileStat(entry)   ← parallel events
  │  emit ScanComplete
  ▼
GetFileStat Handler  (scanner.aro)           × N (one per file)
  │  Stat the file
  │  Store stats into file-stats-repository
  │       │
  │       └─► file-stats-repository Observer  (processor.aro)
  │               only reacts to "created" changes
  │               count = Retrieve all + count()
  │               n     = scan-config-repository : n
  │               when count > n  →  emit ProcessStats
  ▼
ScanComplete Handler  (renderer.aro)
  │  emit ProcessStats("final")   ← ensures last batch is always pruned
  │  emit RenderResult("final")   ← enqueued after all pending ProcessStats
  ▼
ProcessStats Handler  (processor.aro)        × M (once per threshold crossing)
  │  double n  (if n < 1024, stop otherwise)
  │  find entry with max(modified) via tracker-repository accumulator
  │  delete all stale entries from file-stats-repository
  ▼
RenderResult Handler  (renderer.aro)
     Retrieve the single remaining entry
     Transform template  →  Log to console
```

---

### Growing-Threshold Behaviour

| Trigger # | n before | count > n? | n after |
|-----------|----------|------------|---------|
| 1st       | 8        | count > 8  | 16      |
| 2nd       | 16       | count > 16 | 32      |
| 3rd       | 32       | count > 32 | 64      |
| …         | …        | …          | …       |
| 7th       | 512      | count > 512| 1024    |
| 8th+      | 1024     | count > 1024 | 1024 (capped) |

The observer fires on every repository insert.  Because `ProcessStats` events
are fire-and-forget (queued), the n update does not take effect until the
corresponding `ProcessStats` handler actually runs — after all `GetFileStat`
handlers have already completed.  This means:

* The observer may emit several `ProcessStats` events (one per threshold
  crossing during the scan).
* The first `ProcessStats` to run will find **all** N files and prune to one.
* Subsequent `ProcessStats` calls find a single file and skip pruning cheaply.
* The final `ProcessStats` (emitted from `ScanComplete`) guarantees pruning
  even when the total file count never crossed the threshold.

---

### Key Design Decisions

**Separate parallel events** — `GetFileStat` events are emitted in a loop from
`StartScan`, making each file's stat retrieval a fully independent event handler
invocation rather than an inline loop body.

**Observer only on "created"** — The observer checks `changeType is "created"`
before counting, which prevents the deletions performed inside `ProcessStats`
from re-triggering the observer and causing an infinite loop.

**Tracker repository accumulator** — ARO variables are immutable, so the
"find max modified" walk uses a dedicated `latest-tracker-repository` as a
mutable accumulator.  It is cleared at the start of every `ProcessStats` call
to avoid stale state from a previous run.

**FIFO event ordering** — `ScanComplete` is emitted at the end of the
`StartScan` loop, so it is enqueued after every `GetFileStat` event.  Similarly,
`RenderResult` is emitted after `ProcessStats("final")` in `ScanComplete`, so
it is always the last event to execute.

---

### File Layout

```
FileScannerApp/
├── README.md               ← this file
├── main.aro                ← Application-Start, Application-End
├── scanner.aro             ← StartScan Handler, GetFileStat Handler
├── processor.aro           ← file-stats-repository Observer, ProcessStats Handler
├── renderer.aro            ← ScanComplete Handler, RenderResult Handler
└── templates/
    └── latest-file.tpl     ← display template
```

---

### Usage

```bash
# Scan the current directory
cd /path/to/scan
aro run /path/to/FileScannerApp

# Or scan a specific project
cd ~/Projects/MyApp
aro run ./Examples/FileScannerApp
```

Expected output (example):

```
File scanner starting...
Scanning directory recursively...
Threshold crossed: count=9  n=8
...
Repository pruned: kept 1 file, removed stale entries.
All file events dispatched. Finalising...

─────────────────────────────────────────────────────────────────
  Most Recently Modified File
─────────────────────────────────────────────────────────────────

  Path      ./Sources/ARORuntime/Actions/BuiltIn/ComputeAction.swift

  Size      42816 bytes
  Modified  2026-03-22T14:37:05Z

─────────────────────────────────────────────────────────────────
```
