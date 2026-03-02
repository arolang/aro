# Chapter 24: Multi-file Applications

*"Organize by domain, not by technical layer."*

---

## 24.1 Application Structure

An ARO application is a directory containing source files, configuration, and optional auxiliary files. The runtime automatically discovers all ARO source files in this directory and its subdirectories, compiling them together into a unified application.

This directory-based approach differs from many languages where you explicitly import dependencies between files. In ARO, there are no imports. Every feature set in every source file is globally visible within the application. An event emitted in one file can trigger a handler defined in another file without any explicit connection between them.

The automatic discovery means you can organize your source files however makes sense for your project. Group by domain, by feature, by technical concern, or by any other scheme. The runtime does not care about your directory structure—it simply finds all the source files and processes them together.

Certain files have special significance. The openapi.yaml file, if present, defines the HTTP API contract. Plugin directories can contain dynamically loaded extensions. Configuration files might be loaded during startup. But the core source files—the .aro files containing your feature sets—are all treated equally regardless of where they appear in the directory tree.

---

## 24.2 Auto-Discovery

When you run an ARO application, the runtime scans the application directory recursively for files with the .aro extension. Each file is parsed, and its feature sets are registered. This happens automatically without any configuration.

Verbose output shows what the discovery process finds. You can see which files were discovered, how many feature sets each contains, and whether an OpenAPI specification was found. This visibility helps you verify that your application structure matches your expectations.

Subdirectories are fully supported. You can create deep hierarchies if that helps organize your code. A large application might have domain directories, each containing subdirectories for different aspects of that domain. The runtime flattens this hierarchy during discovery—all feature sets end up in the same namespace regardless of which subdirectory they came from.

The discovery process validates structural requirements. It checks that exactly one Application-Start feature set exists across all discovered files. It checks that at most one Application-End: Success and one Application-End: Error exist. Violations of these constraints produce clear error messages indicating which files contain the conflicting definitions.

---

## 24.3 Global Visibility

Feature sets are globally visible without imports. This is a fundamental design choice that enables loose coupling through events.

When you emit an event in one file, handlers in any file can respond to it. The emitting code does not need to know that handlers exist or where they are defined. The handlers do not need to import the emitting code. The connection happens at runtime through the event bus based on naming conventions.

This global visibility means you must ensure feature set names are unique across your entire application. If two files define feature sets with the same name, the runtime reports an error. Choose distinctive names that avoid conflicts.

The same visibility applies to published variables within a business activity. When you use the Publish action to make a value available, it becomes accessible from any feature set with the same business activity that executes afterward. This scoping to business activity enforces modularity—feature sets in different domains cannot accidentally depend on each other's published variables. Use publishing sparingly because shared state complicates reasoning about program behavior.

Repositories are implicitly shared. When one feature set stores data to a repository and another retrieves from the same repository, they are working with shared storage. This is how data flows between feature sets beyond the scope of a single event handling chain.

---

## 24.4 The Application-Start Requirement

Every ARO application must have exactly one Application-Start feature set. This requirement ensures there is an unambiguous entry point for execution.

Having zero Application-Start feature sets is an error. The runtime would have nothing to execute, no way to begin the application's work. The error message explains this clearly and reminds you of the requirement.

Having multiple Application-Start feature sets is also an error. The runtime would not know which one to execute first or whether to execute all of them. The error message lists the locations of all conflicting definitions so you can resolve the conflict.

This constraint applies across all source files in the application. It does not matter which file contains the Application-Start—what matters is that exactly one exists somewhere in the application.

The Application-End feature sets (Success and Error variants) have similar constraints. You can have at most one of each. Having multiple success handlers or multiple error handlers creates ambiguity about shutdown behavior.

---

## 24.5 Organization Strategies

Several strategies for organizing multi-file applications have proven effective in practice.

Organization by domain groups related functionality together. A user management domain might have files for CRUD operations, authentication, and profile management. An order domain might have files for checkout, payment, and fulfillment. Each domain directory contains everything related to that business concept.

Organization by feature groups all code for a specific feature. A product search feature might have its HTTP handlers, event handlers, and utilities in one directory. This organization works well when features are relatively independent and you want to see everything related to a feature in one place.

Organization by technical concern groups code by what it does technically. HTTP handlers go in one directory, event handlers in another, background jobs in a third. This organization works well for teams familiar with layered architectures and can make it easy to find all handlers of a particular type.

Many applications combine these strategies. Domain directories at the top level, with technical concerns separated within each domain. Or feature directories with shared utilities factored out. The right organization depends on your team and your application.

### Complete Application Layout Example

Here is a complete e-commerce API organized by domain:

```
ecommerce-api/
├── openapi.yaml              # API contract (required for HTTP server)
├── main.aro                  # Application lifecycle only
├── products/
│   └── products.aro          # Product CRUD operations
├── orders/
│   ├── orders.aro            # Order CRUD operations
│   └── order-events.aro      # Order event handlers
├── inventory/
│   └── inventory.aro         # Stock management
└── notifications/
    └── notifications.aro     # Email/notification handlers
```

**main.aro** — Lifecycle only, no business logic:
```aro
(Application-Start: E-commerce API) {
    Log "Starting e-commerce API..." to the <console>.
    Start the <http-server> on port 8080.
    Keepalive the <application> for the <events>.
    Return an <OK: status> for the <startup>.
}

(Application-End: Success) {
    Stop the <http-server>.
    Log "E-commerce API stopped." to the <console>.
    Return an <OK: status> for the <shutdown>.
}
```

