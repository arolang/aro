# FIXTRAIN — Training Data Issues in knowledge_pairs.jsonl

Source file: `/Volumes/Models/data/02_knowledge/knowledge_pairs.jsonl`
Total entries: 6,435
Issues found: 83
Verified against: Proposals/, Sources/, Book/, Examples/

## Issue Categories Summary

| Category | Count |
|----------|-------|
| String concatenation `+` instead of `++` | 14 |
| Wrong `Emit` syntax | 14 |
| Wrong `Publish` syntax / semantics | 8 |
| Hallucinated `when { }` block construct | 6 |
| Feature set header missing business activity | 7 |
| Invalid `Compute from X with Y` for arithmetic | 5 |
| Wrong action prepositions (`Throw`, `Delete`, `Accept`, `Transform`) | 6 |
| Hallucinated actions (`Subscribe`, `Set`, `Build`, `while`) | 5 |
| Wrong feature set declaration syntax | 4 |
| Wrong behavioral claim (immutability, subdirectories, set ops) | 5 |
| Hallucinated non-ARO syntax (`<-` arrow, type annotations) | 4 |
| Wrong Log syntax | 8 |
| Miscellaneous (HTTP routes, streaming, Return, Listen, Render) | 7 |

---

## ISSUE-001: Emit — data/event positions swapped, missing `: event` qualifier

**Source entry:** `book:Chapter08-ExportActions`
**Wrong original:** `Emit the <user> to the <user-created-event>.`
**Why it's wrong:** Emit requires the event type in the **result** position with a `: event` qualifier, and the payload after `with`. This example reverses them: `<user>` (data) is in result position, the event name is in object position, and uses wrong preposition `to`. Article should be `a`/`an` not `the`.
**Corrected version:** `Emit a <UserCreated: event> with <user>.`
**Origin:** `Book/TheLanguageGuide/AppendixA-ActionReference.md` §Emit — "Valid Prepositions: `with`"

---

## ISSUE-002: Log — `for ... with` is not a valid Log form

**Source entry:** `proposal:ARO-0019-standard-library:0` through `:8` (lines 170, 172, 173, 176, 177, 178)
**Wrong original:** `Log the <message> for the <console> with "Calculator ready".` (and similar)
**Why it's wrong:** Log syntax is `Log <message> to the <console>.` — preposition is `to`, not `for`. There is no combined `for` + `with` form. The extra `<message>` result variable is also incorrect; Log takes the message directly as the first argument.
**Corrected version:** `Log "Calculator ready" to the <console>.`
**Origin:** `Book/TheLanguageGuide/AppendixA-ActionReference.md` §Log

---

## ISSUE-003: String concatenation `+` instead of `++` (lines 170, 174–175 range)

**Source entry:** `proposal:ARO-0014-domain-modeling:6` (line 170)
**Wrong original:** `"Order placed: " + <order-id>`
**Why it's wrong:** ARO uses `++` for string concatenation. `+` is reserved for numeric arithmetic only. Mixing string operands with `+` is an error.
**Corrected version:** `"Order placed: " ++ <order-id>`
**Origin:** `Book/TheLanguageGuide/Chapter09-Computations.md` §String Concatenation — "ARO uses `++` for string concatenation, distinct from the `+` arithmetic operator"

---

## ISSUE-004: `Compute from <X> with <Y>` used for arithmetic without an operation qualifier

**Source entry:** `proposal:ARO-0019-standard-library:0`, `:1` (lines 174, 175)
**Wrong original:** `Compute the <total> from the <quantity> with <price>.` / `Compute the <tax> from the <subtotal> with <tax-rate>.`
**Why it's wrong:** The `Compute … from <A> with <B>` form is only valid for set operations (where a qualifier like `: intersect`, `: union`, or `: difference` is on the result). For arithmetic, the expression goes entirely after `from`: `Compute the <total> from <quantity> * <price>.`
**Corrected version:** `Compute the <total> from <quantity> * <price>.`
**Origin:** `Book/TheLanguageGuide/AppendixA-ActionReference.md` §Compute; `Book/TheLanguageGuide/Chapter09-Computations.md` §Set Operations

---

## ISSUE-005: `while` loop is not a canonical ARO construct

**Source entry:** `example:WhileLoop` (line 96)
**Wrong original:** `while <count> <= 3 { ... }` with attribution `(* ARO-0131: While Loop Demo *)`
**Why it's wrong:** No ARO proposal defines a `while` loop. The only iteration construct is `For-each`. Proposal `ARO-0131` does not exist in the codebase. Presenting `while` as canonical ARO syntax is incorrect.
**Corrected version:** Use `For-each <item> in <collection> { ... }` for iteration. For counted loops, create a range collection and iterate it.
**Origin:** `Book/TheLanguageGuide/AppendixA-ActionReference.md` (no `While` action entry); `CLAUDE.md` §ARO Syntax

