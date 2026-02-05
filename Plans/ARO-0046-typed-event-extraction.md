# Typed Event Extraction Using OpenAPI Schemas

## Git Workflow

1. Create feature branch: `feature/typed-event-extraction`
2. Commit this plan file
3. Push to GitLab (git.ausdertechnik.de)
4. Open Merge Request

---

## Summary

Add typed event extraction to ARO where event handlers can validate/coerce event data against OpenAPI schemas defined in `components.schemas`.

**Syntax:**
```aro
<Extract> the <event-data: ExtractLinksEvent> from the <event: data>.
<ParseHtml> the <links> from the <event-data: html>.
```

**Behavior:**
- Result qualifier `ExtractLinksEvent` references `#/components/schemas/ExtractLinksEvent`
- Strict validation: fails at runtime if data doesn't match schema
- Property access uses standard qualifier notation: `<event-data: html>`

---

## Files to Modify

### Code

| File | Change |
|------|--------|
| `Sources/ARORuntime/OpenAPI/SchemaRegistry.swift` | **NEW** - Protocol and implementation for schema lookup |
| `Sources/ARORuntime/Core/ExecutionContext.swift` | Add `schemaRegistry` accessor to protocol |
| `Sources/ARORuntime/Core/RuntimeContext.swift` | Implement schema registry storage |
| `Sources/ARORuntime/Actions/BuiltIn/ExtractAction.swift` | Add schema qualifier detection and validation |
| `Sources/ARORuntime/OpenAPI/SchemaBinding.swift` | Add `SchemaValidationError` types |
| `Sources/ARORuntime/Core/ExecutionEngine.swift` | Register schemas when OpenAPI spec is loaded |
| `Tests/AROuntimeTests/TypedEventExtractionTests.swift` | **NEW** - Unit tests |

### Documentation

| File | Change |
|------|--------|
| `Proposals/ARO-0046-typed-event-extraction.md` | **NEW** - Language specification |
| `Proposals/README.md` | Add ARO-0046 to index |
| `Book/TheLanguageGuide/Chapter13-CustomEvents.md` | Add typed extraction section |
| `Book/TheLanguageGuide/Chapter09-QualifierSyntax.md` | Document schema qualifiers |
| `Book/TheLanguageGuide/AppendixA-ActionReference.md` | Update Extract action entry |
| `Book/AROByExample/Chapter04-EventDrivenArchitecture.md` | Add typed event example |
| `Book/AROByExample/Chapter06-LinkExtraction.md` | Update with typed ExtractLinksEvent |
| `Book/Reference/Actions.md` | Update Extract action docs |
| Wiki: Action Developer Guide | Document schema registry access |
| Wiki: OpenAPI Integration | Event schema definitions |
| Wiki: Event Handlers | Typed extraction examples |

---

## Implementation Steps

### Step 1: Create SchemaRegistry

**File:** `Sources/ARORuntime/OpenAPI/SchemaRegistry.swift` (new)

```swift
public protocol SchemaRegistry: Sendable {
    func schema(named: String) -> Schema?
    func hasSchema(named: String) -> Bool
    var components: Components? { get }
}

public struct OpenAPISchemaRegistry: SchemaRegistry {
    private let spec: OpenAPISpec

    public init(spec: OpenAPISpec) { self.spec = spec }

    public func schema(named name: String) -> Schema? {
        spec.components?.schemas?[name]?.value
    }

    public func hasSchema(named name: String) -> Bool {
        spec.components?.schemas?[name] != nil
    }

    public var components: Components? { spec.components }
}
```

### Step 2: Add Schema Registry to ExecutionContext

**File:** `Sources/ARORuntime/Core/ExecutionContext.swift`

Add to protocol:
```swift
var schemaRegistry: SchemaRegistry? { get }
```

### Step 3: Implement in RuntimeContext

**File:** `Sources/ARORuntime/Core/RuntimeContext.swift`

