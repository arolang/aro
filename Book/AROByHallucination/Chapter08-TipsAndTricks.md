\newpage

# Chapter 8: Tips and Tricks

> "Mastery is not knowing the tool's features. It is knowing which features to use when."

---

## 8.1 Writing Good Prompts

The fine-tune responds to shape. It was trained on thousands of instruction/response pairs, and every instruction had the same structure: a verb, a subject, and constraints. The closer your prompt matches that structure, the better the response.

Good prompts:

- "Write a feature set for `createOrder` that validates the total is positive and emits an `OrderCreated` event."
- "Add a `deleteUser` endpoint to the OpenAPI spec and write the matching feature set."
- "Explain why this feature set uses `Publish as` instead of returning the value directly."

Bad prompts:

- "I'm trying to build a thing where users can create orders and I want to make sure the order total is a positive number and also after the order is created I want to send out some kind of event so other parts of the system know about it..."
- "Can you help me?"
- "Write me a complete e-commerce application."

The pattern is: tell the model what to do, tell it what constraints matter, and stop. Do not explain your reasoning. Do not provide background the model did not ask for. Do not hedge. The model is not a person who needs to be convinced. It is a tool that needs a clear instruction.

There is one exception. When you are asking the model to make a judgement call — "should this be one feature set or two?" — a sentence of context helps. "This endpoint returns paginated results and also sets a cache header; should that be one feature set or two?" The context narrows the judgement space.

## 8.2 Common Mistakes the Model Makes

The fine-tune is good. It is not perfect. Here are the mistakes you will see most often, and what to do about them.

**Inventing verbs.** The model occasionally generates a verb that does not exist in ARO. "Process the order" sounds natural, but `Process` is not a registered action verb. When this happens, `aro check` will catch it. The fix is usually obvious: `Process` should be `Compute` or `Transform`. You can tell the model "Process is not a valid verb, use Compute instead" and it will correct itself.

**Wrong prepositions.** Each action verb takes specific prepositions. `Retrieve ... from` is correct. `Retrieve ... with` is not. The fine-tune mostly gets this right, but under long contexts it drifts. Run `aro check` early and often — it validates prepositions.

**Forgetting angle brackets.** ARO uses `<angle-brackets>` for all identifiers in statements. The model sometimes drops them, especially when it is explaining code in prose and then switches to writing code. A missing bracket is a parse error. `aro check` catches it. `/fix` fixes it.

**Overcomplicating.** ARO's error philosophy is "code is the error message". The happy case is all you write. The model sometimes forgets this and adds `When` guards for error conditions that the runtime handles automatically. If you see a feature set that is twice as long as you expected, look for defensive guards and remove them. Or tell the model: "remove the error handling, ARO handles that at runtime."

**Confusing feature set triggers.** The model sometimes writes a feature set named `createUser` and assigns it to a business activity that does not match the OpenAPI operationId. The feature set will parse but will never be triggered. Check that the name in parentheses matches the operationId in `openapi.yaml`.

## 8.3 Using /fix vs. Manual Editing

`/fix` is the fastest path from "broken" to "working". It runs the check, reads the diagnostics, and applies edits. For simple errors — typos, missing brackets, wrong prepositions — it is nearly always right on the first try.

But `/fix` is not always the right choice. Here is the dividing line.

Use `/fix` when:
- The error is syntactic. A misspelled verb, a missing period, a malformed feature set header.
- The error is local. One file, one line, one obvious fix.
- You want speed. `/fix` is faster than opening the file, finding the line, and editing it yourself.

Edit manually when:
- The error is semantic. The code parses but does the wrong thing.
- The fix requires understanding context that the model does not have. A business rule that is not written down anywhere, a naming convention your team uses, a dependency between files.
- You are learning. Reading the error and fixing it yourself teaches you ARO. Letting the model fix it teaches you nothing.

A good rhythm is: let `/fix` handle the mechanical errors, and handle the design errors yourself. Over time, the ratio shifts — you make fewer mechanical errors, and the model handles more of the design, because you have trained yourself to write better prompts and the model has been fine-tuned to understand your patterns.

## 8.4 Building Incrementally

The best way to build an ARO application with `aro ask` is one feature set at a time. Not because the model cannot write ten feature sets in one go — it can — but because you cannot review ten feature sets in one go. Not well.

The workflow:

1. Write or generate `openapi.yaml` with `/openapi`.
2. Ask the model to write the `Application-Start` feature set. Review it. Run `aro check`.
3. Pick the next endpoint. Ask the model to write the feature set. Review it. Run `aro check`.
4. Repeat until the application is complete.
5. Run `aro run` and test it.