---

## ISSUE-006: Wrong feature set declaration syntax — `Application X {` / `Feature set X {`

**Source entry:** `actions_context` (lines 224, 314, 329, 382)
**Wrong original:** `Application ExtractDemo {` / `Feature set ProcessOrder {` / `Feature Set: Execute Action Examples {` / `Application Emit Demo {`
**Why it's wrong:** ARO feature set declarations must follow exactly `(Feature Name: Business Activity) { ... }`. None of the forms `Application X {`, `Feature set X {`, or `Feature Set: X {` exist. The colon-separated business activity inside parentheses is mandatory.
**Corrected version:** `(ExtractDemo: My Application) { ... }`
**Origin:** `Book/TheLanguageGuide/Chapter06-FeatureSets.md` §6.2; `CLAUDE.md` §ARO Syntax

---

## ISSUE-007: Missing angle brackets on variable references

**Source entry:** `actions_context` (line 224)
**Wrong original:** `Extract the age from the person` / `Transform the data` / `Filter the records` (no angle brackets, no trailing period)
**Why it's wrong:** All variable identifiers in ARO must be enclosed in angle brackets `<...>`. Bare words are not valid variable references. Statements require a trailing period.
**Corrected version:** `Extract the <age> from the <person>.`
**Origin:** `Book/TheLanguageGuide/Chapter04-StatementAnatomy.md` §Result and Object Positions; `Sources/AROParser/Parser.swift`

---

## ISSUE-008: Execute — wrong preposition `from` instead of `for`

**Source entry:** `actions_context` (line 329)
**Wrong original:** `Execute the <result> from the <console> with "date +%Y-%m-%d".`
**Why it's wrong:** Execute uses `for` to identify the command, not `from`. `from the <console>` incorrectly implies the console is a data source. The feature set header is also invalid syntax (`Feature Set: Execute Action Examples {`).
**Corrected version:** `Execute the <result> for the <command: "date +%Y-%m-%d">.`
**Origin:** `Book/TheLanguageGuide/AppendixA-ActionReference.md` §Execute — "Valid Prepositions: `for`, `on`, `with`"

---

## ISSUE-009: Throw — extra invalid clauses after `for`

**Source entry:** `actions_context` (line 361)
**Wrong original:** `Throw an <Unauthorized: error> for the <admin> to the <console> with <no access>.`
**Why it's wrong:** `Throw` accepts only the `for` preposition. The additional clauses `to the <console>` and `with <no access>` are not valid for Throw.
**Corrected version:** `Throw an <Unauthorized: error> for the <admin>.`
**Origin:** `Book/TheLanguageGuide/AppendixA-ActionReference.md` §Throw — "Valid Prepositions: `for`"

---

## ISSUE-010: Log — extra trailing clauses beyond `to the <console>`

**Source entry:** `actions_context` (line 371)
**Wrong original:** `Log <debug> to the <console> for the <application> with <level>.`
**Why it's wrong:** Once the `to the <console>` target is specified, Log accepts no further clauses.
**Corrected version:** `Log <debug> to the <console>.`
**Origin:** `Book/TheLanguageGuide/AppendixA-ActionReference.md` §Log

---

## ISSUE-011: Emit — used as console-output action with entirely wrong syntax

**Source entry:** `actions_context` (line 382)
**Wrong original:** `emit "Hello from ARO!" to the <console> <Output>.` / `Emit the <result> to the <console> for the <debug>.` / `Emit <literal> "Success!" to the <console> for the <debug>.` / `Emit <event> when <keyboard> key <space> is pressed.`
**Why it's wrong:** `Emit` is a domain-event publisher, not a console-output action. These forms are completely fabricated syntax. Console output uses `Log`. None of these patterns have any basis in the ARO specification.
**Corrected version:** `Emit a <UserCreated: event> with <user>.` (for domain events); `Log "Hello" to the <console>.` (for console output)
**Origin:** `Book/TheLanguageGuide/AppendixA-ActionReference.md` §Emit, §Log

---

## ISSUE-012: Publish — inverted syntax + hallucinated `Build` action

**Source entry:** `actions_context` (line 407)
**Wrong original:** `Publish the <result> as <build>.` and `Build the <result> with <options> from the <source>.`
**Why it's wrong:** (1) `Publish` syntax is `Publish as <alias> <variable>.` — alias comes first, variable second. The shown entry reverses them. (2) `Build` is not a defined ARO action in any proposal or the action catalog.
**Corrected version:** `Publish as <build> <result>.`
**Origin:** `Book/TheLanguageGuide/AppendixA-ActionReference.md` §Publish — "Publish as `<alias>` `<variable>`."

---

## ISSUE-013: `when { } else { }` standalone block construct does not exist in ARO

