# Appendix B: Preposition Semantics

*How prepositions shape meaning in ARO.*

---

## Overview

<div style="text-align: center; margin: 2em 0;">
<svg width="480" height="100" viewBox="0 0 480 100" xmlns="http://www.w3.org/2000/svg">  <!-- from -->  <g transform="translate(20, 10)">    <rect x="0" y="20" width="40" height="25" rx="3" fill="#e0e7ff" stroke="#6366f1" stroke-width="1"/>    <text x="20" y="36" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#4338ca">source</text>    <line x1="40" y1="32" x2="55" y2="32" stroke="#22c55e" stroke-width="2"/>    <polygon points="55,32 50,28 50,36" fill="#22c55e"/>    <rect x="55" y="20" width="40" height="25" rx="3" fill="#dcfce7" stroke="#22c55e" stroke-width="1.5"/>    <text x="75" y="36" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#166534">result</text>    <text x="47" y="60" text-anchor="middle" font-family="monospace" font-size="9" font-weight="bold" fill="#374151">from</text>    <text x="47" y="72" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#9ca3af">pull in</text>  </g>  <!-- to -->  <g transform="translate(130, 10)">    <rect x="0" y="20" width="40" height="25" rx="3" fill="#dcfce7" stroke="#22c55e" stroke-width="1.5"/>    <text x="20" y="36" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#166534">data</text>    <line x1="40" y1="32" x2="55" y2="32" stroke="#ef4444" stroke-width="2"/>    <polygon points="55,32 50,28 50,36" fill="#ef4444"/>    <rect x="55" y="20" width="40" height="25" rx="3" fill="#fee2e2" stroke="#ef4444" stroke-width="1"/>    <text x="75" y="36" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#991b1b">dest</text>    <text x="47" y="60" text-anchor="middle" font-family="monospace" font-size="9" font-weight="bold" fill="#374151">to</text>    <text x="47" y="72" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#9ca3af">push out</text>  </g>  <!-- into -->  <g transform="translate(240, 10)">    <rect x="20" y="5" width="30" height="18" rx="3" fill="#dcfce7" stroke="#22c55e" stroke-width="1.5"/>    <text x="35" y="17" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#166534">data</text>    <line x1="35" y1="23" x2="35" y2="35" stroke="#f59e0b" stroke-width="2"/>    <polygon points="35,35 31,30 39,30" fill="#f59e0b"/>    <rect x="10" y="35" width="50" height="25" rx="3" fill="#fef3c7" stroke="#f59e0b" stroke-width="1.5"/>    <text x="35" y="51" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#92400e">storage</text>    <text x="35" y="75" text-anchor="middle" font-family="monospace" font-size="9" font-weight="bold" fill="#374151">into</text>    <text x="35" y="87" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#9ca3af">insert</text>  </g>  <!-- with -->  <g transform="translate(320, 10)">    <rect x="0" y="25" width="40" height="25" rx="3" fill="#dbeafe" stroke="#3b82f6" stroke-width="1.5"/>    <text x="20" y="41" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#1e40af">action</text>    <rect x="50" y="25" width="40" height="25" rx="3" fill="#f3e8ff" stroke="#a855f7" stroke-width="1"/>    <text x="70" y="41" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#7c3aed">data</text>    <text x="45" y="18" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#9ca3af">+</text>    <text x="45" y="65" text-anchor="middle" font-family="monospace" font-size="9" font-weight="bold" fill="#374151">with</text>    <text x="45" y="77" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#9ca3af">provide</text>  </g>  <!-- against -->  <g transform="translate(410, 10)">    <rect x="0" y="25" width="30" height="25" rx="3" fill="#dcfce7" stroke="#22c55e" stroke-width="1.5"/>    <text x="15" y="41" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#166534">val</text>    <text x="40" y="41" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#6b7280">⟷</text>    <rect x="50" y="25" width="30" height="25" rx="3" fill="#e0e7ff" stroke="#6366f1" stroke-width="1"/>    <text x="65" y="41" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#4338ca">ref</text>    <text x="40" y="65" text-anchor="middle" font-family="monospace" font-size="9" font-weight="bold" fill="#374151">against</text>    <text x="40" y="77" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#9ca3af">compare</text>  </g></svg>
</div>

ARO uses eight prepositions, each with specific semantic meaning:

| Preposition | Primary Meaning | Data Flow |
|-------------|-----------------|-----------|
| `from` | Source/extraction | External → Internal |
| `with` | Accompaniment/using | Provides data |
| `for` | Purpose/target | Indicates beneficiary |
| `to` | Destination | Internal → External |
| `into` | Insertion/transformation | Internal → Storage |
| `against` | Comparison/validation | Reference point |
| `via` | Through/medium | Intermediate channel |
| `on` | Location/surface | Attachment point |

---

## from

**Meaning:** Source extraction — data flows from an external source inward.

**Indicates:** The origin of data being pulled into the current context.

**Common with:** `Extract`, `Retrieve`, `Request`, `Read`, `Receive`

### Examples

```aro
(* Extract from request context *)
<Extract> the <user-id> from the <pathParameters: id>.
<Extract> the <body> from the <request: body>.
<Extract> the <token> from the <headers: authorization>.

(* Retrieve from repository *)
<Retrieve> the <user> from the <user-repository>.
<Retrieve> the <orders> from the <order-repository> where <status> is "active".

(* Request from external URL *)
<Request> the <data> from "https://api.example.com/users".

(* Read from file *)
<Read> the <config> from the <file> with "config.json".

(* Filter from collection *)
<Filter> the <active> from the <users> where <status> is "active".
```

### Semantic Notes

- `from` typically indicates an external or persistent source
- Used when data crosses a boundary into the current scope
- The preposition signals that the action is "pulling" data

---

## with

