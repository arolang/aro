# Chapter 6: Data Flow

*"Data flows forward, never backward."*

---

## 6.1 The Direction of Data

Every ARO statement moves data in a predictable direction. This is not merely a conceptual framework but a fundamental property of the language that the runtime enforces. Understanding data flow is essential for writing effective ARO code because it shapes how you think about structuring your feature sets.

The fundamental principle is that data enters from the outside world, transforms within the feature set, and exits to the outside world. External sources include HTTP requests, files, databases, and network connections. Internal transformations include creating new values, validating existing ones, computing results, and restructuring data. External destinations include responses to callers, persistent storage, emitted events, and outbound communications.

This directional flow creates a natural structure for feature sets. The beginning of a feature set typically contains actions that bring data in. The middle contains actions that transform that data. The end contains actions that send results out. While this is not enforced syntactically—you can technically write statements in any order—the data dependencies between statements create an inherent ordering that usually follows this pattern.

The flow is unidirectional within a single execution. Data moves forward through the statement sequence; it does not loop back. Each statement receives its inputs from the accumulated results of previous statements and produces outputs that become available to subsequent statements. This forward-only flow simplifies reasoning about program behavior because you can trace the origin of any value by looking backward through the statement sequence.

---

## 6.2 Semantic Roles

Every action in ARO has a semantic role that categorizes its data flow characteristics. The role is determined by the action's verb and affects how the runtime processes the action and validates its usage. There are four roles: REQUEST, OWN, RESPONSE, and EXPORT.

REQUEST actions bring data from outside the feature set into its local scope. When you extract data from a request, retrieve records from a repository, fetch content from a URL, or read a file, you are performing a REQUEST operation. The characteristic of REQUEST actions is that they produce new bindings by pulling data inward. After a REQUEST action executes, the symbol table contains a new entry that was not there before, and the value came from somewhere external.

OWN actions transform data that already exists within the feature set. When you create a new value from existing ones, compute a result from inputs, validate data against a schema, filter a collection, or merge objects, you are performing an OWN operation. The characteristic of OWN actions is that they read from existing bindings and produce new bindings, but all the data stays internal to the feature set. No external communication occurs.

RESPONSE actions send data out of the feature set to the caller and terminate normal execution. When you return a response to an HTTP client or throw an error, you are performing a RESPONSE operation. The characteristic of RESPONSE actions is that they move data outward and end the feature set's execution. After a RESPONSE action, no subsequent statements execute because control has returned to the caller.

EXPORT actions make data available beyond the current execution without terminating it. When you store data to a repository, emit an event for handlers to process, publish a value for other feature sets in the same business activity, log a message, or send a notification, you are performing an EXPORT operation. The characteristic of EXPORT actions is that they have side effects—they change something in the outside world—but execution continues with the next statement.

The runtime uses these roles for validation and optimization. It can detect when you try to use a value that has not been bound, when you attempt to read from a binding that a statement's role would not produce, or when you have dead code after a RESPONSE action. Understanding the roles helps you write code that the runtime can validate effectively.

---

## 6.3 The Symbol Table

As statements execute, ARO maintains a symbol table that maps variable names to values. This table is the mechanism by which data flows between statements. When a statement produces a result, the result is added to the symbol table under the specified name. When a subsequent statement references that name, the runtime looks up the value in the symbol table.

The symbol table starts empty at the beginning of each feature set execution. As each statement executes, any result it produces is added to the table. This accumulation creates the context in which later statements operate. A statement near the end of the feature set has access to all the bindings created by statements that came before it.

The symbol table is append-only within a single execution. You cannot rebind a name to a different value. If you try to create a binding for a name that already exists, the compiler or runtime reports an error. This immutability prevents a common class of bugs where variables change unexpectedly and makes it easier to reason about program behavior—when you see a reference to a name, you know it refers to exactly the value that was originally bound.

When a statement references a variable that does not exist in the symbol table, the runtime produces an error describing which variable is undefined and where the reference occurred. This is a runtime error rather than a compile-time error because the compiler cannot always determine whether a binding will exist. Some bindings depend on conditional execution or on values that only become known during execution.

