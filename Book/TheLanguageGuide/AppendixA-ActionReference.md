# Appendix A: Action Reference

*Complete reference for all built-in actions.*

---

## REQUEST Actions (External → Internal)

### Extract
**Role:** REQUEST
**Verbs:** `Extract`
**Prepositions:** `from`

Extracts data from a structure.

```aro
<Extract> the <user-id> from the <pathParameters: id>.
<Extract> the <body> from the <request: body>.
<Extract> the <name> from the <user: profile.name>.
```

---

### Retrieve
**Role:** REQUEST
**Verbs:** `Retrieve`
**Prepositions:** `from`

Retrieves data from a repository or data store.

```aro
<Retrieve> the <users> from the <user-repository>.
<Retrieve> the <user> from the <user-repository> where <id> is <user-id>.
```
*Source: [Examples/UserService/users.aro:7-14](../Examples/UserService/users.aro)*

---

### Fetch
**Role:** REQUEST
**Verbs:** `Fetch`
**Prepositions:** `from`

Makes an HTTP request to an external URL.

```aro
<Fetch> the <response> from "https://api.example.com/data".
<Fetch> the <weather> from "https://api.weather.gov/forecast".
```

---

### Read
**Role:** REQUEST
**Verbs:** `Read`
**Prepositions:** `from`

Reads content from a file.

```aro
<Read> the <content> from the <file> with "config.json".
<Read> the <data> from the <file> with "/path/to/file.txt".
```

---

### Receive
**Role:** REQUEST
**Verbs:** `Receive`
**Prepositions:** `from`

Receives data from a socket or stream.

```aro
<Receive> the <message> from the <socket>.
<Receive> the <data> from the <stream>.
```

---

### Get
**Role:** REQUEST
**Verbs:** `Get`
**Prepositions:** `from`

General-purpose retrieval action.

```aro
<Get> the <value> from the <cache> with <key>.
<Get> the <setting> from the <config: database.host>.
```

---

### Load
**Role:** REQUEST
**Verbs:** `Load`
**Prepositions:** `from`

Loads resources or configuration.

```aro
<Load> the <plugins> from the <plugins: directory>.
<Load> the <config> from the <environment>.
```

---

## OWN Actions (Internal → Internal)

### Create
**Role:** OWN
**Verbs:** `Create`
**Prepositions:** `with`

Creates a new value or object.

```aro
<Create> the <user> with <user-data>.
<Create> the <greeting> with "Hello, World!".
<Create> the <total> with <subtotal> + <tax>.
```

---

### Compute
**Role:** OWN
**Verbs:** `Compute`
**Prepositions:** `for`, `from`, `with`

Computes a derived value.

```aro
<Compute> the <total> for the <items> with sum(<price>).
<Compute> the <average> from <values> with avg().
<Compute> the <hash> for the <password>.
```

---

### Validate
**Role:** OWN
**Verbs:** `Validate`
**Prepositions:** `against`, `for`

Validates data against a schema or rules.

```aro
<Validate> the <input> against the <user: schema>.
<Validate> the <email> against the <email-format>.
```

---

### Transform
**Role:** OWN
**Verbs:** `Transform`
**Prepositions:** `from`, `into`

Transforms data from one format to another.

```aro
<Transform> the <dto> from the <entity>.
<Transform> the <json> from the <xml>.
```

---

### Filter
**Role:** OWN
**Verbs:** `Filter`
**Prepositions:** `from`

Filters a collection based on criteria.

```aro
<Filter> the <active-users> from the <users> where <status> is "active".
<Filter> the <expensive> from the <products> where <price> > 100.
```

---

### Sort
**Role:** OWN
**Verbs:** `Sort`
**Prepositions:** `from`, `by`

Sorts a collection.

```aro
<Sort> the <sorted-users> from the <users> by <name>.
<Sort> the <ordered> from the <items> by <price> with "desc".
```

---

### Merge
**Role:** OWN
**Verbs:** `Merge`
**Prepositions:** `from`, `with`

Merges two objects or collections.

```aro
<Merge> the <updated> from <existing> with <changes>.
<Merge> the <combined> from <list1> with <list2>.
```

---

### Compare
**Role:** OWN
**Verbs:** `Compare`
**Prepositions:** `against`, `with`

Compares two values.

```aro
<Compare> the <old-user> against the <new-user>.
<Compare> the <a> with the <b>.
```

---

### Parse
**Role:** OWN
**Verbs:** `Parse`
**Prepositions:** `from`

Parses structured data from a string.

```aro
<Parse> the <json> from the <string>.
<Parse> the <date> from the <date-string>.
```

---

## RESPONSE Actions (Internal → External)

### Return
**Role:** RESPONSE
**Verbs:** `Return`
**Prepositions:** `with`, `for`

Returns a response to the caller.

```aro
<Return> an <OK: status> with <data>.
<Return> a <Created: status> with <user>.
<Return> a <NoContent: status> for the <deletion>.
<Return> a <NotFound: status> for the <resource>.
```

