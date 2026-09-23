# Report on what a delete removed

Create an ARO application that deletes from a repository and then says what it
did, rather than only doing it.

- `main.aro` — one `Application-Start` feature set that:
  - stores three orders, two of them cancelled,
  - deletes the cancelled ones and logs `<purged: count>`,
  - iterates `<purged: deleted>` logging each removed order's id,
  - deletes with a `where` that matches nothing and logs its `count` — which is
    what distinguishes it from a delete that matched,
  - deletes with no `where` at all, clearing the repository, and logs how many
    entries it held.