The symbol table is scoped to the feature set. Bindings in one feature set do not affect bindings in another. Each feature set maintains its own independent table that exists only for the duration of that feature set's execution. This isolation prevents unintended interactions between feature sets and allows you to use descriptive names without worrying about conflicts.

---

## 6.4 Data Flow Patterns

Several common patterns emerge in how data flows through feature sets. Recognizing these patterns helps you structure your code effectively and understand existing code more quickly.

<div style="display: flex; flex-wrap: wrap; justify-content: space-around; margin: 2em 0;">

<div style="text-align: center; margin: 0.5em;">
<svg width="160" height="100" viewBox="0 0 160 100" xmlns="http://www.w3.org/2000/svg">  <text x="80" y="12" text-anchor="middle" font-family="sans-serif" font-size="9" font-weight="bold" fill="#1e40af">Linear Pipeline</text>  <rect x="10" y="25" width="30" height="20" rx="3" fill="#dbeafe" stroke="#3b82f6" stroke-width="1.5"/>  <line x1="40" y1="35" x2="55" y2="35" stroke="#6b7280" stroke-width="1.5"/>  <polygon points="55,35 50,32 50,38" fill="#6b7280"/>  <rect x="55" y="25" width="30" height="20" rx="3" fill="#dcfce7" stroke="#22c55e" stroke-width="1.5"/>  <line x1="85" y1="35" x2="100" y2="35" stroke="#6b7280" stroke-width="1.5"/>  <polygon points="100,35 95,32 95,38" fill="#6b7280"/>  <rect x="100" y="25" width="30" height="20" rx="3" fill="#fce7f3" stroke="#ec4899" stroke-width="1.5"/>  <line x1="130" y1="35" x2="145" y2="35" stroke="#6b7280" stroke-width="1.5"/>  <polygon points="145,35 140,32 140,38" fill="#6b7280"/>  <text x="80" y="65" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#6b7280">A → B → C → out</text>  <text x="80" y="78" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#9ca3af">sequential transforms</text></svg>
</div>

<div style="text-align: center; margin: 0.5em;">
<svg width="160" height="100" viewBox="0 0 160 100" xmlns="http://www.w3.org/2000/svg">  <text x="80" y="12" text-anchor="middle" font-family="sans-serif" font-size="9" font-weight="bold" fill="#166534">Fan-Out</text>  <rect x="55" y="20" width="50" height="20" rx="3" fill="#dcfce7" stroke="#22c55e" stroke-width="1.5"/>  <line x1="55" y1="40" x2="30" y2="55" stroke="#22c55e" stroke-width="1.5"/>  <line x1="80" y1="40" x2="80" y2="55" stroke="#22c55e" stroke-width="1.5"/>  <line x1="105" y1="40" x2="130" y2="55" stroke="#22c55e" stroke-width="1.5"/>  <rect x="10" y="55" width="40" height="16" rx="3" fill="#e0e7ff" stroke="#6366f1" stroke-width="1"/>  <rect x="60" y="55" width="40" height="16" rx="3" fill="#e0e7ff" stroke="#6366f1" stroke-width="1"/>  <rect x="110" y="55" width="40" height="16" rx="3" fill="#e0e7ff" stroke="#6366f1" stroke-width="1"/>  <text x="80" y="88" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#9ca3af">one to many outputs</text></svg>
</div>

<div style="text-align: center; margin: 0.5em;">
<svg width="160" height="100" viewBox="0 0 160 100" xmlns="http://www.w3.org/2000/svg">  <text x="80" y="12" text-anchor="middle" font-family="sans-serif" font-size="9" font-weight="bold" fill="#7c3aed">Aggregation</text>  <rect x="10" y="22" width="40" height="16" rx="3" fill="#f3e8ff" stroke="#a855f7" stroke-width="1"/>  <rect x="60" y="22" width="40" height="16" rx="3" fill="#f3e8ff" stroke="#a855f7" stroke-width="1"/>  <rect x="110" y="22" width="40" height="16" rx="3" fill="#f3e8ff" stroke="#a855f7" stroke-width="1"/>  <line x1="30" y1="38" x2="70" y2="52" stroke="#a855f7" stroke-width="1.5"/>  <line x1="80" y1="38" x2="80" y2="52" stroke="#a855f7" stroke-width="1.5"/>  <line x1="130" y1="38" x2="90" y2="52" stroke="#a855f7" stroke-width="1.5"/>  <rect x="55" y="52" width="50" height="20" rx="3" fill="#f3e8ff" stroke="#a855f7" stroke-width="1.5"/>  <text x="80" y="88" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#9ca3af">many to one result</text></svg>
</div>