---

### Throw
**Role:** RESPONSE
**Verbs:** `Throw`
**Prepositions:** `for`, `with`

Throws an error.

```aro
<Throw> a <ValidationError> for the <invalid: input>.
<Throw> an <AuthError> with "Invalid credentials".
```

---

### Respond
**Role:** RESPONSE
**Verbs:** `Respond`
**Prepositions:** `to`, `with`

Sends a response.

```aro
<Respond> the <data> to the <client>.
<Respond> with <message>.
```

---

## EXPORT Actions (Internal → Persistent/Global)

### Store
**Role:** EXPORT
**Verbs:** `Store`
**Prepositions:** `into`

Stores data in a repository.

```aro
<Store> the <user> into the <user-repository>.
<Store> the <order> into the <order-repository>.
```
*Source: [Examples/UserService/users.aro:23](../Examples/UserService/users.aro)*

---

### Emit
**Role:** EXPORT
**Verbs:** `Emit`
**Prepositions:** `with`

Emits an event.

```aro
<Emit> a <UserCreated: event> with <user>.
<Emit> an <OrderPlaced: event> with { orderId: <id>, total: <total> }.
```
*Source: [Examples/UserService/users.aro:26](../Examples/UserService/users.aro)*

---

### Publish
**Role:** EXPORT
**Verbs:** `Publish`
**Prepositions:** `as`

Publishes a value to the business activity scope, making it accessible to other feature sets with the same business activity.

```aro
<Publish> as <app-config> the <config>.
<Publish> as <db-connection> the <connection>.
```

---

### Log
**Role:** EXPORT
**Verbs:** `Log`
**Prepositions:** `for`, `with`

Logs a message.

```aro
<Log> the <message> for the <console>.
<Log> the <error> for the <console> with <details>.
```

---

### Write
**Role:** EXPORT
**Verbs:** `Write`
**Prepositions:** `to`

Writes content to a file.

```aro
<Write> the <data> to the <file> with "output.json".
<Write> the <content> to the <file> with <path>.
```

---

### Send
**Role:** EXPORT
**Verbs:** `Send`
**Prepositions:** `to`

Sends data to a destination.

```aro
<Send> the <email> to the <user: email>.
<Send> the <notification> to the <admin>.
<Send> the <request> to "https://api.example.com/webhook".
```

---

### Delete
**Role:** EXPORT
**Verbs:** `Delete`
**Prepositions:** `from`

Deletes data from a repository.

```aro
<Delete> the <user> from the <user-repository> where <id> is <user-id>.
<Delete> the <file> with <path>.
```
*Source: [Examples/UserService/users.aro:49](../Examples/UserService/users.aro)*

---

## Service Actions

### Start
Starts a service.

```aro
<Start> the <http-server> for the <contract>.
<Start> the <socket-server> on port 9000.
```
*Source: [Examples/HTTPServer/main.aro:7](../Examples/HTTPServer/main.aro)*

---

### Stop
Stops a service.

```aro
<Stop> the <http-server> for the <application>.
<Stop> the <socket-server> for the <application>.
```

---

### Connect
Connects to a service.

```aro
<Connect> the <database> to "postgres://localhost/mydb".
<Connect> the <socket> to "localhost:9000".
```

---

### Disconnect / Close
Closes a connection.

```aro
<Disconnect> the <database> for the <application>.
<Close> the <socket> for the <connection>.
```

---

### Watch
Starts watching for changes.

```aro
<Watch> the <file-monitor> for the <directory> with "./data".
```
*Source: [Examples/FileWatcher/main.aro:7](../Examples/FileWatcher/main.aro)*

---

### Keepalive
Keeps the application running.

```aro
<Keepalive> the <application> for the <events>.
```
*Source: [Examples/FileWatcher/main.aro:12](../Examples/FileWatcher/main.aro)*

---

## Summary Table

| Action | Role | Prepositions |
|--------|------|--------------|
| Extract | REQUEST | from |
| Retrieve | REQUEST | from |
| Fetch | REQUEST | from |
| Read | REQUEST | from |
| Receive | REQUEST | from |
| Get | REQUEST | from |
| Load | REQUEST | from |
| Create | OWN | with |
| Compute | OWN | for, from, with |
| Validate | OWN | against, for |
| Transform | OWN | from, into |
| Filter | OWN | from |
| Sort | OWN | from, by |
| Merge | OWN | from, with |
| Compare | OWN | against, with |
| Parse | OWN | from |
| Return | RESPONSE | with, for |
| Throw | RESPONSE | for, with |
| Respond | RESPONSE | to, with |
| Store | EXPORT | into |
| Emit | EXPORT | with |
| Publish | EXPORT | as |
| Log | EXPORT | for, with |
| Write | EXPORT | to |
| Send | EXPORT | to |
| Delete | EXPORT | from |
