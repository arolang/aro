# Chapter 6: Extend

*"The REPL is not isolated. It can reach the world."*

---

## Beyond the Prompt

The REPL isn't just for local calculations. It reaches:

- The event bus, with handlers you define at the prompt
- Git, with no setup
- Plugins, installed from a Git URL mid-session
- Files, sockets and HTTP, through ordinary ARO statements

There are no `:service` meta-commands. Services start the way they start in a
program — with a statement — because the prompt runs the same runtime.

## Events, and handlers that answer them

Define a handler, emit its event, watch it fire:

```
aro> (Greet: UserCreated Handler) {
Defining feature set: Greet
(Greet)> Extract the <name> from the <event: name>.
  +
(Greet)> Log "welcome ${<name>}" to the <console>.
  +
(Greet)> Return an <OK: status> for the <greeting>.
  +
(Greet)> }
Feature set 'Greet' defined

aro> Emit a <UserCreated: event> with { name: "Ada" }.
welcome Ada
=> OK
```

The `[Greet]` prefix is the handler naming itself — this is the clearest way to
see the event bus working, because the log line comes from a different feature
set than the one you typed into.

`${<name>}` interpolates a binding into a string literal. It works anywhere a
string does.

**What a definition will do, the prompt tells you.** Whatever you can trigger
with a statement, the session dispatches — `{EventName} Handler` on `Emit`,
`{repository} Observer` on a `Store`, `StateTransition Handler` on an `Accept`,
`NotificationSent Handler` on a `Notify`, and `File Event Handler` on a change
under a directory you are watching. The prompt says which:

```
aro> (Report Drop: File Event Handler) {
(Report Drop)>     Extract the <dropped> from the <event: path>.
(Report Drop)>     Log "arrived: ${dropped}" to the <console>.
(Report Drop)>     Return an <OK: status> for the <ingestion>.
(Report Drop)> }
Feature set 'Report Drop' defined
  fires on changes under a path this session watches — Start the <file-monitor> first
```

Start the monitor and the handler runs on the next change:

```
aro> Start the <file-monitor> with "./data".
=> OK
arrived: ./data/notes.txt
```

The families a session *cannot* deliver say so instead of pretending. A
`Socket Event Handler`, a `WebSocket Event Handler` or a `KeyPress Handler`
needs a TCP server, an HTTP contract or a raw keyboard — none of which belongs
to a session — so the prompt keeps the definition and names what will not
happen:

```
aro> (Echo Input: Socket Event Handler) {
...
Feature set 'Echo Input' defined
  this session delivers no socket events — nothing in a session starts a TCP
  server; put it in an application and `aro run` it
```

That line is the whole difference between a handler that is waiting and a
handler that is dead. Copy the definition into a directory and `aro run` it,
unchanged.

A key press is unsolicited, which is why that family needs a terminal. *Asking*
for an answer is a different thing, and it works everywhere:

```
aro> Prompt the <name> with "Your name: ".
Your name: Ada Lovelace
=> OK
```

At this prompt the keyboard answers directly. In a notebook the question goes
to the front-end, which asks its own user and sends the answer back — the same
statement, a different answerer (ARO-0091 §Interactive input). Where *nobody*
can answer — a cell run with input disabled, a piped script — the statement
fails and says so, because a prompt waiting on an answer that will never come
is indistinguishable from a program thinking hard.

## Git

`<git>` is available without setup. `Retrieve` reads state; `Stage`, `Commit`
and `Push` change it:

```
aro> Retrieve the <status> from the <git>.
=> OK

aro> Extract the <branch> from the <status: branch>.
=> OK

aro> Log "On branch: ${<branch>}" to the <console>.
[_repl_session_] On branch: main
=> OK
```

Each git action emits an event (`git.commit`, `git.push`, …), and a
`git.commit Handler` defined in the same session will receive it.

## Installing Plugins from Git

Plugins extend ARO with new actions. Install them directly from Git:

```
aro> /plugin add git@github.com:arolang/plugin-rust-csv.git
Plugin 'plugin-rust-csv' v1.0.0 installed and loaded (commit: 7b2e4f1)
  [+] Rust plugin built
Actions: ParseCSV, FormatCSV
```

If the plugin ships qualifiers as well as actions, a `Qualifiers:` line follows,
listing them under the handle you will use to call them.

Install a specific version:

```
aro> /plugin add git@github.com:arolang/plugin-swift-hello.git --ref v2.0.0
Plugin 'plugin-swift-hello' v2.0.0 installed and loaded (commit: a3f9c21)
  [+] Swift sources ready
Actions: Greet
```

Now use them:

```
aro> Greet the <message> with "World".
=> OK
```

New verbs. New capabilities. Same syntax.

The plugin is cloned, built, and loaded in one step. REPL plugins are stored in
`~/.aro/repl-plugins/` and persist across sessions — set `ARO_REPL_PLUGINS_DIR`
to put them somewhere else.

## Listing Plugins

```
aro> /plugin list
Name               | Version | Handle | Status
------------------ | ------- | ------ | -------
plugin-rust-csv    | 1.0.0   | CSV    | loaded
plugin-swift-hello | 2.0.0   | Hello  | loaded
```

## Updating and Removing Plugins

```
aro> /plugin update plugin-rust-csv
Plugin 'plugin-rust-csv' updated: v1.0.0 -> v1.1.0 (commit: 7b2e4f1 -> 9c1d0a4)
  [+] Rust plugin built
```

`--ref <ref>` pins the update to a tag or commit instead of taking the latest.
If there is nothing new, it says so and does not rebuild.

```
aro> /plugin remove plugin-swift-hello
Plugin 'plugin-swift-hello' removed
```

The actions disappear, and the plugin is deleted from disk as well as unloaded,
so a later `/plugin add` of the same URL starts clean. The session continues.

## A Note on Reusable Logic

A feature set whose business activity is `Action` is callable as
`Application.<Name>` (ARO-0081), and that holds at the prompt as much as in a
compiled application:

```
aro> (Doubled: Action takes <number>) {
(Doubled)>     Extract the <n> from the <input: number>.
(Doubled)>     Compute the <out> from <n> * 2.
(Doubled)>     Return an <OK: status> with { value: <out> }.
(Doubled)> }
Feature set 'Doubled' defined
aro> Application.Doubled the <r> from 21.
=> OK
aro> Extract the <v> from the <r: value>.
=> OK
aro> Log "doubled: ${<v>}" to the <console>.
[_repl_session_] doubled: 42
=> OK
```

Every definition in the session is compiled alongside the statement that calls
it, which is what makes this work — a statement on its own is a program of
one, and `Application.<Name>` resolves against the program it is given. So an
action can call a sibling action defined earlier, and redefining one is what
the next call reaches. Earlier editions of this chapter said the call site
answered `Unknown user-defined action` and told you to reach for `:invoke`
instead; that was true until GitLab #576.

`:invoke` still has its place for running a definition once without writing a
call, and its JSON object now arrives as `input` — so `:invoke Doubled
{"number": 21}` runs an action written for a file unchanged, rather than
needing its `Extract`s rewritten.

## The Coding Assistant

For longer or more exploratory work, exit the REPL and run `aro ask` — a project-aware coding assistant with tool calling:

```
aro> :q
$ aro ask "show me how to extract a path parameter from an HTTP request"
```

---

**Next: Chapter 7 — Depart**
