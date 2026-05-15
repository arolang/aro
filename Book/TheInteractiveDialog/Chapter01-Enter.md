# Chapter 1: Enter

*"The prompt is patient. It waits for you to speak."*

---

## The Beginning

Every conversation begins with a greeting. With ARO, that greeting is a single command:

```bash
$ aro repl
```

The screen clears. A message appears:

```
ARO REPL v1.0
Type :help for commands, :quit to exit

aro> _
```

You are now in dialog with ARO. The cursor blinks. The machine listens.

This is the REPL—the Read-Eval-Print Loop. It reads what you type, evaluates it, prints the result, and loops back for more. Simple. Immediate. Conversational.

## The Prompt

The `aro>` prompt is your invitation to speak. Everything you type after it becomes a statement to ARO. Every statement gets a response.

Try typing `:help`:

```
aro> :help
ARO REPL Commands:

  :help, :h, :?         Show this help message
  :vars                 List all variables
  :clear                Clear session state
  :history              Show input history
  :export               Export session as .aro file
  :quit, :q, :exit      Exit the REPL

Type ARO statements directly, ending with .
Example: Set the <x> to 42.
```

Commands that start with `:` talk to the REPL itself. Everything else is ARO.

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
