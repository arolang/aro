# Chapter 24: Custom Actions

*"When 61 actions aren't enough, write your own."*

---

## 24.1 When to Create Custom Actions

ARO's built-in actions cover common operations, but real applications often need capabilities beyond the standard set. Custom actions extend the language with domain-specific operations while maintaining ARO's declarative style.

Create custom actions when you need to integrate with external services. Database drivers, message queues, third-party APIs, and specialized protocols all require code that cannot be expressed in ARO alone. A custom action wraps the integration logic and exposes it through a clean verb in your ARO code.

Create custom actions when you need complex business logic that does not fit ARO's linear statement model. Algorithms, complex validations, recursive processing, and stateful operations are better expressed in Swift. The custom action handles the complexity; the ARO statement expresses the intent.

Create custom actions when you want to wrap existing Swift or Objective-C libraries. Rich ecosystems of libraries exist for image processing, machine learning, cryptography, and countless other domains. Custom actions bridge these libraries into ARO.

Create custom actions when you want domain-specific operations that make your ARO code more expressive. Instead of multiple generic statements, a single statement with a domain-specific verb can express complex operations clearly.

---

## 24.2 The Escape Hatch Pattern

No constrained language survives contact with reality without an extension mechanism. This is the pattern that made other constrained languages successful: Terraform has providers, Ansible has modules, Make has recipes—and ARO has actions and services.

The contract is clear: ARO gives you rails; you build the track extensions when the rails don't go where you need.

ARO provides two extension mechanisms:

| Mechanism | What It Adds | Syntax | Best For |
|-----------|--------------|--------|----------|
| **Custom Actions** | New verbs | `Geocode the <coords> from <addr>.` | Domain-specific operations |
| **Custom Services** | External integrations | `Call from <postgres: query>` | Systems with multiple methods |

Custom actions, covered in this chapter, let you add new verbs to the language. When you implement a custom action, you can write statements like `Geocode the <coordinates> from the <address>` that feel native to ARO.

Custom services, covered in Chapter 24, let you integrate external systems through the `Call` action. Services provide multiple methods under a single service name: `Call from <postgres: query>`, `Call from <postgres: insert>`.

Plugins, covered in Chapter 25, let you package and share both actions and services with the community.

The rest of this chapter focuses on implementing custom actions—the fundamental building block of ARO's extensibility.

---

## 24.3 The Action Protocol

Every custom action implements the ActionImplementation protocol. This protocol defines the structure that the runtime expects: a role indicating data flow direction, a set of verbs that trigger the action, valid prepositions that can appear with the action, and an execute method that performs the work.

The role categorizes the action by its data flow direction. REQUEST actions bring data from outside the feature set inward—fetching from APIs, querying databases, reading external state. OWN actions transform data already present in the feature set—computing, validating, reformatting. RESPONSE actions send data out and terminate execution—returning results, throwing errors. EXPORT actions send data out without terminating—storing, emitting events, logging.

The verbs set contains the words that trigger this action. When the parser sees one of these verbs in an action statement, it resolves to this action implementation. Choose verbs that read naturally and describe what the action does. A geocoding action might use "Geocode" as its verb.

The valid prepositions set constrains how the action can be used syntactically. If your action makes sense with "from" (extracting from a source) but not "into" (inserting into a destination), include only "from" in the valid prepositions. This helps catch misuse at parse time.

The execute method does the actual work. It receives descriptors for the result and object from the statement, plus an execution context that provides access to bound values and methods for binding new values.

---

