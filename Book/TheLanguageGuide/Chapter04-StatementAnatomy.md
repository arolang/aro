# Chapter 4: Anatomy of a Statement

*"Grammar is the logic of speech."*

---

## 4.1 The Universal Structure

<div style="text-align: center; margin: 2em 0;">
<svg width="520" height="80" viewBox="0 0 520 80" xmlns="http://www.w3.org/2000/svg">  <!-- Action -->  <rect x="5" y="25" width="70" height="30" rx="4" fill="#dbeafe" stroke="#3b82f6" stroke-width="2"/>  <text x="40" y="45" text-anchor="middle" font-family="monospace" font-size="11" fill="#1e40af">&lt;Action&gt;</text>  <text x="40" y="70" text-anchor="middle" font-family="sans-serif" font-size="9" fill="#6b7280">verb</text>  <!-- Article 1 -->  <rect x="85" y="25" width="35" height="30" rx="4" fill="#f3f4f6" stroke="#9ca3af" stroke-width="1"/>  <text x="102" y="45" text-anchor="middle" font-family="serif" font-size="11" fill="#374151">the</text>  <!-- Result -->  <rect x="130" y="25" width="70" height="30" rx="4" fill="#dcfce7" stroke="#22c55e" stroke-width="2"/>  <text x="165" y="45" text-anchor="middle" font-family="monospace" font-size="11" fill="#166534">&lt;Result&gt;</text>  <text x="165" y="70" text-anchor="middle" font-family="sans-serif" font-size="9" fill="#6b7280">output</text>  <!-- Preposition -->  <rect x="210" y="25" width="55" height="30" rx="4" fill="#fef3c7" stroke="#f59e0b" stroke-width="2"/>  <text x="237" y="45" text-anchor="middle" font-family="serif" font-size="11" fill="#92400e">from</text>  <text x="237" y="70" text-anchor="middle" font-family="sans-serif" font-size="9" fill="#6b7280">relation</text>  <!-- Article 2 -->  <rect x="275" y="25" width="35" height="30" rx="4" fill="#f3f4f6" stroke="#9ca3af" stroke-width="1"/>  <text x="292" y="45" text-anchor="middle" font-family="serif" font-size="11" fill="#374151">the</text>  <!-- Object -->  <rect x="320" y="25" width="70" height="30" rx="4" fill="#fce7f3" stroke="#ec4899" stroke-width="2"/>  <text x="355" y="45" text-anchor="middle" font-family="monospace" font-size="11" fill="#9d174d">&lt;Object&gt;</text>  <text x="355" y="70" text-anchor="middle" font-family="sans-serif" font-size="9" fill="#6b7280">input</text>  <!-- Period -->  <rect x="400" y="25" width="25" height="30" rx="4" fill="#1f2937" stroke="#1f2937" stroke-width="2"/>  <text x="412" y="45" text-anchor="middle" font-family="serif" font-size="14" font-weight="bold" fill="#ffffff">.</text>  <!-- Connectors -->  <line x1="75" y1="40" x2="85" y2="40" stroke="#9ca3af" stroke-width="1"/>  <line x1="120" y1="40" x2="130" y2="40" stroke="#9ca3af" stroke-width="1"/>  <line x1="200" y1="40" x2="210" y2="40" stroke="#9ca3af" stroke-width="1"/>  <line x1="265" y1="40" x2="275" y2="40" stroke="#9ca3af" stroke-width="1"/>  <line x1="310" y1="40" x2="320" y2="40" stroke="#9ca3af" stroke-width="1"/>  <line x1="390" y1="40" x2="400" y2="40" stroke="#9ca3af" stroke-width="1"/>  <!-- Legend -->  <text x="460" y="35" font-family="sans-serif" font-size="8" fill="#6b7280">Required</text>  <text x="460" y="50" font-family="sans-serif" font-size="8" fill="#6b7280">elements</text></svg>
</div>

