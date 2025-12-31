# ARO-0003: Variable Scoping and Visibility

* Proposal: ARO-0003
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001

## Abstract

This proposal defines the rules for variable scoping, visibility, and lifetime in ARO. It establishes how variables are created, accessed, and shared between feature sets.

## Motivation

Clear scoping rules are essential for:

1. **Predictability**: Developers know where variables are accessible
2. **Encapsulation**: Feature sets can have private state
3. **Sharing**: Controlled exposure of data between features
4. **Safety**: Prevent unintended variable access or modification

## Proposed Solution

### 1. Scope Hierarchy

ARO has three scope levels:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Global Scope                                   │
│                 (external dependencies, environment)                        │
│                                                                             │
│  ┌─────────────────────────────────┐  ┌─────────────────────────────────┐  │
│  │  Business Activity: User Mgmt   │  │  Business Activity: Orders      │  │
│  │  (published variables here)     │  │  (published variables here)     │  │
│  │                                 │  │                                 │  │
│  │  ┌───────────┐ ┌───────────┐   │  │  ┌───────────┐ ┌───────────┐   │  │
│  │  │ Feature   │ │ Feature   │   │  │  │ Feature   │ │ Feature   │   │  │
│  │  │ Set       │ │ Set       │   │  │  │ Set       │ │ Set       │   │  │
│  │  │ (local)   │ │ (local)   │   │  │  │ (local)   │ │ (local)   │   │  │
│  │  └───────────┘ └───────────┘   │  │  └───────────┘ └───────────┘   │  │
│  └─────────────────────────────────┘  └─────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2. Visibility Levels

```ebnf
visibility = "internal" | "published" | "external" ;
```

| Visibility | Description | Accessible From |
|------------|-------------|-----------------|
| `internal` | Default, private to feature set | Same feature set only |
| `published` | Exported via `<Publish>` | Feature sets in same business activity |
| `external` | Defined outside (framework/runtime) | Any feature set |

---

### 3. Variable Definition

#### 3.1 Implicit Definition via ARO Statements

Variables are implicitly defined by ARO statements:

```
<Extract> the <user: identifier> from the <request>.
           ^^^^
           Creates variable "user" with visibility "internal"
```

**Rules:**

1. The **result** of an ARO statement creates a new variable
2. The variable is bound to the value produced by the action
3. Default visibility is `internal`

#### 3.2 Definition Semantics by Action Type

| Action Type | Result Variable | Object Variable |
|-------------|-----------------|-----------------|
| Request | Creates new | Must exist (external or internal) |
| Own | Creates new | Must exist (internal) |
| Response | — (no variable) | Must exist |
| Export | Creates alias | Must exist |

#### 3.3 Redefinition

Within a feature set, redefining a variable **overwrites** it:

```aro
(Example: Demo) {
    <Extract> the <user> from the <request>.   // user = extracted value
    <Transform> the <user> from the <user>.    // user = transformed value (overwritten)
}
```

All variables are visible throughout the entire feature set scope.

---

### 4. Variable Reference

#### 4.1 Reference Syntax

```ebnf
variable_reference = "<" , qualified_noun , ">" ;
```

#### 4.2 Resolution Order

When resolving a variable reference, the runtime searches:

1. **Feature set scope** (local variables)
2. **Global scope** (published and external variables)

```aro
(Example: Scoping) {
    <Create> the <x> with 1.
    <Create> the <y> with 2.
    <Compute> the <z> from <x> + <y>.
    <Return> an <OK: status> with <z>.
}
```

---

### 5. Publishing Variables

#### 5.1 Publish Statement

```
<Publish> as <external-name> <internal-variable>.
```

**Semantics:**

1. `internal-variable` must be defined in the current feature set
2. `external-name` becomes accessible to all feature sets
3. Both names can be used (alias created)

---

### 6. External Dependencies

#### 6.1 Framework-Provided Variables

Some variables are provided by the runtime:

| Variable | Description |
|----------|-------------|
| `<request>` | Incoming HTTP request |
| `<context>` | Execution context |
| `<session>` | Current session |
| `<environment>` | Environment variables |

#### 6.2 Require Statement

Explicitly declare external dependencies using standard ARO syntax:

