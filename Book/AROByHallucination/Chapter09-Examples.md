\newpage

# Chapter 9: Worked Examples

> "Theory is what you know before you try it. Practice is what you know after."

---

## 9.1 Example 1: A User Service from Scratch

This example builds a complete REST API for managing users — list, create, get, delete — using nothing but `aro ask` in a fresh directory.

### The Opening Prompt

```
$ mkdir UserService && cd UserService
$ aro ask
lm> create an openapi.yaml for a user service with CRUD operations on /users and /users/{id}
```

The model calls `write_openapi` and produces:

```yaml
openapi: 3.0.3
info:
  title: User Service
  version: 1.0.0
paths:
  /users:
    get:
      operationId: listUsers
      summary: List all users
      responses:
        '200':
          description: OK
    post:
      operationId: createUser
      summary: Create a user
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
              properties:
                name:
                  type: string
                email:
                  type: string
      responses:
        '201':
          description: Created
  /users/{id}:
    get:
      operationId: getUser
      summary: Get a user by ID
      parameters:
        - name: id
          in: path
          required: true
          schema:
            type: string
      responses:
        '200':
          description: OK
    delete:
      operationId: deleteUser
      summary: Delete a user
      parameters:
        - name: id
          in: path
          required: true
          schema:
            type: string
      responses:
        '204':
          description: Deleted
```

The model then says it has written `openapi.yaml`. The tool call log shows a single `write_openapi` call. No edits needed.

### The Application Start

```
lm> write main.aro with Application-Start that starts the HTTP server
```

The model calls `write_file` with path `main.aro`:

```aro
(Application-Start: User Service) {
    Log "User Service starting..." to the <console>.
    Start the <http-server> with <contract>.
    Keepalive the <application> for the <events>.
    Return an <OK: status> for the <startup>.
}
```

Then it calls `aro_check` on the directory. The check passes.

### The Feature Sets

```
lm> write users.aro with feature sets for all four operations in the OpenAPI spec
```

The model calls `read_file` on `openapi.yaml` to refresh its memory of the operationIds, then calls `write_file` with path `users.aro`:

```aro
(listUsers: User Service) {
    Retrieve the <users> from the <user-repository>.
    Return an <OK: status> with <users>.
}

(createUser: User Service) {
    Extract the <data> from the <request: body>.
    Create the <user> with <data>.
    Store the <user> to the <user-repository>.
    Emit a <UserCreated: event> with <user>.
    Return a <Created: status> with <user>.
}

(getUser: User Service) {
    Extract the <id> from the <pathParameters: id>.
    Retrieve the <user> from the <user-repository> where id is <id>.
    Return an <OK: status> with <user>.
}

(deleteUser: User Service) {
    Extract the <id> from the <pathParameters: id>.
    Retrieve the <user> from the <user-repository> where id is <id>.
    Delete the <removed> from the <user-repository> where id is <id>.
    Emit a <UserDeleted: event> with <user>.
    Return a <NoContent: status> for the <deletion>.
}
```

The model calls `aro_check`. The check passes. Four feature sets, four endpoints, all matching the OpenAPI contract.

### Running It

```
lm> /quit
$ aro run .
User Service starting...
HTTP server listening on 0.0.0.0:8080
```

In another terminal:

```bash
$ curl -s localhost:8080/users
{"data":[]}
$ curl -s -X POST localhost:8080/users \
    -H 'Content-Type: application/json' \
    -d '{"name":"Ada","email":"ada@example.com"}'
{"email":"ada@example.com","name":"Ada"}
$ curl -s localhost:8080/users
{"data":[{"email":"ada@example.com","id":"7238552A-548A-4A2D-A932-4C00BFB7D86B","name":"Ada"}]}
$ curl -s localhost:8080/users/7238552A-548A-4A2D-A932-4C00BFB7D86B
{"id":"7238552A-548A-4A2D-A932-4C00BFB7D86B","name":"Ada"}
$ curl -s -X DELETE localhost:8080/users/7238552A-548A-4A2D-A932-4C00BFB7D86B -o /dev/null -w '%{http_code}\n'
204
$ curl -s localhost:8080/users
{"data":[]}
```

Three files. Two minutes. A working REST API.

Look closely at that session, because three things in it will surprise you and none of them are bugs.

**A list comes back wrapped.** `Return an <OK: status> with <users>.` produces `{"data": [...]}`, not a bare array. The envelope is the runtime's, not yours.

**Ids are UUIDs, and the create response does not have one.** The repository assigns the id when the value is stored. `<user>` was bound by `Create` before that happened, so the `Created` response carries only the fields you sent. If you want the id back, retrieve the stored record and return that instead.

**`where id is <id>` compares against the real id.** Which means `GET /users/1` returns `{"data":[]}` — not a 404, an empty result — and `DELETE /users/1` returns `204` having deleted nothing. Both are the happy path doing exactly what it was asked. If you sketch this API from memory and test it with `/users/1`, you will conclude that delete is broken. It is not; your id is.

