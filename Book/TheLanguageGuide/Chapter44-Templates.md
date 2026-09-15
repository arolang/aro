# Chapter 44: Template Engine

> "The best templates are invisible—they get out of the way and let your content shine."
> — Unknown

The ARO template engine provides a powerful way to generate dynamic content by combining static text with executable ARO statements. Whether you're generating HTML pages, email bodies, configuration files, or reports, templates let you separate presentation from logic while maintaining the full power of ARO's action-result-object paradigm.

## 44.1 Introduction to Templates

Templates in ARO are files containing a mix of static content and execution blocks. The template engine processes these files, executing the ARO statements within execution blocks and combining the results with the static portions to produce the final output.

<div style="text-align: center; margin: 2em 0;">
<svg width="520" height="180" viewBox="0 0 520 180" xmlns="http://www.w3.org/2000/svg" font-family="sans-serif">
  <defs>
    <marker id="arrowTP" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#374151"/>
    </marker>
  </defs>

  <text x="260" y="16" text-anchor="middle" font-size="11" font-weight="bold" fill="#374151">Template Processing</text>

  <!-- Template file -->
  <rect x="20" y="32" width="190" height="96" rx="4" fill="#e0e7ff" stroke="#6366f1" stroke-width="2"/>
  <text x="115" y="52" text-anchor="middle" font-size="10" font-weight="bold" fill="#4338ca">Template File</text>
  <text x="34" y="74" font-size="10" font-family="monospace" fill="#4338ca">Hello </text>
  <rect x="76" y="63" width="98" height="14" rx="2" fill="#818cf8"/>
  <text x="80" y="74" font-size="10" font-family="monospace" fill="#ffffff">{{ &lt;name&gt; }}</text>
  <text x="34" y="92" font-size="10" font-family="monospace" fill="#4338ca">You have</text>
  <rect x="34" y="99" width="104" height="14" rx="2" fill="#818cf8"/>
  <text x="38" y="110" font-size="10" font-family="monospace" fill="#ffffff">{{ &lt;count&gt; }}</text>
  <text x="34" y="126" font-size="10" font-family="monospace" fill="#4338ca">messages.</text>

  <!-- Arrow -->
  <line x1="212" y1="80" x2="298" y2="80" stroke="#374151" stroke-width="2" marker-end="url(#arrowTP)"/>
  <text x="255" y="72" text-anchor="middle" font-size="9" fill="#374151">render</text>

  <!-- Rendered output -->
  <rect x="300" y="32" width="190" height="96" rx="4" fill="#d1fae5" stroke="#22c55e" stroke-width="2"/>
  <text x="395" y="52" text-anchor="middle" font-size="10" font-weight="bold" fill="#166534">Rendered Output</text>
  <text x="314" y="74" font-size="10" font-family="monospace" fill="#166534">Hello Alice</text>
  <text x="314" y="92" font-size="10" font-family="monospace" fill="#166534">You have</text>
  <text x="314" y="110" font-size="10" font-family="monospace" fill="#166534">5</text>
  <text x="314" y="126" font-size="10" font-family="monospace" fill="#166534">messages.</text>

  <text x="260" y="152" text-anchor="middle" font-size="9" fill="#374151">Static text passes through unchanged</text>
  <text x="260" y="168" text-anchor="middle" font-size="9" fill="#374151">Execution blocks are replaced with their output</text>
</svg>
</div>

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

## 44.2 Execution Blocks

