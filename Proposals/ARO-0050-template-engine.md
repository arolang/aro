# ARO-0050: Template Engine

* Proposal: ARO-0050
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0002, ARO-0004, ARO-0005, ARO-0008, ARO-0009

## Abstract

This proposal defines ARO's template engine for dynamic content generation. Templates reside in the `./templates/` directory and are rendered using the `<Transform>` action with isolated execution contexts. Templates support full ARO statements inside `{{ }}` execution blocks, variable interpolation, control structures like for-each spanning blocks, and nested template inclusion. In compiled binaries, templates are bundled as embedded resources for self-contained deployment.

## 1. Introduction

Template rendering is essential for generating dynamic HTML, emails, reports, and other text-based outputs. ARO's template engine integrates seamlessly with the language's action-based paradigm:

1. **Template Directory Convention**: Templates live in `./templates/`
2. **Context Isolation**: Templates receive a cloned context - nothing bleeds back
3. **Full ARO Power**: Any ARO statement is valid inside execution blocks
4. **Print Action Extension**: `<Print>` outputs directly to the template result
5. **Spanning Control Structures**: For-each loops that span across template text
6. **Nested Templates**: `<Include>` for template composition
7. **Binary Bundling**: Templates embedded in compiled binaries

### Architecture Overview

```
+------------------+     +------------------+     +------------------+
|  Feature Set     | --> | Transform      | --> | Template Engine  |
|  Context         |     | template: foo    |     |                  |
+------------------+     +------------------+     +------------------+
        |                        |                        |
        v                        v                        v
+------------------+     +------------------+     +------------------+
| Variables:       |     | Clone Context    |     | Parse Template   |
| - user           | --> | (Isolation)      | --> | - Static text    |
| - items          |     |                  |     | - {{ blocks }}   |
+------------------+     +------------------+     +------------------+
                                                          |
                         +------------------+             |
                         | Rendered String  | <-----------+
                         | (result bound)   |
                         +------------------+
```

## 2. Template Directory Convention

### 2.1 Directory Structure

Templates are stored in a `templates/` directory relative to the application root:

```
MyApp/
├── main.aro
├── users.aro
├── openapi.yaml
└── templates/
    ├── welcome.tpl
    ├── user-profile.html
    └── emails/
        ├── confirmation.tpl
        └── reset-password.tpl
```

### 2.2 Path Syntax

The `template:` qualifier specifies the template path relative to `./templates/`:

| Qualifier | Resolves To |
|-----------|-------------|
| `template: welcome.tpl` | `./templates/welcome.tpl` |
| `template: emails/confirmation.tpl` | `./templates/emails/confirmation.tpl` |
| `template: reports/monthly/summary.html` | `./templates/reports/monthly/summary.html` |

## 3. Transform Action Extension

### 3.1 Syntax

The existing `<Transform>` action is extended to support template rendering:

```aro
Transform the <result> from the <template: path>.
```

### 3.2 Examples

```aro
(* Simple template rendering *)
Transform the <html> from the <template: welcome.tpl>.

(* Template with path variable *)
Create the <template-name> with "user-profile.html".
Transform the <output> from the <template: template-name>.

(* Render and return in HTTP response *)
Transform the <page> from the <template: home.html>.
Return an <OK: status> with <page>.
```

### 3.3 Semantic Role

Transform remains an OWN action (internal computation). The template is read, executed in isolation, and the rendered string is bound to the result variable.

## 4. Context Isolation

### 4.1 Cloned Context

When rendering a template, the engine:

1. Creates a child context via `createChild(featureSetName:)`
2. Copies all current variable bindings to the child
3. Executes template statements in the child context
4. Returns only the rendered string - no variable changes propagate back

### 4.2 Isolation Diagram

```
Parent Context               Template Execution              Result
+-------------+              +------------------+            +---------+
| user: {...} |   Clone      | user: {...}      |   Return   | rendered|
| items: [...] | --------->  | items: [...]     | -------->  | string  |
| count: 5    |              | count: 5         |            +---------+
+-------------+              | temp: "local"    |
                             +------------------+
                                   |
                       Variables created in template
                       stay in template context only
```

