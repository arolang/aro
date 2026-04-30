\newpage

# Chapter 4: Habits

> "A sharp tool makes the user faster; a well-habituated tool makes the user calmer."

---

## 4.1 Context Is Small

The single most common mistake, made by everyone who picks up `aro ask` for the first time, is treating the context file as a long-lived project log. It is not. It is a scratchpad. The longer it gets, the worse the model gets.

There are two reasons. The first is mechanical: the fine-tune has a context window of 8192 tokens. The longer your `.context` grows, the closer you get to the edge, and the more the model forgets. The second is behavioural: when there are twenty turns of prior conversation in the prompt, the model tends to confuse the current question with a previous one. It starts giving you answers to things you asked an hour ago.

The habit is simple: one task, one `.context`. When you finish a feature, run `/clean`. When you switch from writing a feature to debugging a test, run `/clean`. When you come back to work in the morning and the previous evening's conversation does not match what you want to do now, run `/clean`.

You will not lose anything important. If the conversation was worth keeping, you already committed the code it produced. The chat is not the artifact. The code is the artifact.

## 4.2 Let It Read the Project

The second most common mistake is pasting code into the prompt. Do not do this. The model has a tool — `read_file` — for precisely this reason. When you want the model to look at `users.aro`, do not paste the file. Say "read users.aro and explain how the validation works." The model will call `read_file` and report back.

The habit generalises. Never describe what a file contains when the model could just read it. Never describe what a directory contains when the model could just `list_dir` it. Never run a command yourself and paste the output when the model could `run_shell` it and get the output directly. The more the model does by itself, the less drift there is between what you think is true and what actually is.

The exceptions are real but small. If a file is enormous, say "read the first hundred lines of …". If the command is destructive, approve it or deny it but do not bypass the approval by running it in another terminal and pasting the result.

## 4.3 Approve Shell Commands Like You Mean It

When the model wants to run a shell command, `aro ask` stops and asks:

```
[aro ask] approve shell command? [y/N]
  rm -rf build/
>
```

Read the command before typing `y`. Read it *every* time. The fine-tune is good. The fine-tune is not infallible. "Approve-and-forget" is how people end up deleting directories they did not mean to delete. Typing `y` is muscle memory; pausing for half a second before typing `y` is also muscle memory, and the second one is the muscle memory you want.

The `--yes` flag bypasses the prompt. It exists because there are legitimate, non-interactive reasons to run `aro ask` — CI pipelines, scheduled jobs, batch refactors. Use it in scripts. Do not use it when you are about to leave the terminal unattended. A model that is permitted to run arbitrary shell commands without supervision is, at minimum, an engineer who does not need to sleep. At maximum it is a mistake waiting for a moment of distraction. The safety margin between those two is the `--yes` flag.

## 4.4 Parse Before You Write

The model has a tool called `parse_aro`. It takes a block of ARO source and returns either `ok` or a parser diagnostic. It does not write anything to disk. It does not touch the filesystem. It just tells you whether what the model is about to write is going to compile.

Train yourself — and the model — to use this tool before writing files. "Parse this first, and if it's clean, write it to `users.aro`." Two calls instead of one, but the second call only happens if the first one succeeds. The result is that your working tree never contains a half-written feature set that does not parse.

## 4.5 Keep the Index Fresh

The first time you run `aro ask /index` in a project, it walks every indexable file, chunks them, embeds them, and writes the result to `.context.index/vectors.json`. After that, the model has access to a search tool that can find a relevant piece of the project in one call.

The index does not update itself. If you move a file, add a new proposal, or rewrite a large chunk of source, run `/index` again. It is fast. There is no reason not to.

Your `.gitignore` should include `.context.index/`. The index is a cache, not a source of truth; regenerating it is cheap, and committing it would bloat the repo with megabytes of vectors that go stale on every edit. Similarly, decide explicitly whether you want `.context` to be committed. Some teams do — a shared record of the conversations that shaped a feature. Most teams do not. Either is fine; just make the choice deliberately.

## 4.6 Read the Proposals Before You Argue

When `aro ask` gives you an answer you disagree with, your first instinct will be to argue with it. Your second instinct should be to ask it for a citation. The fine-tune was trained on the `Proposals/` directory, and it has the `read_proposal` tool. Ask: "read ARO-0018 and tell me why you suggested pipeline syntax for this." The model will read the proposal and either reinforce its original answer with a citation, or it will notice it was wrong and correct itself.

The habit is to move disagreements from your head into the spec. Both of you — human and model — get better at ARO this way.

## 4.7 Commit Messages Are Not the Model's Job

`aro ask` is excellent at writing ARO feature sets, explaining error messages, refactoring handlers, and chasing down compiler diagnostics. It is mediocre at writing commit messages, because the training data did not include many.

If you ask it to write a commit message, you will get one. It will be syntactically fine and semantically vague, because the model does not know what you were trying to accomplish outside of this one conversation. Write the commit message yourself. It will take you thirty seconds and will be better than anything the model produces. This is not a rule. It is a recommendation based on which battles are worth picking.

## 4.8 Precise Prompts Are Better

For single feature sets, keep prompts short and direct. "Write a feature set for `createUser` that validates the email and emits a `UserCreated` event" is better than "Could you please help me write a feature set that will create a user, and also make sure to validate that the email address they provide is in a valid format, and then after the user is created successfully, it would be good if we could emit an event saying the user was created..."

But when you want a complete application — multiple files, an OpenAPI contract, event handlers, the full structure — give the model a detailed implementation plan. Describe the endpoints, the data models, the event flow, and the file layout. The model was trained on exactly this pattern: read a plan, produce every file. The more precise the plan, the closer the output is to what you want. A good plan names the feature sets, the event types, the repository names, and the API routes. A vague plan gets vague code.

The rule in both cases is the same: say exactly what you mean, no more and no less. For a single feature set, that is one sentence. For a full application, that is a few paragraphs.
