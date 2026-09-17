# Chapter 48: Git Actions

ARO has native Git support through the `<git>` system object and a small set of dedicated actions. Operations run against a real repository via `libgit2`, so there is no shelling out for status, log, branch, stage, commit, clone, checkout, or tag. Push and pull use the `git` CLI under the hood because they need credential handling that `libgit2` does not provide out of the box.

Native Git unlocks the same kind of business logic you'd otherwise script with shell:

- Continuous-integration helpers that read status, stage changed files, and commit on a schedule
- Release tools that tag a build and push it
- Audit jobs that walk the commit log and emit events
- Bots that clone a repository, run a check, and report

The Git actions are introduced in [ARO-0080](../../Proposals/ARO-0080-git-actions.md). Today, all Git actions are available on macOS and Linux. Windows builds skip the module.

## The `<git>` System Object

`<git>` represents a Git repository. With no qualifier, it **discovers the enclosing repository** by walking upward from the current working directory — exactly like the `git` CLI, so it works from any subdirectory of a work tree (linked worktrees included):

```aro
Retrieve the <status> from the <git>.
```

To target a different repository, pass a path as a string qualifier. An explicit path is opened as given — no upward discovery:

```aro
Retrieve the <status> from the <git: "/srv/projects/my-repo">.
```

The same syntax works for every Git action — the `<git>` object is the source for `Retrieve`, `Pull`, `Clone`, `Checkout`, and the sink for `Stage`, `Commit`, `Push`, `Tag`.

## Reading Repository State

`Retrieve` is the REQUEST action for Git. The result name selects what to read:

| Result name | Returns |
|-------------|---------|
| `<status>`  | Current branch + working-tree state |
| `<log>`     | Commit history (most recent first) |
| `<branch>`  | Name of the current branch |

### Status

```aro
Retrieve the <status> from the <git>.
Extract the <branch> from the <status: branch>.
Extract the <clean> from the <status: clean>.
Extract the <files> from the <status: files>.

Log "On branch ${branch}" to the <console>.
for each <change> in <files> {
    Extract the <path> from the <change: path>.
    Extract the <state> from the <change: status>.
    Log "${state} ${path}" to the <console>.
}
```

The `status` object exposes:

| Field        | Type    | Description                                    |
|--------------|---------|------------------------------------------------|
| `branch`     | String  | Current branch name (or commit ref if detached) |
| `clean`      | Boolean | `true` when the working tree is clean          |
| `files`      | List    | Per-file status entries                        |

### Log

```aro
Retrieve the <log> from the <git>.
for each <entry> in <log> {
    Extract the <hash>    from the <entry: short>.
    Extract the <message> from the <entry: message>.
    Extract the <author>  from the <entry: author>.
    Log "${hash} ${message} (${author})" to the <console>.
}
```

Each log entry exposes `short`, `hash`, `message`, `author`, `email`, and `timestamp`.

### Branch

```aro
Retrieve the <branch> from the <git>.
Log "Current branch: ${branch}" to the <console>.
```

## Staging and Committing

`Stage` and `Commit` work as a pair:

```aro
Stage  the <files>  to the <git> with ".".                (* OWN — preposition: to, for *)
Commit the <result> to the <git> with "feat: add feature". (* EXPORT — preposition: to, with *)
```

The `with` clause for `Stage` accepts:

- `"."` — stage everything (matches `git add .`)
- A path string: `"src/main.aro"`
- A list of paths: `["a.txt", "b.txt"]`

`Commit` returns a commit object containing `hash`, `short`, `message`, and `author`. It also emits a `GitCommit` event.

## Push, Pull, Clone

```aro
(* Pull from origin *)
Pull the <updates> from the <git>.

(* Push the current branch *)
Push the <result> to the <git>.

(* Clone a remote repository *)
Clone the <repo> from the <git> with {
    url: "https://github.com/user/repo.git",
    path: "./cloned"
}.
```