### 4.3 Why Isolation?

- **Safety**: Template code cannot corrupt parent state
- **Predictability**: Same template, same input = same output
- **Consistency**: Aligns with ARO's immutable variable philosophy

## 5. Template Syntax

### 5.1 Execution Blocks

Template execution blocks are delimited by `{{` and `}}`:

```
Static content here...
{{ <ARO statement> }}
More static content...
```

### 5.2 Static Text

Everything outside `{{ }}` is static template text that passes through unchanged.

### 5.3 ARO Statements in Blocks

Any valid ARO statement can appear inside execution blocks:

```html
<html>
<body>
{{ Extract the <name> from the <user: name>. }}
{{ Compute the <greeting> from "Hello, " ++ <name> ++ "!". }}
<h1>{{ Print <greeting> to the <template>. }}</h1>
</body>
</html>
```

### 5.4 Multiple Statements

Multiple statements can appear in a single block:

```
{{
    Extract the <first-name> from the <user: firstName>.
    Extract the <last-name> from the <user: lastName>.
    Compute the <full-name> from <first-name> ++ " " ++ <last-name>.
    Print <full-name> to the <template>.
}}
```

## 6. Print to Template

### 6.1 The Template Target

The `<Print>` action is extended with the `template` target:

```aro
Print expression to the <template>.
```

### 6.2 Behavior

- Output is appended to the template result buffer
- Supports all sink syntax expressions (strings, variables, literals)
- Only valid inside template execution context

### 6.3 Examples

```
{{ Print "Hello, World!" to the <template>. }}
{{ Print <user: name> to the <template>. }}
{{ Print <count> * 100 to the <template>. }}
```

## 7. Variable Interpolation Shorthand

### 7.1 Syntax

For simple variable output, a shorthand syntax avoids full `<Print>` statements:

```
{{ <variable> }}
{{ <variable: property> }}
```

### 7.2 Equivalence

```
{{ <user: name> }}
```

Is equivalent to:

```
{{ Print <user: name> to the <template>. }}
```

### 7.3 Expression Support

The shorthand supports any expression that evaluates to a printable value:

```
{{ <count> }}
{{ <user: name> }}
{{ <price> * 1.1 }}
{{ <first-name> ++ " " ++ <last-name> }}
```

## 8. For-Each Spanning Blocks

### 8.1 Syntax

For-each loops can span across static template content:

```
{{ for each <item> in <collection> { }}
    Static content with {{ <item: property> }}
{{ } }}
```

### 8.2 Block Structure

- **Opening block**: `{{ for each <var> in <collection> { }}`
- **Body**: Static text with embedded `{{ }}` blocks
- **Closing block**: `{{ } }}`

### 8.3 Examples

**List rendering:**
```html
<ul>
{{ for each <user> in <users> { }}
    <li>{{ <user: name> }} - {{ <user: email> }}</li>
{{ } }}
</ul>
```

**Table rows:**
```html
<table>
  <thead><tr><th>Name</th><th>Price</th></tr></thead>
  <tbody>
{{ for each <product> in <products> { }}
    <tr>
      <td>{{ <product: name> }}</td>
      <td>{{ <product: price> }}</td>
    </tr>
{{ } }}
  </tbody>
</table>
```

### 8.4 Index Variable

The `at <index>` syntax provides access to iteration index:

```
{{ for each <item> at <idx> in <items> { }}
    {{ <idx> }}. {{ <item> }}
{{ } }}
```

### 8.5 Nested Loops

Loops can be nested:

```html
{{ for each <category> in <categories> { }}
<div class="category">
  <h2>{{ <category: name> }}</h2>
  <ul>
  {{ for each <product> in <category: products> { }}
    <li>{{ <product: name> }}</li>
  {{ } }}
  </ul>
</div>
{{ } }}
```

## 9. Conditional Rendering

### 9.1 Guarded Print

Use when guards for conditional output:

```
{{ Print "Premium User" to the <template> when <user: isPremium> = true. }}
```

