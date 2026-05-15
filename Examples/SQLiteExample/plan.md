# Build a SQLite database CRUD demo using a plugin

Create a single-file ARO application that demonstrates full database CRUD operations using the SQLite plugin via the `Call` action.

In `main.aro`, the `Application-Start` feature set performs seven steps:

1. Create a users table: `Call the <create-result> from the <sqlite: execute> with { sql: "CREATE TABLE..." }`.
2. Insert three users using separate execute calls. Extract `lastInsertRowid` from each result.
3. Query all users: `Call the <all-users-result> from the <sqlite: query> with { sql: "SELECT * FROM users ORDER BY id" }`. Extract rows.
4. Update Bob's email. Extract `changes` count from the result.
5. Query Bob specifically after the update.
6. Delete Charlie. Extract `changes` count.
7. Final query to show remaining users.

Include an `Application-End: Success` handler. Log progress at each step.
