# Chapter 2: Training the Local

> "The question is not whether a model can learn ARO. The question is how small it can be and still do it."

---

## 2.1 Why Small

The fine-tuned model that ships with `aro ask` is not large. By the standards of 2026, it is small — a 4-bit quantised mixture-of-experts model with 30 billion total parameters but only 3 billion active per token, small enough to run comfortably on a laptop with unified memory or a mid-range GPU. This was not a compromise. It was the point.

A large model trained on ARO would be impressive. It would also be useless, because nobody would be able to run it. The decision to build a local assistant meant the decision to build a small one. Everything about the training pipeline was designed around that constraint. The goal was never "state of the art on general code". The goal was "good enough on ARO to make a working engineer faster".

## 2.2 What the Pipeline Does

The training pipeline lives in the sibling project `ARO-Train`. It is a sequence of Jupyter notebooks — numbered `00` through `21` — that collect data, shape it into pairs, fine-tune a base model, and package the result. You do not need to run it to use `aro ask`. You only need to run it if you want to train your own variant.

In prose, the pipeline does the following:

1. **Collects a corpus** from every authoritative source in the ARO project — proposals, the Book, the wiki, every example application, the commit history of the language itself, and the README. This is the only place where the training process touches the public internet; after this step, everything happens locally.
2. **Extracts knowledge** from that corpus into a structured file — the grammar, the list of actions with their verbs and prepositions, the canonical syntax, and the error philosophy.
3. **Generates instruction/response pairs** from the knowledge file, from the books, from the git history of the language, and from comments left in existing ARO applications. Every example and application ships with a `plan.md` — a detailed implementation plan — and the pipeline generates ten paraphrases of each plan, all paired with the same verified output. This teaches the model to recognise many different ways of asking for the same thing. The same ten-variant strategy is applied to every training pair in the pipeline: application prompts, code-to-comment explanations, and example-based code generation all produce ten instruction variants per ground-truth response.
4. **Warm-starts a fine-tune** on a general base model — by default a 4-bit Qwen coder — using the pairs.
5. **Runs a preference optimisation pass (DPO)** using pairs of good and bad ARO answers, so the model learns which of two superficially correct responses is the one a human would actually want.
6. **Evaluates** the fine-tune against a fixed set of probe prompts, checks the output with `aro check`, and reports a syntax pass rate.
7. **Packages** the resulting weights for distribution — both as an MLX bundle for Apple Silicon and a GGUF bundle for `llama.cpp`.

The entire pipeline was written by the same method as the rest of ARO: a person asking a general model what each step should look like, reading the draft, running it, fixing it, and asking for the next step. The training script that produced `aro-coder-4bit` was itself the product of a long conversation with a model that did not know what ARO was, and that needed to be told.

The irony is load-bearing. A model that did not know ARO wrote the code that trained a model that does.

## 2.3 What the Model Was Taught

The fine-tuned model learned five things, in roughly decreasing order of how much pipeline time was spent on each:

**The shape of every statement.** Every line of ARO is *verb the \<result\> preposition [the] \<object\>*. The model saw thousands of statements in that shape and learned to produce new ones in the same shape without dropping the angle brackets, without inventing prepositions, and without drifting into Python or Swift syntax halfway through.

**The five action roles.** REQUEST actions (Extract, Retrieve, Read, Fetch) pull data from outside. OWN actions (Compute, Validate, Compare, Create, Transform) work inside the process. RESPONSE actions (Return, Send, Log, Store) hand data back or persist it. EXPORT actions (Emit, Schedule) push data to external consumers. SERVER actions (Start, Stop, Connect, Listen) manage services and infrastructure. The model learned which verbs live in which category, and which prepositions each verb actually takes.

**The feature set shape.** A feature set is `(Name: Business Activity) { statements }`. Feature sets are triggered by events — HTTP requests, domain events, repository changes — not called directly. The model learned to write complete, runnable feature sets given only the trigger and a one-line description of what should happen.

**The error philosophy.** ARO feature sets contain only the happy case. Errors are handled by the runtime. The model learned to resist adding defensive `when` guards, try/catch constructs, or error returns — because none of those exist in ARO.

**What does not exist.** A model trained only on correct examples will cheerfully invent plausible-sounding actions — Tail, Scan, Update, Query — that are not part of the language. The training pipeline includes explicit correction data: pairs where the user asks for a non-existent action and the model explains which real action to use instead. The validation pass rejects any generated sample that uses a verb not in the canonical action list.

It was also taught, almost as an afterthought, how to wrap its output in markdown fences and how to cite the proposal number when asked about a design decision. These are small things. They compound into the difference between a useful assistant and an exasperating one.

## 2.4 What the Model Was Not Taught

The pipeline deliberately did not teach the model several things.

It was not taught to hold your hand. There are no long prefaces, no "I'll be happy to help with your request" boilerplate, no summary at the end of every reply. The training data was stripped of these. You get the answer, or you get an ARO code block, and then the model stops talking.

It was not taught to pretend it knows things it does not. When asked about features that do not exist in ARO, the fine-tune will say so and point you at the closest proposal. The alternative — confidently inventing features — was exactly the failure mode that killed general models on ARO. The DPO pass pushed hard against that mode.

It was not taught general web knowledge. The corpus is *just* the ARO project. Ask the fine-tune about Kubernetes and it will redirect you to its general base model's knowledge, which is stale and thin on ARO terms. Ask it about the EventBus and it will quote you the relevant proposal.

## 2.5 Running the Model

The fine-tune is published as `ARO-Lang/aro-coder-4bit` on Hugging Face. It is loaded automatically the first time you run `aro ask`. You do not need to run the training pipeline to use the model. You only need to install one of the supported runners — `llama-server`, `mlx_lm.server`, or any OpenAI-compatible endpoint — and the first `aro ask` invocation will offer to download the weights to `~/.cache/aro/models/`.

The interactive loop inside the training pipeline (notebook `21_chat.ipynb`) is the same loop that `aro ask` uses, in spirit: load the model, build a system prompt from the ARO knowledge base, pass user turns through the tokenizer, and stream back a reply. The difference is that `aro ask` does not require Python, does not require MLX, and does not require you to start Jupyter. It is the same brain in a simpler body.

## 2.6 A Note on Iteration

One of the later notebooks in the pipeline is `19_iterative_loop.ipynb`. It does something that is easy to describe and hard to do well: it uses the *current* fine-tune to generate new training data for the *next* fine-tune. Every cycle, the model is asked to produce ARO programs for a list of prompts; the ones that pass `aro check` are added to the training set; the ones that fail are added to the DPO negative set. The next round of training learns from both.

This is a feedback loop. It is also the point where the story becomes recursive: the model is now helping train its own successor. Not autonomously — a human still runs the notebooks, reviews the outputs, and decides what to keep. But the leverage is enormous. A morning of curation turns into a weekend of training, which turns into a model that is better at helping you curate.

The first version of `aro-coder-4bit` was bootstrapped from data generated by a general cloud model. The next version will be bootstrapped from data generated by the first version of `aro-coder-4bit`. The cloud model will, eventually, drop out of the loop entirely. That is the plan, and it is less far away than it sounds.