**Source entry:** `actions_context` (line 482)
**Wrong original:** `when true { ... } else { ... }` and `when <condition> { ... } else { ... }` as standalone control-flow blocks. Also uses `{ "Business Activity: Feature Sets"` as a feature set header.
**Why it's wrong:** In ARO, `when` is exclusively a **per-statement suffix guard** (`Log <msg> to the <console> when <ready>.`) or a **feature-set declaration guard** on event handler headers. There are no standalone `when { } else { }` block constructs. The `{ "Business Activity: ..." }` feature set header format is also fabricated.
**Corrected version:** `Return an <OK: status> with <user> when <active>.`
**Origin:** `Book/TheLanguageGuide/Chapter33-ControlFlow.md` §When Guards — "The `when` clause conditionally executes a single statement."

---

## ISSUE-014: String concatenation `+` in TheConstructionStudies examples (lines 1609, 1611, 1682, 1953)

**Source entry:** `book_qa:TheConstructionStudies:AppendixB-Grammar:Notation` (lines 1609, 1611); `book_qa:TheConstructionStudies:Chapter01-DesignPhilosophy:Trade-offs` (line 1682); `book_qa:TheConstructionStudies:Chapter08-NativeCompilation:Historical Note` (line 1953)
**Wrong original (1609):** "The comma operator is used for string concatenation in ARO. You can use it to combine strings like this: `result = "Hello" + " " + "World"`"
**Wrong original (1682):** `Throw a <CustomError: status> with "Processing failed due to" + <result>.`
**Wrong original (1953):** `Create the <ir-output> with "Hello, World" + "\n".`
**Why it's wrong:** ARO uses `++` for string concatenation. `+` is the arithmetic addition operator. There is no "comma operator". The shown code also uses assignment syntax (`result =`) which is not valid ARO.
**Corrected version:** `Compute the <greeting> from "Hello, " ++ "World".` / `Throw a <CustomError: error> with "Processing failed due to " ++ <result>.`
**Origin:** `Book/TheLanguageGuide/Chapter09-Computations.md` §String Concatenation

---

## ISSUE-015: Wrong claim — ARO does not support subdirectories for `.aro` files

**Source entry:** `book_qa:AROByExample:Chapter02-ProjectSetup:2.3 ARO Application Structure` (line 775)
**Wrong original:** "All `.aro` files exist at the top level of the application directory. ARO does not support subdirectories for `.aro` files."
**Why it's wrong:** This is factually incorrect. ARO automatically discovers `.aro` files in the application directory AND all subdirectories to any depth. The `sources/` subdirectory convention is explicitly supported.
**Corrected version:** All `.aro` files in the directory and subdirectories are automatically discovered. Files can be in root, `sources/`, or any subdirectory to any depth.
**Origin:** `CLAUDE.md` §Application Structure; `Book/TheLanguageGuide/Chapter06-FeatureSets.md` §Multi-file Applications

---

## ISSUE-016: Invalid `Compute from X with Y` for arithmetic (lines 532, 556, 1092)

**Source entry:** `mutation` (lines 532, 556); `book_qa:AROByExample:Chapter01-Introduction:1.7 What Needs Improvement` (line 1092)
**Wrong original (532):** `Compute the <doubled> from <counter> with <counter> * 2.`
**Wrong original (556):** `Compute the <square> from <number> with <number>.`
**Wrong original (1092):** `Compute the <discount> from <amount> with <rate>.`
**Why it's wrong:** The `from X with Y` form of Compute is only valid for set operations (`intersect`, `union`, `difference`) where a qualifier is present. For arithmetic, the entire expression goes after `from`.
**Corrected version:** `Compute the <doubled> from <counter> * 2.` / `Compute the <square> from <number> * <number>.` / `Compute the <discount> from <amount> * <rate>.`
**Origin:** `Book/TheLanguageGuide/Chapter09-Computations.md` §Set Operations vs §Arithmetic

---

## ISSUE-017: `count` is not a set operation

**Source entry:** `book_qa:AROByExample:Chapter11-SetOperations:11.10 What Could Be Better` (line 1417)
**Wrong original:** "ARO provides basic set operations: union, difference, and **count**."
**Why it's wrong:** The three set operations are `intersect`, `difference`, and `union`. `count` is a built-in computation qualifier (`Compute the <n: count> from <items>.`), not a set operation.
**Corrected version:** ARO provides three set operations: `intersect`, `union`, and `difference`, used as `Compute the <result: intersect> from <a> with <b>.`
**Origin:** `Book/TheLanguageGuide/Chapter35-SetOperations.md`; `Book/TheLanguageGuide/Chapter09-Computations.md` §Set Operations

---

## ISSUE-018: Missing set-op qualifier on `difference` result variable

