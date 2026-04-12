# Chapter 7: Tool Calling

> "A model that can only talk is a lecturer. A model that can read, write, and run is a colleague."

---

## 7.1 The Eighteen Tools

When you type `/tools` in the REPL, you see a list. It looks something like this:

```
Built-in tools:
  read_file         Read a file from the project
  write_file        Write content to a file
  edit_file         Apply a targeted edit to a file
  list_dir          List files and directories
  grep              Search file contents by pattern
  search_project    Semantic search over the project index
  run_shell         Execute a shell command (requires approval)
  parse_aro         Parse ARO source and return diagnostics
  aro_check         Run aro check on a directory
  aro_run           Run aro run on a directory
  aro_test          Run aro test on a directory
  read_proposal     Read an ARO proposal by number
  create_plugin     Scaffold a plugin directory
  write_openapi     Write or update an openapi.yaml file
  write_plugin_yaml Write a plugin.yaml manifest
  explain_error     Explain an ARO diagnostic in plain English
  format_aro        Format ARO source to canonical style
  list_actions      List available ARO actions and their verbs
```

Eighteen tools. Some read. Some write. Some run code. Together they turn the model from something that generates text into something that modifies your project. That distinction matters more than anything else in this book.

A model without tools can suggest a fix. A model with tools can *apply* the fix, check that it compiles, and tell you whether it worked. The difference is the difference between a code review and a pull request.

## 7.2 How the Loop Works

Every conversation with `aro ask` follows the same loop. It is simple enough to fit in a paragraph.

You send a message. The model reads it and decides what to do. If the answer is obvious, it replies with text. If the answer requires information the model does not have, it generates a *tool call* — a structured request to one of the eighteen tools. `aro ask` executes the tool call, captures the result, and feeds it back to the model. The model reads the result and decides again: reply, or call another tool. This continues until the model has enough information to answer, or until it has made the changes you asked for.

A typical exchange looks like this under the hood:

```
User:     "fix the parser error in users.aro"
Model:    [tool_call: aro_check {"path": "."}]
Runtime:  "users.aro:4: error: unknown verb 'Retreive' — did you mean 'Retrieve'?"
Model:    [tool_call: read_file {"path": "users.aro"}]
Runtime:  (file contents)
Model:    [tool_call: edit_file {"path": "users.aro", "old": "Retreive", "new": "Retrieve"}]
Runtime:  "ok"
Model:    [tool_call: aro_check {"path": "."}]
Runtime:  "all checks passed"
Model:    "Fixed the typo in users.aro line 4: 'Retreive' → 'Retrieve'. Check passes now."
```

Five tool calls. No human intervention between them. The model read the error, found the file, fixed the typo, and verified the fix. This is the tool-call loop at its most routine, and it is the kind of work that `aro ask` does dozens of times a day if you let it.

## 7.3 The Shape of a Tool Call

A tool call is not a free-form shell command. It is a structured JSON object with a name and parameters. The model cannot call a tool that does not exist. It cannot pass parameters the tool does not accept. The schema of every tool is baked into the system prompt, and the fine-tune was trained to produce calls that match the schema.

This is a deliberate constraint. An unconstrained model that could run arbitrary code would be powerful and terrifying. A constrained model that can only call eighteen well-defined tools is powerful and predictable. You know, at any point, exactly what the model *could* do, because the list of tools is right there in `/tools`.

The constraint also means the model cannot surprise you with tools you did not know about — unless you bridge an MCP server that adds new ones, in which case you chose to add them, and `/tools` will show you what they are.

## 7.4 Approval and Trust

Not all tools are created equal. `read_file` is harmless — it reads a file and returns its contents. `run_shell` is not harmless — it executes an arbitrary shell command. `aro ask` knows the difference.

Tools are classified into three tiers:

- **Read-only tools** (`read_file`, `list_dir`, `grep`, `search_project`, `read_proposal`, `list_actions`, `explain_error`): these run without asking. The model can read your project freely. This is by design — a model that has to ask permission to read a file is too slow to be useful.
- **Write tools** (`write_file`, `edit_file`, `write_openapi`, `write_plugin_yaml`, `create_plugin`, `format_aro`): these run without asking in REPL mode, but every change is printed to the terminal so you can see what happened. In one-shot mode with `--yes`, they run silently. Without `--yes`, one-shot mode prints the change and asks for confirmation.
- **Execution tools** (`run_shell`, `aro_run`, `aro_check`, `aro_test`, `parse_aro`): `aro_check`, `aro_test`, and `parse_aro` are considered safe and run without asking, because they do not modify anything. `aro_run` and `run_shell` always ask for approval unless `--yes` is set.

