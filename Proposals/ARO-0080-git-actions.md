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

| Event           | Triggered By | Payload             |
|-----------------|-------------|---------------------|
| `git.commit`    | Commit      | hash, message, author |
| `git.push`      | Push        | branch              |
| `git.pull`      | Pull        | branch              |
| `git.checkout`  | Checkout    | ref                 |
| `git.tag`       | Tag         | name                |
| `git.clone`     | Clone       | url, path           |

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