<div style="text-align: center; margin: 2em 0;">
<svg width="540" height="150" viewBox="0 0 540 150" xmlns="http://www.w3.org/2000/svg" font-family="sans-serif">
  <defs>
    <marker id="arrowT" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#374151"/>
    </marker>
  </defs>

  <!-- Template file box -->
  <rect x="10" y="20" width="150" height="110" rx="4" fill="#e0e7ff" stroke="#6366f1" stroke-width="2"/>
  <text x="85" y="42" text-anchor="middle" font-size="11" font-weight="bold" fill="#4338ca">Template (.tpl)</text>
  <rect x="20" y="52" width="130" height="14" rx="2" fill="#c7d2fe" stroke="none"/>
  <text x="85" y="63" text-anchor="middle" font-size="9" fill="#4338ca">static text...</text>
  <rect x="20" y="70" width="130" height="14" rx="2" fill="#818cf8" stroke="none"/>
  <text x="85" y="81" text-anchor="middle" font-size="9" fill="#ffffff">{{ expression }}</text>
  <rect x="20" y="88" width="130" height="14" rx="2" fill="#c7d2fe" stroke="none"/>
  <text x="85" y="99" text-anchor="middle" font-size="9" fill="#4338ca">static text...</text>
  <rect x="20" y="106" width="130" height="14" rx="2" fill="#818cf8" stroke="none"/>
  <text x="85" y="117" text-anchor="middle" font-size="9" fill="#ffffff">{{ statements }}</text>

  <!-- Arrow 1 with label -->
  <line x1="160" y1="75" x2="193" y2="75" stroke="#374151" stroke-width="1.5" marker-end="url(#arrowT)"/>
  <text x="176" y="69" text-anchor="middle" font-size="8" fill="#374151">Template</text>
  <text x="176" y="87" text-anchor="middle" font-size="8" fill="#374151">Parser</text>

  <!-- Segments box -->
  <rect x="195" y="20" width="150" height="110" rx="4" fill="#fef3c7" stroke="#f59e0b" stroke-width="2"/>
  <text x="270" y="42" text-anchor="middle" font-size="11" font-weight="bold" fill="#92400e">Segments</text>
  <rect x="205" y="52" width="130" height="20" rx="2" fill="#fde68a" stroke="none"/>
  <text x="270" y="66" text-anchor="middle" font-size="9" fill="#92400e">staticText</text>
  <rect x="205" y="76" width="130" height="20" rx="2" fill="#fde68a" stroke="none"/>
  <text x="270" y="90" text-anchor="middle" font-size="9" fill="#92400e">expression</text>
  <rect x="205" y="100" width="130" height="20" rx="2" fill="#fde68a" stroke="none"/>
  <text x="270" y="114" text-anchor="middle" font-size="9" fill="#92400e">statements</text>

  <!-- Arrow 2 with label -->
  <line x1="345" y1="75" x2="378" y2="75" stroke="#374151" stroke-width="1.5" marker-end="url(#arrowT)"/>
  <text x="361" y="69" text-anchor="middle" font-size="8" fill="#374151">Template</text>
  <text x="361" y="87" text-anchor="middle" font-size="8" fill="#374151">Executor</text>

  <!-- Rendered output box -->
  <rect x="380" y="20" width="150" height="110" rx="4" fill="#d1fae5" stroke="#22c55e" stroke-width="2"/>
  <text x="455" y="42" text-anchor="middle" font-size="11" font-weight="bold" fill="#166534">Rendered Output</text>
  <text x="455" y="62" text-anchor="middle" font-size="9" fill="#166534">static text resolved</text>
  <text x="455" y="78" text-anchor="middle" font-size="9" fill="#166534">expressions evaluated</text>
  <text x="455" y="94" text-anchor="middle" font-size="9" fill="#166534">statements executed</text>
  <text x="455" y="110" text-anchor="middle" font-size="9" fill="#166534">→ final string</text>
</svg>
</div>

Execution blocks are delimited by `{{ }}` and contain ARO statements. Any valid ARO statement can appear inside an execution block.

```text
(* templates/greeting.tpl *)
Hello, {{ Print <user: name> to the <template>. }}!

Welcome to our service. Your account was created on
{{ Print <user: createdAt> to the <template>. }}.
```

Multiple statements can appear in a single block:

```text
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

## 44.3 Variable Interpolation Shorthand

For simple variable output, ARO provides a shorthand syntax. When an execution block contains only a variable reference, it's automatically printed:

```text
(* Full syntax *)
{{ Print <username> to the <template>. }}