---

## 9.2 Example 2: A File Watcher

This example builds an application that watches a directory for changes and logs them.

### The Prompt

```
$ mkdir FileWatcher && cd FileWatcher
$ aro ask "create an ARO application that watches the current directory for file changes and logs each change to the console"
```

This time we use one-shot mode. The model makes several tool calls in sequence:

1. `list_dir` on `.` — empty directory, nothing to conflict with.
2. `write_file` for `main.aro`:

```aro
(Application-Start: File Watcher) {
    Log "File watcher starting..." to the <console>.
    Start the <file-monitor> with ".".
    Keepalive the <application> for the <events>.
    Return an <OK: status> for the <startup>.
}

(File Changed: File Event Handler) {
    Extract the <path> from the <event: path>.
    Extract the <kind> from the <event: kind>.
    Compute the <message> from "[" ++ <kind> ++ "] " ++ <path>.
    Log <message> to the <console>.
    Return an <OK: status> for the <notification>.
}
```

3. `aro_check` on `.` — passes.

The model replies: "Created `main.aro` with two feature sets. `Application-Start` starts a file monitor on the current directory and keeps the application alive. `File Changed` handles file events by extracting the path and kind and logging them. Run with `aro run .`."

### Testing It

```bash
$ aro run .
[Application-Start] File watcher starting...
```

In another terminal:

```bash
$ echo "hello" > test.txt
$ echo "world" >> test.txt
$ rm test.txt
```

Back in the first terminal:

```
```

Nothing. Not an error — nothing at all. This is the best example in the book of a hallucination that survives every check you have.

Two things are wrong, and neither is visible.

