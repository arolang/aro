# ARO-0046: Typed Event Extraction

* Proposal: ARO-0046
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0003, ARO-0007

## Abstract

This proposal introduces typed event extraction using OpenAPI schema validation. Event handlers can extract event data as typed objects by referencing schema definitions from `components.schemas` in the OpenAPI specification.

---

## 1. Motivation

Current event handlers extract data field-by-field:

```aro
(Extract Links: ExtractLinks Handler) {
    Extract the <event-data> from the <event: data>.
    Extract the <html> from the <event-data: html>.
    Extract the <url> from the <event-data: url>.
    Extract the <base> from the <event-data: base>.

    (* Now use html, url, base... *)
}
```

This pattern has several drawbacks:
- **Boilerplate**: Each handler repeats extraction statements
- **No validation**: Missing or mistyped fields cause runtime errors deep in handler logic
- **No documentation**: Event structure is implicit, not defined anywhere

---

## 2. Proposed Solution

### 2.1 Schema Qualifier Syntax

Use a PascalCase result qualifier to reference an OpenAPI schema:

```aro
Extract the <event-data: ExtractLinksEvent> from the <event: data>.
```

The qualifier `ExtractLinksEvent` references `#/components/schemas/ExtractLinksEvent` in the OpenAPI specification.

### 2.2 Schema Definition

Define event schemas in `openapi.yaml`:

```yaml
openapi: 3.0.3
info:
  title: Crawler API
  version: 1.0.0

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
```

### 2.3 Validation Behavior

When a PascalCase schema qualifier is detected:

1. Look up the schema in `components.schemas`
2. Validate the extracted data against the schema
3. **Fail fast** if validation fails (strict mode)
4. Return the validated object if successful

---

## 3. Schema Qualifier Detection

The Extract action detects schema qualifiers by naming convention:

```
┌─────────────────────────────────────────────────────────────────┐
│                    Qualifier Detection Rules                     │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Qualifier Pattern          │  Interpretation                  │
│  ─────────────────────────  │  ──────────────────────────────  │
│  PascalCase (ExtractLinks)  │  Schema lookup                   │
│  lowercase (html, url)      │  Property access                 │
│  kebab-case (base-domain)   │  Property access                 │
│  first, last               │  Array element access            │
│  0, 1, 2 (numeric)         │  Array index access              │
│  3-5 (range)               │  Array range access              │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 3.1 Detection Algorithm

```
1. Check if qualifier starts with uppercase letter
2. Check if qualifier contains only letters and numbers (no hyphens)
3. Verify qualifier is not a reserved word (first, last, etc.)
4. If all checks pass → Schema qualifier
5. Otherwise → Property/element specifier
```

---

## 4. Error Messages

Validation errors follow ARO-0006 "Code Is The Error Message":

### 4.1 Schema Not Found

```
Cannot Extract the <event-data: UnknownSchema> from the <event: data>.
  Schema 'UnknownSchema' is not defined in openapi.yaml components.schemas.
  Available schemas: ExtractLinksEvent, CrawlPageEvent, UserData
```

### 4.2 Missing Required Property

```
Cannot Extract the <event-data: ExtractLinksEvent> from the <event: data>.
  Schema 'ExtractLinksEvent' validation failed:
    Missing required property 'html'
  Required properties: url, html
```

### 4.3 Type Mismatch

```
Cannot Extract the <event-data: PageData> from the <event: data>.
  Schema 'PageData' validation failed:
    Property 'depth' expected integer, got string
```

---

## 5. Examples

### 5.1 Before (Field-by-Field)

```aro
(Extract Links: ExtractLinks Handler) {
    Extract the <event-data> from the <event: data>.
    Extract the <html> from the <event-data: html>.
    Extract the <source-url> from the <event-data: url>.
    Extract the <base-domain> from the <event-data: base>.

    ParseHtml the <links> from the <html>.

    for each <link> in <links> {
        Emit a <CrawlPage: event> with { url: <link: href> }.
    }

    Return an <OK: status> for the <extraction>.
}
```

### 5.2 After (Typed Extraction)

```aro
(Extract Links: ExtractLinks Handler) {
    Extract the <event-data: ExtractLinksEvent> from the <event: data>.

    ParseHtml the <links> from the <event-data: html>.

    for each <link> in <links> {
        Emit a <CrawlPage: event> with {
            url: <link: href>,
            referrer: <event-data: url>
        }.
    }

    Return an <OK: status> for the <extraction>.
}
```

### 5.3 Property Access

After typed extraction, access properties with standard qualifier notation:

```aro
Extract the <event-data: ExtractLinksEvent> from the <event: data>.

(* Access properties using qualifier syntax *)
ParseHtml the <links> from the <event-data: html>.
Log <event-data: url> to the <console>.
```

---

## 6. Implementation

### 6.1 Schema Resolution Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                    Typed Event Extraction                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Extract the <event-data: ExtractLinksEvent> from <event>     │
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

### 6.2 Key Components

| Component | Location | Purpose |
|-----------|----------|---------|
| `SchemaRegistry` | `OpenAPI/SchemaRegistry.swift` | Protocol for schema lookup |
| `OpenAPISchemaRegistry` | `OpenAPI/SchemaRegistry.swift` | Implementation backed by OpenAPISpec |
| `SchemaValidationError` | `OpenAPI/SchemaBinding.swift` | Error types for validation failures |
| `validateAgainstSchema` | `OpenAPI/SchemaBinding.swift` | Schema validation logic |
| `detectSchemaQualifier` | `Actions/ExtractAction.swift` | PascalCase detection |

---

## 7. Backward Compatibility

This feature is fully backward compatible:

- **No schema registry**: Existing code works unchanged
- **lowercase qualifiers**: Continue to work as property specifiers
- **Reserved words**: `first`, `last`, numeric indices work as before

---

## 8. Related Proposals

- **ARO-0001**: Language Fundamentals (qualifier syntax)
- **ARO-0003**: Type System (schema types)
- **ARO-0006**: Error Philosophy (descriptive error messages)
- **ARO-0007**: Events & Reactive (event handlers)
- **ARO-0038**: List Element Access (reserved specifiers)
