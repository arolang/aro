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
| Graceful shutdown (SIGINT/SIGTERM) | Flush all pending writes immediately |
| Crash / SIGKILL | Pending changes lost (last successful write preserved) |

**Atomic writes:** Write-back always uses a write-to-temporary-then-rename strategy to prevent corruption:

```
┌──────────────────────────────────────────────────┐
│              ATOMIC WRITE-BACK                    │
│                                                    │
│   1. Serialize repository to YAML                 │
│   2. Write to  <name>.store.tmp                   │
│   3. fsync     <name>.store.tmp                   │
│   4. Rename    <name>.store.tmp -> <name>.store   │
│                                                    │
│   If step 2 or 3 fails: .tmp is abandoned         │
│   Original .store file is never corrupted         │
└──────────────────────────────────────────────────┘
```

### 6. Compiled Binary Restrictions

When using `aro build` to produce a native binary, writable stores are rejected at build time:

```
$ aro build ./MyApp
Error: config.store has other-write permission set.
       Writable stores are not supported in compiled binaries
       because the binary cannot write back to bundled data.

       Fix: chmod o-w config.store
       Or:  remove config.store and seed via Application-Start
```

Read-only stores are embedded in the binary as bundled resources and loaded into repositories at startup, just as they would be in interpreter mode.

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
| SIGKILL / power loss | Last successful atomic write preserved |
| Write-back I/O error | Error logged, retried on next change; original file intact |
| Disk full during write-back | `.tmp` file abandoned, original intact, error logged |

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
- `Sources/AROCompiler/Linker.swift` -- Bundle read-only stores; reject writable stores

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
- Compiled binaries cannot write back

---

## References

- [ARO-0007: Events and Reactive Systems](ARO-0007-events-reactive.md) -- Repository and observer model
- [ARO-0008: I/O Services](ARO-0008-io-services.md) -- File system operations
- [ARO-0036: Extended File Operations](ARO-0036-file-operations.md) -- File permission model
- [YAML Specification](https://yaml.org/spec/1.2.2/)
- [POSIX File Permissions](https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/sys_stat.h.html)