**Source entry:** `book_qa:AROByExample:Chapter11-SetOperations:11.10 What Could Be Better` (line 1417)
**Wrong original:** `Compute the <missing-items> from the <expected> with the <found>.`
**Why it's wrong:** Without the `: difference` qualifier on the result, Compute does not know which set operation to perform.
**Corrected version:** `Compute the <missing-items: difference> from the <expected> with the <found>.`
**Origin:** `Book/TheLanguageGuide/Chapter09-Computations.md` §Set Operations

---

## ISSUE-019: Feature set header using string `+` expression as name (lines 1271–1273)

**Source entry:** `book_qa:AROByExample:Chapter07-URLNormalization:7.12 What Could Be Better` (lines 1271, 1272, 1273)
**Wrong original:** `("Strip Fragment: " + <url: "https://example.com/page#section1">) {`
**Why it's wrong:** Feature set headers must follow `(FeatureName: BusinessActivity) {`. A string concatenation expression `"string" + <var>` is not a valid feature set name.
**Corrected version:** `(StripFragment: URL Normalization) {`
**Origin:** `Book/TheLanguageGuide/Chapter06-FeatureSets.md` §6.2

---

## ISSUE-020: Feature set header missing business activity — `(X Handler) {` without colon (lines 823–825, 1748)

**Source entry:** `book_qa:AROByExample:Chapter04-EventDrivenArchitecture:What We Will Learn` (lines 823–825); `book_qa:TheConstructionStudies:Chapter03-SyntacticAnalysis:The AROStatement Parse` (line 1748)
**Wrong original:** `(UserSignedUp Handler) {` / `(CreateUser Handler) {` / `(Extract User From Request) {`
**Why it's wrong:** Feature set headers require both a feature name AND a business activity separated by a colon: `(FeatureName: BusinessActivity)`. Without the colon and business activity, this is not valid ARO syntax.
**Corrected version:** `(Handle User Signup: UserSignedUp Handler) {` / `(Extract User From Request: User API) { ... }`
**Origin:** `Book/TheLanguageGuide/Chapter06-FeatureSets.md` §6.2 — "The header consists of a feature name and a business activity, separated by a colon."

---

## ISSUE-021: Wrong `Emit` syntax — wrong preposition or missing `: event` qualifier (lines 854, 1136–1139, 1237, 1839)

**Source entry:** Various `book_qa:AROByExample:Chapter04` and `book_qa:TheConstructionStudies:Chapter05` entries
**Wrong originals:**
- Line 854: `Emit a <OK: status> for <the: html>.`
- Line 1136: `Emit the <user-registered> event.`
- Line 1137: `Emit the <data-changed> event when data updates.`
- Line 1138: `Emit the <payment-processed> event.`
- Line 1139: `Emit the <event-name> to the <bus-name>.`
- Line 1237: `Emit a <NormalizeUrl: Event> with { url: <result> }.` (capitalized `Event`)
- Line 1839: `Emit an <EventX> with <result>.` (missing `: event`)

**Why it's wrong:** Correct Emit syntax requires: (1) `: event` qualifier (lowercase) on the result, (2) `with` preposition for payload, (3) no explicit event bus target. `<OK: status>` is for `Return`, not `Emit`. `Event` (capitalized) is invalid — must be lowercase `event`.
**Corrected version:** `Emit a <UserCreated: event> with <user>.`
**Origin:** `Book/TheLanguageGuide/AppendixA-ActionReference.md` §Emit

---

## ISSUE-022: Hallucinated `Subscribe` action (lines 1136, 1145)

**Source entry:** `book_qa:AROByExample:Chapter04-EventDrivenArchitecture` (lines 1136, 1145)
**Wrong original:** `Subscribe to the <user-registered> event.` / `Subscribe to the <ExtractedResult: event>.`
**Why it's wrong:** `Subscribe` is not an ARO action. Event handlers are registered automatically by naming convention — no explicit subscription is needed. There is no `Subscribe` verb in the ARO action vocabulary.
**Corrected version:** Create a feature set with business activity `UserRegistered Handler` to handle the event.
**Origin:** `Book/TheLanguageGuide/AppendixA-ActionReference.md` (Subscribe absent); `Book/TheLanguageGuide/Chapter13-EventBus.md` §13.3

---

## ISSUE-023: Wrong behavioral claim — `Update` allows rebinding local variables (lines 1831, 1850, 1856)

**Source entry:** `book_qa:TheConstructionStudies:Chapter05-SemanticAnalysis` (lines 1831, 1850, 1856)
**Wrong originals:**
- Line 1831: "Yes, you can use `Update` to explicitly rebind a variable when the `With` clause is used."
- Line 1850: "The `update` verb set allows rebinding an existing variable"
- Line 1856: "rebinding variables is forbidden except via special verbs like `set` or `_` prefix" and `Set the <user> to { name: "Bob", age: 30 }. (* ✅ Allowed *)`