**Meaning:** Accompaniment — data provided alongside or used by the action.

**Indicates:** Additional data, parameters, or configuration.

**Common with:** `Create`, `Return`, `Emit`, `Merge`, `Log`

### Examples

```aro
(* Create with data *)
<Create> the <user> with <user-data>.
<Create> the <greeting> with "Hello, World!".
<Create> the <total> with <subtotal> + <tax>.

(* Return with payload *)
<Return> an <OK: status> with <users>.
<Return> a <Created: status> with <user>.

(* Emit with event data *)
<Emit> a <UserCreated: event> with <user>.
<Emit> an <OrderPlaced: event> with { orderId: <id>, total: <total> }.

(* Merge with updates *)
<Merge> the <updated> from <existing> with <changes>.

(* Log to console *)
<Log> "Application started" to the <console>.

(* Read with path *)
<Read> the <content> from the <file> with "data.json".
```

### Semantic Notes

- `with` provides the data or value to use
- Often specifies literal values, expressions, or object references
- Indicates "using this" rather than "from this"

---

## for

**Meaning:** Purpose/target — indicates the beneficiary or purpose.

**Indicates:** What the action is intended for or aimed at.

**Common with:** `Return`, `Log`, `Compute`, `Validate`

### Examples

```aro
(* Return for a target *)
<Return> an <OK: status> for the <request>.
<Return> a <NoContent: status> for the <deletion>.

(* Log to destination *)
<Log> <message> to the <console>.
<Log> <error> to the <error-log>.

(* Compute for an input *)
<Compute> the <total> for the <items>.
<Compute> the <hash> for the <password>.

(* Validate for a type *)
<Validate> the <input> for the <user-type>.
```

### Semantic Notes

- `for` indicates purpose or beneficiary
- Often used with logging and return statements
- Specifies "on behalf of" or "intended for"

---

## to

**Meaning:** Destination — data flows outward to a target.

**Indicates:** The endpoint or recipient of data.

**Common with:** `Send`, `Write`, `Connect`

### Examples

```aro
(* Send to destination *)
<Send> the <email> to the <user: email>.
<Send> the <notification> to the <admin>.
<Send> the <request> to "https://api.example.com/webhook".

(* Write to file *)
<Write> the <data> to the <file> with "output.json".

(* Connect to service *)
<Connect> the <database> to "postgres://localhost/mydb".
<Connect> the <socket> to "localhost:9000".
```

### Semantic Notes

- `to` indicates outward data flow
- Used when sending or directing data to an external destination
- Opposite direction from `from`

---

## into

**Meaning:** Insertion/transformation — data enters or transforms.

**Indicates:** A container or new form for the data.

**Common with:** `Store`, `Transform`

### Examples

```aro
(* Store into repository *)
<Store> the <user> into the <user-repository>.
<Store> the <order> into the <order-repository>.
<Store> the <cache-entry> into the <cache>.

(* Transform into format *)
<Transform> the <dto> into the <json>.
<Transform> the <entity> into the <response-model>.
```

### Semantic Notes

- `into` suggests insertion or transformation
- Used for persistence and format conversion
- Implies the data "enters" something

---

## against

**Meaning:** Comparison/validation — data is checked against a reference.

**Indicates:** The standard or rule for comparison.

**Common with:** `Validate`, `Compare`

### Examples

```aro
(* Validate against schema *)
<Validate> the <input> against the <user: schema>.
<Validate> the <password> against the <password-rules>.
<Validate> the <token> against the <auth-service>.

(* Compare against reference *)
<Compare> the <old-value> against the <new-value>.
<Compare> the <actual> against the <expected>.
```

### Semantic Notes

- `against` implies testing or comparison
- Used for validation, verification, and comparison
- The object is the reference standard

---

## via

**Meaning:** Through/medium — indicates an intermediate channel.

**Indicates:** The pathway or method used.

**Common with:** `Request`, `Send`

### Examples

```aro
(* Request via proxy *)
<Request> the <data> from "https://api.example.com" via the <proxy>.

(* Send via channel *)
<Send> the <message> to the <user> via the <email-service>.
<Send> the <notification> to the <subscriber> via the <websocket>.
```

### Semantic Notes

- `via` indicates an intermediate hop or method
- Less common than other prepositions
- Used when specifying how data travels

---

## on

**Meaning:** Location/surface — indicates attachment or location.

**Indicates:** The point of attachment or surface.

**Common with:** `Start`, `Serve`

### Examples

```aro
(* Start on port *)
<Start> the <http-server> on port 8080.
<Start> the <socket-server> on port 9000.

(* Serve on host *)
<Start> the <http-server> on "0.0.0.0:8080".
```

### Semantic Notes

- `on` specifies a location or attachment point
- Primarily used for network configuration
- Indicates "located at" or "attached to"

---

## Preposition Selection Guide

| Intent | Preposition | Example |
|--------|-------------|---------|
| Pull data in | `from` | `<Extract> the <x> from the <y>` |
| Provide data | `with` | `<Create> the <x> with <y>` |
| Indicate purpose | `for` | `<Return> the <x> for the <y>` |
| Push data out | `to` | `<Send> the <x> to the <y>` |
| Store/transform | `into` | `<Store> the <x> into the <y>` |
| Compare/validate | `against` | `<Validate> the <x> against the <y>` |
| Specify channel | `via` | `<Request> the <x> via the <y>` |
| Specify location | `on` | `<Start> the <x> on <y>` |

---

## External Source Indicators

Some prepositions indicate external sources:

```swift
// From Token.swift
public var indicatesExternalSource: Bool {
    switch self {
    case .from, .via: return true
    default: return false
    }
}
```

The `from` and `via` prepositions signal that data is coming from outside the current context, which affects semantic analysis and data flow tracking.