Every ARO statement follows the same grammatical pattern. This is not a guideline or a convention that you might occasionally break. It is an invariant property of the language, enforced by the parser, and fundamental to how ARO works.

The pattern consists of an action, followed by an article, followed by a result, followed by a preposition, followed by another article, followed by an object, and terminated by a period. Within this structure, there are optional elements—qualifiers, literal values, where clauses, and when conditions—but the core pattern is always present.

Understanding this pattern deeply is essential because it shapes how you think about expressing operations in ARO. When you internalize the pattern, writing ARO code becomes as natural as writing sentences. When you fight against the pattern, trying to express operations that do not fit, you struggle unnecessarily. The pattern is not a constraint to overcome but a tool to master.

Let us examine each component in detail, understanding not just what it is but why it exists and how it contributes to the expressiveness of the language.

## 4.2 Actions: The Verb of Your Sentence

An action is a verb enclosed in angle brackets. It tells the reader what operation the statement performs. Actions are the most prominent part of any ARO statement because they appear at the beginning and because they carry semantic meaning that affects how the runtime behaves.

When you write an action, you are choosing from a vocabulary of approximately fifty built-in verbs, each representing a fundamental operation. The choice of verb is significant because each verb carries a semantic role that determines the direction of data flow. When you choose Extract, you are telling the runtime that you want to pull data from an external source into the current context. When you choose Return, you are telling the runtime that you want to send data out to the caller and terminate execution.

The verbs are case-sensitive. Extract is a valid action. extract is not. This case sensitivity is deliberate: it makes actions visually distinctive from other identifiers in your code, and it aligns with the convention that actions are proper verbs deserving of capitalization.

The built-in actions cover the operations that virtually every business application needs. You can extract data from requests, retrieve data from repositories, create new values, validate inputs against schemas, transform data between formats, store data persistently, emit events for other handlers, and return responses to callers. When these built-in actions are insufficient for your needs, you can create custom actions in Swift, extending the vocabulary of the language for your specific domain.

The power of actions comes from their abstraction. When you write a Retrieve action, you are not specifying whether the data comes from an in-memory store, a relational database, a document database, or an external service. You are expressing the intent to retrieve data from a named repository. The runtime, or a custom action implementation, handles the details. This abstraction allows your ARO code to remain focused on business logic while technical concerns are handled elsewhere.

## 4.3 Results: The Noun You Create

The result is the variable that will hold the value produced by the action. It appears after the action and its article, enclosed in angle brackets. The result is where the output of the operation lands, giving it a name that you can reference in subsequent statements.

Choosing good result names is one of the most important skills in writing ARO code. The name you choose becomes part of the program's documentation. It appears in error messages when something goes wrong. It serves as the identifier that subsequent statements use to reference the value. A well-chosen name makes the code self-explanatory; a poorly chosen name obscures intent.

Consider the difference between naming a result "x" versus naming it "user-email-address." The first name tells you nothing about what the value represents. The second name tells you exactly what you are dealing with. Because ARO does not allow you to rebind names, you cannot use generic names for everything. This constraint pushes you toward descriptive names, which in turn makes your code more readable.

Results can include type qualifiers, written after a colon. When you write a result like "user-id: String" you are documenting that the result is expected to be a string. Currently, ARO uses runtime typing, so these qualifiers do not affect execution. However, they serve as documentation for readers and may enable static type checking in future versions of the language. Using qualifiers is optional but recommended for results whose types are not obvious from context.

ARO allows hyphenated identifiers, which is unusual among programming languages. This feature exists because hyphenated names often read more naturally than camelCase or snake_case for business concepts. "user-email-address" reads more like natural language than "userEmailAddress" or "user_email_address." You can choose whichever style you prefer, but the language supports hyphens for those who want them.

## 4.4 Objects: The Context You Operate On

The object is the input or context for the action. It appears after the preposition, enclosed in angle brackets. The object provides the data or reference that the action operates on.

