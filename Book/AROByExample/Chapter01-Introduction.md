# Chapter 1: Introduction

*"The best way to learn a language is to build something real with it."*

---

## What We Will Learn

- What ARO is and why it exists
- The Action-Result-Object pattern
- What makes ARO different from other languages
- What we will build: a concurrent web crawler
- What ARO does well and what needs work

---

## 1.1 Welcome to ARO

ARO is a domain-specific language for expressing business logic as natural language statements. The name comes from its core pattern: **Action-Result-Object**. Every statement in ARO follows this structure, making code read almost like English.

Here is your first ARO statement:

```aro
Log "Hello, World!" to the <console>.
```

This reads naturally: "Log 'Hello, World!' to the console." The angle brackets mark the key elements: `<Log>` is the action, `"Hello, World!"` is what we're logging, and `<console>` is where we're sending it.

> **Note:** This book is based on a beta version of ARO, which is currently in active development. The language may change as it evolves. We will update this book to reflect significant changes. Check the official ARO repository for the latest information.

---

## 1.2 The Action-Result-Object Pattern

Every ARO statement follows a consistent pattern:

```
Action the <result> preposition the <object>.
```

The components are:

- **Action** — A verb that describes what happens (Extract, Compute, Return, etc.)
- **Result** — What the action produces, bound to a name you choose
- **Object** — The input or context the action works with
- **Preposition** — Connects result and object (from, to, with, into, etc.)

For example:

```aro
Extract the <username> from the <request: body>.
```

This extracts a value called `username` from the request body. The result `username` is now available for use in subsequent statements.

---

## 1.3 What Makes ARO Different

ARO is not a general-purpose language. It is designed for a specific domain: business logic that responds to events. Several design choices set it apart:

**Event-Driven by Default.** Code in ARO does not call functions. Instead, it emits events, and other code listens for those events. This creates natural decoupling between components.

**Happy Path Only.** You write only the success case. When something fails—a file not found, a network timeout, a missing field—the runtime handles it. The error message is derived from the code itself: "Could not extract the username from the request body."

**No Control Flow (Almost).** ARO has no if/else statements in the traditional sense. Instead, it uses pattern matching and guard expressions. This keeps code flat and readable.

**Natural Language Syntax.** Articles (the, a, an) and prepositions (from, to, with) make statements read like sentences. This is not just aesthetic—it reduces the cognitive load of reading code.

---

## 1.4 What We Will Build

Throughout this book, we will build a **concurrent web crawler**. When finished, it will:

1. Accept a starting URL from the environment
2. Fetch web pages and convert them to Markdown
3. Extract all links from each page
4. Normalize relative URLs to absolute URLs
5. Filter out links to external domains
6. Avoid re-crawling pages we have already visited
7. Process multiple links in parallel
8. Save each page as a Markdown file

The complete application is about 200 lines of ARO code across four files. By the end of this book, you will understand every line.

The source code is available at [github.com/arolang/example-web-crawler](https://github.com/arolang/example-web-crawler).

---

## 1.5 The Architecture

Our crawler follows an event-driven pipeline:

```
Application-Start
       │
       ▼
   CrawlPage ──────► SavePage ──────► Write to file
       │
       ▼
  ExtractLinks
       │
       ▼
  NormalizeUrl
       │
       ▼
   FilterUrl
       │
       ▼
   QueueUrl ──────► CrawlPage (loops back)
```

Each box is a **feature set**—a named block of ARO statements that handles a specific event. When one feature set finishes, it emits an event that triggers the next one. This is the core pattern of ARO applications.

---

## 1.6 What ARO Does Well

As we build this crawler, you will notice several strengths:

**Readability.** ARO code reads like a description of what it does. New team members can understand the flow without deep language knowledge.

**Concurrency.** Parallel processing requires no callbacks, promises, or async/await. You write `parallel for each` and ARO handles the rest.

**Event Decoupling.** Feature sets do not know about each other. They only know about events. This makes the system easy to extend and modify.

**Built-in Capabilities.** HTTP requests, HTML parsing, file operations, and set mathematics are all built into the language. No external libraries needed.

---

## 1.7 What Needs Improvement

ARO is young, and some areas need work:

**Error Messages.** When something goes wrong, the current error messages can be cryptic. Better diagnostics are on the roadmap.

**Debugging Tools.** There is no debugger or step-through execution. You rely on `<Log>` statements to trace execution.

**Documentation.** The language is evolving, so documentation sometimes lags behind features.

**Package Management.** There is no way to share or reuse code across projects yet.

We mention these not to discourage you, but to set honest expectations. ARO is a beta language, and you are an early adopter.

---

## Chapter Recap

- ARO uses Action-Result-Object statements that read like natural language
- Applications are event-driven: feature sets respond to events and emit new ones
- We will build a concurrent web crawler across 14 chapters
- ARO excels at readability, concurrency, and event-driven design
- The language is in beta; expect rough edges in tooling and documentation

---

*Next: Chapter 2 - Project Setup*