**Why it's wrong:** ARO variables are unconditionally immutable — no verb bypasses this. `Update` modifies data objects (e.g. merging fields on a record), not local symbol table bindings. There is no `Set` action in ARO. The `_` prefix exception is not documented anywhere in canonical ARO sources.
**Corrected version:** `Update` modifies fields on an existing data object. To produce a new value, create a new binding with a different name.
**Origin:** `Book/TheLanguageGuide/Chapter11-Immutability.md` §11.2; `Book/TheLanguageGuide/AppendixA-ActionReference.md` (no `Set` action)

---

## ISSUE-024: Wrong `Accept` action syntax — `from` preposition used (line 1830)

**Source entry:** `book_qa:TheConstructionStudies:Chapter05-SemanticAnalysis:Immutability Enforcement` (line 1830)
**Wrong original:** `Accept the <price> from 200.   (* Works - mutation verb *)`
**Why it's wrong:** `Accept` is the state transition action with no prepositions in the canonical syntax: `Accept the <order: placed>.` The `from 200` form is not valid. Accept does NOT rebind local variables — it validates and applies state transitions.
**Corrected version:** `Accept the <order: placed>.` (transitions `order` to the `placed` state)
**Origin:** `Book/TheLanguageGuide/AppendixA-ActionReference.md` §Accept; `Sources/ARORuntime/Actions/BuiltIn/AcceptAction.swift` (`validPrepositions = [.on]`)

---

## ISSUE-025: HTTP handlers using route patterns instead of operationIds (lines 1613, 1614)

**Source entry:** `book_qa:TheConstructionStudies:AppendixB-Grammar:Program Structure` (lines 1613, 1614)
**Wrong original:** `(GET /users) { Return an <OK: status> with Users. }` / `(GET /users/{userId}) { ... }`
**Why it's wrong:** ARO uses contract-first HTTP via OpenAPI. Feature set names must match the `operationId` from `openapi.yaml`, not HTTP method+path patterns. `GET /users` is not valid ARO feature set name syntax.
**Corrected version:** `(listUsers: User API) { Retrieve the <users> from the <user-repository>. Return an <OK: status> with <users>. }`
**Origin:** `CLAUDE.md` §Contract-First HTTP APIs; `Book/TheLanguageGuide/Chapter17-OpenAPI.md`

---

## ISSUE-026: String concatenation `+` in TheLanguageGuide examples (lines 2932, 3690, 3691, 4293)

**Source entry:** Multiple `book_qa:TheLanguageGuide:Chapter08/25/36` entries
**Wrong originals:**
- Line 2932: `Compute the <message> from "[AUDIT] user-repository: " + <changeType> + " (id: " + <entityId> + ")".`
- Lines 3690, 3691: `key: "user:" + <user-id>,`
- Line 4293: "ARO uses the `+` operator for string concatenation..."

**Why it's wrong:** ARO uses `++` for string concatenation. Single `+` is arithmetic addition only. Line 4293 is additionally a false factual claim.
**Corrected version:** `Compute the <message> from "[AUDIT] user-repository: " ++ <changeType> ++ " (id: " ++ <entityId> ++ ")".` / `key: "user:" ++ <user-id>`
**Origin:** `Book/TheLanguageGuide/Chapter09-Computations.md` §String Concatenation

---

## ISSUE-027: Transform uses non-existent `using` preposition (line 3722)

**Source entry:** `book_qa:TheLanguageGuide:Chapter26-Plugins:26.4 ARO File Plugins` (line 3722)
**Wrong original:** `Transform the <title> from <text> using <titlecase>.`
**Why it's wrong:** `using` is not a valid preposition in ARO. Transform's only valid preposition is `from` (with optional `with`). This was copied from a bug in Chapter26 source material.
**Corrected version:** `Transform the <title: titlecase> from <text>.`
**Origin:** `Book/TheLanguageGuide/AppendixA-ActionReference.md` §Transform — "Valid Prepositions: `from`"

---

## ISSUE-028: `Store` uses `in` instead of canonical `into` preposition (lines 3127, 3382)

**Source entry:** `book_qa:TheLanguageGuide:Chapter12-HappyPath` (line 3127); `book_qa:TheLanguageGuide:Chapter18-HTTPFeatureSets` (line 3382)
**Wrong original:** `Store the <order> in the <order-repository>.` / `Store the <item> in the <item-repository>.`
**Why it's wrong:** While the runtime accepts `in`, the canonical documented form throughout all ARO book examples and AppendixA is `into`. Training data should use canonical form.
**Corrected version:** `Store the <order> into the <order-repository>.`
**Origin:** `Book/TheLanguageGuide/AppendixA-ActionReference.md` §Store — "Valid Prepositions: `into`"

---

## ISSUE-029: Emit — used `to <service>` instead of `with <data>` (lines 2917, 2918, 2937, 2938, 2939)

