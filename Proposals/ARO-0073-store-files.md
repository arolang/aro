# ARO-0073: Store Files

- **Status:** Draft
- **Author:** Claude Code
- **Created:** 2026-04-01
- **Related:** ARO-0007 (Events & Reactive), ARO-0008 (I/O Services), ARO-0036 (File Operations)

## Abstract

This proposal introduces `.store` files -- YAML files placed in an ARO application directory that automatically seed and optionally persist repository data. A `<name>.store` file backs the `<name>-repository`, loading its contents before `Application-Start` executes. File permissions determine whether runtime changes are written back to disk: if the file's POSIX other-write bit is set, the store is writable and changes persist; otherwise it is read-only.

## Motivation

### The Problem

ARO repositories are purely in-memory. There is no declarative way to seed them with initial data, no persistence across restarts, and no structured configuration format for repository contents. Developers must write imperative `Store` statements inside `Application-Start`:

```aro
(Application-Start: My App) {
    Store { name: "Alice", role: "admin" } into the <user-repository>.
    Store { name: "Bob", role: "viewer" } into the <user-repository>.
    Store { name: "Carol", role: "editor" } into the <user-repository>.
    (* ... dozens more ... *)

    Start the <http-server> with <contract>.
    Keepalive the <application> for the <events>.
    Return an <OK: status> for the <startup>.
}
```

This approach has several drawbacks:

| Problem | Impact |
|---------|--------|
| Verbose boilerplate | Startup logic drowns in data |
| No separation of data and logic | Hard to review, hard to diff |
| No persistence | Data lost on every restart |
| No tooling support | YAML editors provide validation; ARO editors do not validate data shapes |
| Painful for large datasets | 100 users = 100 Store statements |

### What We Want

```
MyApp/
├── main.aro
├── openapi.yaml
├── users.store          <-- seeds user-repository (read-only)
└── config.store         <-- seeds config-repository (writable, chmod o+w)
```

Data lives in YAML. Logic stays in `.aro` files. Persistence is opt-in via file permissions.

---

## Proposed Design

### 1. File Convention

A file named `<name>.store` in the application directory (or any subdirectory) automatically backs the repository named `<name>-repository`.

```
┌─────────────────────────────────────────────────┐
│                 FILE DISCOVERY                    │
│                                                   │
│   MyApp/                                          │
│   ├── users.store ────────▶ user-repository       │
│   │   (note: "users" maps to "user-repository"    │
│   │    by dropping trailing 's')                   │
│   ├── config.store ───────▶ config-repository      │
│   ├── products.store ─────▶ product-repository     │
│   └── order-items.store ──▶ order-item-repository  │
│                                                   │
│   Naming rule:                                    │
│     <name>.store  -->  <singular(name)>-repository │
│     Singularization: strip trailing 's'           │
│     If no trailing 's': use name as-is            │
└─────────────────────────────────────────────────┘
```

### 2. File Format

Each `.store` file is a YAML list of objects. Each object becomes one repository entry.

**users.store:**
```yaml
- name: Alice
  role: admin
  email: alice@example.com

- name: Bob
  role: viewer
  email: bob@example.com

- name: Carol
  role: editor
  email: carol@example.com
```

### 3. Writability via POSIX Permissions

Rather than introducing a YAML header or new configuration syntax, writability is controlled by the file's POSIX permissions -- specifically the **other-write** bit.

| Permission | Command | Behavior |
|------------|---------|----------|
| Read-only (default) | `chmod o-w users.store` | Seed at startup, no write-back |
| Writable | `chmod o+w users.store` | Seed at startup, persist changes |

**Why the other-write bit?**

- It is the least commonly set permission bit, so accidental writability is unlikely
- It is visible in `ls -l` output (`-rw-r--rw-` vs `-rw-r--r--`)
- No new syntax, no new config files, no new CLI flags
- Works with standard UNIX tooling (`chmod`, `stat`, `test -w`)