- Add `private var _schemaRegistry: SchemaRegistry?`
- Add `public func setSchemaRegistry(_ registry: SchemaRegistry)`
- Implement `schemaRegistry` computed property

### Step 4: Register Schemas at Startup

**File:** `Sources/ARORuntime/Core/ExecutionEngine.swift`

After loading OpenAPI spec, create registry and register in root context:
```swift
if let spec = openAPISpec {
    let registry = OpenAPISchemaRegistry(spec: spec)
    context.setSchemaRegistry(registry)
}
```

Ensure child contexts (event handlers) inherit schema registry from parent.

### Step 5: Add Schema Validation Errors

**File:** `Sources/ARORuntime/OpenAPI/SchemaBinding.swift`

```swift
public enum SchemaValidationError: Error, Sendable {
    case schemaNotFound(schemaName: String)
    case typeMismatch(schemaName: String, expected: String, actual: String, path: String)
    case missingRequiredProperty(schemaName: String, property: String)
    case invalidPropertyType(schemaName: String, property: String, expected: String, actual: String)
}
```

### Step 6: Enhance ExtractAction

**File:** `Sources/ARORuntime/Actions/BuiltIn/ExtractAction.swift`

Add schema qualifier detection:
```swift
private func detectSchemaQualifier(_ specifiers: [String]) -> String? {
    guard let first = specifiers.first else { return nil }

    // Reserved specifiers - never schema names
    let reserved = ["first", "last"]
    if reserved.contains(first.lowercased()) { return nil }
    if Int(first) != nil { return nil }  // Numeric index

    // PascalCase = schema name
    if let char = first.first, char.isUppercase {
        return first
    }
    return nil
}
```

Add validation in `execute()`:
```swift
if let schemaName = detectSchemaQualifier(result.specifiers),
   let registry = context.schemaRegistry,
   let schema = registry.schema(named: schemaName) {
    return try validateAgainstSchema(
        source: resolvedSource,
        schema: schema,
        schemaName: schemaName,
        components: registry.components
    )
}
```

### Step 7: Add Tests

**File:** `Tests/AROuntimeTests/TypedEventExtractionTests.swift` (new)

Test cases:
- Schema qualifier detection (PascalCase vs lowercase)
- Valid schema extraction
- Unknown schema error
- Type mismatch error
- Missing required property error
- Nested object validation
- Backward compatibility (untyped extraction still works)

---

## Schema Qualifier Detection Rules

| Specifier | Type | Example |
|-----------|------|---------|
| PascalCase | Schema | `ExtractLinksEvent`, `UserData` |
| lowercase | Property | `html`, `url`, `body` |
| kebab-case | Property | `user-id`, `base-domain` |
| `first`, `last` | Element | Reserved for array access |
| Numeric | Index | `0`, `3-5`, `3,5,7` |

---

## Example openapi.yaml for Crawler

```yaml
components:
  schemas:
    ExtractLinksEvent:
      type: object
      required:
        - url
        - html
      properties:
        url:
          type: string
        html:
          type: string
        base:
          type: string

    CrawlPageEvent:
      type: object
      required:
        - url
      properties:
        url:
          type: string
        depth:
          type: integer
```

---

## Transformed Crawler Code

**Before:**
```aro
(Extract Links: ExtractLinks Handler) {
    <Extract> the <event-data> from the <event: data>.
    <Extract> the <html> from the <event-data: html>.
    <Extract> the <source-url> from the <event-data: url>.
    <Extract> the <base-domain> from the <event-data: base>.

    <ParseHtml> the <links> from the <html>.
    ...
}
```

**After:**
```aro
(Extract Links: ExtractLinks Handler) {
    <Extract> the <event-data: ExtractLinksEvent> from the <event: data>.

    <ParseHtml> the <links> from the <event-data: html>.
    ...
}
```

---

## Error Message Format

Following ARO-0006 "Code Is The Error Message":

