# Chapter 38: Template Engine

> "The best templates are invisible—they get out of the way and let your content shine."
> — Unknown

The ARO template engine provides a powerful way to generate dynamic content by combining static text with executable ARO statements. Whether you're generating HTML pages, email bodies, configuration files, or reports, templates let you separate presentation from logic while maintaining the full power of ARO's action-result-object paradigm.

## 38.1 Introduction to Templates

Templates in ARO are files containing a mix of static content and execution blocks. The template engine processes these files, executing the ARO statements within execution blocks and combining the results with the static portions to produce the final output.

```
┌─────────────────────────────────────────────────────────────┐
│                    Template Processing                       │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│   Template File              Rendered Output                 │
│   ┌─────────────────┐       ┌─────────────────┐             │
│   │ Hello {{ name }}│  ───► │ Hello Alice     │             │
│   │ You have        │       │ You have        │             │
│   │ {{ count }}     │       │ 5               │             │
│   │ messages.       │       │ messages.       │             │
│   └─────────────────┘       └─────────────────┘             │
│                                                              │
│   Static text passes through unchanged                       │
│   Execution blocks are replaced with their output            │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Template Directory Convention

Templates are stored in a `templates/` directory relative to your application root:

```
MyApp/
├── main.aro
├── users.aro
├── openapi.yaml
└── templates/
    ├── welcome.tpl
    ├── email/
    │   ├── confirmation.tpl
    │   └── newsletter.tpl
    └── partials/
        ├── header.tpl
        └── footer.tpl
```

Template paths are always relative to the `templates/` directory. When you reference `email/confirmation.tpl`, ARO looks for `./templates/email/confirmation.tpl`.

## 38.2 Execution Blocks

Execution blocks are delimited by `{{ }}` and contain ARO statements. Any valid ARO statement can appear inside an execution block.

```aro
(* templates/greeting.tpl *)
Hello, {{ Print <user: name> to the <template>. }}!

Welcome to our service. Your account was created on
{{ Print <user: createdAt> to the <template>. }}.
```

Multiple statements can appear in a single block:

```aro
{{
    Compute the <total> from <price> * <quantity>.
    Print <total> to the <template>.
}}
```

### The Print-to-Template Action

The `<Print>` action with `to the <template>` writes output to the template's result buffer:

```aro
Print <value> to the <template>.
Print "literal text" to the <template>.
Print <price> * 1.1 to the <template>.
```

## 38.3 Variable Interpolation Shorthand

For simple variable output, ARO provides a shorthand syntax. When an execution block contains only a variable reference, it's automatically printed:

```aro
(* Full syntax *)
{{ Print <username> to the <template>. }}

(* Shorthand - equivalent to above *)
{{ <username> }}
```

The shorthand also works with expressions:

```aro
{{ <price> * 1.1 }}
{{ <first-name> + " " + <last-name> }}
```

And with qualified specifiers:

```aro
{{ <user: name> }}
{{ <order: total> }}
```

## 38.4 Rendering Templates with Transform

The `<Transform>` action renders a template with the current context:

```aro
(Send Welcome Email: User Notification) {
    Extract the <user> from the <event: user>.

    (* Render the email template *)
    Transform the <email-body> from the <template: welcome.tpl>.

    (* Send the email with the rendered content *)
    Send the <email> to the <user: email> with {
        subject: "Welcome!",
        body: <email-body>
    }.

    Return an <OK: status> for the <notification>.
}
```

The template receives all variables from the current execution context:

```aro
(* templates/welcome.tpl *)
Dear {{ <user: name> }},

Welcome to our platform! Your username is {{ <user: username> }}.

Best regards,
The Team
```

## 38.5 Context Isolation

Templates execute in an isolated child context. This means:

1. Templates can **read** all variables from the parent context
2. Variables created or modified inside templates **do not** affect the parent
3. The only output from a template is the rendered string

```
┌─────────────────────────────────────────────────────────────┐
│                    Context Isolation                         │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│   Parent Context                Template Context             │
│   ┌─────────────────┐          ┌─────────────────┐          │
│   │ user: Alice     │ ──copy─► │ user: Alice     │          │
│   │ count: 5        │          │ count: 5        │          │
│   │                 │          │ temp: "..."     │  (local) │
│   └─────────────────┘          └─────────────────┘          │
│          │                              │                    │
│          │                              ▼                    │
│          │                     ┌─────────────────┐          │
│          │  ◄── result ─────── │ Rendered String │          │
│          │                     └─────────────────┘          │
│          ▼                                                   │
│   Only the rendered                                          │
│   string returns                                             │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

This isolation ensures templates are safe and predictable—they cannot accidentally modify your application state.

## 38.6 For-Each Loops in Templates

For iterating over collections, templates use spanning blocks with a special syntax:

```aro
(* templates/user-list.tpl *)
<h1>Users</h1>
<ul>
{{ for each <user> in <users> { }}
    <li>{{ <user: name> }} ({{ <user: email> }})</li>
{{ } }}
</ul>
```

