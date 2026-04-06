# Chapter 6: Reclaiming the Local

> "Every generation of computing begins by promising the user control and ends by renting it back to them. Ours does not have to end that way."

---

## 6.1 The Drift to the Cloud

There was a period, roughly from 2020 to 2024, when the trajectory of programming tooling was clear: everything moves to the cloud. The editor, the compiler, the assistant, the test runner, the deployment pipeline — all of it was migrating from the developer's laptop into someone else's data centre. The argument for this was seductive. Cloud services had more compute, newer hardware, bigger models, faster iteration. Your laptop was just a terminal; the real work happened elsewhere.

What went unspoken was that the real work *also cost money*, per token, per CPU-second, per gigabyte of egress. And that the real work could be throttled, or rate-limited, or rewritten on someone else's schedule, or simply switched off. And that the code you fed to the real work was copied, stored, and sometimes used as training data in ways the terms of service made technically legal and morally vague.

This was not a conspiracy. It was the natural economic pull of a market in which compute was expensive and centralisation was efficient. It was also, quietly, a loss. The programmer's laptop — a machine more powerful than any mainframe of 1985 — was reduced to a display for a login screen.

## 6.2 What Changed

Two things changed, more or less simultaneously.

The first is that inference got dramatically cheaper. A model small enough to run on a laptop with integrated graphics, in 2026, is roughly as capable on code as a flagship cloud model was two years earlier. The capability curve is not flat — the frontier is still in the cloud — but the *useful* line has dropped well below the laptop hardware of ordinary engineers. A 30-billion-parameter coder, 4-bit quantised, fits in memory on machines that cost less than a business-class flight.

The second is that we finally learned how to fine-tune for tasks. A model that knows a little bit about everything is less useful, on a specific domain, than a model that knows only that domain. The ARO fine-tune is a sharp example: it is terrible at explaining kubernetes YAML, because it was never trained on it, but it is excellent at writing ARO feature sets, because that is all it was trained on. A team that knows its domain can build a specialised model that outperforms any general-purpose cloud model *on that domain*, for a fraction of the cost, on a machine they already own.

Put those two changes together and the economic pull reverses. The cloud is no longer the obvious answer for domain-specific programming tasks. The obvious answer is the laptop — *your* laptop, running *your* model, talking to *your* code.

## 6.3 What `aro lm` Is For

`aro lm` is a small, specific bet on that reversal. It is not a general-purpose coding assistant. It is a coding assistant for one language, running locally, with tools that are scoped to one project. It does not phone home. It does not require an account. It does not need network access once the model is downloaded. It does not train on your conversations.

That last point is worth dwelling on. Every message you send to `aro lm`, every file it reads, every command it runs, lives on your machine and nowhere else. The `.context` file is yours. The tool-call logs are yours. The history of your thinking, captured in the back-and-forth with the model, is yours. If you want to share a conversation with a colleague, you copy the `.context` file. If you want to delete it, you delete it. There is no "but a copy is still on our servers for thirty days per our retention policy".

This is the most understated feature of the whole tool. It is also, arguably, the most important one.

## 6.4 The Recursive Game

Chapter 2 ended with a note on the iterative loop notebook — the one where the current version of the fine-tune helps train the next version. That note is worth expanding, because it points at something genuinely new.

A local model that is *good enough* to help improve itself creates a feedback loop that does not require a cloud provider to close. A person with a laptop, a handful of gigabytes of disk space, and a willingness to curate, can train a model that is slightly better at ARO than last week's version. Not in three weeks on a rented GPU cluster. On a laptop, over a weekend. And next week, the slightly-better model helps curate slightly-better training data for the week after. The curve is not steep. It does not need to be. It is locally owned, and it does not stop.

The end state of this game is not "our local model beats GPT-7". It is "our local model is good enough that we no longer need to ask whether a cloud model would be better, because the cost of finding out is more than the value of the answer." That is a different kind of sufficiency than the frontier chases. It is the kind that used to be called "tools the engineer owns".

## 6.5 What You Can Do Now

If you are reading this and you have an ARO project on your laptop, here is what you can do today, without permission, without a subscription, without an account:

1. Install `aro lm` — it comes with the `aro` binary. You already have it.
2. Install `llama-server` or `mlx_lm.server`. Five minutes.
3. Run `aro lm "hello"`. Answer `y` to the download prompt. Wait.
4. Ask the model to help you write a feature set. Any feature set. The one you have been putting off because it was boring.
5. When it is done, commit the code, delete the `.context`, and go to bed.

That sequence is a small act, but it is an act of claiming something back. The code is on your machine. The model is on your machine. The decision about what to build next is on your machine. There is no cloud to consult, no quota to worry about, no billing email at the end of the month, no vendor's priorities leaking into your architecture.

## 6.6 Where This Ends

The honest answer is: we do not know where this ends. The fine-tune will get better. The pipeline will get simpler. The hardware will get cheaper. Eventually, someone on the ARO team will train a variant of the model that specialises in their own application domain — invoicing, logistics, content moderation — and ship it alongside the base `aro-coder`. Someone else will bridge an internal MCP server and get the model to do things we have not thought of yet. Someone else will fork the whole training pipeline and train a model for a language that is *not* ARO, because the pattern generalises.

Every one of those things is a small victory against the drift to the cloud. None of them require anybody's permission.

ARO started with a conversation. So did this chapter of computing. The conversation continues on the laptop in front of you.

---

*That is the end of the book. The Language Guide continues where this one leaves off; so does the Proposals directory, so does the Wiki, and so does the `aro mcp` server that the model behind `aro lm` consults when it needs to look something up. All of it is local, all of it is readable, all of it is yours. Use it well.*