(* Shorthand *)
{{ <username> }}
```

The shorthand takes a variable or an expression, never a bare literal:
`{{ "some text" }}` does not parse. Static text belongs outside the braces.

The two forms are *not* interchangeable in one respect — see
Section 44.13 on escaping.

The shorthand also works with expressions:

```text
{{ <price> * 1.1 }}
{{ <first-name> ++ " " ++ <last-name> }}
```

And with qualified specifiers:

```text
{{ <user: name> }}
{{ <order: total> }}
```

## 44.4 Rendering Templates with Transform

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

```text
(* templates/welcome.tpl *)
Dear {{ <user: name> }},

Welcome to our platform! Your username is {{ <user: username> }}.

Best regards,
The Team
```

## 44.5 Context Isolation

Templates execute in an isolated child context. This means:

1. Templates can **read** all variables from the parent context
2. Variables created or modified inside templates **do not** affect the parent
3. The only output from a template is the rendered string

<div style="text-align: center; margin: 2em 0;">
<svg width="500" height="210" viewBox="0 0 500 210" xmlns="http://www.w3.org/2000/svg" font-family="sans-serif">
  <defs>
    <marker id="arrowCI" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#374151"/>
    </marker>
    <marker id="arrowCIg" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#22c55e"/>
    </marker>
  </defs>

  <text x="250" y="16" text-anchor="middle" font-size="11" font-weight="bold" fill="#374151">Context Isolation</text>

  <!-- Parent context -->
  <rect x="20" y="34" width="170" height="86" rx="4" fill="#e0e7ff" stroke="#6366f1" stroke-width="2"/>
  <text x="105" y="53" text-anchor="middle" font-size="10" font-weight="bold" fill="#4338ca">Parent Context</text>
  <text x="34" y="74" font-size="10" font-family="monospace" fill="#4338ca">user: Alice</text>
  <text x="34" y="92" font-size="10" font-family="monospace" fill="#4338ca">count: 5</text>

  <!-- copy arrow -->
  <line x1="192" y1="72" x2="288" y2="72" stroke="#374151" stroke-width="2" marker-end="url(#arrowCI)"/>
  <text x="240" y="64" text-anchor="middle" font-size="9" fill="#374151">copy</text>

  <!-- Template context -->
  <rect x="290" y="34" width="190" height="86" rx="4" fill="#fef3c7" stroke="#f59e0b" stroke-width="2"/>
  <text x="385" y="53" text-anchor="middle" font-size="10" font-weight="bold" fill="#92400e">Template Context</text>
  <text x="304" y="74" font-size="10" font-family="monospace" fill="#92400e">user: Alice</text>
  <text x="304" y="92" font-size="10" font-family="monospace" fill="#92400e">count: 5</text>
  <text x="304" y="110" font-size="10" font-family="monospace" fill="#92400e">temp: "…"  (local)</text>

  <!-- down to rendered string -->
  <line x1="385" y1="122" x2="385" y2="146" stroke="#22c55e" stroke-width="2" marker-end="url(#arrowCIg)"/>
  <rect x="290" y="150" width="190" height="34" rx="4" fill="#d1fae5" stroke="#22c55e" stroke-width="2"/>
  <text x="385" y="172" text-anchor="middle" font-size="10" font-weight="bold" fill="#166534">Rendered String</text>

  <!-- result back to parent -->
  <line x1="288" y1="167" x2="110" y2="167" stroke="#22c55e" stroke-width="2" marker-end="url(#arrowCIg)"/>
  <line x1="105" y1="167" x2="105" y2="124" stroke="#22c55e" stroke-width="2" marker-end="url(#arrowCIg)"/>
  <text x="200" y="160" text-anchor="middle" font-size="9" fill="#166534">only the string returns</text>
</svg>
</div>

This isolation ensures templates are safe and predictable—they cannot accidentally modify your application state.

## 44.6 For-Each Loops in Templates

For iterating over collections, templates use spanning blocks with a special syntax:

```text
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