**Source entry:** `book_qa:TheLanguageGuide:Chapter08-ExportActions:8.1 Three Paths Out` and `:When to Use Emit` (lines 2917, 2918, 2937, 2938, 2939)
**Wrong originals:**
- `Emit the <event-data> to the <event-bus>.`
- `Emit the <campaign-started> to the <event-bus>.`
- `Emit a <notification> to the <notification-service>.`
- `Emit a <page-view> to the <analytics-service>.`

**Why it's wrong:** Emit does not take an explicit destination. The event bus is implicit. Valid preposition is `with`, not `to`. The results also lack the required `: event` qualifier.
**Corrected version:** `Emit a <CampaignStarted: event> with <campaign-data>.`
**Origin:** `Book/TheLanguageGuide/AppendixA-ActionReference.md` §Emit — "Valid Prepositions: `with`"

---

## ISSUE-030: Wrong `Publish` syntax — multiple invalid forms (lines 2617–2619, 2966, 3551, 2917, 2918)

**Source entry:** Multiple `book_qa:TheLanguageGuide` entries
**Wrong originals:**
- `Publish the <result> as <alias>.` (word order inverted, extra `the`)
- `Publish the <variable: name>.` (missing `as <alias>` entirely)
- `Publish the <notification> with the <channel>.`
- `Publish the <shared-value> to the <registry>.`
- `Publish the <campaign-id> to the <registry>.`
- `Publish the <event: PaymentProcessed> to the <payment-topic>.`

**Why it's wrong:** The only valid Publish syntax is `Publish as <alias> <variable>.` — `as` comes immediately after `Publish`, then the alias, then the variable. No `the` article, no `to` or `with` preposition, no named destination.
**Corrected version:** `Publish as <alias> <result>.`
**Origin:** `Sources/AROParser/Parser.swift` line 869 (`try expect(.as, ...)`); `Book/TheLanguageGuide/AppendixA-ActionReference.md` §Publish

---

## ISSUE-031: Wrong claim — Publish is for external pub/sub systems (line 2966)

**Source entry:** `book_qa:TheLanguageGuide:Chapter08-ExportActions:Comparison Table` (line 2966)
**Wrong original:** "Publish, in contrast, is for broadcasting events to external systems like a message broker or pub/sub system"
**Why it's wrong:** Publish is entirely in-process. It "registers data in a global registry" within the same application process. The external pub/sub claim is a hallucinated feature that does not exist.
**Corrected version:** Publish makes a value accessible to other feature sets within the same application via an in-process global registry. It does not connect to external message brokers.
**Origin:** `Book/TheLanguageGuide/Chapter08-ExportActions.md` §8.4 Publish: Shared Values

---

## ISSUE-032: Invalid feature set syntax — parenthesized statement as name (line 2936)

**Source entry:** `book_qa:TheLanguageGuide:Chapter08-ExportActions:8.3 Emit: Event-Driven Communication` (line 2936)
**Wrong original:** `(Emit a UserSignedUp event) when user.email is set.`
**Why it's wrong:** Feature set headers use `(Name: Business Activity)` format, not parenthesized statements. `user.email is set` is not valid ARO condition syntax.
**Corrected version:** `Emit a <UserSignedUp: event> with <user>.` (inside a feature set body)
**Origin:** `CLAUDE.md` §ARO Syntax; `Book/TheLanguageGuide/Chapter06-FeatureSets.md` §6.2

---

## ISSUE-033: Hallucinated `when { }` block construct (lines 3279, 3325, 3431, 3632)

**Source entry:** Multiple `book_qa:TheLanguageGuide:Chapter16/20/23` entries
**Wrong originals:**
- `when <status> = "paid" { (* do the work *) }` presented as valid but "slow"
- `when <age> >= 18 { Log "Adult user" to the <console>. }` labeled as "statement guard"
- `when <found> is false { Log "Config not found!" to the <console>. }`
- `when <verbose> is true { Log "Processing file:" to the <console>. Log <path> to the <console>. }`

**Why it's wrong:** ARO does not have `when <condition> { ... }` block constructs. The `when` keyword is only a trailing guard suffix on individual statements. Multiple statements cannot be grouped with a `when` block.
**Corrected version:** Each statement needs its own guard: `Log "Config not found!" to the <console> when <found> is false.`
**Origin:** `Book/TheLanguageGuide/Chapter33-ControlFlow.md` §When Guards — "The `when` clause conditionally executes a single statement."

---

## ISSUE-034: Wrong `Accept` syntax — `with { error: ... }` clause (line 3134)