The opening block `{{ for each <item> in <collection> { }}` starts the loop, and `{{ } }}` closes it. Everything between these markers is repeated for each item.

### Loop Index

To access the current index, use the `at` keyword:

```aro
{{ for each <item> at <idx> in <items> { }}
    {{ <idx> }}. {{ <item: name> }}
{{ } }}
```

Indices are zero-based.

### Nested Loops

Loops can be nested for complex data structures:

```aro
{{ for each <category> in <categories> { }}
<h2>{{ <category: name> }}</h2>
<ul>
{{ for each <product> in <category: products> { }}
    <li>{{ <product: name> }} - ${{ <product: price> }}</li>
{{ } }}
</ul>
{{ } }}
```

## 38.7 Conditional Rendering

Use `when` guards for conditional output:

```aro
(* Conditional print *)
{{ Print "Premium Member" to the <template> when <user: isPremium>. }}

(* With else using match *)
{{
    match <user: tier> {
        "gold" => Print "Gold Member" to the <template>.
        "silver" => Print "Silver Member" to the <template>.
        _ => Print "Standard Member" to the <template>.
    }
}}
```

For conditional sections, combine with for-each over a filtered collection or use a guarded block:

```aro
{{ for each <item> in <items> { }}
{{ Print <item: name> to the <template> when <item: isActive>. }}
{{ } }}
```

## 38.8 Nested Templates with Include

The `<Include>` action embeds one template inside another:

```aro
(* templates/page.tpl *)
<!DOCTYPE html>
<html>
<head>
    <title>{{ <page: title> }}</title>
</head>
<body>
    {{ Include the <template: partials/header.tpl>. }}

    <main>
        {{ <content> }}
    </main>

    {{ Include the <template: partials/footer.tpl>. }}
</body>
</html>
```

### Passing Variables to Included Templates

Use the `with` clause to pass additional variables:

```aro
{{ Include the <template: partials/user-card.tpl> with {
    user: <current-user>,
    showEmail: true
}. }}
```

The included template receives both the parent context variables and the explicitly passed values.

### Creating Reusable Components

This pattern enables component-style template composition:

```aro
(* templates/components/button.tpl *)
<button class="{{ <class> }}" type="{{ <type> }}">
    {{ <label> }}
</button>

(* templates/form.tpl *)
<form action="/submit">
    <input type="text" name="email" />
    {{ Include the <template: components/button.tpl> with {
        class: "primary",
        type: "submit",
        label: "Subscribe"
    }. }}
</form>
```

## 38.9 Cards: Calendar and Event Templates

A common use case for templates is generating formatted cards for dates and events. Here's a pattern for creating date-aware cards:

```aro
(* templates/cards/event-card.tpl *)
<div class="event-card">
    <div class="event-date">
        <span class="month">{{ <event: month> }}</span>
        <span class="day">{{ <event: day> }}</span>
    </div>
    <div class="event-details">
        <h3>{{ <event: title> }}</h3>
        <p class="time">{{ <event: startTime> }} - {{ <event: endTime> }}</p>
        <p class="location">{{ <event: location> }}</p>
    </div>
</div>
```

Use with the Transform action:

```aro
(Render Event Cards: Calendar Display) {
    Retrieve the <events> from the <calendar-repository>
        where date >= <today> and date <= <nextWeek>.

    Transform the <cards> from the <template: cards/event-list.tpl>.

    Return an <OK: status> with <cards>.
}
```

### Upcoming Dates Pattern

For displaying upcoming dates like birthdays, deadlines, or appointments:

```aro
(* templates/cards/upcoming-dates.tpl *)
<div class="upcoming-dates">
    <h2>Upcoming</h2>
    {{ for each <date-item> in <upcoming> { }}
    <div class="date-card {{ <date-item: urgency> }}">
        <div class="countdown">{{ <date-item: daysUntil> }} days</div>
        <div class="title">{{ <date-item: title> }}</div>
        <div class="date">{{ <date-item: formattedDate> }}</div>
    </div>
    {{ } }}
</div>
```

```aro
(Show Upcoming Dates: Dashboard) {
    Retrieve the <deadlines> from the <task-repository>
        where dueDate >= <today>.

    (* Compute days until each deadline *)
    {{ for each <deadline> in <deadlines> { }}
        Compute the <days> from <deadline: dueDate> - <today>.
        (* Add to processed list *)
    {{ } }}

    Transform the <widget> from the <template: cards/upcoming-dates.tpl>.

    Return an <OK: status> with <widget>.
}
```

## 38.10 Binary Mode Compilation

When you compile an ARO application to a native binary using `aro build`, templates are automatically bundled into the executable. This creates a self-contained binary that doesn't need external template files at runtime.

```bash
# Templates in ./templates/ are bundled automatically
aro build ./MyApp

# The resulting binary contains all templates
./MyApp  # No external files needed
```