The dividing line is simple: tools that cannot change your project or execute arbitrary code run freely. Tools that can change files print what they did. Tools that can run your code ask first. If you want to move the line — make everything auto-approved — use `--yes`. If you want to move it the other way, there is no flag for that, because the default is already cautious.

## 7.5 Chaining: Read, Edit, Check

The most common tool-call pattern is the three-step chain: read a file, edit it, and check the result. You will see this pattern over and over, and it is worth understanding why it works so well.

The model does not edit files blind. It reads first. This matters because the edit tool uses exact string matching — the model provides the old text and the new text, and the tool replaces one with the other. If the model has not read the file, it cannot know what the old text looks like, and the edit will fail. The fine-tune learned this the hard way during training, and now it almost always reads before editing.

After the edit, the model calls `aro_check` or `parse_aro` to verify that the change did not break anything. If the check fails, it reads the new diagnostic, edits again, and checks again. This loop — edit, check, edit, check — runs until the check passes or the model decides it cannot fix the problem and asks you for help.

The pattern generalises. For creating a new file:

```
write_openapi → write_file (main.aro) → aro_check → edit_file (fix) → aro_check
```

For adding a feature to an existing application:

```
list_dir → read_file (openapi.yaml) → read_file (main.aro) → write_file (new.aro) → aro_check
```

For debugging a runtime error:

```
aro_run → read error → read_file → edit_file → aro_run → confirm fix
```

Every chain follows the same rhythm: gather information, make a change, verify the change. If you watch the tool calls scroll by in the terminal, you will start to see the rhythm, and you will start to trust it — or to interrupt it when something looks wrong.

## 7.6 Creating a Project from Scratch

Here is what happens when you ask `aro ask` to build something from nothing. Say you type:

```
"create an ARO application called HealthCheck with a single GET /health endpoint that returns OK"
```

The model will typically make these calls, in this order:

1. `list_dir` on the current directory to see what exists.
2. `write_openapi` to create `HealthCheck/openapi.yaml` with a single path.
3. `write_file` to create `HealthCheck/main.aro` with `Application-Start` and the `healthCheck` feature set.
4. `aro_check` on `HealthCheck/` to verify everything parses.
5. If the check fails, `read_file` and `edit_file` to fix whatever it got wrong.
6. A final `aro_check` to confirm.

The result is a directory you can immediately run with `aro run ./HealthCheck`. Two files, both correct, both checked. The model did not guess at the directory structure or the OpenAPI format — it used dedicated tools that know the conventions.

## 7.7 The Limits of Tools

Tools make the model useful. They do not make the model infallible.

The model can call the wrong tool. It occasionally calls `write_file` when it should call `edit_file`, overwriting content it meant to preserve. It sometimes runs `aro_check` on the wrong directory. It sometimes calls `run_shell` with a command that makes sense on Linux but not on macOS, or the other way around.

The model can also get stuck in a loop. If a check keeps failing and the model keeps making the same edit, it will cycle until the tool-call limit is reached (25 rounds by default). When this happens, the model gives up and reports what it tried. This is the right behaviour — an infinite loop of bad edits would be worse — but it means you sometimes have to step in and fix the problem yourself.

The defence against both failure modes is the same: watch the tool calls. They are printed to the terminal as they happen. If you see the model heading in the wrong direction, press Ctrl+C. The conversation is saved, and you can steer it back on course with your next message.

## 7.8 Tips for Better Tool Usage

A few patterns reliably get better results from the tool-call loop.

**Be specific about paths.** "Fix the error in users.aro" is better than "fix the error". The model will find the file either way, but the specific prompt saves a `list_dir` and a `grep`, which saves time and context window.

**Ask for verification.** "Write the feature set and run aro check" is better than "write the feature set". The model often checks on its own, but explicitly asking makes it reliable.

**One task per conversation.** The model is better at tool-calling when the goal is clear. "Add a deleteUser endpoint" is one task. "Add deleteUser, refactor the repository pattern, and update the README" is three tasks, and the model will try to do all three in one chain of tool calls, which gets messy. Do them one at a time. Use `/clean` between them.

**Let it fail.** If the first edit does not fix the check, do not interrupt. Let the model see the failure and try again. The second attempt is usually better than the first, because the model now has the diagnostic *and* the knowledge of what did not work. Interrupting after the first failure robs it of that learning.

**Read the diffs.** Every `edit_file` call prints the change. Read it. Not because the model is untrustworthy, but because reading the diff is faster than reading the whole file, and it keeps you in the loop. The model is a colleague, not a contractor. You are still responsible for the code.
