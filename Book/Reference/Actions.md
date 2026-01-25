# ARO Action Reference

Complete reference of all 51 ARO actions organized by category.

| **Action**    | **Category**      | **Semantic Role** | **Description**                                           |
| ------------- | ----------------- | ----------------- | --------------------------------------------------------- |
| **Send**      | Communication     | RESPONSE          | Delivers data or message outward.<br>`<Send> "Hello" to the <connection>.` |
| **Receive**   | Communication     | REQUEST           | Accepts incoming data or message from external source.<br>`<Receive> the <message> from the <event>.` |
| **Request**   | Communication     | REQUEST           | Initiates a query or ask for data or service.<br>`<Request> the <data> from the <api-url>.` |
| **Listen**    | Communication     | OWN               | Waits for incoming events or data.<br>`<Listen> on port 9000 as <socket-server>.` |
| **Connect**   | Communication     | OWN               | Establishes a link between endpoints.<br>`<Connect> to <host: "localhost"> on port 5432 as <db>.` |
| **Close**     | Communication     | OWN               | Terminates a connection or handle.<br>`<Close> the <database-connection>.` |
| **Keepalive** | Communication     | OWN               | Maintains an active connection.<br>`<Keepalive> the <application> for the <events>.` |
| **Notify**    | Communication     | RESPONSE          | Signals a change or event to observers.<br>`<Notify> the <alert> to the <admin>.` |
| **Broadcast** | Communication     | RESPONSE          | Sends to multiple recipients.<br>`<Broadcast> the <message> to the <socket-server>.` |
| **Publish**   | Communication     | EXPORT            | Publishes an event or message to a channel.<br>`<Publish> as <app-config> <config>.` |
| **Emit**      | Communication     | EXPORT            | Emits an event or signal.<br>`<Emit> a <UserCreated: event> with <user>.` |
| **Make**      | Construction      | OWN               | Builds or prepares a resource (e.g., dirs).<br>`<Make> the <output-dir> to the <path: "./output">.` |
| **Execute**   | Control           | OWN               | Runs a command or code block.<br>`<Execute> the <result> with "ls -la".` |
| **Call**      | Control           | OWN               | Invokes a function or service.<br>`<Call> the <result> via <API: POST /users> with <data>.` |
| **Return**    | Control           | RESPONSE          | Sends back a result from a call.<br>`<Return> an <OK: status> with <data>.` |
| **Given**     | Control/Spec      | OWN               | Denotes initial precondition in scenarios.<br>`<Given> the <user> with { name: "Test" }.` |
| **When**      | Control/Spec      | OWN               | Denotes conditional trigger.<br>`<When> the <action> from the <feature-set>.` |
| **Then**      | Control/Spec      | OWN               | Denotes expected result after condition.<br>`<Then> the <result> with <expected>.` |
| **Extract**   | Data Access       | REQUEST           | Pulls a subset or component from a larger data structure.<br>`<Extract> the <user-id> from the <request: parameters>.` |
| **Retrieve**  | Data Access       | REQUEST           | Gets existing data by key or identifier.<br>`<Retrieve> the <user> from the <user-repository> where id = <id>.` |
| **List**      | Enumeration       | REQUEST           | Enumerates items in a collection or directory.<br>`<List> the <files> from the <directory: "./src">.` |
| **Filter**    | Enumeration       | OWN               | Selects items matching criteria.<br>`<Filter> the <active> from the <users> where status = "active".` |
| **Sort**      | Enumeration       | OWN               | Orders items in a sequence.<br>`<Sort> the <users> by <name>.` |
| **Throw**     | Error Handling    | RESPONSE          | Signals an exception or fault.<br>`<Throw> a <NotFound: error> for the <user>.` |
| **Start**     | Execution Control | OWN               | Begins a process or session.<br>`<Start> the <http-server> with <contract>.` |
| **Stop**      | Execution Control | OWN               | Ends a process or session.<br>`<Stop> the <http-server> with <application>.` |
| **Stat**      | Inspection        | REQUEST           | Checks metadata or status of a resource.<br>`<Stat> the <info> for the <file: "./doc.pdf">.` |
| **Read**      | I/O               | REQUEST           | Reads data from storage or stream.<br>`<Read> the <config> from the <file: "./config.json">.` |
| **Write**     | I/O               | RESPONSE          | Writes data to storage or stream.<br>`<Write> the <data> to the <file: "./output.txt">.` |
| **Append**    | I/O               | RESPONSE          | Adds data to end of existing resource.<br>`<Append> the <log-line> to the <file: "./app.log">.` |
| **Split**     | Manipulation      | OWN               | Breaks a data sequence into parts.<br>`<Split> the <words> from the <sentence> by /\s+/.` |
| **Merge**     | Manipulation      | OWN               | Combines multiple sequences into one.<br>`<Merge> the <existing-user> with <update-data>.` |
| **Log**       | Monitoring        | RESPONSE          | Records informational/debug output.<br>`<Log> "Server started" to the <console>.` |
| **Create**    | Mutation          | OWN               | Makes a new resource or object.<br>`<Create> the <user> with { name: "Alice" }.` |
| **Update**    | Mutation          | OWN               | Modifies an existing resource or object.<br>`<Update> the <user> with <changes>.` |
| **Delete**    | Mutation          | EXPORT            | Removes a resource or entry.<br>`<Delete> the <user> from the <users> where id = <id>.` |
| **Copy**      | Mutation          | OWN               | Duplicates data from one location to another.<br>`<Copy> the <file: "./a.txt"> to the <destination: "./b.txt">.` |
| **Move**      | Mutation          | OWN               | Transfers data or resources.<br>`<Move> the <file: "./old.txt"> to the <destination: "./new.txt">.` |
| **Store**     | Persistence       | EXPORT            | Saves data persistently.<br>`<Store> the <user> into the <user-repository>.` |
| **Compute**   | Processing        | OWN               | Performs calculation or algorithm.<br>`<Compute> the <total> from <price> * <quantity>.` |
| **Transform** | Processing        | OWN               | Converts data from one form to another.<br>`<Transform> the <dto> from the <entity>.` |
| **Map**       | Processing        | OWN               | Applies a function across elements.<br>`<Map> the <names> from the <users: name>.` |
| **ParseHtml** | Processing        | OWN               | Extracts structured data from HTML. Specifiers: `links`, `content`, `text`, `markdown`.<br>`<ParseHtml> the <result: markdown> from the <html>.` |
| **Reduce**    | Processing        | OWN               | Aggregates elements into a summary.<br>`<Reduce> the <total> from the <amounts> with sum.` |
| **Accept**    | Protocol          | OWN               | Acknowledges or agrees to a connection/request.<br>`<Accept> the <order: placed>.` |
| **Exists**    | Query             | REQUEST           | Tests whether a resource or value is present.<br>`<Exists> the <found> for the <file: "./config.json">.` |
| **Validate**  | Verification      | OWN               | Checks correctness or conformance.<br>`<Validate> the <data> for the <schema>.` |
| **Compare**   | Evaluation        | OWN               | Compares two values or structures.<br>`<Compare> the <hash> against the <stored-hash>.` |
| **Assert**    | Verification      | OWN               | Checks that a condition holds true.<br>`<Assert> the <value> equals <expected>.` |