`Push`, `Pull`, and `Clone` shell out to the `git` CLI. Make sure `git` is on `$PATH` and that the user running ARO has the credentials it needs (SSH key, credential helper, or token).

`Clone` accepts an extra `branch` field if you only want a specific ref:

```aro
Clone the <repo> from the <git> with {
    url: "https://github.com/user/repo.git",
    path: "./cloned",
    branch: "main"
}.
```

## Branches and Tags

```aro
(* Switch branches (creates the branch if it doesn't exist locally) *)
Checkout the <branch> from the <git> with "feature/new".

(* Tag the current commit *)
Tag the <release> for the <git> with "v1.0.0".

(* Annotated tag with message *)
Tag the <release> for the <git> with {
    name: "v1.0.0",
    message: "First stable release"
}.
```

## Action Summary

| Verb       | Role    | Prepositions | Notes |
|------------|---------|--------------|-------|
| `Retrieve` | REQUEST | `from`       | `<status>`, `<log>`, `<branch>` |
| `Stage`    | OWN     | `to`, `for`  | `with` accepts `"."`, path, or list |
| `Commit`   | EXPORT  | `to`, `with` | Emits `GitCommit`                |
| `Pull`     | REQUEST | `from`       | Shells out; emits `GitPull`      |
| `Push`     | EXPORT  | `to`, `with` | Shells out; emits `GitPush`      |
| `Clone`    | REQUEST | `from`, `with` | Shells out; emits `GitClone`   |
| `Checkout` | OWN     | `from`, `to`, `with` | Emits `GitCheckout`      |
| `Tag`      | EXPORT  | `for`, `with` | Emits `GitTag`                   |

## Git Events

Every mutating Git action emits an event, and a feature set subscribes to it the way it subscribes to any other — by naming it as its business activity. The read-only actions (`Retrieve` for status, log and branch) emit nothing; there is no state change to announce.

| Event           | Trigger     | Payload                       |
|-----------------|-------------|-------------------------------|
| `GitCommit`     | `Commit`    | `hash`, `message`, `author`   |
| `GitPush`       | `Push`      | `branch`                      |
| `GitPull`       | `Pull`      | `branch`                      |
| `GitCheckout`   | `Checkout`  | `ref`                         |
| `GitTag`        | `Tag`       | `name`                        |
| `GitClone`      | `Clone`     | `url`, `path`                 |

```aro
(Notify Release: GitTag Handler) {
    Extract the <name> from the <event: name>.
    Compute the <note> from "Released " ++ <name>.
    Send the <note> to the <slack-channel> with { channel: "#releases" }.
    Return an <OK: status> for the <notification>.
}
```

**The name in the left column is the only spelling.** `aro actions` and the
action reference also show an internal event type for each of these —
`git.tag`, `git.commit` and so on — but a dot cannot appear in a business
activity, so those are not handler names. Neither is the Swift type:
`GitTagEvent`, `Tag` and `gittag` all name nothing. A handler whose activity
matches no event is not an error; it simply never runs, so the symptom is
silence rather than a message.

**The payload is the fields in the table and nothing else.** A `GitCommit`
handler can read `<event: hash>`, `<event: message>` and `<event: author>`;
there is no commit object hiding behind the event. If a handler needs more
than the event carries — a diff, a file list — it reads the repository itself
with `Retrieve`.

## Worked Example

The bundled `Examples/GitDemo` walks through a typical session — read the current branch, walk the log, and print a one-line summary of each commit. Run it from inside any Git repository:

```sh
aro run ./Examples/GitDemo
```

## When to Reach for `Exec` Instead

The native actions cover the most common operations. If you need something they don't expose — `git bisect`, `git rebase`, custom plumbing — drop down to `Exec`:

```aro
Exec the <result> for the <command: "git"> with ["bisect", "start"].
```

Use `Exec` only when the native action set really doesn't fit; native actions are typed, emit events, and don't depend on the `git` binary for read-only operations.

---

*Next: Chapter 49 — The Local Coding Assistant*