**products/products.aro** — Product domain:
```aro
(listProducts: Product API) {
    Retrieve the <products> from the <product-repository>.
    Return an <OK: status> with <products>.
}

(getProduct: Product API) {
    Extract the <id> from the <pathParameters: id>.
    Retrieve the <product> from the <product-repository> where id = <id>.
    Return an <OK: status> with <product>.
}
```

**orders/orders.aro** — Order domain:
```aro
(createOrder: Order API) {
    Extract the <order-data> from the <request: body>.
    Create the <order> with <order-data>.
    Store the <order> in the <order-repository>.
    Emit an <OrderPlaced: event> with <order>.
    Return a <Created: status> with <order>.
}
```

**orders/order-events.aro** — Separated event handlers:
```aro
(Reserve Stock: OrderPlaced Handler) {
    Extract the <order> from the <event: order>.
    Extract the <items> from the <order: items>.
    Update the <inventory> for <items> with { reserved: true }.
    Emit an <StockReserved: event> with <order>.
}
```

**notifications/notifications.aro** — Cross-domain event handlers:
```aro
(Send Order Confirmation: OrderPlaced Handler) {
    Extract the <order> from the <event: order>.
    Extract the <email> from the <order: customerEmail>.
    Send the <confirmation-email> to the <email-service> with {
        to: <email>,
        template: "order-confirmation",
        order: <order>
    }.
    Return an <OK: status> for the <notification>.
}
```

Key points in this layout:
- **main.aro** contains only lifecycle handlers
- **Each domain** has its own directory
- **Event handlers** are separated from emitters
- **Cross-domain handlers** (notifications) have their own location
- **No imports needed** — all feature sets are globally visible

> **See also:** `Examples/UserService` for a working multi-file application.

---

## 24.6 Recommended Patterns

Experience suggests some patterns that work well across different types of applications.

Keep the main file minimal. It should contain only lifecycle feature sets—Application-Start and Application-End. Business logic belongs in other files organized by domain or feature. This keeps the entry point focused and easy to understand.

Group related feature sets in the same file. All CRUD handlers for a resource belong together. All handlers for a particular event type might belong together. When you need to understand or modify how something works, you should find all the relevant code in one or a few related files.

Separate event handlers from the feature sets that emit events. The code that creates a user and emits UserCreated belongs in the user domain. The handlers that react to UserCreated might belong in separate files—one for notifications, one for analytics, one for search indexing. This separation allows adding handlers without modifying the emitting code.

Use descriptive file names that indicate content. A file named users.aro clearly contains user-related code. A file named user-events.aro clearly contains event handlers for user events. Readers should be able to navigate your codebase by file names alone.

---

## 24.7 Sharing Data Between Files

Feature sets in different files can share data through several mechanisms, each appropriate for different scenarios.

Events carry data from producers to consumers. When you emit an event with a payload, handlers extract the data they need from that payload. This is the primary mechanism for loosely coupled communication. The producer does not know who consumes the event; consumers do not need to be in the same file as the producer.

Published variables make data available within a business activity. When you publish a value during startup, any feature set with the same business activity that executes afterward can access it. This is appropriate for configuration, constants, and shared state within a domain. Use it sparingly because shared state complicates understanding of program behavior.

Repositories provide persistent shared storage. One feature set stores data; another retrieves it. The repository provides the shared namespace. This is how data persists beyond the lifetime of individual event handling and how different parts of the application work with the same underlying data.

The choice between these mechanisms depends on the relationship between the sharing feature sets. Closely related feature sets reacting to the same event should use event data. Widely separated feature sets needing configuration should use published variables. Feature sets that work with persistent domain entities should use repositories.

---

## 24.8 Best Practices

Establish naming conventions early and follow them consistently. File names, feature set names, event names, and repository names should follow predictable patterns that team members can learn and apply.

Document the intended organization. New team members should understand how files are organized and where new code should go. A brief README or documented convention saves confusion and prevents inconsistent organization.

Keep files focused. A file with fifty feature sets is probably too large. If a file grows unwieldy, split it along natural boundaries—separate CRUD from search, separate handlers from emitters, separate domains from each other.

Consider how changes propagate. When you modify a feature set, what other feature sets might be affected? The event-driven model means effects can be non-obvious. Understanding the event flow through your application helps you understand change impact.

Test files can follow the same organization as production code. Test files for user functionality go alongside or parallel to user functionality source files. This keeps tests easy to find and maintain.

---

## 24.9 The Sources Directory Convention

For larger applications, you may want to separate configuration files from source code. The `sources/` directory convention provides a clean way to organize your project:

```
my-app/
├── openapi.yaml              # Configuration in root
├── main.aro                  # Entry point in root (optional)
├── sources/                  # All source files in subdirectory
│   ├── users/
│   │   └── users.aro
│   ├── orders/
│   │   └── orders.aro
│   └── notifications/
│       └── notifications.aro
└── README.md
```

The runtime discovers all `.aro` files regardless of their location in the directory tree. You can place source files in the root directory, in `sources/`, or use a combination. The `sources/` convention is particularly useful when:

- Your project has many configuration files (OpenAPI specs, environment configs)
- You want a clear separation between code and configuration
- You are following conventions from other languages that use `src/` directories

Files can be nested to any depth within `sources/`. The runtime flattens the hierarchy during discovery—all feature sets end up in the same namespace.

> **See also:** `Examples/SourceStructure` demonstrates this organization pattern.

---

*Next: Chapter 24 — Patterns & Practices*