<div style="text-align: center; margin: 0.5em;">
<svg width="160" height="100" viewBox="0 0 160 100" xmlns="http://www.w3.org/2000/svg">  <text x="80" y="12" text-anchor="middle" font-family="sans-serif" font-size="9" font-weight="bold" fill="#92400e">Enrichment</text>  <rect x="10" y="30" width="40" height="20" rx="3" fill="#fef3c7" stroke="#f59e0b" stroke-width="1.5"/>  <line x1="50" y1="40" x2="65" y2="40" stroke="#6b7280" stroke-width="1.5"/>  <polygon points="65,40 60,37 60,43" fill="#6b7280"/>  <rect x="65" y="30" width="40" height="20" rx="3" fill="#fef3c7" stroke="#f59e0b" stroke-width="1.5"/>  <line x1="105" y1="40" x2="120" y2="40" stroke="#6b7280" stroke-width="1.5"/>  <polygon points="120,40 115,37 115,43" fill="#6b7280"/>  <rect x="120" y="30" width="30" height="20" rx="3" fill="#fee2e2" stroke="#ef4444" stroke-width="1.5"/>  <!-- Plus signs -->  <text x="85" y="58" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#f59e0b">+</text>  <line x1="85" y1="20" x2="85" y2="30" stroke="#f59e0b" stroke-width="1" stroke-dasharray="2,1"/>  <rect x="70" y="8" width="30" height="12" rx="2" fill="#fef9c3" stroke="#eab308" stroke-width="1"/>  <text x="80" y="88" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#9ca3af">add related data</text></svg>
</div>

</div>

The linear pipeline is the most common pattern. Data enters at the beginning, flows through a series of transformations, and exits at the end. Each statement takes the output of the previous statement (or the original input) and produces something that the next statement needs. This creates a chain of dependencies that naturally organizes the code.

The fan-out pattern occurs when a single piece of data needs to trigger multiple independent operations. You might create a user and then want to store it, emit an event, log an audit message, and send a notification. Each of these operations uses the same user data but is otherwise independent. The statements appear in sequence but could conceptually execute in parallel because they do not depend on each other's results.

The aggregation pattern collects data from multiple sources and combines it into a single result. You might retrieve users from one repository, orders from another, and products from a third, then create a summary object that includes counts or statistics from all three. The gathering happens through multiple REQUEST actions, and the combination happens through an OWN action that references all the gathered bindings.

The enrichment pattern starts with a primary piece of data and augments it with related information from other sources. You might retrieve an order, then retrieve the customer associated with that order, then retrieve the items in that order, and finally assemble a detailed response that includes all of this related information. The key characteristic is that each subsequent retrieval depends on information from previous retrievals.

These patterns can combine in complex feature sets. A realistic API handler might aggregate data from multiple sources, enrich some of that data with additional lookups, fan out to multiple export operations, and finally return a response. Understanding the underlying patterns helps you navigate this complexity.

---

## 6.5 Cross-Feature Set Communication

Because each feature set has its own isolated symbol table, data does not automatically flow between feature sets. If one feature set creates a value and another feature set needs that value, you must explicitly communicate it through one of several mechanisms.

The Publish action makes a binding available to other feature sets within the same business activity. When you publish a value under an alias, that alias becomes accessible from any feature set with the same business activity that executes afterward. This scoping to business activity enforces modularity—feature sets in different business domains cannot accidentally depend on each other's published variables. Use publishing for configuration data, constants, or values that need to be shared within a domain, but prefer events for communication when the pattern fits.