### How It Works

1. **Build time**: `aro build` discovers all files in `./templates/`
2. **Bundling**: Template contents are embedded as string constants in the binary
3. **Runtime**: The template service checks embedded templates first, then falls back to file system

This follows the same pattern as OpenAPI spec bundling, ensuring compiled binaries are truly portable.

### Development vs Production

| Mode | Template Source | Use Case |
|------|-----------------|----------|
| `aro run` | File system | Development, hot reload |
| Compiled binary | Embedded | Production deployment |

During development, use `aro run` to load templates from disk—changes take effect immediately without recompilation. For production, compile with `aro build` for a self-contained deployment.

## 38.11 Complete Example

Here's a complete example showing a feature set that renders a user profile page:

```aro
(* main.aro *)
(Application-Start: Profile App) {
    Start the <http-server> with <contract>.
    Keepalive the <application> for the <events>.
    Return an <OK: status> for the <startup>.
}

(getUserProfile: Profile API) {
    Extract the <userId> from the <pathParameters: id>.
    Retrieve the <user> from the <user-repository> where id = <userId>.
    Retrieve the <posts> from the <post-repository> where authorId = <userId>.

    Transform the <html> from the <template: profile.tpl>.

    Return an <OK: status> with <html>.
}
```

```aro
(* templates/profile.tpl *)
<!DOCTYPE html>
<html>
<head>
    <title>{{ <user: name> }}'s Profile</title>
    <style>
        .profile { max-width: 800px; margin: 0 auto; }
        .post { border: 1px solid #ddd; padding: 1rem; margin: 1rem 0; }
    </style>
</head>
<body>
    <div class="profile">
        {{ Include the <template: partials/header.tpl>. }}

        <h1>{{ <user: name> }}</h1>
        <p>{{ <user: bio> }}</p>

        <h2>Posts</h2>
        {{ for each <post> in <posts> { }}
        <article class="post">
            <h3>{{ <post: title> }}</h3>
            <p>{{ <post: excerpt> }}</p>
            <small>Posted on {{ <post: createdAt> }}</small>
        </article>
        {{ } }}

        {{ Include the <template: partials/footer.tpl>. }}
    </div>
</body>
</html>
```

## 38.12 Best Practices

### Keep Templates Focused

Each template should have a single responsibility. Break complex pages into smaller, reusable partials:

```
templates/
├── pages/
│   └── dashboard.tpl      # Main page structure
├── components/
│   ├── user-card.tpl      # Reusable user display
│   ├── stat-box.tpl       # Reusable statistics box
│   └── nav-menu.tpl       # Navigation component
└── partials/
    ├── header.tpl         # Page header
    └── footer.tpl         # Page footer
```

### Prepare Data in Feature Sets

Do computations and data preparation in your feature set, not in templates. Templates should focus on presentation:

```aro
(* Good: Prepare data first *)
(Render Dashboard: Admin View) {
    Retrieve the <users> from the <user-repository>.
    Compute the <user-count: count> from <users>.
    Compute the <active-users> from <users> where isActive = true.
    Compute the <active-count: count> from <active-users>.

    Transform the <page> from the <template: dashboard.tpl>.
    Return an <OK: status> with <page>.
}

(* Template just displays prepared values *)
(* templates/dashboard.tpl *)
<p>Total users: {{ <user-count> }}</p>
<p>Active users: {{ <active-count> }}</p>
```

### Use Meaningful Variable Names

Since templates access variables by name, use descriptive names that make templates self-documenting:

```aro
(* Clear what each variable represents *)
Transform the <confirmation-email> from the <template: order-confirmation.tpl>.

(* Instead of generic names *)
Transform the <result> from the <template: email.tpl>.
```

### Handle Missing Data Gracefully

Consider what happens when optional data is missing:

```aro
(* Template with conditional rendering *)
{{ Print <user: bio> to the <template> when <user: bio>. }}
{{ Print "No bio provided" to the <template> when not <user: bio>. }}
```

## Summary

| Feature | Syntax | Description |
|---------|--------|-------------|
| Execution block | `{{ ... }}` | Execute ARO statements |
| Variable interpolation | `{{ <var> }}` | Print variable value |
| Print to template | `Print x to the <template>.` | Output to template buffer |
| Render template | `Transform the <result> from the <template: path>.` | Render and capture output |
| For-each loop | `{{ for each <x> in <list> { }} ... {{ } }}` | Iterate over collection |
| Include template | `{{ Include the <template: path>. }}` | Embed another template |
| Include with vars | `{{ Include the <template: path> with { k: v }. }}` | Pass variables to include |

The template engine bridges ARO's action-oriented paradigm with the need for dynamic content generation. By maintaining context isolation and embracing the familiar `{{ }}` delimiter syntax, templates integrate naturally into ARO applications while preserving safety and predictability.

---

*Next: Chapter 39 — WebSockets*
