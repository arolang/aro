# ARO-0007: Application Imports

* Proposal: ARO-0007
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0003

## Abstract

This proposal defines how ARO applications can import other ARO applications. When imported, all feature sets and types from the imported application become accessible. This enables composition of small, distributable services into larger systems.

## Philosophy

ARO rejects traditional visibility modifiers. There is no `public`, `private`, or `internal`.

**The fundamental principle**: Everything created in a feature set is valid within that feature set. To share data outside the feature set, use the `<Publish>` action (see ARO-0003). To use another application's feature sets and types, simply import it.

This reflects how project managers think: applications are black boxes that do things. If you need what another application does, you import it. No access control configuration, no visibility declarations, no module boundaries to navigate.

---

## How It Works

### 1. Single Application (No Imports)

An ARO application is a directory containing `.aro` files:

```
MyApp/
├── main.aro           # Contains Application-Start
├── users.aro          # User feature sets
└── orders.aro         # Order feature sets
```

Within a single application:
- All `.aro` files are automatically discovered
- All feature sets are globally visible
- No imports needed between files in the same directory

### 2. Importing Another Application

To use another application's feature sets and types:

```aro
import ../user-service
import ../payment-gateway
import ../../shared/auth
```

**That's it.** After the import:
- All feature sets from the imported application are accessible
- All types from the imported application are accessible
- Published variables from the imported application are accessible

---

## Import Syntax

```ebnf
import_statement = "import" , relative_path ;

relative_path = "./" , path_segment , { "/" , path_segment }
              | "../" , { "../" } , path_segment , { "/" , path_segment } ;
```

### Examples

```aro
(* Import sibling application *)
import ../auth-service

(* Import application two levels up *)
import ../../shared/common

(* Import from same parent *)
import ./utilities
```

---

## Imported Application Structure

When you import an application, ARO:

1. Finds the directory at the specified path
2. Discovers all `.aro` files in that directory
3. Makes all feature sets accessible
4. Makes all types accessible
5. Makes all published variables accessible

```
workspace/
├── user-service/           # Can import ../payment-service
│   ├── main.aro
│   └── users.aro
├── payment-service/        # Can import ../user-service
│   ├── main.aro
│   └── payments.aro
└── api-gateway/            # Can import both
    └── main.aro
```

**api-gateway/main.aro:**
```aro
import ../user-service
import ../payment-service

(Application-Start: API Gateway) {
    <Log> "Gateway starting..." to the <console>.
    <Start> the <http-server> on port 8080.
    <Keepalive> the <application> for the <events>.
    <Return> an <OK: status> for the <startup>.
}

(* Can now use feature sets from both imported applications *)
(Handle User Request: HTTP Handler) {
    (* Uses user-service feature sets and types *)
    <Invoke> the <Get User> with <request>.
    <Return> an <OK: status> with <response>.
}
```

---

## No Visibility Modifiers

ARO explicitly rejects visibility modifiers:

| Traditional | ARO |
|-------------|-----|
| `public` | Not needed - everything is accessible after import |
| `private` | Not needed - don't export what you don't want shared |
| `internal` | Not needed - feature set scope handles this |
| `protected` | Not needed - no inheritance hierarchy |

### Why No Visibility?

1. **Simplicity**: Project managers don't think about access control
2. **Trust**: If you import an application, you trust it
3. **Clarity**: The code says what it does, not what it hides
4. **ARO-0003**: Variable scoping already handles encapsulation within feature sets

---

## Sharing Data Between Applications

Use `<Publish>` (ARO-0003) to share data:

**user-service/users.aro:**
```aro
(Authenticate User: Security) {
    <Extract> the <credentials> from the <request: body>.
    <Retrieve> the <user> from the <user-repository> where credentials = <credentials>.
    <Publish> as <authenticated-user> <user>.
    <Return> an <OK: status> with <user>.
}
```

**api-gateway/main.aro:**
```aro
import ../user-service

(Process Request: API Gateway) {
    (* Access published variable from imported application *)
    <Use> the <authenticated-user> in the <authorization-check>.
    <Return> an <OK: status> for the <request>.
}
```

---

## Distributed Services Pattern

ARO applications are designed as small, distributable services:

```
microservices/
├── auth/                   # Authentication service
│   ├── main.aro
│   └── openapi.yaml
├── users/                  # User management service
│   ├── main.aro
│   └── openapi.yaml
├── orders/                 # Order processing service
│   ├── main.aro
│   └── openapi.yaml
└── gateway/                # API gateway
    ├── main.aro
    └── openapi.yaml        # Aggregated API
```

Each service:
- Has its own `Application-Start`
- Can run independently
- Can be imported by other services
- Shares through published variables

---

## Circular Imports

Circular imports are allowed but should be avoided:

```aro
(* A imports B, B imports A - this works but is confusing *)
```

The compiler handles circular imports by:
1. Loading all files from all imported applications
2. Building a unified symbol table
3. Resolving references across all loaded feature sets

However, circular dependencies often indicate poor architecture. Consider extracting shared code to a common application.

---

## Non-Goals

ARO explicitly does **not** provide:

- Module declarations (`module com.example.foo`)
- Namespace qualifiers (`com.example.foo.MyType`)
- Selective imports (`import { User, Order } from ./users`)
- Import aliases (`import ./users as u`)
- Package manifests (`aro.config`, `Package.yaml`)
- Version constraints (`^1.0.0`, `~2.1.0`)
- Remote package repositories

These are implementation concerns. ARO applications are directories. If you need versioning, use git. If you need remote packages, use git submodules or symbolic links.

---

## Examples

### Basic Import

**shared/types.aro:**
```aro
(* Type definitions - no Application-Start, just types *)

type User {
    id: String;
    email: String;
    name: String;
}

type Order {
    id: String;
    userId: String;
    total: Decimal;
}
```

**order-service/main.aro:**
```aro
import ../shared

(Application-Start: Order Service) {
    <Log> "Starting..." to the <console>.
    <Return> an <OK: status> for the <startup>.
}

(Create Order: Order API) {
    (* Uses User and Order types from imported application *)
    <Extract> the <user: User> from the <context: authenticated-user>.
    <Create> the <order: Order> with <user: id>.
    <Return> a <Created: status> with <order>.
}
```

### Service Composition

**api/main.aro:**
```aro
import ../auth
import ../users
import ../orders
import ../notifications

(Application-Start: API) {
    <Start> the <http-server> on port 8080.
    <Keepalive> the <application> for the <events>.
    <Return> an <OK: status> for the <startup>.
}

(* All feature sets from all imported applications are now accessible *)
(* Routes are registered based on openapi.yaml as per ARO-0027 *)
```

---

## Summary

ARO's import system is radically simple:

1. **`import ../path`** - Import another application
2. **Everything accessible** - All feature sets, types, published variables
3. **No visibility modifiers** - Trust and simplicity over access control
4. **Small services** - Compose applications from focused, distributable units

This isn't enterprise-grade module management. It's application composition for humans who want to build systems from small, understandable pieces.

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-01 | Initial specification with full module system |
| 2.0 | 2024-12 | Complete rewrite: simplified import system, no visibility modifiers |