**Source entry:** `book_qa:TheLanguageGuide:Chapter12-HappyPath:12.6 Strategies for Complex Error Handling` (line 3134)
**Wrong original:** `Accept the <user: email> with { error: "Invalid email format" }.`
**Why it's wrong:** Accept's only valid preposition is `.on`. The canonical form is `Accept the <entity: new-state>.` There is no `with { error: ... }` form — this conflates Accept with Validate/Throw.
**Corrected version:** `Accept the <user: valid>.`
**Origin:** `Book/TheLanguageGuide/AppendixA-ActionReference.md` §Accept; `Sources/ARORuntime/Actions/BuiltIn/AcceptAction.swift` (`validPrepositions = [.on]`)

---

## ISSUE-035: Throw — uses `with` instead of `for` (line 3384)

**Source entry:** `book_qa:TheLanguageGuide:Chapter18-HTTPFeatureSets:18.7 Best Practices` (line 3384)
**Wrong original:** `Throw an <InvalidUser: error> with { message: "Invalid user data" }.`
**Why it's wrong:** Throw's only valid preposition is `for`. There is no `with` clause for Throw.
**Corrected version:** `Throw an <InvalidUser: error> for the <invalid: user-data>.`
**Origin:** `Book/TheLanguageGuide/AppendixA-ActionReference.md` §Throw — "Valid Prepositions: `for`"

---

## ISSUE-036: Delete — uses `with` dictionary instead of `from ... where` (line 3375)

**Source entry:** `book_qa:TheLanguageGuide:Chapter18-HTTPFeatureSets:18.4 Response Patterns` (line 3375)
**Wrong original:** `Delete the <user> with { id: 42 }.`
**Why it's wrong:** Delete uses the `from` preposition with an optional `where` clause. There is no `with` dictionary form.
**Corrected version:** `Delete the <user> from the <user-repository> where id = 42.`
**Origin:** `Book/TheLanguageGuide/AppendixA-ActionReference.md` §Delete — "Valid Prepositions: `from`"

---

## ISSUE-037: String concatenation `+` in template expression (line 4696)

**Source entry:** `book_qa:TheLanguageGuide:Chapter44-Templates:44.3 Variable Interpolation Shorthand` (line 4696)
**Wrong original:** `{{ <first-name> + " " + <last-name> }}`
**Why it's wrong:** ARO's string concatenation operator is `++`. Using `+` in templates is incorrect. (Note: this bug also appears in the source book at Chapter44 line 149 — the training data faithfully reproduces a bug from its source material.)
**Corrected version:** `{{ <first-name> ++ " " ++ <last-name> }}`
**Origin:** `Book/TheLanguageGuide/Chapter09-Computations.md` §String Concatenation

---

## ISSUE-038: Non-ARO `<-` arrow-assignment syntax — Concurrency chapter (lines 4474–4476)

**Source entry:** `book_qa:TheLanguageGuide:Chapter39-Concurrency:No Concurrency Primitives` (lines 4474, 4475, 4476)
**Wrong originals:**
- `(response: Response) <- (.Body from https://api.example.com/data).`
- `(getUsers: Response) <- (.Body from "https://api.users.com/list").`
- `orderId: String <- (.OrderId from <order>.`
- `processedAt: DateTime <- now.`

**Why it's wrong:** ARO does not have `<-` assignment syntax, `.Body from` accessor chains, or type-annotated assignments. These are hallucinated non-ARO constructs. The "No Concurrency Primitives" section in Chapter39 only lists what ARO does NOT provide — it contains no such code examples.
**Corrected version:** `Request the <response> from <url>.` / `Extract the <orderId> from the <order: orderId>.`
**Origin:** `Book/TheLanguageGuide/Chapter39-Concurrency.md` §No Concurrency Primitives; `Book/TheLanguageGuide/AppendixA-ActionReference.md`

---

## ISSUE-039: Wrong parallel for-each syntax (line 4503)

**Source entry:** `book_qa:TheLanguageGuide:Chapter39-Concurrency:Performance Characteristics` (line 4503)
**Wrong original:** `(Parallel For Each item in items) {` presented as correct ARO syntax
**Why it's wrong:** Canonical ARO parallel loop syntax is lowercase with angle brackets: `parallel for each <variable> in <collection> {`. The shown form uses title case, no angle brackets, and wraps in parentheses as if it were a feature set declaration.
**Corrected version:** `parallel for each <item> in <items> {`
**Origin:** `Book/TheLanguageGuide/Chapter39-Concurrency.md` §Syntax

---

## ISSUE-040: Wrong Render action — `from` preposition instead of `to` (line 4704)

**Source entry:** `book_qa:TheLanguageGuide:Chapter44-Templates:44.5 Context Isolation` (line 4704)
**Wrong original:** `Render the <greeting> from the <Render Template>.`
**Why it's wrong:** Render action uses `to the <console>`, not `from`. The object `<Render Template>` referencing a feature set name as a variable is also a fabricated pattern not present in Chapter44.
**Corrected version:** `Render the <greeting> to the <console>.`
**Origin:** `Book/TheLanguageGuide/Chapter47-TerminalUI.md` §47.6 — `Render the <menu> to the <console>.`