**Checking writability:**
```
$ ls -l *.store
-rw-r--r--  1 user  staff  245  users.store      # read-only
-rw-r--rw-  1 user  staff  102  config.store      # writable (other-write set)
```

### 3a. Writability on Windows

Windows has no other-write bit, and no permission that means what `o+w` means
here. The check that stood in for it asked `FileManager.isWritableFile`, which
is true for any file the current user owns -- so every `.store` on Windows was
writable and a seed file the author meant to be read-only was rewritten at
shutdown. That is the contract inverted, not approximated (GitLab #684).

On Windows, and only on Windows, writability is declared in the file:

```yaml
# aro-store: writable
- name: Alice
  role: admin
```

| Marker | Behavior |
|--------|----------|
| absent (default) | Seed at startup, no write-back |
| `# aro-store: writable` | Seed at startup, persist changes |

The marker must appear in the leading comment block, before the first entry.
A marker below the data is ignored, so an application writing to its own store
cannot opt that store in. Matching ignores case and spacing.

Alternative 1 below rejects exactly this header for POSIX, and that rejection
stands: there, file permissions already exist and are visible in `ls -l`. On
Windows there is nothing to prefer them to, and the alternative is no opt-in at
all.

The marker is a YAML comment, so the file stays valid everywhere and stays
portable. A store authored on Windows and carried to a POSIX host is read-only
until someone runs `chmod o+w` -- the marker is not consulted there. A store
drifting toward read-only is the safe direction; the reverse would mean a file
that quietly began persisting when it changed machines.

### 4. Lifecycle

```
┌──────────────────────────────────────────────────────────────┐
│                    APPLICATION STARTUP                         │
│                                                                │
│   1. Discover .aro files                                      │
│   2. Discover .store files                                    │
│   3. Parse each .store file as YAML                           │
│   4. Check POSIX permissions for each .store                  │
│   5. Create/seed repositories from .store contents            │
│   6. Execute Application-Start feature set                    │
│                                                                │
│   ┌──────────┐    ┌──────────────┐    ┌──────────────────┐    │
│   │  .store  │───▶│ YAML Parser  │───▶│   Repository     │    │
│   │  files   │    │              │    │   (seeded)       │    │
│   └──────────┘    └──────────────┘    └──────────────────┘    │
│                                              │                 │
│                                              ▼                 │
│                                     ┌──────────────────┐      │
│                                     │ Application-Start│      │
│                                     │   (executes)     │      │
│                                     └──────────────────┘      │
└──────────────────────────────────────────────────────────────┘
```

**Key rule:** Store files are loaded **before** `Application-Start`. This means repositories are already populated when startup logic runs. Any `Store` statements in `Application-Start` add to or overwrite the seeded data.

### 5. Write-Back Behavior

For writable stores, changes are persisted back to disk:

| Trigger | Behavior |
|---------|----------|
| `Store` action | Schedule write-back with 1-second debounce |
| `Update` action | Schedule write-back with 1-second debounce |
| `Delete` action | Schedule write-back with 1-second debounce |
| `Commit` statement | Write now, and wait for it (§5a) |
| Graceful shutdown (SIGINT/SIGTERM) | Flush all pending writes immediately |
| Crash / SIGKILL | Pending changes lost (last successful write preserved) |

The debounce is why a program that wants a guarantee needs `Commit`: between a
`Store` and the write it schedules there is a second in which a SIGKILL loses
the change, and nothing in the source says so.

**Atomic writes:** Write-back always uses a write-to-temporary-then-rename strategy to prevent corruption:

```
+--------------------------------------------------+
|              ATOMIC WRITE-BACK                    |
|                                                   |
|   1. Serialize repository to YAML                 |
|   2. Write to  <name>.store.tmp                   |
|   3. fsync     <name>.store.tmp                   |
|   4. rename(2) <name>.store.tmp -> <name>.store   |
|                                                   |
|   If step 2 or 3 fails: .tmp is abandoned         |
|   Original .store file is never corrupted         |
+--------------------------------------------------+
```

Steps 3 and 4 are worth stating exactly, because this document described them
before the code did them (GitLab #863). `rename(2)` **replaces** its
destination atomically; the implementation removed the destination first and
then moved, which left a window in which the `.store` file did not exist at
all, and it never called `fsync`, so a crash could leave a file whose *name*
had been renamed into place and whose *contents* had not reached the disk.
Both are fixed. What the diagram promises is now what happens.

### 5a. Checkpoints

The permission bit decides *whether* a store is written. It says nothing about
*when*, and until GitLab #863 there was nothing between "on every mutation,
one second later" and "never".

```aro
Commit the <saved> to the <orders-repository>.   (* this store, now *)
Commit the <checkpoint> to the <stores>.         (* every writable store, together *)
```

`Commit` is the same verb ARO-0080 uses for Git, and deliberately: both are the
act of taking what is in memory and making it durable. The object says which —
`<git>` a repository of commits, a `*-repository` or `<stores>` the file behind
a seeded repository.

The statement binds a record:

| Field | Meaning |
|-------|---------|
| `repositories` | the names written, sorted |
| `written` | how many files were replaced |
| `items` | how many rows went to disk |

A `Commit` to a repository that no writable `.store` file backs is an error
naming the repository, not a silent success. Reporting a write that could not
have happened is the one outcome worth ruling out.

#### Write-back mode

```aro
Configure the <stores: write-back> with "manual".
```

| Mode | Behaviour |
|------|-----------|
| `auto` (default) | every mutation schedules a debounced write; shutdown flushes |
| `manual` | mutations mark the store dirty; only `Commit` — and shutdown — write |

`manual` is for the run that rewrites the same rows repeatedly: one write at
the end instead of one per second of churn. Shutdown still flushes in both
modes, because losing a run's work to a clean exit would be a worse default
than any amount of I/O.

#### What "all-or-nothing" means here, exactly

`Commit the <r> to the <stores>.` serialises every store and writes and fsyncs
every temp file **before** moving any of them into place. So:

- A failure while serialising or writing aborts the whole checkpoint and leaves
  every `.store` file untouched. The temp files are removed.
- No `.store` file is ever observed truncated or missing, in any scenario.
- The renames themselves are separate syscalls. **A crash between two of them
  can leave one store new and one store old.**

That last line is the honest limit, and the one this section exists to state.
Closing it needs a write-ahead journal and a recovery pass at startup — which
is a database, which is the thing a `.store` file exists in order not to be. An
application that needs two stores to move together as a matter of correctness
has outgrown `.store` files and wants a database plugin; ARO-0016 is the door.


### 6. Compiled Binaries

Writable stores persist in compiled binaries too, matching `aro run`. The
persistence target is the `.store` file that sits **next to the executable**
(the binary's own directory, resolved via
`ToolResolver.resolveExecutableDirectory`). At startup the runtime discovers
the `.store` files beside the binary — carrying their `isWritable` bit — seeds
the repositories, and, for every writable store, wires up the same
`StoreFlushService` write-back the interpreter uses (debounced atomic writes
during the run, plus a final flush on graceful shutdown / Ctrl-C).

```
$ aro build ./MyApp
Note: Writable store files persist changes to the .store file next to the binary.
  - config.store -> config-repository (writable, persisted next to the binary)
Hint: the .store file next to the binary must be writable by the running user;
      chmod o-w <file>.store for a read-only (seed-only) store.
```

Read-only stores are loaded into repositories at startup and never written
back, exactly as in interpreter mode. Writable stores require that the
`.store` file beside the binary be writable by the running user (its `o+w`
bit is preserved into the build output); on a read-only filesystem the store
simply falls back to seed-only behavior.

---

## Examples

### Example 1: Read-Only Seed Data

**products.store:**
```yaml
- id: 1
  name: Widget
  price: 9.99
  category: hardware

- id: 2
  name: Gadget
  price: 19.99
  category: electronics

- id: 3
  name: Doohickey
  price: 4.99
  category: hardware
```

**main.aro:**
```aro
(Application-Start: Product Catalog) {
    (* product-repository is already seeded from products.store *)
    Log "Product catalog loaded" to the <console>.
    Start the <http-server> with <contract>.
    Keepalive the <application> for the <events>.
    Return an <OK: status> for the <startup>.
}

(listProducts: Product API) {
    Retrieve the <products> from the <product-repository>.
    Return an <OK: status> with <products>.
}
```

No `Store` statements needed. The repository is ready before `Application-Start` runs.

### Example 2: Writable Configuration Store

```bash
$ chmod o+w config.store
```

**config.store:**
```yaml
- key: max-connections
  value: 100

- key: log-level
  value: info

- key: feature-flags
  value: "dark-mode,beta-search"
```

**main.aro:**
```aro
(Application-Start: Configurable App) {
    (* config-repository is seeded and writable *)
    Retrieve the <log-config> from the <config-repository> where key = "log-level".
    Log <log-config: value> to the <console>.

    Start the <http-server> with <contract>.
    Keepalive the <application> for the <events>.
    Return an <OK: status> for the <startup>.
}

(updateConfig: Config API) {
    Extract the <key> from the <pathParameters: key>.
    Extract the <body> from the <request: body>.
    Retrieve the <entry> from the <config-repository> where key = <key>.
    Update the <entry: value> with <body: value>.
    Store the <entry> into the <config-repository>.
    (* Write-back to config.store happens automatically after 1s debounce *)
    Return an <OK: status> with <entry>.
}
```

### Example 3: Multiple Store Files

```
OrderApp/
├── main.aro
├── openapi.yaml
├── customers.store      # read-only seed data
├── products.store       # read-only seed data
└── orders.store         # writable (chmod o+w)
```

Each `.store` file independently backs its repository. Read-only and writable stores can coexist.

---

## Detailed Design

### Discovery Rules

| Rule | Description |
|------|-------------|
| Location | Any `.store` file in the app directory or subdirectories |
| Naming | `<name>.store` maps to `<singular(name)>-repository` |
| Conflicts | Two files mapping to the same repository is a compile error |
| Empty files | Creates an empty repository (valid) |
| Invalid YAML | Reported as a startup error with file path and line number |
| Non-list YAML | Error: "Expected YAML list in <name>.store, got <type>" |

### Singularization Rules

The mapping from filename to repository name uses simple English singularization:

| Filename | Repository |
|----------|------------|
| `users.store` | `user-repository` |
| `products.store` | `product-repository` |
| `config.store` | `config-repository` |
| `order-items.store` | `order-item-repository` |
| `status.store` | `status-repository` |
| `addresses.store` | `addresse-repository` |

**Note:** Singularization only strips a trailing `s`. For irregular plurals, use the singular form directly (e.g., `person.store` instead of `people.store`).

### Interaction with Existing Repository Operations

| Operation | Read-Only Store | Writable Store | No Store |
|-----------|----------------|----------------|----------|
| `Retrieve` | Works (reads seeded data) | Works (reads current data) | Works (empty or imperatively stored) |
| `Store` | Works (in-memory only, no persist) | Works (persists to disk) | Works (in-memory only) |
| `Update` | Works (in-memory only, no persist) | Works (persists to disk) | Works (in-memory only) |
| `Delete` | Works (in-memory only, no persist) | Works (persists to disk) | Works (in-memory only) |
| Repository Observer | Fires normally | Fires normally | Fires normally |

**Important:** Even read-only stores allow in-memory mutations. "Read-only" means changes are not written back to disk -- the runtime does not block mutations.

### Crash Semantics

| Scenario | Data State |
|----------|------------|
| Clean shutdown (SIGINT/SIGTERM) | All pending writes flushed |
| SIGKILL / power loss | Last successful atomic write preserved; changes since it are lost |
| SIGKILL inside the debounce window | That window's changes are lost — use `Commit` (§5a) |
| Write-back I/O error | Error logged, retried on next change; original file intact |
| Disk full during write-back | `.tmp` file abandoned, original intact, error logged |
| Crash mid-`Commit`, before any rename | Every store unchanged |
| Crash mid-`Commit`, between renames | Some stores new, some old; none corrupt (§5a) |

### Debounce Behavior

```
Store action at T=0.0s  -->  schedule write at T=1.0s
Store action at T=0.3s  -->  reschedule write to T=1.3s
Store action at T=0.8s  -->  reschedule write to T=1.8s
(no more changes)
Write executes at T=1.8s
```

The 1-second debounce window prevents excessive disk I/O during burst writes. The debounce timer resets on each mutation.

---

## Impact on Existing Features

### No Syntax Changes

This proposal requires **zero changes** to ARO syntax. Store files are a runtime discovery mechanism, not a language feature. All existing `.aro` code continues to work unchanged.

### Backward Compatibility

| Scenario | Behavior |
|----------|----------|
| App with no `.store` files | Identical to current behavior |
| App with `.store` files and imperative `Store` | Both work; imperative stores add to/overwrite seeded data |
| Existing repositories | Unaffected unless a `.store` file matches their name |

### Files to Modify

**New files:**
- `Sources/ARORuntime/Core/StoreFileLoader.swift` -- Discovery, parsing, permission checking
- `Sources/ARORuntime/Core/StoreFileWriter.swift` -- Atomic write-back with debounce

**Modified files:**
- `Sources/ARORuntime/Application/Application.swift` -- Load `.store` files before `Application-Start`
- `Sources/ARORuntime/Core/RepositoryStorage.swift` -- Hook write-back on mutations for writable stores
- `Sources/ARORuntime/Bridge/RuntimeCoreBridge.swift` -- Compiled-binary runtime: discover `.store` files next to the executable, seed repositories, and wire `StoreFlushService` write-back for writable stores (flushed on shutdown)
- `Sources/AROCLI/Commands/BuildCommand.swift` -- Report that writable stores persist next to the binary (no longer downgraded to read-only)

---

## Alternatives Considered

### Alternative 1: YAML Header for Writability

```yaml
# mode: writable
- name: Alice
  role: admin
```

**Rejected because:**
- Requires parsing a comment as configuration (fragile)
- Easy to miss in code review
- Not visible from `ls -l`
- Invents a new convention when POSIX permissions already exist

### Alternative 2: Separate `.store.yaml` and `.store.writable.yaml` Extensions

**Rejected because:**
- Two extensions for the same concept adds confusion
- `.store` is already a clear, purpose-built extension
- File permissions are a more natural UNIX mechanism

### Alternative 3: Configuration in `aro.yaml`

```yaml
stores:
  users:
    file: users.yaml
    writable: true
```

**Rejected because:**
- Adds indirection (file references another file)
- Convention-over-configuration is simpler
- `aro.yaml` is for plugin configuration, not data management

### Alternative 4: Always Writable

**Rejected because:**
- Unexpected disk writes are dangerous
- Read-only should be the safe default

This list used to end with "compiled binaries cannot write back", which stopped
being true with GitLab #442 and contradicted §6 of this same document:
`RuntimeCoreBridge.swift:369` wires a `StoreFlushService` for every writable
store and `aro_runtime_shutdown` flushes it, on normal exit and on the
keepalive SIGINT path alike. The permission gate is what makes always-writable
the wrong default — not a limitation of the compiled path (GitLab #831).

---

## References

- [ARO-0007: Events and Reactive Systems](ARO-0007-events-reactive.md) -- Repository and observer model
- [ARO-0008: I/O Services](ARO-0008-io-services.md) -- File system operations
- [ARO-0036: Extended File Operations](ARO-0036-file-operations.md) -- File permission model
- [YAML Specification](https://yaml.org/spec/1.2.2/)
- [POSIX File Permissions](https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/sys_stat.h.html)
