# ARO-0080: Git Actions

* Proposal: ARO-0080
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0004, ARO-0008

## Abstract

Native Git actions for ARO, enabling applications to interact with Git
repositories directly from ARO code using libgit2.

## System Object: `git`

The `<git>` system object represents a Git repository.

* **No qualifier** — the enclosing repository, discovered by walking upward
  from the current working directory (libgit2 repository discovery), exactly
  like the `git` CLI. Running from any subdirectory of a work tree finds the
  repository root; linked worktrees (where `.git` is a file) are handled.
  When no repository encloses the working directory, the action fails with
  `Not a Git repository: <cwd>`.
* **String qualifier** — explicit path: `<git: "/path/to/repo">`. An explicit
  path (including `<git: ".">`) is opened as given — no upward discovery.

```
+-------------------+
|  git              |  Bidirectional
|  - status         |  Source (Retrieve)
|  - log            |  Source (Retrieve)
|  - branch         |  Source (Retrieve)
|  - commit         |  Sink (Commit)
|  - stage          |  Sink (Stage)
|  - push           |  Sink (Push)
|  - pull           |  Source (Pull)
+-------------------+
```

## Actions

| Verb       | Role    | Prepositions | Description                       |
|------------|---------|--------------|-----------------------------------|
| Retrieve   | REQUEST | from         | Status, log, branch from `<git>`  |
| Stage      | OWN     | to, for      | Stage files for commit            |
| Commit     | EXPORT  | to, with     | Create a commit                   |
| Pull       | REQUEST | from         | Fetch and merge remote changes    |
| Push       | EXPORT  | to, with     | Push commits to remote            |
| Clone      | REQUEST | from, with   | Clone a remote repository         |
| Checkout   | OWN     | from, to     | Switch branches                   |
| Tag        | EXPORT  | for, with    | Create a tag                      |

## Syntax

### Retrieve result names

`Retrieve … from the <git>` selects **what** to retrieve from the result
name: `log` (alias `history`) retrieves the commit log, `branch` the current
branch name, and anything else the full status. To use a different variable
name, put the subcommand in the qualifier position (qualifier-as-name):

```aro
Retrieve the <log> from the <git>.              (* commit log *)
Retrieve the <recent: log> from the <git>.      (* commit log, named <recent> *)
Retrieve the <branch> from the <git>.           (* current branch *)
Retrieve the <status> from the <git>.           (* full status *)
Retrieve the <state> from the <git>.            (* also full status — the default *)
```

### Status

```aro
Retrieve the <status> from the <git>.
Extract the <branch> from the <status: branch>.
Extract the <is-clean> from the <status: clean>.
Extract the <files> from the <status: files>.
```

### Log

```aro
Retrieve the <log> from the <git>.
For each <entry> in <log> {
    Extract the <hash> from the <entry: short>.
    Extract the <msg> from the <entry: message>.
    Log "${hash} ${msg}" to the <console>.
}
```

### Stage and Commit

```aro
Stage the <files> to the <git> with ".".
Commit the <result> to the <git> with "feat: add feature".
```

### Push / Pull

```aro
Pull the <updates> from the <git>.
Push the <result> to the <git>.
```

### Clone

```aro
Clone the <repo> from the <git> with {
    url: "https://github.com/user/repo.git",
    path: "./cloned"
}.
```

The optional `branch:` key checks out a specific branch at clone time
instead of the remote's default. Equivalent to `git clone --branch <name>`:

```aro
Clone the <repo> from the <git> with {
    url: "https://github.com/user/repo.git",
    path: "./cloned",
    branch: "develop"
}.
```

### Checkout / Tag

```aro
Checkout the <branch> from the <git> with "feature/new".
Tag the <release> for the <git> with "v1.0.0".
```

## Events

Each mutating action emits an event. Write a handler feature set against the
**handler name**; the routing name is the internal one and is not spellable as
a business activity, because a dot there is a parse error.

| Handler name  | Routing name   | Triggered By | Payload               |
|---------------|----------------|--------------|-----------------------|
| `GitCommit`   | `git.commit`   | Commit       | hash, message, author |
| `GitPush`     | `git.push`     | Push         | branch                |
| `GitPull`     | `git.pull`     | Pull         | branch                |
| `GitCheckout` | `git.checkout` | Checkout     | ref                   |
| `GitTag`      | `git.tag`      | Tag          | name                  |
| `GitClone`    | `git.clone`    | Clone        | url, path             |

```aro
(Notify Commit: GitCommit Handler) {
    Extract the <message> from the <event: message>.
    Extract the <hash> from the <event: hash>.
    Log "committed ${<hash>}: ${<message>}" to the <console>.
    Return an <OK: status> for the <notification>.
}
```

Until GitLab #588 none of the six was observable: handler registration
subscribes on the Swift type `DomainEvent`, which is what `Emit` produces, and
the typed Git events are not `DomainEvent`s — so this table described six
events with payloads that nothing could consume. Each action now emits a
`DomainEvent` alongside its typed event, so the handler names above work and
the typed events remain for Swift-side subscribers.

## Implementation

* **GitService** (`Sources/ARORuntime/Git/GitService.swift`) — libgit2 wrapper
* **GitEvents** (`Sources/ARORuntime/Git/GitEvents.swift`) — event types
* **GitActions** (`Sources/ARORuntime/Actions/BuiltIn/GitActions.swift`) — action implementations
* **GitActionsModule** (`Sources/ARORuntime/Actions/Modules/GitActionsModule.swift`) — registration
* **RetrieveAction** extended to handle `<git>` as a source object

Push and Pull shell out to `git` CLI because libgit2 push/pull requires
complex credential callback setup. All other operations use libgit2 directly.

## Backwards Compatibility

Purely additive. No existing actions or syntax are modified.