```text
{{ for each <item> at <idx> in <items> { }}
    {{ <idx> }}. {{ <item: name> }}
{{ } }}
```

Indices are zero-based.

### Nested Loops

Loops can be nested for complex data structures:

```text
{{ for each <category> in <categories> { }}
<h2>{{ <category: name> }}</h2>
<ul>
{{ for each <product> in <category: products> { }}
    <li>{{ <product: name> }} - ${{ <product: price> }}</li>
{{ } }}
</ul>
{{ } }}
```

## 44.7 Conditional Rendering

Use `when` guards for conditional output:

```text
(* Conditional print *)
{{ Print "Premium Member" to the <template> when <user: isPremium>. }}

(* Several outcomes: match, with the same case/otherwise syntax as Chapter 33 *)
{{
    match <user: tier> {
        case "gold"   { Print "Gold Member" to the <template>. }
        case "silver" { Print "Silver Member" to the <template>. }
        otherwise     { Print "Standard Member" to the <template>. }
    }
}}
```

For conditional sections, combine with for-each over a filtered collection or use a guarded block:

```text
{{ for each <item> in <items> { }}
{{ Print <item: name> to the <template> when <item: isActive>. }}
{{ } }}
```

## 44.8 Nested Templates with Include

The `<Include>` action embeds one template inside another. Like every other
ARO statement it needs a result binding and a preposition — `Include the
<name> from the <template: path>.` The included text is written into the
output at that point, and `<name>` also holds it.

```text
(* templates/page.tpl *)
<!DOCTYPE html>
<html>
<head>
    <title>{{ <page: title> }}</title>
</head>
<body>
    {{ Include the <header> from the <template: partials/header.tpl>. }}

    <main>
        {{ <content> }}
    </main>

    {{ Include the <footer> from the <template: partials/footer.tpl>. }}
</body>
</html>
```

