# ARO Action Reference

Complete reference of all 70 ARO actions organized by category.

> Git actions (`Stage`, `Commit`, `Push`, `Pull`, `Clone`, `Checkout`, `Tag`) operate on the `<git>` system object and emit `git.commit`, `git.push`, `git.pull`, `git.checkout`, `git.tag`, `git.clone` events. See [ARO-0080](../../Proposals/ARO-0080-git-actions.md) and Chapter 48 of TheLanguageGuide.

| **Action**    | **Category**      | **Semantic Role** | **Description**                                           |
| ------------- | ----------------- | ----------------- | --------------------------------------------------------- |
| **Accept**    | Protocol          | OWN               | Acknowledges or agrees to a state transition.<br>`Accept the <order: placed>.` |
| **Append**    | I/O               | RESPONSE          | Adds data to end of existing resource.<br>`Append the <log-line> to the <file: "./app.log">.` |
| **Assert**    | Verification      | OWN               | Checks that a condition holds true.<br>`Assert the <value> equals <expected>.` |
| **Broadcast** | Communication     | RESPONSE          | Sends to multiple WebSocket recipients.<br>`Broadcast the <message> to the <websocket>.` |
| **Call**      | Control           | OWN               | Invokes a function or service.<br>`Call the <result> via <API: POST /users> with <data>.` |
| **Checkout**  | Git               | OWN               | Switches Git branches via `<git>`. Emits `git.checkout`.<br>`Checkout the <branch> from the <git> with "feature/x".` |
| **Clear**     | Terminal          | OWN               | Clears the terminal screen.<br>`Clear the <screen> for the <terminal>.` |
| **Clone**     | Git               | REQUEST           | Clones a remote repository via `<git>`. Emits `git.clone`.<br>`Clone the <repo> from the <git> with { url: "...", path: "./out" }.` |
| **Close**     | Server            | SERVER            | Terminates a connection or handle.<br>`Close the <database-connections> for the <application>.` |
| **Commit**    | Git               | EXPORT            | Creates a Git commit on `<git>`. Emits `git.commit`.<br>`Commit the <result> to the <git> with "feat: add feature".` |
| **Compare**   | Evaluation        | OWN               | Compares two values or structures.<br>`Compare the <hash> against the <stored-hash>.` |
| **Compute**   | Processing        | OWN               | Performs calculation or algorithm.<br>`Compute the <total> from <price> * <quantity>.` |
| **Connect**   | Server            | SERVER            | Establishes a link between endpoints.<br>`Connect the <socket> to the <host: "localhost">.` |
| **Copy**      | File System       | SERVER            | Duplicates data from one location to another.<br>`Copy the <file: "./a.txt"> to the <destination: "./b.txt">.` |
| **Create**    | Mutation          | OWN               | Makes a new resource or object.<br>`Create the <user> with { name: "Alice" }.` |
| **Delete**    | Mutation          | OWN               | Removes a resource or entry.<br>`Delete the <user> from the <user-repository> where id = <id>.` |
| **Emit**      | Communication     | EXPORT            | Emits an event to the event bus.<br>`Emit a <UserCreated: event> with <user>.` |
| **Execute**   | Control           | OWN               | Runs a system command.<br>`Exec the <result> for the <command> with "ls -la".` |
| **Exists**    | Query             | REQUEST           | Tests whether a resource or value is present.<br>`Exists the <found> for the <file: "./config.json">.` |
| **Extract**   | Data Access       | REQUEST           | Pulls a field from a data structure. PascalCase qualifiers enable typed extraction with OpenAPI schema validation (ARO-0046).<br>`Extract the <user-id> from the <request: body>.`<br>`Extract the <data: UserEvent> from the <event>.` |
| **Filter**    | Enumeration       | OWN               | Selects items matching criteria.<br>`Filter the <active> from the <users> where status = "active".` |
| **Given**     | Testing           | OWN               | Denotes initial precondition in test scenarios.<br>`Given the <user> with { name: "Test" }.` |
| **Group**     | Processing        | OWN               | Partitions a collection into sub-collections by field value.<br>`Group the <by-status> from the <orders> by "status".` |
| **Include**   | Templates         | OWN               | Includes a partial template.<br>`Include the <header> from the <template: "header.tpl">.` |
| **Join**      | Manipulation      | OWN               | Joins a collection with a separator.<br>`Join the <csv-line> from the <fields> by ",".` |
| **Keepalive** | Server            | SERVER            | Blocks execution to keep application alive for external events.<br>`Keepalive the <application> for the <events>.` |
| **List**      | Enumeration       | REQUEST           | Enumerates items in a collection or directory.<br>`List the <files> from the <directory: "./src">.` |
| **Listen**    | Server            | SERVER            | Waits for incoming events or data.<br>`Listen the <keyboard> to the <stdin>.` |
| **Log**       | Monitoring        | RESPONSE          | Records informational/debug output.<br>`Log "Server started" to the <console>.` |
| **Make**      | File System       | SERVER            | Builds or creates a directory.<br>`Make the <output-dir> to the <directory: output-path>.` |
| **Map**       | Processing        | OWN               | Applies a transformation across elements.<br>`Map the <names> from the <users: name>.` |
| **Merge**     | Manipulation      | OWN               | Combines multiple objects or collections into one.<br>`Merge the <existing-user> with <update-data>.` |
| **Move**      | File System       | SERVER            | Transfers or renames files.<br>`Move the <file: "./old.txt"> to the <destination: "./new.txt">.` |
| **Notify**    | Communication     | RESPONSE          | Signals a change or event to observers.<br>`Notify the <alert> to the <admin>.` |
| **ParseHtml** | Processing        | OWN               | Extracts structured data from HTML. Specifiers: `links`, `markdown`, `title`.<br>`ParseHtml the <result: markdown> from the <html>.` |
| **ParseLinkHeader** | Processing   | OWN               | Parses RFC 8288 Link headers for pagination.<br>`Parse the <links: link-header> from the <response>.` |
| **Prompt**    | Terminal          | REQUEST           | Prompts the user for terminal input.<br>`Prompt the <answer> for the <question>.` |
| **Publish**   | Communication     | EXPORT            | Makes a variable globally accessible across feature sets.<br>`Publish as <app-config> <config>.` |
| **Pull**      | Git               | REQUEST           | Pulls remote changes into `<git>`. Emits `git.pull`.<br>`Pull the <updates> from the <git>.` |
| **Push**      | Git               | EXPORT            | Pushes local commits via `<git>`. Emits `git.push`.<br>`Push the <result> to the <git>.` |
| **Read**      | I/O               | REQUEST           | Reads data from a file.<br>`Read the <config> from the <file: "./config.json">.` |
| **Receive**   | Communication     | REQUEST           | Accepts incoming data from external source.<br>`Receive the <message> from the <event>.` |
| **Reduce**    | Processing        | OWN               | Aggregates elements into a summary.<br>`Reduce the <total> from the <amounts> with sum.` |
| **Render**    | Terminal          | RESPONSE          | Renders a terminal UI screen from a template.<br>`Render the <screen> from the <template: "menu.screen">.` |
| **Repaint**   | Terminal          | RESPONSE          | Incrementally updates a terminal screen.<br>`Repaint the <screen> from the <template: "monitor.screen">.` |
| **Request**   | Communication     | REQUEST           | Makes an HTTP request. Returns response object with body, status, headers.<br>`Request the <response> from the <url>.`<br>`Request the <response> to the <url> with <data>.` |
| **Retrieve**  | Data Access       | REQUEST           | Gets existing data by key or identifier from a repository, or `<status>`/`<log>`/`<branch>` from `<git>`.<br>`Retrieve the <user> from the <user-repository> where id = <id>.`<br>`Retrieve the <status> from the <git>.` |
| **Return**    | Control           | RESPONSE          | Sends back a result from a feature set.<br>`Return an <OK: status> with <data>.` |
| **Schedule**  | Communication     | EXPORT            | Schedules a delayed or recurring action.<br>`Schedule the <task> for the <timer> with 5000.` |
| **Select**    | Terminal          | REQUEST           | Presents a terminal selection menu.<br>`Select the <choice> from the <options>.` |
| **Send**      | Communication     | RESPONSE          | Delivers data or message outward.<br>`Send the <message> to the <connection>.` |
| **Show**      | Terminal          | OWN               | Shows content on the terminal.<br>`Show the <content> to the <terminal>.` |
| **Sleep**     | Control           | OWN               | Pauses execution for a duration.<br>`Sleep the <delay> for 1000.` |
| **Sort**      | Enumeration       | OWN               | Orders items in a sequence.<br>`Sort the <users> by <name>.` |
| **Split**     | Manipulation      | OWN               | Breaks a string into parts by regex delimiter.<br>`Split the <words> from the <sentence> by /\s+/.` |
| **Stage**     | Git               | OWN               | Stages files for the next Git commit on `<git>`.<br>`Stage the <files> to the <git> with ".".` |
| **Start**     | Server            | SERVER            | Begins a server or service.<br>`Start the <http-server> with <contract>.` |
| **Stat**      | Inspection        | REQUEST           | Checks metadata or status of a resource.<br>`Stat the <info> for the <file: "./doc.pdf">.` |
| **Stop**      | Server            | SERVER            | Ends a server or service.<br>`Stop the <http-server> with <application>.` |
| **Store**     | Persistence       | RESPONSE          | Saves data to a repository.<br>`Store the <user> into the <user-repository>.` |
| **Stream**    | I/O               | REQUEST           | Reads a file line-by-line as a lazy stream, or subscribes to SSE/WebSocket.<br>`Stream the <lines> from "./bigfile.dat".` |
| **Tag**       | Git               | EXPORT            | Creates a Git tag on `<git>`. Emits `git.tag`.<br>`Tag the <release> for the <git> with "v1.0.0".` |
| **Then**      | Testing           | OWN               | Denotes expected result in test scenarios.<br>`Then the <result> with <expected>.` |
| **Throw**     | Error Handling    | RESPONSE          | Signals an exception or fault.<br>`Throw a <NotFound: error> for the <user>.` |
| **Transform** | Processing        | OWN               | Renders a template with data context.<br>`Transform the <output> from the <template: "welcome.tpl">.` |
| **Update**    | Mutation          | OWN               | Modifies an existing resource or object field.<br>`Update the <user: name> with "Alice".` |
| **Validate**  | Verification      | OWN               | Checks correctness or conformance.<br>`Validate the <data> for the <schema>.` |
| **When**      | Testing           | OWN               | Denotes conditional trigger in test scenarios.<br>`When the <action> from the <feature-set>.` |
| **Write**     | I/O               | RESPONSE          | Writes data to a file.<br>`Write the <data> to the <file: "./output.txt">.` |

