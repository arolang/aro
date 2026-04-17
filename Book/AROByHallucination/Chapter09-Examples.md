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
    Retrieve the <user> from the <user-repository> where id = <id>.
    Return an <OK: status> with <user>.
}

(deleteUser: User Service) {
    Extract the <id> from the <pathParameters: id>.
    Retrieve the <user> from the <user-repository> where id = <id>.
    Delete the <user> from the <user-repository> where id = <id>.
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
[]
$ curl -s -X POST localhost:8080/users -H 'Content-Type: application/json' -d '{"name":"Ada","email":"ada@example.com"}'
{"id":"1","name":"Ada","email":"ada@example.com"}
$ curl -s localhost:8080/users
[{"id":"1","name":"Ada","email":"ada@example.com"}]
$ curl -s localhost:8080/users/1
{"id":"1","name":"Ada","email":"ada@example.com"}
```

Three files. Two minutes. A working REST API.

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
File watcher starting...
```

In another terminal:

```bash
$ echo "hello" > test.txt
$ echo "world" >> test.txt
$ rm test.txt
```

Back in the first terminal:

```
[created] ./test.txt
[modified] ./test.txt
[deleted] ./test.txt
```

One file. One prompt. A working file watcher.

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

The model calls `aro_check`. Passes. The qualifier is referenced as `SlugGenerator.slug` — the handle from `plugin.yaml` dot the qualifier name from `aro_plugin_info`.

### The Full Picture

Three prompts. A plugin directory with a manifest and source. A feature set that uses the plugin's qualifier. Everything checked, everything parseable, everything following the conventions documented in the proposals.

The model did not memorise the C ABI for ARO plugins. It was trained on the proposals and the examples in the `Examples/` directory, and it applied that knowledge through its tools. The `create_plugin` tool gave it the scaffold. The `read_file` tool let it see the stub. The `edit_file` tool let it fill in the implementation. The `aro_check` tool confirmed it worked.

That is the tool-call loop doing what it was designed to do: turning a description of what you want into a project that works, one verified step at a time.

---

## 9.4 What the Examples Show

All three examples follow the same arc. You describe what you want. The model reads the project, writes files, and checks its work. You review the result and run it. The conversation is short — three to five turns — because the model has tools that let it act instead of explain.

The examples also show what the model does *not* do. It does not write tests unless you ask. It does not set up deployment. It does not make architectural decisions about things you did not mention. It stays in its lane: ARO code, ARO tooling, ARO conventions. Everything else is yours.

That division of labour is the point. The model handles the syntax, the boilerplate, the mechanical correctness. You handle the design, the naming, the business logic that only you know. Between the two of you, a working application emerges faster than either of you could produce alone.