> ARO-0050 §10 used to spell this without the binding — `{{ Include the
> <template: header.tpl>. }}` — which cannot parse, since every ARO statement
> carries a preposition clause. It also offered `{{ Include the <template:
> header.tpl> with { … }. }}`, which parsed and rendered *nothing*: with `with`
> as the preposition the object is an expression, and the executor binds its
> value without ever dispatching `Include`. The proposal now specifies the
> `from` form above, and `aro check` reports the `with` spelling with a hint
> naming it ([GitLab #563](https://git.ausdertechnik.de/arolang/aro/-/issues/563)).

### Passing Variables to Included Templates

Use the `with` clause to pass additional variables:

```text
{{ Include the <card> from the <template: partials/user-card.tpl> with {
    user: <current-user>,
    showEmail: true
}. }}
```

The included template receives both the parent context variables and the explicitly passed values.

### Creating Reusable Components

This pattern enables component-style template composition:

```text
(* templates/components/button.tpl *)
<button class="{{ <class> }}" type="{{ <type> }}">
    {{ <label> }}
</button>

(* templates/form.tpl *)
<form action="/submit">
    <input type="text" name="email" />
    {{ Include the <button> from the <template: components/button.tpl> with {
        class: "primary",
        type: "submit",
        label: "Subscribe"
    }. }}
</form>
```

## 44.9 Cards: Calendar and Event Templates

A common use case for templates is generating formatted cards for dates and events. Here's a pattern for creating date-aware cards:

```text
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
        where <date> >= <today> and <date> <= <nextWeek>.

    Transform the <cards> from the <template: cards/event-list.tpl>.

    Return an <OK: status> with <cards>.
}
```

### Upcoming Dates Pattern

For displaying upcoming dates like birthdays, deadlines, or appointments:

```text
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
        where <dueDate> >= <today>.

    (* Compute days until each deadline *)
    for each <deadline> in <deadlines> {
        Extract the <due> from the <deadline: dueDate>.
        Compute the <days> from <due> - <today>.
        (* Add to processed list *)
    }

    Transform the <widget> from the <template: cards/upcoming-dates.tpl>.

    Return an <OK: status> with <widget>.
}
```

## 44.10 Binary Mode Compilation

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

## 44.11 Complete Example

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
    Retrieve the <user> from the <user-repository> where <id> = <userId>.
    Retrieve the <posts> from the <post-repository> where <authorId> = <userId>.

    Transform the <html> from the <template: profile.tpl>.

    Return an <OK: status> with <html>.
}
```

```text
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
        {{ Include the <header> from the <template: partials/header.tpl>. }}

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

        {{ Include the <footer> from the <template: partials/footer.tpl>. }}
    </div>
</body>
</html>
```

## 44.12 Best Practices

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
    Filter the <active-users> from <users> where <isActive> is true.
    Compute the <active-count: count> from <active-users>.

    Transform the <page> from the <template: dashboard.tpl>.
    Return an <OK: status> with <page>.
}
```

```text
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

```text
(* Template with conditional rendering *)
{{ Print <user: bio> to the <template> when <user: bio>. }}
{{ Print "No bio provided" to the <template> when not <user: bio>. }}
```

## 44.13 Escaping: What the Extension Decides

The `{{ }}` delimiters look like Mustache, which escapes by default and makes
you write `{{{ }}}` to opt out. ARO does not work that way, and the difference
is the one place a template can hurt you.

**The template's file extension chooses the escaping.** A `.html` or `.htm`
template HTML-escapes `& < > " '`; every other extension — `.tpl`, `.txt`,
`.md`, `.screen` — escapes nothing, because those are not markup.

So the practical rule is: **if a template produces HTML, name it `.html`.**
The `profile.tpl` in Section 44.11 emits a full HTML document, and because of
its extension nothing in it is escaped — a user whose name is
`<script>…</script>` runs it in the reader's browser. Renaming it
`profile.html` fixes that for free.

The opt-out, for content you have already sanitised, qualifies the *target*:

```text
{{ Print <trusted-html> to the <template: raw>. }}
```

### The shorthand does not escape

In an `.html` template the two forms Section 44.3 called equivalent are not:

```text
S1: {{ <user: name> }}                              → Alice <b>
S2: {{ Print <user: name> to the <template>. }}     → Alice &lt;b&gt;
S3: {{ Print <user: name> to the <template: raw>. }} → Alice <b>
```

The shorthand behaves like the deliberate opt-out. Until that is fixed
([GitLab #560](https://git.ausdertechnik.de/arolang/aro/-/issues/560)), write
untrusted values through `Print` in HTML templates, and keep the shorthand for
values you produced yourself.

Where escaping is not automatic — a `.tpl` file that happens to emit markup —
escape in the feature set instead, with the `html-escape` qualifier of
Chapter 9:

```aro
Compute the <safe-bio: html-escape> from <user-bio>.
Transform the <page> from the <template: profile.html>.
```

---

## Summary

| Feature | Syntax | Description |
|---------|--------|-------------|
| Execution block | `{{ ... }}` | Execute ARO statements |
| Variable interpolation | `{{ <var> }}` | Print variable value (does **not** escape) |
| HTML escaping | name the template `.html` | Escapes `Print`ed values; `.tpl` escapes nothing |
| Print to template | `Print x to the <template>.` | Output to template buffer |
| Render template | `Transform the <result> from the <template: path>.` | Render and capture output |
| For-each loop | `{{ for each <x> in <list> { }} ... {{ } }}` | Iterate over collection |
| Include template | `{{ Include the <x> from the <template: path>. }}` | Embed another template |
| Include with vars | `{{ Include the <x> from the <template: path> with { k: v }. }}` | Pass variables to include |

The template engine bridges ARO's action-oriented paradigm with the need for dynamic content generation. By maintaining context isolation and embracing the familiar `{{ }}` delimiter syntax, templates integrate naturally into ARO applications while preserving safety and predictability.

---

*Next: Chapter 45 — WebSockets*
