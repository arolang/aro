# ARO-0007: Modules and Imports

* Proposal: ARO-0007
* Author: ARO Language Team
* Status: **Draft**
* Requires: ARO-0001, ARO-0003, ARO-0006

## Abstract

This proposal introduces a module system to ARO, enabling code organization across multiple files, reusable components, and controlled visibility.

## Motivation

Large specifications need:

1. **Organization**: Split code across files
2. **Reusability**: Share common definitions
3. **Encapsulation**: Hide implementation details
4. **Namespacing**: Avoid name collisions

## Proposed Solution

A module system with explicit imports and exports.

---

### 1. Module Declaration

#### 1.1 Module Header

Each file begins with an optional module declaration:

```ebnf
module_declaration = "module" , module_path , ";" ;

module_path = identifier , { "." , identifier } ;
```

**Example:**
```
module com.example.auth;

(User Authentication: Security) {
    // ...
}
```

#### 1.2 File as Module

If no module declaration, the filename determines the module:

```
// File: auth/login.aro
// Implicit module: auth.login
```

---

### 2. Import Statements

#### 2.1 Basic Import

```ebnf
import_statement = "import" , import_path , [ import_alias ] , ";" ;

import_path = module_path , [ "." , ( "*" | "{" , import_list , "}" ) ] ;

import_list = identifier , { "," , identifier } ;

import_alias = "as" , identifier ;
```

#### 2.2 Import Forms

##### Import Entire Module

```
import com.example.auth;

// Access as: auth.User, auth.authenticate
```

##### Import with Alias

```
import com.example.auth as authentication;

// Access as: authentication.User
```

##### Import Specific Items

```
import com.example.auth.{ User, Role, authenticate };

// Access directly: User, Role, authenticate
```

##### Import All (Wildcard)

```
import com.example.auth.*;

// All public symbols available directly
```

#### 2.3 Import Examples

```
module com.example.orders;

import com.example.auth.{ User, AuthResult };
import com.example.products.{ Product, Inventory };
import com.example.common.*;

(Order Processing: E-Commerce) {
    // Can use User, Product, etc. directly
    <Retrieve> the <user: User> from the <auth-context>.
    <Retrieve> the <products: List<Product>> from the <cart>.
}
```

---

### 3. Export Control

#### 3.1 Visibility Modifiers

```ebnf
visibility_modifier = "public" | "internal" | "private" ;
```

| Modifier | Visibility |
|----------|------------|
| `public` | Accessible from any module |
| `internal` | Accessible within same module (default) |
| `private` | Accessible only in same file |

#### 3.2 Applying Modifiers

##### To Types

```
public type User {
    id: String;
    email: String;
    internal passwordHash: String;  // Not exported
}

private type InternalCache {
    // Only visible in this file
}
```

##### To Feature Sets

```
public (User Authentication: Security) {
    // Exported, can be imported
}

internal (Helper Functions: Utilities) {
    // Only within this module
}
```

##### To Published Variables

```
<Publish> public as <authenticated-user> <user>.
<Publish> internal as <session-cache> <cache>.
```

---

### 4. Module Structure

#### 4.1 Recommended Layout

```
project/
├── aro.config                    # Project configuration
├── src/
│   ├── main.aro                  # Entry point
│   ├── common/
│   │   ├── types.aro             # Shared types
│   │   └── utils.aro             # Utilities
│   ├── auth/
│   │   ├── module.aro            # Module definition
│   │   ├── login.aro
│   │   ├── logout.aro
│   │   └── types.aro
│   ├── orders/
│   │   ├── module.aro
│   │   ├── create.aro
│   │   └── process.aro
│   └── products/
│       └── ...
└── tests/
    └── ...
```

#### 4.2 Module Definition File

`module.aro` defines the public interface:

```
// auth/module.aro
module com.example.auth;

// Re-export from submodules
public import ./login.{ LoginFeature };
public import ./logout.{ LogoutFeature };
public import ./types.{ User, Role, AuthResult };

// Module-level exports
public type AuthConfig {
    tokenExpiry: Duration;
    maxAttempts: Int;
}
```

---

### 5. Relative Imports

#### 5.1 Syntax

```ebnf
relative_import = "import" , relative_path , ";" ;

relative_path = "./" , path_segment , { "/" , path_segment }
              | "../" , { "../" } , path_segment , { "/" , path_segment } ;
```

#### 5.2 Examples

```
// In: auth/login.aro
import ./types.{ User };           // auth/types.aro
import ../common/utils.*;          // common/utils.aro
import ../../shared/constants;     // Up two levels
```

---

### 6. Conditional Imports

#### 6.1 Platform-Specific Imports

```ebnf
conditional_import = "import" , import_path , "if" , condition , ";" ;
```

**Example:**
```
import platform.ios.push if platform is "ios";
import platform.android.push if platform is "android";
import platform.web.push if platform is "web";
```

#### 6.2 Feature Flags

```
import features.experimental.ai if feature("ai-enabled");
```

---

### 7. Namespaces

#### 7.1 Namespace Access

```
// Full qualification
<Retrieve> the <user: com.example.auth.User> from the <repository>.

// With import alias
import com.example.auth as auth;
<Retrieve> the <user: auth.User> from the <repository>.
```

#### 7.2 Namespace Conflicts

When names collide, use full qualification:

```
import com.example.orders.{ Item };
import com.example.inventory.{ Item as InventoryItem };

<Process> the <order-item: Item> for the <order>.
<Check> the <stock-item: InventoryItem> in the <warehouse>.
```

---

### 8. Circular Dependencies

#### 8.1 Detection

The compiler detects circular imports:

```
// A.aro
import B;  // B imports A -> Error

// B.aro  
import A;
```

**Error:**
```
Circular dependency detected: A -> B -> A
```

#### 8.2 Resolution Strategies

1. **Extract Common**: Move shared types to a third module
2. **Interface Modules**: Use protocols/interfaces
3. **Lazy Imports**: Import only when needed (runtime)

```
// common/types.aro
public type SharedEntity { ... }

// A.aro
import common.types.{ SharedEntity };

// B.aro
import common.types.{ SharedEntity };
```

---

### 9. Package Management

#### 9.1 Package Manifest

`aro.config`:

```yaml
name: my-project
version: 1.0.0
main: src/main.aro

dependencies:
  aro-stdlib: ^1.0.0
  aro-http: ^2.1.0
  company-shared:
    git: https://github.com/company/shared.git
    tag: v1.2.3

devDependencies:
  aro-test: ^1.0.0
```

#### 9.2 External Package Import

```
import aro.http.{ Request, Response, Client };
import company.shared.{ Logger, Config };
```

---

### 10. Standard Library

#### 10.1 Built-in Modules

| Module | Contents |
|--------|----------|
| `aro.core` | Basic types, utilities |
| `aro.collections` | List, Map, Set operations |
| `aro.text` | String manipulation |
| `aro.time` | DateTime, Duration |
| `aro.math` | Mathematical functions |
| `aro.io` | Input/output |
| `aro.http` | HTTP client/server |
| `aro.json` | JSON parsing |
| `aro.crypto` | Cryptographic functions |

#### 10.2 Implicit Imports

`aro.core` is implicitly imported:

```
// These are always available without import:
// String, Int, Float, Bool, List, Map, Set, Optional
```

---

### 11. Complete Grammar Extension