### 9.2 Match Expression

Match expressions work in templates:

```
{{ match <status> {
    case "active" {
        Print "<span class='active'>Active</span>" to the <template>.
    }
    case "pending" {
        Print "<span class='pending'>Pending</span>" to the <template>.
    }
    otherwise {
        Print "<span class='unknown'>Unknown</span>" to the <template>.
    }
} }}
```

## 10. Nested Templates (Include)

### 10.1 Syntax

The `<Include>` action embeds another template:

```aro
{{ Include the <template: header.tpl>. }}
```

### 10.2 Context Inheritance

Included templates:
- Receive the current template's context (which is already a clone)
- Can access all variables from the parent template
- Cannot modify the parent template's variables

### 10.3 Examples

**Base layout:**
```html
<!-- templates/layout.html -->
<!DOCTYPE html>
<html>
<head>
  <title>{{ <page-title> }} | MyApp</title>
</head>
<body>
  {{ Include the <template: partials/header.tpl>. }}

  <main>
    {{ Print <content> to the <template>. }}
  </main>

  {{ Include the <template: partials/footer.tpl>. }}
</body>
</html>
```

**Partial template:**
```html
<!-- templates/partials/header.tpl -->
<header>
  <nav>
    <a href="/">Home</a>
    {{ Print " | " to the <template> when <user> exists. }}
    {{ Print <user: name> to the <template> when <user> exists. }}
  </nav>
</header>
```

### 10.4 Include with Override Variables

Use `with` to pass/override variables to included template:

```
{{ Include the <template: user-card.tpl> with { user: <current-user>, showDetails: true }. }}
```

## 11. Examples

### 11.1 Simple Email Template

**templates/welcome-email.tpl:**
```
Dear {{ <user: firstName> }},

Welcome to our service! Your account has been created with the following details:

Email: {{ <user: email> }}
Plan: {{ <user: plan> }}

{{ Print "Your premium benefits are now active!" to the <template> when <user: plan> = "premium". }}

Best regards,
The Team
```

**Usage:**
```aro
(Send Welcome Email: UserCreated Handler) {
    Extract the <user> from the <event: user>.
    Transform the <email-body> from the <template: welcome-email.tpl>.
    Send the <email-body> to the <user: email>.
    Return an <OK: status> for the <notification>.
}
```

### 11.2 HTML Page with Loop

**templates/user-list.html:**
```html
<!DOCTYPE html>
<html>
<head><title>Users</title></head>
<body>
  <h1>User Directory</h1>
  {{ Compute the <user-count: length> from <users>. }}
  <p>Total users: {{ <user-count> }}</p>

  <table>
    <thead>
      <tr><th>#</th><th>Name</th><th>Email</th></tr>
    </thead>
    <tbody>
{{ for each <user> at <idx> in <users> { }}
      <tr>
        <td>{{ <idx> }}</td>
        <td>{{ <user: name> }}</td>
        <td>{{ <user: email> }}</td>
      </tr>
{{ } }}
    </tbody>
  </table>
</body>
</html>
```

**Usage:**
```aro
(listUsersPage: User UI) {
    Retrieve the <users> from the <user-repository>.
    Transform the <html> from the <template: user-list.html>.
    Return an <OK: status> with <html>.
}
```

### 11.3 Nested Templates with Layout

**templates/layout.tpl:**
```html
<!DOCTYPE html>
<html>
<head>
  <title>{{ <title> }} | MyApp</title>
  {{ Include the <template: partials/head.tpl>. }}
</head>
<body>
  {{ Include the <template: partials/nav.tpl>. }}
  <main>
    {{ Print <body-content> to the <template>. }}
  </main>
  {{ Include the <template: partials/footer.tpl>. }}
</body>
</html>
```

**templates/pages/dashboard.tpl:**
```html
{{
    Create the <title> with "Dashboard".
}}
<h1>Welcome, {{ <user: name> }}</h1>
<div class="stats">
{{ for each <stat> in <stats> { }}
  <div class="stat-card">
    <h2>{{ <stat: label> }}</h2>
    <p>{{ <stat: value> }}</p>
  </div>
{{ } }}
</div>
```

