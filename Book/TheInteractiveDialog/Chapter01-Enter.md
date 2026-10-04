# Chapter 1: Enter

*"The prompt is patient. It waits for you to speak."*

---

## The Beginning

Every conversation begins with a greeting. With ARO, that greeting is a single command:

```bash
$ aro repl
```

Two lines appear, then a prompt:

```
ARO REPL v@ARO_VERSION@
Type :help or /help for commands, :quit to exit

aro> _
```

You are now in dialog with ARO. The cursor blinks. The machine listens.

This is the REPL—the Read-Eval-Print Loop. It reads what you type, evaluates it, prints the result, and loops back for more. Simple. Immediate. Conversational.

## The Prompt

The `aro>` prompt is your invitation to speak. Everything you type after it becomes a statement to ARO. Every statement gets a response.

Try typing `:help`. The full text is longer than this page; here is its spine:

```
aro> :help
ARO REPL Commands (use : or / prefix):

Session:
  :help, :h, :?           Show this help message
  :vars, :v               List all session variables
  :vars <name>            Show details of a specific variable
  :type <name>, :t        Show the type of a variable
  :clear, :c              Clear all session state
  :history, :hist         Show input history
  :history <n>            Show last n entries

Feature Sets:
  :fs                     List defined feature sets
  :invoke <name>, :i      Invoke a feature set
  :invoke <name> <json>   Invoke with input data

Data:
  :set <name> <value>     Set a variable to a value
  :load <file>            Load and execute a .aro file
  :export, :e             Print session as .aro code
  :export <file>          Save session to file
  :export --test <file>   Export as test file

Plugins:
  :plugin add <git-url>   Install and load a plugin from Git
  ...

Control:
  :quit, :q, :exit        Exit the REPL
```

Commands that start with `:` talk to the REPL itself. Everything else is ARO.

The worked examples in that help text are copy-and-paste ready, and they write
the verb bare — `Set the <x> to 42.` — which is the only spelling the language
accepts. Angle brackets mark the result and the object, never the action.

## Standing Inside a Project

A bare session knows the language and nothing about where you are. Hand it a project directory and it knows that too:

```bash
$ aro repl ./MyApp
Project: MyApp
  contract: 3 path(s) from openapi.yaml
  stores: 12 row(s) in 2 repositories
  templates: templates/
  feature sets: 7 from 3 file(s)
  lifecycle: 1 Application-Start/End not run
```

Those five lines are the whole difference, and each is something a cell can now do. The contract is registered, so routes and status names behave as they do under `aro run`. The `.store` seed rows are already in the repositories you `Retrieve` from. `templates/` is where `Transform the <page> from the <template: hi.tpl>.` looks. The project's plugins are loaded, so its own actions and qualifiers resolve. And its feature sets are added, so `Application.<Name>` calls work.

Read the last line again, because it is a decision rather than a limitation: **`Application-Start` is found and not run.** A session is a place to try statements against an application, not a process that boots one. A REPL that bound a port and started a file watcher because you opened it would be a surprise you had to undo, and the count is printed so you can see the choice being made rather than wonder whether it happened.

If something in the project is broken, you still get the rest. A malformed `openapi.yaml` is one warning line; the templates still load. That matters because a session is often where you go to find out *why* something is broken, and a tool that refuses to start on a broken project cannot be that.

`aro kernel --project ./MyApp` does the same for a notebook front-end.

## Leaving

When the conversation ends, you have two ways to depart:

```
aro> :quit
Goodbye!
```

Or simply press `Ctrl+D` on an empty line. The REPL closes, and you return to your shell.

But don't leave yet. We've only just begun.

## A One-Liner Path In

Sometimes you don't want a session—just an answer. When `aro` is invoked with no arguments and stdin is piped from another command or file, it reads the source, evaluates it through the same REPL session, and exits. No prompt, no banner, no feature-set prefix on Log output.

```bash
$ echo 'Log "Hello World" to the <console>.' | aro
Hello World
```

Multi-line input works the same way and shares one evaluation context, so variables flow from one statement to the next:

```bash
$ aro <<'ARO'
Compute the <x> from 21.
Compute the <doubled> from <x> * 2.
Log <doubled> to the <console>.
ARO
42
```

This is the REPL with the lights off. Useful for quick experiments, shell pipelines, and editor "send selection to ARO" integrations.

---

**Next: Chapter 2 — Speak**
