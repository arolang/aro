# SQLiteExample

Demonstrates database operations using the **Call action** with a SQLite plugin.

## What This Example Shows

This example demonstrates:
- **CRUD Operations**: CREATE TABLE, INSERT, SELECT, UPDATE, DELETE
- **SQLite Plugin**: Dynamic library using SQLite.swift package
- **Stateful Service**: Database state persists across method calls
- **JSON Results**: Query results as arrays of dictionaries

## Features Demonstrated

- **Database operations** - CREATE TABLE, INSERT, SELECT, UPDATE, DELETE
- **Plugin system** - SQLite service implemented using SQLite.swift library
- **JSON data exchange** - Rows returned as arrays of dictionaries
- **Error handling** - SQLite errors returned as JSON error objects
- **Thread safety** - All database operations serialized with DispatchQueue

## Plugin Implementation

The SQLitePlugin (`plugins/SQLitePlugin/`) demonstrates:

- Swift Package Manager integration (SQLite.swift dependency)
- C-compatible plugin interface with `@_cdecl` functions
- Thread-safe database operations with DispatchQueue
- In-memory database for deterministic testing
- Row-to-JSON conversion with proper type handling

## Database Schema

```sql
CREATE TABLE users (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    email TEXT
)
```

## Operations Demonstrated

1. **Create Table**: Set up users table
2. **Insert**: Add Alice, Bob, and Charlie (get insert IDs)
3. **Query All**: Retrieve all users
4. **Update**: Change Bob's email
5. **Query One**: Verify Bob's updated email
6. **Delete**: Remove Charlie
7. **Query Final**: Verify Charlie is gone

## ARO Syntax

```aro
(* Create table *)
<Call> the <create-result> from the <sqlite: execute> with {
    sql: "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT)"
}.

(* Insert data *)
<Call> the <insert-result> from the <sqlite: execute> with {
    sql: "INSERT INTO users (name, email) VALUES ('Alice', 'alice@example.com')"
}.
<Extract> the <user-id> from the <insert-result: lastInsertRowid>.

(* Query data *)
<Call> the <query-result> from the <sqlite: query> with {
    sql: "SELECT * FROM users"
}.
<Extract> the <users> from the <query-result: rows>.
```

## Related Proposals

- [ARO-0004: Actions](../../Proposals/ARO-0004-actions.md) - Call action
- [ARO-0010: Advanced Features](../../Proposals/ARO-0010-advanced-features.md) - Plugin system

## Usage

```bash
# Build the plugin first
cd Examples/SQLiteExample/plugins/SQLitePlugin
swift build -c release
cd ../../../..

# Run the example (interpreted)
aro run ./Examples/SQLiteExample

# Or compile to native binary
aro build ./Examples/SQLiteExample
./Examples/SQLiteExample/SQLiteExample
```

## Testing

```bash
# Generate expected output
./test-examples.pl --generate SQLiteExample

# Run automated test
./test-examples.pl SQLiteExample
```

---

*SQLite plugin enables persistent data storage with familiar SQL syntax.*