---

## ISSUE-041: Non-ARO `<-` arrow-assignment + wrong Emit in Streaming chapter (lines 4865–4867)

**Source entry:** `book_qa:TheLanguageGuide:Chapter46-StreamingExecution:Best Practices for Format Selection` (lines 4865, 4866, 4867)
**Wrong originals:**
- `LogLine <- extract the <message> from the <event-log>.`
- `Event <- extract the <event-data> from the <stream>.`
- `Emit <event> to the <event-hub>.`
- `Rows <- list the <sales-data> from the <database>.`
- `CsvContent <- transform the <rows> into <csv>.`

**Why it's wrong:** ARO does not have `<-` arrow-assignment syntax. `Emit <event> to the <event-hub>` is wrong on two counts: missing required article+event qualifier, and uses `to` instead of `with`. None of these patterns appear in Chapter46.
**Corrected version:** `Extract the <message> from the <event-log>.` / `Emit a <DataProcessed: event> with <data>.`
**Origin:** `Book/TheLanguageGuide/Chapter46-StreamingExecution.md`; `Book/TheLanguageGuide/AppendixA-ActionReference.md` §Emit

---

## ISSUE-042: Wrong streaming qualifier placement — qualifier on result instead of verb (line 4879)

**Source entry:** `book_qa:TheLanguageGuide:Chapter46-StreamingExecution:Streaming Heuristics` (line 4879)
**Wrong original:** `Read the <file:streaming> from the <file-path>.` / `Read the <file:eager> from the <file-path>.`
**Why it's wrong:** The canonical syntax for explicit streaming mode qualifiers places the qualifier on the **verb** (in angle-bracket verb form), not on the result variable: `<Read: streaming> the <data> from the <file: "huge.csv">.`
**Corrected version:** `<Read: streaming> the <data> from the <file: "huge.csv">.` / `<Read: eager> the <data> from the <file: "small.csv">.`
**Origin:** `Book/TheLanguageGuide/Chapter46-StreamingExecution.md` §Explicit Mode Control

---

## ISSUE-043: Wrong Listen action syntax — wrong preposition and wrong placement (line 4962)

**Source entry:** `book_qa:TheLanguageGuide:Chapter47-TerminalUI:47.7 Keyboard-Driven Interactive UIs` (line 4962)
**Wrong original:** `(Handle KeyPress: KeyPress Handler) { Listen the <input> from the <keyboard>. }`
**Why it's wrong:** (1) Canonical Listen syntax is `Listen the <keyboard> to the <stdin>.` — not `from`. Object and preposition are reversed. (2) `Listen` is called once in `Application-Start` to put the terminal in raw mode, not inside a `KeyPress Handler` body.
**Corrected version:** `Listen the <keyboard> to the <stdin>.` (in Application-Start); KeyPress Handler body uses `Extract the <key> from the <event: key>.`
**Origin:** `Book/TheLanguageGuide/Chapter47-TerminalUI.md` §47.7.1

---

## ISSUE-044: Wrong Return action syntax — uses `from` preposition (line 6370)

**Source entry:** `book_qa:ThePluginGuide:Cover:Introduction` (line 6370)
**Wrong original:** `Return <sum> from <a> + <b>.`
**Why it's wrong:** Return syntax is `Return an <OK: status> with <data>.` or `Return a <Status: status> for the <object>.` Using `from` preposition for Return is not valid.
**Corrected version:** `Return an <OK: status> with <sum>.` (after computing sum in a separate Compute statement)
**Origin:** `Book/TheLanguageGuide/AppendixA-ActionReference.md` §Return

---

## Systemic Issues (High-Priority Fixes)

The following errors appear across many entries and should be fixed by replacing the entire generation prompt or post-processing corrections:

### 1. String concatenation `+` → `++` (affects ~14+ entries)
Search-and-replace pattern in `output` field: any ARO code using `"string" + <var>` or `<var> + "string"` — change `+` to `++` when operands are strings.

### 2. Publish syntax inversion (affects ~8+ entries)
Pattern: `Publish the <X> as <alias>` or `Publish the <X> to the <Y>` → `Publish as <alias> <X>`

### 3. Emit missing `: event` qualifier (affects ~14+ entries)
Pattern: `Emit a <Name>` or `Emit the <name>` without `: event` → `Emit a <Name: event> with <data>.`

### 4. Hallucinated `when { }` blocks (affects ~6+ entries)
Pattern: Any `when <condition> { ... }` inside a feature set body → each statement needs its own `... when <condition>.` suffix

### 5. `<-` arrow-assignment syntax (affects ~7+ entries in lines 4400–4900)
All occurrences of `<-` in ARO code examples are hallucinated non-ARO syntax.

### 6. `while` loops and `Subscribe` action
These constructs do not exist in ARO and should be removed.
