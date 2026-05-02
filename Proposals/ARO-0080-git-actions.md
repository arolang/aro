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

* **No qualifier** — current working directory (pwd)
* **String qualifier** — explicit path: `<git: "/path/to/repo">`

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