## Summary by Semantic Role

- **REQUEST** (8 actions): Extract, Retrieve, Receive, Request, Read, List, Stat, Exists
- **OWN** (32 actions): Compute, Validate, Compare, Transform, Create, Update, Filter, Sort, Split, Merge, Copy, Move, Map, ParseHtml, Reduce, Accept, Given, When, Then, Assert, Start, Stop, Listen, Connect, Close, Keepalive, Make, Execute, Call
- **RESPONSE** (8 actions): Return, Throw, Send, Log, Write, Append, Notify, Broadcast
- **EXPORT** (3 actions): Publish, Store, Emit, Delete

## Summary by Category

- **Communication** (11): Send, Receive, Request, Listen, Connect, Close, Keepalive, Notify, Broadcast, Publish, Emit
- **Construction** (1): Make
- **Control** (3): Execute, Call, Return
- **Control/Spec** (3): Given, When, Then
- **Data Access** (2): Extract, Retrieve
- **Enumeration** (3): List, Filter, Sort
- **Error Handling** (1): Throw
- **Execution Control** (2): Start, Stop
- **Inspection** (1): Stat
- **I/O** (3): Read, Write, Append
- **Manipulation** (2): Split, Merge
- **Monitoring** (1): Log
- **Mutation** (5): Create, Update, Delete, Copy, Move
- **Persistence** (1): Store
- **Processing** (5): Compute, Transform, Map, ParseHtml, Reduce
- **Protocol** (1): Accept
- **Query** (1): Exists
- **Verification** (3): Validate, Compare, Assert
