# Template Engine Example

This example demonstrates the ARO-0050 Template Engine syntax (formerly ARO-0045).

> **Status**: The template engine is fully implemented. This example shows all supported features.

## Features Demonstrated

| Feature | File | Description |
|---------|------|-------------|
| Variable interpolation | `user-list.html` | `{{ <user: name> }}` |
| For-each spanning blocks | `user-list.html` | `{{ for each <user> in <users> { }} ... {{ } }}` |
| Index variable | `user-list.html` | `{{ for each <user> at <idx> in <users> { }}` |
| Match expressions | `user-list.html` | `{{ match <status> { case ... } }}` |
| Conditional print | `welcome.tpl` | `{{ <Print> "text" to the <template> when <condition>. }}` |
| Nested templates | `dashboard.html` | `{{ <Include> the <template: partials/header.html>. }}` |
| Compute in templates | `user-list.html` | `{{ <Compute> the <count: length> from <users>. }}` |

## Directory Structure

```
TemplateEngine/
├── main.aro              # Application entry point
├── expected.txt          # Expected output for testing
├── test.hint             # Test configuration
└── templates/
    ├── user-list.html    # User listing with for-each loop
    ├── emails/
    │   └── welcome.tpl   # Welcome email with conditionals
    ├── pages/
    │   └── dashboard.html # Dashboard with includes
    └── partials/
        ├── header.html   # Reusable header partial
        └── footer.html   # Reusable footer partial
```

## Running the Example

```bash
# Run the template demo
aro run Examples/TemplateEngine

# Expected output:
# === Template Engine Demo ===
# Rendering welcome template...
# --- Rendered Output ---
# Dear Alice,
# ...
```

## Template Syntax Summary

```html
<!-- Variable interpolation -->
{{ <variable> }}
{{ <object: property> }}

<!-- Full ARO statement -->
{{ <Compute> the <result> from <expression>. }}

<!-- Print to template -->
{{ <Print> "Hello" to the <template>. }}

<!-- Conditional print -->
{{ <Print> "Premium!" to the <template> when <user: plan> = "premium". }}

<!-- For-each spanning block -->
{{ for each <item> in <collection> { }}
    <li>{{ <item: name> }}</li>
{{ } }}

<!-- With index -->
{{ for each <item> at <idx> in <collection> { }}
    <li>{{ <idx> }}. {{ <item> }}</li>
{{ } }}

<!-- Include partial -->
{{ <Include> the <template: partials/header.html>. }}

<!-- Match expression -->
{{ match <status> {
    case "active" { <Print> "Active" to the <template>. }
    otherwise { <Print> "Unknown" to the <template>. }
} }}
```