## 12. Binary Mode Compilation

When using `aro build`, all templates from `./templates/` are bundled into the final binary for self-contained deployment.

### 12.1 Build-Time Behavior

```
./templates/          BuildCommand.swift         LLVMCodeGenerator
      |                      |                          |
      v                      v                          v
+------------+       +---------------+          +---------------+
| welcome.tpl| ----> | Read & Encode | -------> | Embed as LLVM |
| users.html |       | to JSON       |          | IR constants  |
| partials/  |       +---------------+          +---------------+
+------------+              |                          |
                            v                          v
                    +---------------+          +---------------+
                    | Template      |          | @.tpl.welcome |
                    | Manifest      |          | @.tpl.users   |
                    +---------------+          +---------------+
```

1. `BuildCommand.swift` discovers all files in `./templates/` directory
2. Each template file is read and serialized (with path as key)
3. Templates are embedded as LLVM IR string constants
4. A manifest maps template paths to embedded data

### 12.2 Runtime Behavior

```
TemplateService.load("welcome.tpl")
         |
         v
+------------------+
| Check embedded   |-----> Found: Return embedded content
| templates        |
+------------------+
         |
         v (not found)
+------------------+
| Fall back to     |-----> Read from ./templates/
| file system      |
+------------------+
```

1. `TemplateService` first checks for embedded templates
2. Falls back to file system if not found (enables development mode)
3. No external template files needed for production deployment

### 12.3 LLVM IR Pattern

Similar to OpenAPI embedding:

```llvm
; Template content embedded as string constants
@.tpl.welcome = private unnamed_addr constant [256 x i8] c"Dear {{ <user: firstName> }}...\00"
@.tpl.users = private unnamed_addr constant [1024 x i8] c"<!DOCTYPE html>...\00"

; Manifest mapping paths to templates
@.tpl.manifest = private unnamed_addr constant [128 x i8] c"{\"welcome.tpl\":0,\"users.html\":1}\00"
```

### 12.4 Benefits

- **Self-contained binaries**: Single executable with all templates included
- **No deployment complexity**: No need to manage separate template files
- **Consistent versioning**: Templates always match the application version
- **Development flexibility**: File system fallback enables rapid iteration

## 13. Grammar

### 13.1 Template File Grammar

```ebnf
template_file     = { template_segment } ;

template_segment  = static_text
                  | execution_block
                  | foreach_open
                  | foreach_close ;

static_text       = { character - "{{" } ;

execution_block   = "{{" , whitespace , block_content , whitespace , "}}" ;

block_content     = statement_list
                  | expression_shorthand ;

statement_list    = { aro_statement } ;

expression_shorthand = expression ;

foreach_open      = "{{" , whitespace , "for" , "each" ,
                    "<" , identifier , ">" ,
                    [ "at" , "<" , identifier , ">" ] ,
                    "in" , "<" , qualified_noun , ">" ,
                    [ "where" , condition ] ,
                    "{" , whitespace , "}}" ;

foreach_close     = "{{" , whitespace , "}" , whitespace , "}}" ;
```

### 13.2 Transform Action Extension

```ebnf
transform_template = "<Transform>" , "the" , "<" , result_noun , ">" ,
                     "from" , "the" , "<" , template_reference , ">" , "." ;

template_reference = "template:" , template_path ;

template_path      = string_literal | identifier ;
```

### 13.3 Print to Template

```ebnf
print_to_template = "<Print>" , expression , "to" , "the" , "<template>" , "." ;
```

### 13.4 Include Action

```ebnf
include_template  = "<Include>" , "the" , "<" , template_reference , ">" ,
                    [ "with" , object_literal ] , "." ;
```

## 14. Implementation Considerations

### 14.1 TemplateService Protocol

```swift
public protocol TemplateService: Sendable {
    func render(
        templatePath: String,
        context: ExecutionContext
    ) async throws -> String

    func load(templatePath: String) async throws -> String
}
```

### 14.2 Template Parser