Objects are introduced by prepositions, and the choice of preposition is significant. The preposition communicates the relationship between the action and its object. Different prepositions imply different types of operations, and the runtime uses this information to understand data flow.

Like results, objects can include qualifiers. When you write an object like "request: body" you are specifying that you want the body property of the request. Qualifiers allow you to navigate into nested structures. You can chain qualifiers to access deeply nested properties, writing something like "user: address.city" to access the city property of the address property of the user.

The distinction between results and objects is fundamental. Results are outputs—the values produced by actions, which become available for subsequent statements. Objects are inputs—the values consumed by actions, which must have been produced by previous statements or be available from the execution context. This input-output distinction is how data flows through a feature set.

## 4.5 Prepositions: The Relationships Between Things

Prepositions are small words that carry large meaning. In ARO, prepositions connect actions to their objects while communicating the nature of that connection. The language supports ten prepositions:

| Preposition | Meaning | Common Actions |
|-------------|---------|----------------|
| `from` | Source extraction | Extract, Retrieve, Request, Read |
| `with` | Accompaniment/provision | Create, Return, Emit |
| `for` | Purpose/target | Compute, Return, Log |
| `to` | Destination | Send, Write |
| `into` | Insertion | Store |
| `against` | Comparison/validation | Validate, Compare |
| `via` | Intermediate channel | Request (with proxy) |
| `on` | Location/attachment | Listen, Start |
| `at` | Position/placement | CreateDirectory, Make |
| `as` | Type annotation | Filter, Reduce, Map |

Choosing the right preposition makes your code clearer and more accurate. When you extract a user identifier from the path parameters, "from" is the natural choice. When you create a user with provided data, "with" is the natural choice. When you store a user into a repository, "into" is the natural choice. Let the semantics of your operation guide your choice of preposition.

> **See Appendix B** for complete preposition semantics with examples.

## 4.6 Articles: The Grammar Connectors

Articles—"the," "a," and "an"—appear between the action and the result, and between the preposition and the object. They serve a grammatical purpose, making statements read like natural English sentences.

The choice of article does not affect the semantics of the statement. Whether you write "the user" or "a user" has no impact on how the statement executes. However, the choice can affect readability. In general, use "the" when referring to a specific, known thing, and use "a" or "an" when introducing something new or when the thing is one of many possible things.

For results, "the" is usually the appropriate choice because you are creating a specific binding. For objects, "the" is also usually appropriate because you are referring to something specific. For return statuses, "an" or "a" often reads more naturally—"Return an OK status" rather than "Return the OK status."

The important thing is to be consistent within your codebase. Whether you prefer "the" everywhere or vary your articles for readability, stick with your choice so that readers can focus on the meaning rather than the grammatical choices.

## 4.7 Literal Values

Some statements include literal values—strings, numbers, booleans, arrays, or objects. Literal values provide concrete data within the statement rather than referencing previously bound variables.

String literals are enclosed in double quotes. You can include special characters using escape sequences: backslash-n for newline, backslash-t for tab, backslash followed by a quote for a literal quote character. Strings can contain any text and are commonly used for messages, paths, and configuration values.

Number literals can be integers or floating-point values. Integers are written as sequences of digits, optionally preceded by a minus sign for negative numbers. Floating-point numbers include a decimal point between digits. There is no distinction in syntax between integers and floats; the runtime handles numeric types appropriately.

Boolean literals are written as "true" or "false" without any enclosing symbols. They represent the two truth values and are commonly used for flags and conditions.

Array literals are enclosed in square brackets with elements separated by commas. The elements can be any valid expression, including other literals, variable references, or nested arrays. Array literals provide a convenient way to create collections inline.

Object literals are enclosed in curly braces with fields written as key-colon-value pairs separated by commas. The keys are identifiers; the values can be any valid expression. Object literals allow you to construct structured data inline, which is particularly useful for return values and event payloads.

