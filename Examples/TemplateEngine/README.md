# Template Engine Example

This example demonstrates the proposed ARO-0045 Template Engine syntax.

> **Note**: The template engine is not yet implemented. This example serves as a reference for the proposed syntax and features.

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
├── api.aro               # HTTP endpoints
├── openapi.yaml          # API contract
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

## API Endpoints

| Endpoint | Description |
|----------|-------------|
| `GET /users` | Renders user list as HTML table |
| `GET /welcome/{name}` | Generates welcome email for user |
| `GET /dashboard` | Shows dashboard with nested templates |

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