```ebnf
require_statement = "<Require>" , article , "<" , variable_name , ">" ,
                    "from" , article , "<" , source , ">" , "." ;
source            = "framework" | "environment" | identifier ;
```

**Example:**
```aro
(User Authentication: Security) {
    <Require> the <request> from the <framework>.
    <Require> the <database> from the <framework>.
    <Require> the <jwt-secret> from the <environment>.

    <Extract> the <token> from the <request: headers>.
    <Return> an <OK: status> for the <authentication>.
}
```

---

### 7. Lifetime and Initialization

#### 7.1 Variable Lifetime

| Scope | Lifetime |
|-------|----------|
| Feature Set | Until feature execution completes |
| Global | Application lifetime |

#### 7.2 Initialization Rules

1. Variables must be defined before use
2. Use of undefined variable is a compile-time error

**Valid:**
```
<Extract> the <user> from the <request>.
<Use> the <user> in the <operation>.
```

**Invalid:**
```
<Use> the <user> in the <operation>.  // Error: 'user' is not defined
<Extract> the <user> from the <request>.
```

---

### 8. Symbol Table Structure

```swift
/// Visibility of a symbol
public enum Visibility: Sendable {
    case `internal`     // Private to feature set
    case published      // Exported globally  
    case external       // Provided externally
}

/// How a variable was created
public enum DefinitionKind: Sendable {
    case extracted(from: String)      // From external source
    case computed                     // Internally computed
    case assigned(value: Any)         // Direct assignment
    case alias(of: String)            // Alias via Publish
    case parameter                    // Function/block parameter
    case required(from: String)       // External dependency
}

/// A symbol in the symbol table
public struct Symbol: Sendable {
    let name: String
    let visibility: Visibility
    let definitionKind: DefinitionKind
    let definedAt: SourceSpan
    let type: TypeInfo?               // See ARO-0006
    let isMutable: Bool
}

/// Scoped symbol table
public final class SymbolTable: Sendable {
    let scopeId: String
    let scopeName: String
    let parent: SymbolTable?
    let symbols: [String: Symbol]
    
    func lookup(_ name: String) -> Symbol?
    func lookupLocal(_ name: String) -> Symbol?
    func define(_ symbol: Symbol) -> SymbolTable
}
```

---

### 9. Data Flow Rules

#### 9.1 Definition-Use Chains

The compiler tracks:

- **Definitions**: Where a variable is assigned
- **Uses**: Where a variable is read
- **Dependencies**: Which variables depend on others

```
(Example: Data Flow) {
    <Extract> the <a> from the <input>.     // DEF(a)
    <Extract> the <b> from the <input>.     // DEF(b)
    <Compute> the <c> from <a> + <b>.       // USE(a, b), DEF(c)
    <Return> the <c> for the <output>.      // USE(c)
}

Data Flow:
  a: DEF@line1, USE@line3
  b: DEF@line2, USE@line3
  c: DEF@line3, USE@line4
```

#### 9.2 Unused Variable Warning

```
(Example: Unused) {
    <Extract> the <user> from the <request>.   // Defined
    <Extract> the <token> from the <request>.  // Defined but never used
    <Return> the <user> for the <response>.    // user is used
}

// Warning: Variable 'token' is defined but never used
```

---

### 10. Cross-Feature-Set Access

**Important:** Published variables are only accessible to feature sets within the **same business activity**. This enforces modularity and prevents unintended coupling between different business domains.

#### 10.1 Accessing Published Variables

```aro
(* All feature sets share the same business activity: "User Management" *)

(Authentication: User Management) {
    <Extract> the <user> from the <request>.
    <Validate> the <credentials> for the <user>.
    <Publish> as <authenticated-user> <user>.
}

(Order Retrieval: User Management) {
    (* Can access published variable - same business activity *)
    <Retrieve> the <orders> for the <authenticated-user>.
    <Return> an <OK: status> with <orders>.
}

(Audit Logging: User Management) {
    (* Can access published variable - same business activity *)
    <Log> the <action> for the <authenticated-user>.
    <Return> an <OK: status> for the <audit>.
}
```

#### 10.2 Dependency Graph

The compiler builds a dependency graph between feature sets **within the same business activity**:

```
Business Activity: "User Management"
┌─────────────────────────────────────────────────────────────┐
│                                                             │
│  ┌─────────────────┐                                        │
│  │ Authentication  │                                        │
│  │                 │                                        │
│  │ publishes:      │                                        │
│  │   authenticated-│──────┬─────────────────┐               │
│  │   user          │      │                 │               │
│  └─────────────────┘      │                 │               │
│                           ▼                 ▼               │
│  ┌─────────────────┐    ┌─────────────────┐                 │
│  │ Order Retrieval │    │ Audit Logging   │                 │
│  │                 │    │                 │                 │
│  │ requires:       │    │ requires:       │                 │
│  │   authenticated-│    │   authenticated-│                 │
│  │   user          │    │   user          │                 │
│  └─────────────────┘    └─────────────────┘                 │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

#### 10.3 Cross-Activity Isolation

Feature sets with different business activities **cannot** access each other's published variables:

```aro
(Authentication: Security) {
    <Publish> as <authenticated-user> <user>.
}

(Order Processing: Commerce) {
    (* ERROR: Cannot access 'authenticated-user' - different business activity *)
    <Retrieve> the <orders> for the <authenticated-user>.
}
```

This produces a compile-time error:
```
Error: Variable 'authenticated-user' is not accessible.
Published variables are only visible within the same business activity.
'authenticated-user' is published in "Security" but accessed from "Commerce".
```

#### 10.4 Execution Order

Published variables are resolved at runtime within the same execution context and business activity. If a feature set accesses a published variable that hasn't been set yet, the runtime will report an error:

```
Error: Variable 'authenticated-user' is not available.
It may need to be published by another feature set earlier in the event chain.
```

This follows ARO's "Code Is The Error Message" philosophy - the error clearly indicates what's missing and suggests the solution.

---

### 11. Complete Grammar Extension

```ebnf
(* Extends ARO-0001 *)

(* Require Statement *)
require_statement = "<Require>" , article , "<" , compound_identifier , ">" ,
                    "from" , article , "<" , source , ">" , "." ;

source            = "framework"
                  | "environment"
                  | identifier ;

(* Updated Statement *)
statement         = aro_statement
                  | publish_statement
                  | require_statement ;
```

---

## Examples

### Complete Scoping Example

```aro
(*
 * Demonstrates all scoping concepts
 * Note: Both feature sets share the same business activity
 *)

(User Service: User Management) {
    (* External dependencies *)
    <Require> the <database> from the <framework>.
    <Require> the <request> from the <framework>.

    (* Internal variables *)
    <Extract> the <user-id> from the <request: parameters>.
    <Retrieve> the <user: record> from the <database>.
    <Create> the <access-level> with "full".

    (* Publish for other features in same business activity *)
    <Publish> as <current-user> <user>.
    <Return> an <OK: status> with <user>.
}

(Audit Service: User Management) {
    (* Access published variable - same business activity *)
    <Log> the <action> for the <current-user>.
    <Return> an <OK: status> for the <audit>.
}
```

**Note:** Published variables are available within the same business activity and execution context (event chain). When `User Service` publishes `<current-user>`, only feature sets with the same business activity (`User Management`) triggered in the same event chain can access it.

---

## Implementation Notes

### Semantic Analysis Passes

1. **Symbol Collection**: Gather all definitions
2. **Reference Resolution**: Resolve all variable references
3. **Visibility Check**: Verify access permissions
4. **Data Flow Analysis**: Track definition-use chains
5. **Dependency Analysis**: Build inter-feature-set graph

### Error Messages

| Error | Message |
|-------|---------|
| Undefined variable | `Variable 'x' is not defined` |
| Use before definition | `Variable 'x' used before definition` |
| Private access | `Variable 'x' is internal to feature set 'Y'` |
| Circular dependency | `Circular dependency detected: A -> B -> A` |
| Unused variable | `Variable 'x' is defined but never used` (warning) |

---

## Revision History

| Version | Date    | Changes                                              |
|---------|---------|------------------------------------------------------|
| 1.0     | 2025-12 | Initial specification                                |
| 1.1     | 2025-12 | Simplify to two scope levels (Global + Feature Set)  |
| 1.2     | 2025-12 | Remove block scopes, `::` syntax; fix Require syntax |
| 1.3     | 2025-12 | Clarify cross-feature-set access limited to same business activity |