<div style="text-align: center; margin: 2em 0;">
<svg xmlns="http://www.w3.org/2000/svg" width="280" height="210" font-family="sans-serif">
  <!-- Step 1: Action definition (dark) -->
  <rect x="55" y="10" width="170" height="50" rx="4" fill="#1f2937" stroke="#1f2937" stroke-width="2"/>
  <text x="140" y="30" text-anchor="middle" font-size="10" fill="#ffffff" font-weight="bold">verbs: ["MyVerb"]</text>
  <text x="140" y="48" text-anchor="middle" font-size="10" fill="#ffffff">role: .own</text>

  <!-- Arrow down: registered -->
  <line x1="140" y1="60" x2="140" y2="93" stroke="#9ca3af" stroke-width="1.5"/>
  <polygon points="140,93 135,84 145,84" fill="#9ca3af"/>
  <text x="155" y="82" text-anchor="start" font-size="9" fill="#6b7280">registered</text>

  <!-- Step 2: ActionRegistry (indigo) -->
  <rect x="55" y="97" width="170" height="40" rx="4" fill="#e0e7ff" stroke="#6366f1" stroke-width="2"/>
  <text x="140" y="117" text-anchor="middle" font-size="11" fill="#4338ca" font-weight="bold">ActionRegistry</text>
  <text x="140" y="131" text-anchor="middle" font-size="9" fill="#4338ca">verb → implementation</text>

  <!-- Arrow down: matched at runtime -->
  <line x1="140" y1="137" x2="140" y2="168" stroke="#9ca3af" stroke-width="1.5"/>
  <polygon points="140,168 135,159 145,159" fill="#9ca3af"/>
  <text x="148" y="158" text-anchor="start" font-size="9" fill="#6b7280">matched at runtime</text>

  <!-- Step 3: execute() called (green) -->
  <rect x="30" y="172" width="220" height="30" rx="4" fill="#d1fae5" stroke="#22c55e" stroke-width="2"/>
  <text x="140" y="192" text-anchor="middle" font-size="10" fill="#166534">execute(result:object:context:)</text>
</svg>
</div>

## 24.4 Accessing the Context

The execution context is your interface to the ARO runtime. Through it, you access values bound by previous statements, bind new values for subsequent statements, and interact with the event system.

Getting values retrieves bindings created by earlier statements. The require method returns a value and throws if the binding does not exist—use this for required inputs. The get method returns an optional value—use this for optional inputs where missing values are acceptable.

Setting values creates bindings that subsequent statements can access. The bind method associates a value with a name. You typically bind the result using the identifier from the result descriptor, but you can bind additional values if your action produces multiple outputs.

The object descriptor contains information about the statement's object clause. The identifier is the object name. The qualifier, if present, is the path after the object name. For a statement referencing "user: address", the identifier is "user" and the qualifier is "address".

The event bus is accessible through the context for emitting events. Your action can emit domain events that trigger handlers elsewhere in the application.

---

## 24.5 Implementing an Action

Implementing a custom action follows a consistent pattern. You define a struct that conforms to ActionImplementation, specify the required static properties, and implement the execute method.

Begin by choosing an appropriate role based on what the action does with data. If it pulls data from an external source, use REQUEST. If it transforms existing data, use OWN. If it sends data out and ends execution, use RESPONSE. If it has side effects but allows execution to continue, use EXPORT.

Choose verbs that describe the action clearly. The verb appears in ARO statements, so it should read naturally. For a geocoding service, "Geocode" is clear. For a payment processor, "Charge" or "ProcessPayment" might work.

Specify which prepositions make sense for your action. Think about how the statement will read. "Geocode the coordinates from the address" suggests "from" is appropriate. "Encrypt the ciphertext with the key" suggests "with" is appropriate.

In the execute method, retrieve inputs from the context, perform your operation, bind outputs, and return the primary result. Handle errors by throwing exceptions—the runtime converts these to ARO error messages.

---

## 24.6 Error Handling

Custom actions report errors by throwing Swift exceptions. The runtime catches these exceptions and converts them to ARO error messages that follow the happy path philosophy.

Throw descriptive errors that explain what went wrong. Include relevant values in the error message so users can understand the failure. "Cannot geocode address 'invalid street': service returned no results" is more helpful than "Geocoding failed."

Consider the different failure modes your action might encounter. Network errors, validation failures, resource not found, permission denied—each deserves a distinct error message. Users who see these messages should understand both what happened and, ideally, what they might do about it.

The runtime integrates your errors with its error handling system. HTTP handlers convert errors to appropriate status codes. Logging includes the full error context. The error message you throw becomes part of the user-visible output.

