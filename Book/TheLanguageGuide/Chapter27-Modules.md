# Chapter 27: Modules and Imports

*"Compose applications from small, understandable pieces."*

---

## 27.1 Application Composition

<div style="text-align: center; margin: 2em 0;">
<svg width="400" height="140" viewBox="0 0 400 140" xmlns="http://www.w3.org/2000/svg">  <!-- Module A -->  <rect x="30" y="20" width="100" height="50" rx="5" fill="#dbeafe" stroke="#3b82f6" stroke-width="2"/>  <text x="80" y="40" text-anchor="middle" font-family="sans-serif" font-size="10" font-weight="bold" fill="#1e40af">Module A</text>  <text x="80" y="55" text-anchor="middle" font-family="monospace" font-size="8" fill="#3b82f6">/module-a</text>  <!-- Module B -->  <rect x="270" y="20" width="100" height="50" rx="5" fill="#dcfce7" stroke="#22c55e" stroke-width="2"/>  <text x="320" y="40" text-anchor="middle" font-family="sans-serif" font-size="10" font-weight="bold" fill="#166534">Module B</text>  <text x="320" y="55" text-anchor="middle" font-family="monospace" font-size="8" fill="#22c55e">/module-b</text>  <!-- Arrows -->  <line x1="80" y1="70" x2="160" y2="100" stroke="#6b7280" stroke-width="2"/>  <polygon points="160,100 152,95 152,105" fill="#6b7280"/>  <line x1="320" y1="70" x2="240" y2="100" stroke="#6b7280" stroke-width="2"/>  <polygon points="240,100 248,95 248,105" fill="#6b7280"/>  <!-- Combined -->  <rect x="150" y="100" width="100" height="35" rx="5" fill="#e0e7ff" stroke="#6366f1" stroke-width="2"/>  <text x="200" y="118" text-anchor="middle" font-family="sans-serif" font-size="10" font-weight="bold" fill="#4338ca">Combined</text>  <text x="200" y="130" text-anchor="middle" font-family="monospace" font-size="7" fill="#6366f1">import ../A ../B</text>  <!-- Labels -->  <text x="115" y="85" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#9ca3af">import</text>  <text x="285" y="85" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#9ca3af">import</text></svg>
</div>
ARO applications are directories containing `.aro` files. When an application grows or when you want to share functionality between projects, the import system lets you compose applications from smaller pieces.
The import mechanism is radically simple. You import another application directory, and all its feature sets become accessible. No visibility modifiers, no selective imports, no namespacing. If you import an application, you trust it and want all of it.
This design reflects how project managers think about systems. Applications are black boxes that do things. If you need what another application provides, you import it. There are no access control decisions to make, no visibility declarations to configure.
---
## 27.2 Import Syntax
The import statement appears at the top of an ARO file, before any feature sets:
```aro
import ../auth-service
import ../payment-gateway
import ../../shared/utilities
```
Paths are relative to the current file's directory. The `..` notation moves up one directory level. The path points to a directory containing `.aro` files.
When the compiler encounters an import:
1. It resolves the path relative to the current file
2. It finds all `.aro` files in that directory
3. It makes all feature sets from those files accessible
4. Published variables become available
5. Types become available
There is no need to specify what you want from the imported application. Everything becomes accessible.
---
## 27.3 No Visibility Modifiers
ARO explicitly rejects visibility modifiers. There is no `public`, `private`, or `internal`.
| Traditional | ARO Approach |
|-------------|--------------|
| `public` | Everything is accessible after import |
| `private` | Feature set scope handles encapsulation |
| `internal` | Not needed |
| `protected` | No inheritance hierarchy |
This might seem dangerous. What about encapsulation? What about hiding implementation details?
ARO takes a different position. Within a feature set, variables are scoped naturally. They exist only within that feature set unless explicitly published. If you want to share data between feature sets, you use the Publish action or emit events. These are explicit sharing mechanisms.
When you import an application, you are saying: I want this application's capabilities. You trust the imported code. If you need to restrict what is accessible, the answer is not visibility modifiers. The answer is to factor the code into appropriate applications.
---
## 27.4 The ModulesExample
The `Examples/ModulesExample` directory demonstrates application composition with three directories:
```
ModulesExample/
├── ModuleA/
│   ├── main.aro
│   └── openapi.yaml
├── ModuleB/
│   ├── main.aro
│   └── openapi.yaml
└── Combined/
    ├── main.aro
    └── openapi.yaml
```
Each module can run standalone or be imported into a larger application.
### Module A
Module A provides a single endpoint at `/module-a`:
```aro
(* Module A - Standalone Application *)
(Application-Start: ModuleA) {
    Log "Module A starting..." to the <console>.
    Start the <http-server> for the <contract>.
    Keepalive the <application> for the <events>.
    Return an <OK: status> for the <startup>.
}
(getModuleA: ModuleA API) {
    Create the <response> with { message: "Hello from Module A" }.
    Return an <OK: status> with <response>.
}
```
*Source: [Examples/ModulesExample/ModuleA/main.aro](../Examples/ModulesExample/ModuleA/main.aro)*
Run it standalone:
```bash
aro build ./Examples/ModulesExample/ModuleA
./Examples/ModulesExample/ModuleA/ModuleA
```
### Module B
Module B provides a single endpoint at `/module-b`:
```aro
(* Module B - Standalone Application *)
(Application-Start: ModuleB) {
    Log "Module B starting..." to the <console>.
    Start the <http-server> for the <contract>.
    Keepalive the <application> for the <events>.
    Return an <OK: status> for the <startup>.
}
(getModuleB: ModuleB API) {
    Create the <response> with { message: "Hello from Module B" }.
    Return an <OK: status> with <response>.
}
```
*Source: [Examples/ModulesExample/ModuleB/main.aro](../Examples/ModulesExample/ModuleB/main.aro)*
### Combined Application
The Combined application imports both modules and provides both endpoints:
```aro
(* Combined Application *)
import ../ModuleA
import ../ModuleB
(Application-Start: Combined) {
    Log "Combined application starting..." to the <console>.
    Start the <http-server> for the <contract>.
    Keepalive the <application> for the <events>.
    Return an <OK: status> for the <startup>.
}
```
*Source: [Examples/ModulesExample/Combined/main.aro](../Examples/ModulesExample/Combined/main.aro)*
The `getModuleA` and `getModuleB` feature sets come from the imported applications. They do not need to be redefined. The Combined application's OpenAPI contract defines both routes, and the imported feature sets handle them.
---
## 27.5 Building Standalone Binaries
Each module produces its own standalone binary:
```bash
# Build Module A
aro build ./Examples/ModulesExample/ModuleA
# Creates: ModuleA/ModuleA
# Build Module B
aro build ./Examples/ModulesExample/ModuleB
# Creates: ModuleB/ModuleB
# Build Combined
aro build ./Examples/ModulesExample/Combined
# Creates: Combined/Combined
```
The Combined binary includes all code from both imported modules. The resulting binary is self-contained and requires no runtime dependencies.
---
## 27.6 Distributed Services Pattern
<div style="float: right; margin: 0 0 1em 1.5em;">
<svg width="160" height="200" viewBox="0 0 160 200" xmlns="http://www.w3.org/2000/svg">  <!-- Auth -->  <rect x="10" y="10" width="60" height="35" rx="4" fill="#dbeafe" stroke="#3b82f6" stroke-width="1.5"/>  <text x="40" y="28" text-anchor="middle" font-family="sans-serif" font-size="8" font-weight="bold" fill="#1e40af">Auth</text>  <text x="40" y="40" text-anchor="middle" font-family="monospace" font-size="6" fill="#3b82f6">:8081</text>  <!-- Users -->  <rect x="90" y="10" width="60" height="35" rx="4" fill="#dcfce7" stroke="#22c55e" stroke-width="1.5"/>  <text x="120" y="28" text-anchor="middle" font-family="sans-serif" font-size="8" font-weight="bold" fill="#166534">Users</text>  <text x="120" y="40" text-anchor="middle" font-family="monospace" font-size="6" fill="#22c55e">:8082</text>  <!-- Orders -->  <rect x="10" y="60" width="60" height="35" rx="4" fill="#fef3c7" stroke="#f59e0b" stroke-width="1.5"/>  <text x="40" y="78" text-anchor="middle" font-family="sans-serif" font-size="8" font-weight="bold" fill="#92400e">Orders</text>  <text x="40" y="90" text-anchor="middle" font-family="monospace" font-size="6" fill="#f59e0b">:8083</text>  <!-- Payments -->  <rect x="90" y="60" width="60" height="35" rx="4" fill="#f3e8ff" stroke="#a855f7" stroke-width="1.5"/>  <text x="120" y="78" text-anchor="middle" font-family="sans-serif" font-size="8" font-weight="bold" fill="#7c3aed">Payments</text>  <text x="120" y="90" text-anchor="middle" font-family="monospace" font-size="6" fill="#a855f7">:8084</text>  <!-- Arrows to gateway -->  <line x1="40" y1="45" x2="70" y2="130" stroke="#6b7280" stroke-width="1"/>  <line x1="120" y1="45" x2="90" y2="130" stroke="#6b7280" stroke-width="1"/>  <line x1="40" y1="95" x2="70" y2="130" stroke="#6b7280" stroke-width="1"/>  <line x1="120" y1="95" x2="90" y2="130" stroke="#6b7280" stroke-width="1"/>  <!-- Gateway -->  <rect x="35" y="130" width="90" height="40" rx="4" fill="#e0e7ff" stroke="#6366f1" stroke-width="2"/>  <text x="80" y="150" text-anchor="middle" font-family="sans-serif" font-size="9" font-weight="bold" fill="#4338ca">Gateway</text>  <text x="80" y="163" text-anchor="middle" font-family="monospace" font-size="7" fill="#6366f1">:8080</text>  <!-- Label -->  <text x="80" y="190" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#9ca3af">imports all services</text></svg>
</div>
A common pattern is building microservices that can run independently or be composed into a monolith for simpler deployments:
```
services/
├── auth/
│   ├── main.aro
│   └── openapi.yaml
├── users/
│   ├── main.aro
│   └── openapi.yaml
├── orders/
│   ├── main.aro
│   └── openapi.yaml
└── gateway/
    ├── main.aro
    └── openapi.yaml
```
Each service has its own Application-Start and can run on its own port. The gateway imports all services and provides a unified API.
For development, you might run the gateway monolith. For production, you might run each service independently and use a real API gateway.
---
## 27.7 Sharing Data Between Applications
When you import an application, you get access to its published variables within the same business activity. The Publish action (see ARO-0003) makes values available to feature sets sharing that business activity:
```aro
(* In auth-service/auth.aro *)
(Authenticate User: Security) {
    Extract the <credentials> from the <request: body>.
    Retrieve the <user> from the <user-repository> where credentials = <credentials>.
    Publish as <authenticated-user> <user>.
    Return an <OK: status> with <user>.
}
```
After importing auth-service, other feature sets can access the published variable:
```aro
(* In gateway/main.aro *)
import ../auth-service
(Process Request: Gateway) {
    (* Access published variable from imported application *)
    <Use> the <authenticated-user> in the <authorization-check>.
    Return an <OK: status> for the <request>.
}
```
---
## 27.8 What Is Not Imported
When you import an application, its Application-Start feature set is not executed. Only the importing application's Application-Start runs. The imported feature sets become available, but lifecycle management remains with the importing application.
This prevents conflicts when composing applications. Each composed application might have its own startup logic, but only the top-level application controls the actual startup sequence.
Similarly, Application-End handlers from imported applications are not triggered during shutdown. The importing application manages its own lifecycle.
---
## 27.9 Circular Imports
Circular imports are technically allowed:
```aro
(* service-a/main.aro *)
import ../service-b
(* service-b/main.aro *)
import ../service-a
```
The compiler handles this by loading all files from all imported applications, building a unified symbol table, and resolving references across all loaded feature sets.
However, circular dependencies usually indicate poor architecture. If two applications need each other, consider:
1. Extracting shared code to a third application that both import
2. Using events instead of direct access
3. Reorganizing the application boundaries
---
## 27.10 What Is Not Provided
ARO deliberately omits many features found in other module systems:
- **Module declarations** - No `module com.example.foo`
- **Namespace qualifiers** - No `com.example.foo.MyType`
- **Selective imports** - No `import { User, Order } from ./users`
- **Import aliases** - No `import ./users as u`
- **Package manifests** - No `Package.yaml` or `aro.config`
- **Version constraints** - No `^1.0.0` or `~2.1.0`
- **Remote package repositories** - No central registry
These are implementation concerns that add complexity without matching how ARO applications are designed to work. If you need versioning, use git. If you need remote packages, use git submodules or symbolic links.
---
## 27.11 Summary
The import system embodies ARO's philosophy of simplicity:
1. `import ../path` imports another application
2. Everything becomes accessible after import
3. No visibility modifiers complicate decisions
4. Each application can run standalone or be composed
5. Native compilation produces self-contained binaries
This is not enterprise-grade module management. It is application composition for developers who want to build systems from small, understandable pieces.
---
*Next: Chapter 27 — Control Flow*