```aro
<Create> the <user> with { name: "Alice", email: "alice@example.com", active: true }.
```

## 4.8 Where Clauses

The where clause allows you to filter or constrain operations. It appears after the object clause and begins with the keyword "where," followed by a condition.

Where clauses are most commonly used with Retrieve actions to specify which records to fetch from a repository. When you write a where clause, you are expressing a constraint that the retrieved data must satisfy. The repository implementation uses this constraint to filter results, often translating it into a database query.

Conditions in where clauses can use equality checks with "is" or "=" and inequality checks with "!=". They can use comparison operators for numeric values. They can combine multiple conditions with "and" and "or." The expressive power is similar to the WHERE clause in SQL, which is intentional—many repositories are backed by databases, and the mapping should be straightforward.

Where clauses can also appear with Filter actions, where they specify which elements of a collection to include in the result. The semantics are the same: only elements satisfying the condition are included.

```aro
<Retrieve> the <order> from the <order-repository> where id = <order-id>.
```

## 4.9 When Conditions

The when condition allows you to make a statement conditional on some expression being true. It appears at the end of the statement, after any where clause, and begins with the keyword "when."

Unlike traditional if-statements, when conditions do not create branches in control flow. A statement with a when condition either executes (if the condition is true) or is skipped (if the condition is false). There is no else clause, no alternative path. This design keeps the linear flow of ARO feature sets intact while allowing for conditional execution of individual statements.

When conditions are useful for optional operations—things that should happen only if certain prerequisites are met. For example, you might send a notification only when the user has opted into notifications, or log debug information only when debug mode is enabled.

The condition can be any boolean expression. You can reference bound variables, compare values, check for existence, and combine conditions with logical operators. The same expression syntax used elsewhere in ARO applies within when conditions.

```aro
<Send> the <notification> to the <user: email> when <user: notifications> is true.
```

## 4.10 Comments

Comments in ARO use Pascal-style syntax: an opening parenthesis followed by an asterisk, the comment text, an asterisk followed by a closing parenthesis. Comments can span multiple lines and can appear anywhere in the source where whitespace is allowed.

Comments are completely ignored by the parser. They exist solely for human readers, providing explanation, context, or temporary notes. Use comments to explain why something is done, not what is done. The code itself, with its natural-language-like structure, should explain what is happening.

## 4.11 Statement Termination

Every statement ends with a period. This is not optional; omitting the period is a syntax error. The period serves as an unambiguous statement terminator, making it clear where one statement ends and the next begins.

The period also reinforces the sentence metaphor. Just as English sentences end with periods, ARO statements end with periods. This small detail contributes to the natural-language feel of ARO code.

## 4.12 Putting It All Together

Having examined each component in isolation, let us see how they combine in complete statements of varying complexity.

A minimal statement has an action, an article, a result, a preposition, an article, and an object:

```aro
<Retrieve> the <users> from the <user-repository>.
```
*Source: [Examples/UserService/users.aro:7](../Examples/UserService/users.aro)*

A statement with a qualifier on the result and object adds more specificity:

```aro
<Extract> the <user-id: String> from the <pathParameters: id>.
```

A statement with a literal value provides data inline:

```aro
<Create> the <greeting> with "Hello, World!".
```

A statement with an expression computes a value:

```aro
<Compute> the <total> with <subtotal> + <tax>.
```

A statement with a where clause filters the operation:

```aro
<Retrieve> the <user> from the <user-repository> where <id> is <user-id>.
```
*Source: [Examples/UserService/users.aro:14](../Examples/UserService/users.aro)*

A statement with a when condition executes conditionally:

```aro
<Send> the <notification> to the <user> when <user: notifications> is true.
```

Each of these statements follows the same fundamental pattern while using optional elements to add precision and expressiveness. The pattern is the constant; the optional elements are the variables. Once you internalize the pattern, you can read and write any ARO statement fluently.

---

*Next: Chapter 5 — Feature Sets*