Events provide a structured way to pass data between feature sets while maintaining loose coupling. When you emit an event with a payload, all handlers for that event type receive access to the payload. The emitting feature set does not need to know which handlers exist or what they will do with the data. The handlers extract what they need from the event payload and proceed independently. This decoupling allows you to add new behaviors by adding handlers without modifying the emitting code.

Repositories act as shared persistent storage. One feature set can store a value to a repository, and another feature set can retrieve it later. This communication is asynchronous in the sense that the retriever does not need to execute while the storer is executing. The repository holds the data between executions. This is appropriate for persistent data that outlives individual requests.

Repository names must end with `-repository`—this is not merely a convention but a requirement that enables the runtime to identify storage targets. When you write `<Store> the <user> into the <user-repository>`, the runtime recognizes `user-repository` as persistent storage because of its suffix. Names like `users` or `user-data` would not trigger repository semantics.

Repositories are scoped to business activities by default. A `user-repository` accessed by feature sets with the business activity "User Management" is separate from a `user-repository` accessed by feature sets with the business activity "Admin Tools". This scoping prevents unintended data sharing between different domains of your application.

Repositories store data as ordered lists. Each Store operation appends to the repository. A Retrieve operation returns all stored items unless you specify a filter with a where clause. This list-based storage differs from key-value stores—you can have multiple items that match the same criteria, and you retrieve them all unless you filter.

The context object provides data that is available to handlers based on how they were triggered. HTTP handlers receive request data. Event handlers receive event payloads. This is not really communication between feature sets but rather communication from the triggering mechanism to the handler. The context is read-only; handlers cannot modify it to communicate back.

---

## 6.6 Qualified Access

When you reference a variable, you can use qualifiers to access nested properties within that variable's value. The qualifier path is written after the variable name, separated by colons. This allows you to navigate into structured data without creating intermediate bindings.

Accessing a property uses a single qualifier: referencing something like `user: name` accesses the name property of the user object. Accessing a deeply nested property chains qualifiers: referencing something like `order: customer.address.city` navigates three levels deep to get the city from the customer's address on the order.

Array indexing works similarly. You can access a specific element by index: referencing `items: 0` gets the most recently added element of the items array. Index 1 gets the second most recent, and so on. This reverse indexing matches common use cases where applications typically want to access recent data. You can combine array access with property access: referencing `items: 0: name` gets the name property of the most recent item.

Qualifiers work on the result of Extract actions, Create actions, and any other action that produces structured data. They also work on context objects like pathParameters, queryParameters, headers, and event payloads. This allows you to extract specific pieces of complex structures without binding the entire structure to an intermediate name.

The qualifier syntax reads naturally when the values have descriptive names. If you have a user with an address that has a city, then `user: address.city` reads almost like natural language describing what you want. This is another aspect of ARO's design philosophy of making code read like descriptions of intent rather than instructions to a computer.

---

## 6.7 Best Practices

Several practices help maintain clarity in data flow.

Keep the flow linear when possible. The most readable feature sets are those where data flows straight through from input to output with clear transformations along the way. When you find yourself with complex dependencies or multiple sources feeding into multiple outputs, consider whether the feature set is doing too much and might benefit from being split or from using events to separate concerns.

Name variables to reflect their state in the transformation pipeline. If you extract raw input, validate it, and then use it to create an entity, names like `raw-input`, `validated-data`, and `user` help readers understand what each value represents at that point in the flow. Names like `data1`, `data2`, and `data3` obscure this progression.

Minimize what you publish. Shared state creates dependencies between feature sets that can make code harder to understand and modify. Each published variable is a potential coupling point within its business activity. Prefer events for communication when the pattern fits, as they are more explicit about what is being communicated and to whom.

Use events for fan-out scenarios. When a single occurrence needs to trigger multiple independent actions, emitting an event and having multiple handlers is cleaner than listing all the actions inline. It also allows you to add new behaviors by adding handlers rather than modifying the original feature set.

Document complex data flows when the structure is not obvious from the code. A comment describing what data is available at each stage, or a diagram showing how data flows through the feature set, can help future readers understand non-trivial transformations.

---

*Next: Chapter 7 — Computations*
