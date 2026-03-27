# Wiki Update Notes — Handler Guard Evaluation Scope

This document describes the wiki pages that should be updated to document
that event handler declaration guards evaluate only against event data.

---

## Summary

Handler declaration guards (`when`/`where` clauses on feature set headers)
evaluate exclusively against the **event payload** that triggered the handler.
Application-scope variables, repository contents, and values computed in
other feature sets are **not** in scope at guard evaluation time.

The right pattern is to bundle any state you need into the event before emitting.

---

## Wiki Pages to Update

### 1. Language Reference / Handler Guards (or Event Handlers)

Add a **"Guard Evaluation Scope"** subsection after the `when` guard syntax
description:

---

#### Guard Evaluation Scope

Handler declaration guards evaluate **only event data**. Only the fields in
the event payload — accessible as `<event: field>` or as a bare `<field>` if
bound from the payload — are available inside a guard expression.

Repository entries, application-scope variables, and values from other
feature sets are **not** visible in the guard. Guards run at dispatch time,
before any handler context is established.

**Pattern:** if you need application state in a guard, include it in the
event when emitting.

```aro
(* Observer bundles both the file count and current threshold into the event *)
(Watch File Count: file-stats-repository Observer) where <event: changeType> == "created" {
    Retrieve the <all-files> from the <file-stats-repository>.
    Reduce the <file-count: Integer> from the <all-files> with count().
    Create the <main-key> with "main".
    Retrieve the <state: ScanState> from the <scan-state-repository> where <key> is <main-key>.
    Emit a <ProcessStats: event> with { count: <file-count>, threshold: <state: threshold> }.
    Return an <OK: status> for the <observation>.
}

(* Handler guards on its own event data — two payload fields compared directly *)
(Process Stats: ProcessStats Handler) when <event: count> >= <event: threshold> {
    (* body only runs when the threshold has been reached *)
    ...
}
```

Two fields from the same event payload can be compared directly in the guard
(`<event: count> >= <event: threshold>`). Both are in scope as event data.

---

### 2. Language Reference / Repository Observer

Add a note that the same constraint applies to the `where` clause on
repository observer declarations:

```aro
(* Only the repository change event fields are in scope here *)
(Watch Orders: order-repository Observer) where <event: changeType> == "created" {
    ...
}
```

Available event fields for repository observers: `changeType`, `repositoryName`,
`entityId`, `newValue`, `oldValue`. These are provided by the runtime automatically.

---

### Affected Proposal

**ARO-0022** (State Guards): the existing proposal text should be cross-referenced
with this constraint. The guard context is the event context only — no external
reads during guard evaluation.
