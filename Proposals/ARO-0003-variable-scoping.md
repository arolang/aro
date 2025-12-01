# ARO-0003: Variable Scoping and Visibility

* Proposal: ARO-0003
* Author: ARO Language Team
* Status: **Draft**
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
┌─────────────────────────────────────────────────────────────┐
│                      Global Scope                           │
│  (Published variables, external dependencies)               │
│  ┌───────────────────────────────────────────────────────┐ │
│  │                  Feature Set Scope                     │ │
│  │  (Variables defined in the feature set)               │ │
│  │  ┌─────────────────────────────────────────────────┐  │ │
│  │  │              Block Scope                         │  │ │
│  │  │  (Variables in if/match/loop blocks)            │  │ │
│  │  └─────────────────────────────────────────────────┘  │ │
│  └───────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### 2. Visibility Levels

```ebnf
visibility = "internal" | "published" | "external" ;
```

| Visibility | Description | Accessible From |
|------------|-------------|-----------------|
| `internal` | Default, private to feature set | Same feature set only |
| `published` | Exported via `<Publish>` | Any feature set |
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

#### 3.3 Redefinition (Shadowing)

Within the same scope, redefining a variable **overwrites** it:

```
(Example: Demo) {
    <Extract> the <user> from the <request>.   // user = extracted value
    <Transform> the <user> from the <user>.    // user = transformed value (overwritten)
}
```

In nested scopes, redefinition **shadows** the outer variable:

```
(Example: Demo) {
    <Set> the <count> to 10.
    
    if <condition> is true then {
        <Set> the <count> to 20.    // Shadows outer count
        // count == 20 here
    }
    // count == 10 here (outer variable unchanged)
}
```

---

### 4. Variable Reference

#### 4.1 Reference Syntax

```ebnf
variable_reference = "<" , qualified_noun , ">" ;
```

#### 4.2 Resolution Order

When resolving a variable reference, the compiler searches:

1. **Current block scope** (innermost)
2. **Enclosing block scopes** (outward)
3. **Feature set scope**
4. **Published/external scope** (global)

```
(Example: Scoping) {
    <Set> the <x> to 1.                    // Feature set scope
    
    if <condition> then {
        <Set> the <y> to 2.                // Block scope
        <Compute> the <z> from <x> + <y>.  // x from outer, y from current
    }
    
    // <y> not accessible here (block scope ended)
}
```

#### 4.3 Qualified Access

For explicit scope specification:

```ebnf
scoped_reference = scope_qualifier , "::" , variable_reference ;
scope_qualifier  = "global" | "local" | feature_set_name ;
```

**Examples:**
```
global::<authenticated-user>       // Explicit global
local::<user>                      // Explicit current scope
UserAuth::<session-token>          // From specific feature set
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

#### 5.2 Publish with Restrictions

Future extension for controlled access:

```
<Publish> as <user: readonly> <internal-user>.
<Publish> as <config> <settings> to <Logging, Audit>.
```

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

Explicitly declare external dependencies:

```ebnf
require_statement = "<Require>" , "<" , variable_name , ">" , 
                    "from" , source , "." ;
source            = "framework" | "environment" | feature_set_name ;
```

**Example:**
```
(User Authentication: Security) {
    <Require> <request> from framework.
    <Require> <database> from framework.
    <Require> <jwt-secret> from environment.
    
    <Extract> the <token> from the <request: headers>.
    // ...
}
```

---

### 7. Lifetime and Initialization

#### 7.1 Variable Lifetime

| Scope | Lifetime |
|-------|----------|
| Block | Until block ends |
| Feature Set | Until feature execution completes |
| Global | Application lifetime |

#### 7.2 Initialization Rules

1. Variables must be defined before use
2. Use of undefined variable is a compile-time error
3. Conditional definition requires all paths to define (see ARO-0004)

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

#### 10.1 Accessing Published Variables

```
(Authentication: Security) {
    <Extract> the <user> from the <request>.
    <Validate> the <credentials> for the <user>.
    <Publish> as <authenticated-user> <user>.
}

(Order Processing: Business) {
    // Can access published variable
    <Retrieve> the <orders> for the <authenticated-user>.
}
```

#### 10.2 Dependency Graph

The compiler builds a dependency graph between feature sets:

```
┌─────────────────┐
│ Authentication  │
│                 │
│ publishes:      │
│   authenticated-│──────┐
│   user          │      │
└─────────────────┘      │
                         ▼
┌─────────────────┐    ┌─────────────────┐
│ Order Processing│◄───│ Audit Logging   │
│                 │    │                 │
│ requires:       │    │ requires:       │
│   authenticated-│    │   authenticated-│
│   user          │    │   user          │
└─────────────────┘    └─────────────────┘
```

#### 10.3 Circular Dependency Detection

Circular dependencies are compile-time errors:

```
(A: Demo) {
    <Require> <x> from B.
    <Publish> as <y> <something>.
}

(B: Demo) {
    <Require> <y> from A.      // Error: Circular dependency A <-> B
    <Publish> as <x> <other>.
}
```

---

### 11. Complete Grammar Extension

```ebnf
(* Extends ARO-0001 *)

(* Require Statement *)
require_statement = "<Require>" , "<" , compound_identifier , ">" ,
                    "from" , source , "." ;

source            = "framework" 
                  | "environment" 
                  | identifier_sequence ;

(* Scoped Reference *)
scoped_reference  = [ scope_qualifier , "::" ] , variable_reference ;

scope_qualifier   = "global" | "local" | identifier_sequence ;

(* Updated Statement *)
statement         = aro_statement 
                  | publish_statement 
                  | require_statement ;
```

---

## Examples

### Complete Scoping Example

```
(* 
 * Demonstrates all scoping concepts 
 *)

(User Service: User Management) {
    // External dependency
    <Require> <database> from framework.
    <Require> <request> from framework.
    
    // Internal variables
    <Extract> the <user-id> from the <request: parameters>.
    <Retrieve> the <user: record> from the <database>.
    
    // Conditional block scope
    if <user: status> is "active" then {
        <Set> the <access-level> to "full".     // Block scope
        <Compute> the <permissions> for the <user: role>.
    } else {
        <Set> the <access-level> to "limited".  // Different block
    }
    // access-level is defined in both branches, so accessible here
    
    // Publish for other features
    <Publish> as <current-user> <user>.
    <Publish> as <user-permissions> <permissions>.
}

(Audit Service: Compliance) {
    // Access published variables
    <Log> the <action> for the <current-user>.
    <Store> the <audit-record> with the <user-permissions>.
}
```

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

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-01 | Initial specification |