## Summary by Semantic Role

- **REQUEST** (13 actions): Extract, Retrieve, Receive, Request, Read, Stream, List, Stat, Exists, Prompt, Select, Pull, Clone
- **OWN** (30 actions): Compute, Validate, Compare, Transform, Create, Update, Delete, Filter, Group, Sort, Split, Merge, Join, Map, ParseHtml, ParseLinkHeader, Reduce, Accept, Given, When, Then, Assert, Call, Execute, Sleep, Clear, Show, Include, Stage, Checkout
- **RESPONSE** (11 actions): Return, Throw, Send, Log, Write, Append, Store, Notify, Broadcast, Render, Repaint
- **EXPORT** (6 actions): Publish, Emit, Schedule, Commit, Push, Tag
- **SERVER** (9 actions): Start, Stop, Listen, Connect, Close, Keepalive, Make, Copy, Move

## Summary by Category

- **Communication** (7): Send, Receive, Request, Notify, Publish, Emit, Schedule
- **Control** (4): Execute, Call, Return, Sleep
- **Data Access** (2): Extract, Retrieve
- **Enumeration** (3): List, Filter, Sort
- **Error Handling** (1): Throw
- **Evaluation** (1): Compare
- **File System** (3): Make, Copy, Move
- **Git** (7): Stage, Commit, Push, Pull, Clone, Checkout, Tag
- **I/O** (4): Read, Stream, Write, Append
- **Inspection** (1): Stat
- **Manipulation** (3): Split, Merge, Join
- **Monitoring** (1): Log
- **Mutation** (3): Create, Update, Delete
- **Persistence** (1): Store
- **Processing** (7): Compute, Transform, Map, Group, ParseHtml, ParseLinkHeader, Reduce
- **Protocol** (1): Accept
- **Query** (1): Exists
- **Server** (6): Start, Stop, Listen, Connect, Close, Keepalive
- **Templates** (1): Include
- **Terminal** (6): Prompt, Select, Clear, Show, Render, Repaint
- **Testing** (4): Given, When, Then, Assert
- **Verification** (1): Validate
