# Chapter 1: Genesis

> "There are two ways to write a language. One is to know exactly what you want. The other is to ask until you find out."

---

## 1.1 The First Conversation

ARO did not begin with a grammar. It began with a complaint. The complaint went roughly like this: every piece of business software, no matter the domain, ended up expressing the same three things — what happens, what we have afterwards, and what it applies to. Every form, every API, every back-office job. And yet every framework, every language, every architecture pattern found a different way to bury those three things under ceremony.

That complaint was typed into a chat window. The reply — from a general-purpose language model — was a sketch. Not a specification. A sketch. Three words. *Action, result, object.* The shape of every sentence in English business prose. "Retrieve the user from the repository." "Compute the total from the line items." "Publish the invoice to the queue." The sketch fit every example the conversation threw at it.

That was the hallucination. A useful one. The next hour of conversation was spent asking the model to break it — to find a case where the shape didn't fit. It failed. Or rather, it found cases where you could argue about prepositions, but the shape held. At the end of that hour, the first line of ARO was typed:

```aro
Retrieve the <user> from the <user-repository> where id = <id>.
```

It has barely changed since.

## 1.2 Letting the Machine Write

Once the shape was fixed, the question became: who writes the first thousand lines? The honest answer was "nobody, yet". Nobody knew ARO — it didn't exist outside the conversation window. The parser, the lexer, the action registry, the event bus, the OpenAPI integration, the plugin loader, the LLVM backend — every single one of those components was written in the same way. A human asked for a component. A model produced a draft. The human compiled it, ran the tests, pointed out the failures, and asked for a fix. The model fixed it. Repeat until it ran.

This is not a triumphal story. The drafts were wrong about half the time. The model hallucinated Swift APIs that did not exist. It got the concurrency model subtly wrong in ways that only showed up under load. It invented test frameworks. Every one of those wrong drafts was fixed — not by magic, not by "prompting harder", but by reading the code and understanding what it was trying to do, and then correcting it by hand or by going back to the model with a tighter question.

What made it work was not that the model was smart. It was that the language being built — ARO — was small. The grammar fits on one page. The action roles are four categories. The concurrency model follows one rule. When a component was wrong, the smallness of the language made the wrong part easy to see.

The lesson was not "you can ship software without reading code". The lesson was: you can move a lot faster than you think you can, *if you already know what shape you want*.

## 1.3 The First Full Application

The first ARO program that ran end-to-end was a user service. An OpenAPI contract with `listUsers`, `createUser`, `getUser`. Six feature sets, one `Application-Start`, a repository, a handful of events. It compiled, it ran, it served HTTP traffic. The conversation window that produced it is still in a text file somewhere — thousands of turns, mostly fixing things the model got almost right.

The important thing about that first application is not that it worked. It is that it was *readable*. Someone who had never seen ARO before could open `listUsers.aro` and understand what it did, because every statement was an English sentence. That was always the point: ARO is a language for business logic, written in the shape that business people already speak in. The fact that a language model — trained on business prose — could guess at ARO was not a happy accident. It was the whole design.

## 1.4 The Problem With General Models

And yet — ARO has a problem with general models. The problem has two parts.

The first part is vocabulary. There are four action roles, seventeen prepositions, and a few dozen built-in action verbs. The model that wrote the first version of ARO does not know any of them. It has to be reminded, every time, which verbs exist and which prepositions they take. It tends to invent new ones when it runs out of patience. Invented verbs do not parse. Feature sets with invented verbs fail silently in review and loudly in production.

The second part is privacy. Large general models live in a cloud. They see your source, your questions, and — if you're not careful — the production data you paste in when you're trying to debug something. That's a problem for teams that cannot ship their business logic to a vendor for analysis. It's a problem for people who simply do not want a transcript of every engineering decision leaving their machine.

The solution to both problems is obvious once you say it out loud: train a small model on ARO, and run it locally. The obvious solution is what this book is about.

## 1.5 Why "Haluzination"

The title of the book is a joke with a sharp edge. *Haluzination* is what critics call it when an LLM makes something up. It is also, quite accurately, how ARO was born — a chain of well-placed hallucinations, each one checked and kept or thrown away. The derogatory use of the word "hallucination" assumes that making things up is bad. That is wrong. Making things up is how design works. What matters is what happens *after* you make them up.

The rest of this book is about what happens after. Chapter 2 tells the story of training the local model. Chapter 3 teaches the commands. Chapter 4 is about good habits. Chapter 5 is about what you can do with `aro ask` that you cannot do with any other tool. Chapter 6 is about why all of this matters — why the local machine is worth claiming back. Chapter 7 explains how the tool-call loop works. Chapter 8 collects practical tips. And Chapter 9 walks through complete examples from scratch.