**A `File Event Handler` subscribes by its own name.** The runtime looks for the words `created`, `modified` or `deleted` *in the feature-set name* and wires it to that event. A handler called `File Changed` names none of the three and therefore receives all three; read `<event: kind>` to tell them apart. It used to subscribe to nothing and be dead code, with no warning from `aro check` (GitLab #570).

**There is no `kind` field.** The event payload is `{ path }` and nothing else, so one handler could not distinguish the three events even if it did fire. `[created]` was never going to be printable.

The working version needs one feature set per event:

```aro
(Application-Start: File Watcher) {
    Log "File watcher starting..." to the <console>.
    Start the <file-monitor> with ".".
    Keepalive the <application> for the <events>.
    Return an <OK: status> for the <startup>.
}

(Handle File Created: File Event Handler) {
    Extract the <path> from the <event: path>.
    Compute the <message> from "[created] " ++ <path>.
    Log <message> to the <console>.
    Return an <OK: status> for the <notification>.
}

(Handle File Modified: File Event Handler) {
    Extract the <path> from the <event: path>.
    Compute the <message> from "[modified] " ++ <path>.
    Log <message> to the <console>.
    Return an <OK: status> for the <notification>.
}

(Handle File Deleted: File Event Handler) {
    Extract the <path> from the <event: path>.
    Compute the <message> from "[deleted] " ++ <path>.
    Log <message> to the <console>.
    Return an <OK: status> for the <notification>.
}
```

Now the terminal says what you expected — noting that `path` is absolute, not the `./test.txt` you typed:

```
[Handle File Created] [created] /home/you/FileWatcher/test.txt
[Handle File Modified] [modified] /home/you/FileWatcher/test.txt
[Handle File Deleted] [deleted] /home/you/FileWatcher/test.txt
```

One file. One prompt. One convention the model did not know, that no tool in the loop could have caught, and that only running the thing revealed. Chapter 8's advice — *run it yourself, do not just have the model check it* — is this example.

---

## 9.3 Example 3: A Plugin from Scratch

This example builds a Swift plugin that provides a `slug` qualifier — converting a string like "Hello World" into "hello-world".

### Scaffolding

```
$ cd MyApp
$ aro ask
lm> /plugin slug-generator
```

The model calls `create_plugin` with the name `slug-generator`. This creates:

```
Plugins/
└── slug-generator/
    ├── plugin.yaml
    └── Sources/
        └── SlugGenerator.swift
```

The model reports the scaffold is ready.

### Defining the Plugin

```
lm> update the plugin.yaml to provide a slug qualifier with handle SlugGenerator, then implement it in the Swift source
```

The model calls `edit_file` on `Plugins/slug-generator/plugin.yaml`:

```yaml
name: slug-generator
version: 1.0.0
handle: SlugGenerator
provides:
  - type: swift-plugin
    path: Sources/
```

Then it calls `read_file` on `Sources/SlugGenerator.swift` to see the stub, and `edit_file` to replace it:

```swift
import Foundation

@_cdecl("aro_plugin_info")
public func pluginInfo() -> UnsafeMutablePointer<CChar> {
    let info = """
    {
        "name": "slug-generator",
        "version": "1.0.0",
        "qualifiers": ["slug"]
    }
    """
    return strdup(info)
}

@_cdecl("aro_plugin_qualifier")
public func pluginQualifier(
    _ qualifier: UnsafePointer<CChar>,
    _ inputJSON: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar> {
    let qual = String(cString: qualifier)
    let input = String(cString: inputJSON)
    
    guard qual == "slug" else {
        return strdup("{\"error\": \"unknown qualifier\"}")
    }
    
    // Parse the input JSON to extract the value
    let value = input
        .replacingOccurrences(of: "{\"value\":\"", with: "")
        .replacingOccurrences(of: "\"}", with: "")
    
    let slug = value
        .lowercased()
        .replacingOccurrences(of: " ", with: "-")
        .filter { $0.isLetter || $0.isNumber || $0 == "-" }
    
    return strdup("{\"value\": \"\(slug)\"}")
}

@_cdecl("aro_plugin_execute")
public func pluginExecute(
    _ action: UnsafePointer<CChar>,
    _ inputJSON: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar> {
    return strdup("{\"error\": \"no actions provided\"}")
}

@_cdecl("aro_plugin_free")
public func pluginFree(_ ptr: UnsafeMutablePointer<CChar>) {
    free(ptr)
}
```

The model calls `aro_check` on the project root. Passes.

### Using the Plugin

```
lm> write a feature set that uses the slug qualifier on a title extracted from the request body
```

The model calls `write_file` to create `slugify.aro`:

```aro
(createPost: Blog API) {
    Extract the <title> from the <request: body>.
    Compute the <slug: SlugGenerator.slug> from the <title>.
    Compute the <post> from <title> and <slug>.
    Store the <post> to the <post-repository>.
    Return a <Created: status> with <post>.
}
```

The model calls `aro_check`. Passes. The qualifier is referenced as `SlugGenerator.slug` — the handle from `plugin.yaml` dot the qualifier name from `aro_plugin_info`. That part is right.

Two of the other five lines are not, and the check cannot see either.

`Extract the <title> from the <request: body>.` binds the *whole* body, not its `title` field. You get an object where you wanted a string, and the slug qualifier is handed something it was not written for.

`Compute the <post> from <title> and <slug>.` is worse. `and` is a boolean operator, so `<post>` is the literal value `true`. That is what gets stored, and that is what `Return a <Created: status> with <post>.` sends to the client. A `201` with `true` in the body, from a feature set that checks clean.

Here is the version that does what the sentence claims:

```aro
(createPost: Blog API) {
    Extract the <body> from the <request: body>.
    Extract the <title> from the <body: title>.
    Compute the <slug: SlugGenerator.slug> from the <title>.
    Create the <post> with { title: <title>, slug: <slug> }.
    Store the <post> into the <post-repository>.
    Return a <Created: status> with <post>.
}
```

`Create … with { … }` builds a record; `Compute … from <a> and <b>` computes a boolean. The two read almost identically in English and share no behaviour at all, which is precisely why a model trained on English prose reaches for the wrong one.

### The Full Picture

Three prompts. A plugin directory with a manifest and source. A feature set that uses the plugin's qualifier. Everything checked, everything parseable — and, until you read it, two lines that would have shipped `true` as a blog post.

The model did not memorise the C ABI for ARO plugins. It was trained on the proposals and the examples in the `Examples/` directory, and it applied that knowledge through its tools. The `create_plugin` tool gave it the scaffold. The `read_file` tool let it see the stub. The `edit_file` tool let it fill in the implementation. The `aro_check` tool confirmed it worked.

That is the tool-call loop doing what it was designed to do: turning a description of what you want into a project that works, one verified step at a time.

---

## 9.4 What the Examples Show

All three examples follow the same arc. You describe what you want. The model reads the project, writes files, and checks its work. You review the result and run it. The conversation is short — three to five turns — because the model has tools that let it act instead of explain.

They also show, three times in a row, the same thing going wrong. `aro check` passed in every one of them. The API returned a `204` for a delete that deleted nothing; the file watcher printed nothing at all; the blog endpoint stored `true`. Not one of those is a syntax error, so not one of them was catchable by the tool the model reaches for.

That is the boundary. The model is reliable on grammar and unreliable on semantics, and `aro check` is a grammar checker. The review you owe the code is the semantic one — *does this statement mean what its sentence says?* — and you cannot delegate it to the same system that wrote the sentence.

The examples also show what the model does *not* do. It does not write tests unless you ask. It does not set up deployment. It does not make architectural decisions about things you did not mention. It stays in its lane: ARO code, ARO tooling, ARO conventions. Everything else is yours.

That division of labour is the point. The model handles the syntax, the boilerplate, the mechanical correctness. You handle the design, the naming, the business logic that only you know. Between the two of you, a working application emerges faster than either of you could produce alone.