Each step is a single conversation turn. Each step produces a single file. Each step ends with a check that passes. At no point do you have a project with five unreviewed files and a check that fails for reasons you cannot untangle.

The incremental approach also means you can `/clean` between steps without losing anything. The code is committed. The context is disposable.

## 8.5 Using .context Effectively

The `.context` file is your conversation state. It grows with every turn, and as it grows, the model's effective context window shrinks. On the default 8192-token window, a long conversation can push the system prompt and the current question off the edge, and the model starts giving answers that ignore the project structure it was told about three turns ago.

The rule is: `/clean` more often than you think you should.

Some specific signals that it is time to `/clean`:

- You have switched tasks. The context from the previous task is noise.
- The model repeats itself or gives an answer that contradicts what it said two turns ago.
- The model stops calling tools and starts guessing at file contents it could just read.
- You have been going back and forth for more than ten turns on the same problem.

After `/clean`, the model starts fresh. It re-reads the system prompt, re-discovers the project, and gives answers that are based on what is actually there, not on what it remembers from an earlier turn. This feels wasteful. It is not. A fresh context with one good question produces better results than a stale context with ten turns of accumulated confusion.

## 8.6 Combining aro ask with the CLI

`aro ask` is one command in the `aro` toolchain. It works best when you use it alongside the others, not instead of them.

**`aro check`** validates syntax without running anything. Use it after every edit, whether the edit came from you or from the model. The model calls it internally via the `aro_check` tool, but running it yourself in another terminal gives you a second pair of eyes.

**`aro run`** executes the application. The model can call this via `aro_run`, but you should run it yourself when you want to see the actual HTTP responses, the actual log output, the actual behaviour. The model sees the stdout; you see whether the application does what your users need.

**`aro test`** runs colocated tests. If your project has test feature sets, run them after every change. The model can run them via `aro_test`, but the habit of running tests yourself — not just having the model run them — is what keeps you honest.

**`aro build`** compiles to a native binary. The model does not have a tool for this, because building is a deployment decision, not a development one. Build when you are ready to ship, not when the model tells you to.

The pattern is: use `aro ask` for generation and debugging, use the other commands for verification and deployment. The model is good at writing code and finding bugs. You are good at deciding whether the code does the right thing.

## 8.7 Performance Tips

The fine-tune runs locally, and local inference has constraints that cloud inference does not. A few things make a noticeable difference.

**Temperature.** The default is `0.2`. Leave it there. Higher temperatures produce more creative prose but less accurate ARO. If you are asking for an explanation, `0.4` is fine. If you are asking for code, `0.2` or lower. The training data was terse and correct; the model performs best when it is not being asked to improvise.

**Model selection.** The default `aro-coder-4bit` is a 4-bit quantised 8-billion-parameter dense model — about 4.5 GB on disk. It runs comfortably on any machine with 8 GB of memory. If tokens come out slowly or the fan spins up, check that you are using the right backend for your hardware (see section 3.2).

**Backend.** On Apple Silicon, the native MLX backend runs in-process and is the fastest option. On Linux with an NVIDIA GPU, `llama-server` with CUDA is the way to go. On CPU-only machines, both are slow, and the best optimisation is to point `ARO_ASK_ENDPOINT` at a machine that has a GPU.

**Context length.** Keep conversations short. The model's context window is 8192 tokens. A long conversation does not just degrade quality — it also slows inference, because every token of context has to be processed on every turn. `/clean` is a performance optimisation as much as a quality one.

**Indexing.** Run `/index` once after cloning a project. The retrieval index lets the model find relevant files without scanning the whole directory tree, which saves tool calls and time. A project with an index gets better answers faster than one without.

## 8.8 Asking About New Language Features

The training corpus only covers the language up to the snapshot the model was distilled from. Anything newer is *outside* the model's competence, and it will improvise — usually badly. Treat the following as known blind spots and either run `/index` after pulling a recent ARO release, or paste the relevant chapter into the conversation manually:

- **User-defined actions** (ARO-0081). A feature set whose business activity is `Action` is callable as `Application.<Name>`. If the model writes `Call the <r> via Application.MyAction with …` it is hallucinating — show it Chapter 6 of TheLanguageGuide.
- **Native Git actions** (ARO-0080). `<Retrieve> the <status> from the <git>`, `<Stage>`, `<Commit>`, `<Push>`, etc., run via libgit2. The model may try to `<Execute>` git as a shell command — that still works but is no longer the idiomatic form.
- **Lazy execution**. Actions return future handles and are forced on first read. The model may volunteer `await` annotations from other languages; those do not exist in ARO. Effects keep source order automatically.
- **Piped source.** `echo '<Log> "x" to the <console>.' | aro` evaluates piped source. Handy for one-liners; the model rarely suggests it on its own.