The template parser tokenizes template files into segments:

```swift
enum TemplateSegment {
    case staticText(String)
    case executionBlock([Statement])
    case expressionShorthand(Expression)
    case forEachOpen(itemVar: String, indexVar: String?, collection: QualifiedNoun)
    case forEachClose
}
```

### 14.3 Template Executor

```swift
public final class TemplateExecutor {
    func render(
        template: ParsedTemplate,
        context: ExecutionContext
    ) async throws -> String {
        // 1. Create isolated child context
        let childContext = context.createChild(featureSetName: "template")

        // 2. Create output buffer
        var output = ""

        // 3. Process segments
        for segment in template.segments {
            switch segment {
            case .staticText(let text):
                output += text
            case .executionBlock(let statements):
                try await executeStatements(statements, context: childContext)
                output += childContext.flushTemplateBuffer()
            // ... handle other segment types
            }
        }

        return output
    }
}
```

### 14.4 Template Buffer in Context

The execution context is extended with a template output buffer:

```swift
extension ExecutionContext {
    func appendToTemplateBuffer(_ value: String)
    func flushTemplateBuffer() -> String
}
```

## 15. Error Handling

Following ARO's error philosophy, template errors are descriptive:

### 15.1 Template Not Found

```
Error: Template not found: ./templates/missing.tpl
```

### 15.2 Parse Errors

```
Error: Template parse error in welcome.tpl at line 5:
  Unclosed execution block - expected "}}"
```

### 15.3 Runtime Errors

```
Error: Can not extract the <name> from the <user: name> in template welcome.tpl
  The variable <user> is not defined in the template context.
```

## 16. Design Decisions

### 16.1 Why `{{ }}` Delimiters?

- Familiar from Jinja2, Mustache, Handlebars
- Does not conflict with HTML `< >` or ARO `< >`
- Clear visual distinction from static content

### 16.2 Why Context Isolation?

- Prevents side effects from templates modifying parent state
- Makes templates pure functions of their input
- Enables safe template composition and caching

### 16.3 Why Extend Transform?

- Transform already handles data transformation semantically
- Avoids adding a new action verb
- Template rendering is a transformation: template + context -> string

### 16.4 Why Bundle in Binary?

- Self-contained deployment with single executable
- No file management complexity in production
- Templates and code always in sync
- File system fallback preserves development experience

## Summary

| Aspect | Description |
|--------|-------------|
| **Directory** | `./templates/` relative to application |
| **Path Syntax** | `template: path/to/file.tpl` |
| **Action** | `Transform the <result> from the <template: path>.` |
| **Execution Blocks** | `{{ <statement> }}` |
| **Variable Shorthand** | `{{ <variable> }}` |
| **Output Action** | `Print expression to the <template>.` |
| **For-Each** | `{{ for each <item> in <list> { }} ... {{ } }}` |
| **Include** | `{{ Include the <template: partial.tpl>. }}` |
| **Isolation** | Context cloned, no bleed-back |
| **Binary Mode** | Templates embedded in compiled binary |

## References

- `Sources/ARORuntime/Core/ExecutionContext.swift` - Context cloning via `createChild()`
- `Sources/ARORuntime/Core/FeatureSetExecutor.swift` - ForEachLoop execution pattern
- `Sources/ARORuntime/Actions/BuiltIn/ResponseActions.swift` - LogAction as Print model
- `Sources/ARORuntime/FileSystem/FileSystemService.swift` - File reading pattern
- `Sources/AROParser/AST.swift` - ForEachLoop AST structure
- `Sources/AROCLI/Commands/BuildCommand.swift` - OpenAPI embedding pattern
- `Sources/AROCompiler/LLVMC/LLVMCodeGenerator.swift` - LLVM IR generation
- ARO-0001: Language Fundamentals - Core syntax
- ARO-0002: Control Flow - For-each loops
- ARO-0004: Actions - Action roles and extensions
- ARO-0005: Application Architecture - Context management
- ARO-0008: I/O Services - File system patterns
- ARO-0009: Native Compilation - Binary bundling
