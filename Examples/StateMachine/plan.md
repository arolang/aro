# Build a document review state machine

Create a single-file ARO application that demonstrates state machine capabilities using the `Accept` action for state transitions.

Model a document review workflow with these states and transitions:
- `draft` -> `submitted` (submit for review)
- `draft` -> `cancelled` (cancel before submission)
- `submitted` -> `approved` (approve the document)
- `submitted` -> `rejected` (reject the document)

In the `Application-Start` feature set:

1. Create a document object (DOC-001) with fields id, title, author, and status "draft". Use `Accept the <transition: draft_to_submitted> on <document: status>` to transition it to "submitted", then `Accept the <transition: submitted_to_approved> on <document: status>` to approve it. Log the document after each transition.

2. Create a second document (DOC-002) in draft state. Submit it, then reject it using `submitted_to_rejected`. Log the final status.

3. Create a third document (DOC-003) in draft state. Cancel it using `draft_to_cancelled`. Log the final status.

Log descriptive section headers throughout to show which transitions are being tested.