```ebnf
(* Module System Grammar *)

(* File Structure *)
source_file = [ module_declaration ] ,
              { import_statement } ,
              { top_level_declaration } ;

(* Module Declaration *)
module_declaration = "module" , module_path , ";" ;
module_path = identifier , { "." , identifier } ;

(* Import Statement *)
import_statement = [ visibility_modifier ] , 
                   "import" , import_source , 
                   [ import_items ] ,
                   [ import_alias ] ,
                   [ import_condition ] ,
                   ";" ;

import_source = module_path | relative_path ;

relative_path = ( "./" | { "../" } ) , 
                identifier , { "/" , identifier } ;

import_items = "." , ( "*" | "{" , identifier_list , "}" ) ;
identifier_list = import_item , { "," , import_item } ;
import_item = identifier , [ "as" , identifier ] ;

import_alias = "as" , identifier ;
import_condition = "if" , condition ;

(* Visibility *)
visibility_modifier = "public" | "internal" | "private" ;

(* Top-Level Declarations *)
top_level_declaration = [ visibility_modifier ] , 
                        ( type_definition 
                        | feature_set 
                        | constant_declaration ) ;

constant_declaration = "const" , identifier , ":" , type_expr , 
                       "=" , expression , ";" ;
```

---

### 12. Complete Examples

#### Multi-File Project

**common/types.aro:**
```
module com.example.common;

public type EntityId = String;

public type Timestamped {
    createdAt: DateTime;
    updatedAt: DateTime?;
}

public protocol Repository<T> {
    find: (id: EntityId) -> T?;
    save: (entity: T) -> T;
    delete: (id: EntityId) -> Bool;
}
```

**auth/types.aro:**
```
module com.example.auth;

import ../common/types.{ EntityId, Timestamped };

public type User: Timestamped {
    id: EntityId;
    email: String;
    roles: List<Role>;
}

public enum Role {
    Admin,
    User,
    Guest
}

public type AuthResult {
    user: User;
    token: String;
    expiresAt: DateTime;
}
```

**auth/login.aro:**
```
module com.example.auth;

import ./types.{ User, AuthResult };
import ../common/types.{ Repository };
import aro.crypto.{ hash, verify };

public (Login: Authentication) {
    <Require> <request: Request> from framework.
    <Require> <user-repo: Repository<User>> from framework.
    
    <Extract> the <email: String> from the <request: body>.
    <Extract> the <password: String> from the <request: body>.
    
    <Retrieve> the <user: User?> from the <user-repo> 
        with { email: <email> }.
    
    if <user> is null then {
        <Return> an <Unauthorized> for the <request>.
    }
    
    <Verify> the <valid: Bool> from verify(<password>, <user>.passwordHash).
    
    if <valid> then {
        <Create> the <result: AuthResult> for the <user>.
        <Publish> public as <auth-result> <result>.
        <Return> the <result> for the <request>.
    } else {
        <Return> an <Unauthorized> for the <request>.
    }
}
```

**main.aro:**
```
module com.example.app;

import com.example.auth.{ Login, Logout };
import com.example.orders.{ CreateOrder, ProcessOrder };
import com.example.products.{ ProductCatalog };

public (Application: Main) {
    <Register> the <Login> at "/auth/login".
    <Register> the <Logout> at "/auth/logout".
    <Register> the <CreateOrder> at "/orders".
    <Register> the <ProcessOrder> at "/orders/process".
    <Register> the <ProductCatalog> at "/products".
}
```

---

## Implementation Notes

### Module Resolution

```swift
public struct ModuleResolver {
    let searchPaths: [URL]
    let packageManifest: PackageManifest?
    
    func resolve(_ importPath: String, from: SourceLocation) -> Result<ModuleInfo, ImportError>
    func loadModule(_ info: ModuleInfo) -> Result<ParsedModule, LoadError>
}

public struct ModuleInfo {
    let path: ModulePath
    let fileURL: URL
    let isExternal: Bool
}

public struct ParsedModule {
    let path: ModulePath
    let exports: [String: Symbol]
    let dependencies: [ModulePath]
}
```

### Dependency Graph

```swift
public struct DependencyGraph {
    let modules: [ModulePath: ParsedModule]
    
    func topologicalSort() -> Result<[ModulePath], CycleError>
    func detectCycles() -> [Cycle]
}
```

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-01 | Initial specification |