```
Cannot <Extract> the <event-data: ExtractLinksEvent> from the <event: data>.
  Schema 'ExtractLinksEvent' validation failed:
    Missing required property 'html'

  Event data received: { "url": "https://..." }
  Required properties: url, html
```

---

## Documentation Updates

### Proposal: ARO-0046-typed-event-extraction.md (NEW)

**Location:** `Proposals/ARO-0046-typed-event-extraction.md`

**Sections:**
- **Header:** Proposal ARO-0046, Status: Implemented, Requires: ARO-0001, ARO-0003, ARO-0007
- **Abstract:** Typed event extraction using OpenAPI schema validation
- **Motivation:** Reduce boilerplate, add type safety, catch errors early
- **Proposed Solution:**
  - Schema qualifier syntax: `<result: SchemaName>`
  - Detection rules (PascalCase = schema)
  - Validation behavior (strict)
  - Error message format
- **Examples:** Before/after code comparison
- **ASCII Diagram:** Schema resolution flow

```
┌─────────────────────────────────────────────────────────────────┐
│                    Typed Event Extraction                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  <Extract> the <event-data: ExtractLinksEvent> from <event>     │
│                      │                                          │
│                      ▼                                          │
│            ┌─────────────────┐                                  │
│            │ Detect Qualifier │                                  │
│            │  PascalCase?     │                                  │
│            └────────┬────────┘                                  │
│                     │ Yes                                       │
│                     ▼                                           │
│            ┌─────────────────┐      ┌──────────────────────┐   │
│            │ Schema Registry │ ───► │ openapi.yaml         │   │
│            │ Lookup          │      │ components.schemas.  │   │
│            └────────┬────────┘      │ ExtractLinksEvent    │   │
│                     │               └──────────────────────┘   │
│                     ▼                                          │
│            ┌─────────────────┐                                  │
│            │ Validate Data   │                                  │
│            │ Against Schema  │                                  │
│            └────────┬────────┘                                  │
│                     │                                           │
│         ┌──────────┴──────────┐                                │
│         ▼                     ▼                                │
│   ┌──────────┐          ┌──────────┐                           │
│   │ Valid    │          │ Invalid  │                           │
│   │ Return   │          │ Throw    │                           │
│   │ typed    │          │ Schema   │                           │
│   │ object   │          │ Error    │                           │
│   └──────────┘          └──────────┘                           │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Book Updates

#### TheLanguageGuide

**Files:**
- `Book/TheLanguageGuide/Chapter13-CustomEvents.md` - Add "Typed Event Extraction" section
- `Book/TheLanguageGuide/Chapter09-QualifierSyntax.md` - Add schema qualifier documentation
- `Book/TheLanguageGuide/AppendixA-ActionReference.md` - Update Extract action entry

Content to add:
- Explain schema qualifier syntax (`<result: SchemaName>`)
- Show how to define event schemas in openapi.yaml `components.schemas`
- Provide examples with validation
- Explain error messages and ARO-0006 philosophy

#### AROByExample

**Files:**
- `Book/AROByExample/Chapter04-EventDrivenArchitecture.md` - Add typed events concept
- `Book/AROByExample/Chapter06-LinkExtraction.md` - Update with `ExtractLinksEvent` schema

This book builds a web crawler - perfect place to demonstrate typed events:
- Update event handler chapters to show typed extraction
- Add section comparing untyped vs typed approach
- Show openapi.yaml schema definitions for crawler events

#### Reference/Actions.md

**File:** `Book/Reference/Actions.md`

Update **Extract** action documentation:
- Add "Schema Qualifier" section
- Document PascalCase detection rule
- Show typed extraction example
- Document SchemaValidationError types

### Wiki Updates

**Location:** https://github.com/arolang/aro/wiki

Update pages:
- **Action Developer Guide** - Document schema registry access in actions
- **OpenAPI Integration** - Add section on event schema definitions
- **Event Handlers** - Add typed extraction examples

### Proposals/README.md

Add entry for ARO-0046 in the proposal index table.