---

## 24.7 Async Operations

Custom actions can be asynchronous, which is essential for I/O operations. The execute method is declared async, so you can await async operations within it.

Network requests, database queries, file operations, and external API calls should all use async/await rather than blocking. This allows the runtime to handle other work while waiting for I/O to complete.

Swift's async/await syntax integrates naturally. You await async calls, handle their results, and proceed. The ARO runtime manages the execution, ensuring that statement ordering is maintained even with concurrent underlying operations.

Timeouts and cancellation should be considered for long-running operations. If your action might take a long time, consider implementing timeout logic or checking for cancellation signals.

---

## 24.8 Thread Safety

Actions must be thread-safe because the runtime may execute them concurrently. Swift's Sendable protocol, which ActionImplementation requires, helps enforce this.

Design actions to be stateless when possible. Actions that store state between invocations create potential for race conditions. If state is necessary, use appropriate synchronization mechanisms.

Dependencies like database connection pools or HTTP clients should be thread-safe. Most well-designed Swift libraries provide thread-safe interfaces. If you are uncertain about a dependency's thread safety, consult its documentation.

Avoid mutable shared state. If your action needs configuration, receive it during initialization and store it immutably. If your action needs to accumulate results, use the context's binding mechanism rather than internal state.

---

## 24.9 Registration

Custom actions must be registered with the action registry before they can be used. Registration tells the runtime which action implementation handles which verbs.

Registration typically happens during application initialization, before any ARO code executes. For embedded applications, you register actions in your Swift startup code. For plugin-based actions, the plugin system handles registration automatically.

Registration is straightforward: you call the register method on the shared action registry, passing your action type. The runtime examines the type's static properties to learn its verbs and incorporates it into action resolution.

Once registered, your action's verbs become available in ARO code. Statements using those verbs route to your implementation. The integration is seamless—users of your action need not know whether it is built-in or custom.

### Plugin Input JSON

When an action is invoked through a plugin, the runtime passes a rich input JSON payload that includes not only the primary data but also the full result and source descriptors, preposition, execution context, and `with` clause parameters:

```json
{
  "data": "the primary object value",
  "qualifier": "the result qualifier (e.g., sha256)",
  "preposition": "from",
  "result": {
    "base": "digest",
    "qualifiers": ["sha256"],
    "specifiers": ["sha256"]
  },
  "source": {
    "base": "password",
    "specifiers": []
  },
  "_context": {
    "requestId": "req-abc-123",
    "featureSet": "Secure Password: User Registration",
    "businessActivity": "User Registration"
  },
  "_with": {
    "encoding": "hex",
    "rounds": 10
  }
}
```

The `result` and `source` fields expose the full `ResultDescriptor` and `ObjectDescriptor` models. The `_context` field carries execution context information. The `_with` field contains parameters from the `with { }` clause as a nested object—these are no longer merged flat into the top-level input. Plugin code should read `with` parameters from `_with`, not from top-level keys.

Note that `aro_plugin_execute` is **optional** for qualifier-only plugins. If your plugin provides only qualifiers (no actions or services), you do not need to implement this function at all.

---

## 24.10 Best Practices

Single responsibility keeps actions focused and testable. Each action should do one thing well. If an action is doing multiple distinct operations, consider splitting it into multiple actions.

Choose verbs that read naturally in ARO statements. The statement "Geocode the coordinates from the address" should sound like a sentence describing what happens. Avoid generic verbs like "Process" or "Handle" that do not convey meaning.

Provide helpful error messages. When your action fails, users see your error message. Invest effort in making these messages clear and actionable.

Document your actions. Other developers using your actions need to know what verbs are available, what prepositions are valid, what inputs are expected, and what outputs are produced. This documentation might live in code comments, separate documentation files, or both.

Test actions independently. Because actions have a well-defined interface, they are straightforward to unit test. Create mock contexts, invoke the execute method, and verify the results.

---

*Next: Chapter 25 — Custom Services*
