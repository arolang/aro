\newpage

# Chapter 5: Automation Everyone Understands

> "A script that only its author can read is a liability. A script anyone on the team can read is an asset."

---

## 5.1 The Case for Readable Automation

Most automation fails not because it is wrong but because it is illegible. A shell script accumulates flags over the years, each added by someone now on a different team, and eventually nobody is willing to touch it. A Python job grows into three hundred lines of `try` blocks and retry logic, and new joiners are quietly warned not to go near it. The automation works, until it doesn't, and when it doesn't nobody can fix it.

ARO changes the economics of this. Because every ARO feature set is a sequence of English sentences, a person reading an ARO script can understand what it does without reading a single line of Python or shell. Because feature sets are triggered by events, the flow is declarative — you see what happens in what order, not how it happens behind a web of callbacks. And because ARO ships with a local assistant, you can ask the assistant "what does this job do, and what would break it?" and get a real answer.

This chapter is about using `aro ask` to write automation that your non-engineer colleagues can read. Not "should be able to read in principle, with a day of training" — actually read, today, at the same terminal where they already check their email.

## 5.2 The First Useful Script: A Nightly Report

Start small. Here is a prompt that has produced a working ARO application on every model the fine-tune was evaluated against:

> Write an ARO application that runs once, reads every `.log` file in `./logs`, counts how many lines contain the word "ERROR", writes a report to `./report.md`, and exits.

What `aro ask` will do, if you let it:

1. Call `list_dir` on `./logs` to see what's actually there.
2. Call `parse_aro` on a draft feature set before writing anything.
3. Call `write_file` to create `main.aro`.
4. Call `aro_check` on the resulting directory.
5. Report back with a short explanation and the path to the new file.

You can read the resulting `main.aro`, and so can the person sitting next to you who does not write software. It will look like this:

```aro
(Application-Start: Nightly Report) {
    Retrieve the <log-files> from the <filesystem>
        where path = "./logs" and extension = ".log".

    For each <file> in <log-files> {
        Retrieve the <content> from the <file>.
        Filter the <error-lines> from the <content>
            where line contains "ERROR".
        Compute the <error-count: length>
            from the <error-lines>.
        Publish as <counts> append <counts>
            with <error-count>.
    }

    Compute the <total: sum> from the <counts>.
    Compute the <report-text>
        from "Total errors: " ++ <total>.
    Store the <report-text> to the <filesystem>
        where path = "./report.md".

    Return an <OK: status> for the <report>.
}
```

Anyone on the team can read that. Anyone on the team can edit it. The automation is no longer hidden behind someone's personal Python library.

## 5.3 CI-style Invocations

`aro ask` is scriptable. Here are patterns that have proven themselves:

**Ask the assistant to fix a failing check.**

```bash
aro ask --yes \
  "run aro_check on ./Examples/UserService \
   and fix any diagnostics"
```

This will, in order, call `aro_check`, read the offending files, edit them with `edit_file`, re-run the check, and stop when it passes or after 25 rounds of tool calls. The `--yes` flag auto-approves shell access so the loop can run without a human at the keyboard. The result is either a fixed directory or a context file you can open afterwards to see what was tried.

**Generate boilerplate for a new operation.**

```bash
aro ask --yes \
  "add a feature set called deleteUser \
   that handles DELETE /users/{id} in ./MyApp"
```

The model will read `openapi.yaml`, extract the schema, write the new `.aro` file, and run `aro_check` to confirm it parses. Your job is to review the diff, not to write the boilerplate.

**Run on a shared endpoint.**

```bash
ARO_ASK_ENDPOINT=http://192.168.1.42:8080 \
  aro ask --yes "check everything under Examples/"
```

On CI servers, running `llama-server` per job is wasteful. Run it once, on a machine with a GPU, point every job at it with `ARO_ASK_ENDPOINT`, and `aro ask` will happily use it over the network. The model never leaves your infrastructure, and every job gets a fast response.

**Explain changes in a PR.**

```bash
aro ask --no-mcp \
  "read the last five files modified in this \
   branch and write a short PR summary" \
  > pr-summary.md
```

The `--no-mcp` flag skips the MCP bridge boot for a small speedup; the command writes its output to a file you can paste into the PR description. Nothing fancy, just tedium deleted.

## 5.4 Scheduled Jobs

You can put `aro ask --yes "..."` into a cron job, a systemd timer, or a GitHub Actions schedule. The fact that it runs a local model rather than a cloud service is a feature, not a limitation — your scheduled jobs are not rate-limited, not billed per token, and not waiting on someone else's availability.

Two things to watch for:

- **Approval is off.** With `--yes`, every shell and file tool runs without human review. Make sure the job's working directory is one you're willing to have fully modified.
- **The model can still be wrong.** A scheduled `aro ask` job should produce a diff you review before it lands in production, not commit directly to main. Use the job to propose, not to merge.

A good pattern is to have the job open a pull request rather than push to a branch. The assistant writes the code, the CI runs the tests, and a human approves the merge.

## 5.5 Talking to Other MCP Servers

Every MCP server you add to the `mcp_servers:` list in your `.context` file becomes a set of tools the model can call during a conversation. This is how you extend `aro ask` without changing the binary.

A few examples of MCP servers worth bridging, if you use them:

- **An internal docs MCP**: the model can read your company wiki without leaking it to a cloud provider.
- **A ticket system MCP**: the model can look up the ticket number in the commit message and pull its description.
- **A secrets broker MCP**: the model can ask "is there a database password configured for `staging`?" without ever seeing the password itself.

The pattern is always the same: add a server to `.context`, run `aro ask /mcp` to confirm it connected, run `aro ask /tools` to see what new tools are available, and then write a prompt that asks the model to use them. The tools appear alongside the built-ins without any special flag. The model does not care whether a tool is built-in or bridged; it just calls it.

## 5.6 A Principle

The principle threading through this chapter is: automation is readable when the human and the machine are writing in the same language. ARO makes the automation human-readable. `aro ask` makes the human's job of authoring it fast enough to be worth the investment.

The old argument against domain-specific languages was that they were expensive to write. That argument depended on nobody having an assistant that already knew the language. The assistant is here. The language is here. The only thing left is to sit down and write the first script.
