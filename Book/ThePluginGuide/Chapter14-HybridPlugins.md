# Chapter 13: Hybrid Plugins

> *"The best tool is the one that lets you use the right tool for each job."*
> — Pragmatic wisdom

Throughout this book, we've explored plugins written entirely in one language—Swift, Rust, C, C++, or Python. Each approach has strengths: native code for performance and system access, Python for ML ecosystems, Swift for Apple platform integration. But some plugins benefit from combining approaches. **Hybrid plugins** pair native code with ARO files, giving you native performance where you need it and ARO's declarative expressiveness for high-level orchestration.

This chapter explores when and how to build hybrid plugins—plugins that speak two languages.

## 13.1 The Case for Hybrid Architecture

Before diving into implementation, let's understand when hybrid architecture makes sense.

### When Native Alone Isn't Enough

Consider an authentication plugin. The core operations—password hashing, token generation, cryptographic verification—demand native code for security and performance. But authentication also involves:

- Checking user credentials against a database
- Rate limiting login attempts
- Sending password reset emails
- Logging security events

These orchestration tasks don't need native speed. They're business logic that changes frequently and benefits from ARO's readability. A hybrid plugin lets you write:

**Native layer** (Swift):
```swift
// Cryptographic operations - needs native security
@_cdecl("auth_hash_password")
public func hashPassword(...) -> Int32 { ... }

@_cdecl("auth_verify_password")
public func verifyPassword(...) -> Int32 { ... }

@_cdecl("auth_generate_token")
public func generateToken(...) -> Int32 { ... }
```

**ARO layer** (authentication.aro):
```aro
(* Business logic - readable and maintainable *)
(Authenticate User: Authentication) {
    <Extract> the <email> from the <credentials: email>.
    <Extract> the <password> from the <credentials: password>.

    <Retrieve> the <user> from the <user-repository> where email = <email>.
    <Call> the <valid> from the <auth: verifyPassword> with {
        password: <password>,
        hash: <user: passwordHash>
    }.

    <When> <valid> is false:
        <Log> "Failed login attempt for " ++ <email> to the <console>.
        <Return> a <Forbidden: status> for the <authentication>.

    <Call> the <token> from the <auth: generateToken> with { userId: <user: id> }.
    <Return> an <OK: status> with { token: <token> }.
}
```

### The Division of Labor

Hybrid plugins work best when responsibilities divide cleanly:

| Native Code | ARO Files |
|-------------|-----------|
| Cryptography | Business workflows |
| Binary protocols | Data transformation pipelines |
| Performance-critical algorithms | Error handling and recovery |
| System calls and FFI | Configuration and orchestration |
| Memory management | Integration with other services |

### When to Stay Monolithic

Not every plugin needs hybrid architecture. Stay with a single approach when:

- **All code is performance-critical**: A video codec plugin should be entirely native
- **All code is orchestration**: A notification routing plugin might be pure ARO
- **Team expertise is narrow**: If your team knows Rust but not ARO, write Rust
- **Complexity is low**: Simple plugins don't need the overhead of two languages

### Pure ARO Plugins

Before exploring hybrid architecture, let's examine the simplest form: **pure ARO plugins**. These plugins contain only `.aro` files—no native code at all. They're ideal for:

- **Event handlers** that respond to domain events
- **Reusable feature sets** that encapsulate business logic
- **Cross-cutting concerns** like logging, auditing, or notifications
- **Rapid prototyping** before optimizing with native code

Pure ARO plugins are the fastest to develop and easiest to maintain. They require no compilation, no build tools, and no language-specific expertise beyond ARO itself.

#### Example: Audit Logging Plugin

The `plugin-aro-auditlog` demonstrates a pure ARO plugin that automatically logs domain events:

```
plugin-aro-auditlog/
├── plugin.yaml
├── README.md
└── features/
    └── audit-handlers.aro
```

**plugin.yaml:**
```yaml
name: plugin-aro-auditlog
version: 1.0.0
description: Pure ARO audit logging plugin - automatically logs domain events

source:
  git: https://github.com/arolang/plugin-aro-auditlog.git

provides:
  - type: aro-files
    path: features/
```

**features/audit-handlers.aro:**
```aro
(* Event handlers for audit logging *)

(Log User Events: UserCreated Handler) {
    <Log> "[AUDIT] UserCreated: User created" to the <console>.
    <Return> an <OK: status> for the <audit>.
}

(Log Order Events: OrderPlaced Handler) {
    <Log> "[AUDIT] OrderPlaced: Order placed" to the <console>.
    <Return> an <OK: status> for the <audit>.
}

(Log Payment Events: PaymentReceived Handler) {
    <Log> "[AUDIT] PaymentReceived: Payment processed" to the <console>.
    <Return> an <OK: status> for the <audit>.
}
```

#### Event Handler Convention

The magic is in the **business activity naming**. Feature sets with business activity matching the pattern `<EventName> Handler` automatically become event handlers:

| Business Activity | Handles Event |
|-------------------|---------------|
| `UserCreated Handler` | `UserCreated` |
| `OrderPlaced Handler` | `OrderPlaced` |
| `PaymentReceived Handler` | `PaymentReceived` |

When your application emits a matching event, the handler executes automatically:

```aro
(Application-Start: My App) {
    (* This triggers the "Log User Events" handler from the plugin *)
    <Emit> a <UserCreated: event> with {
        user: { id: "123", name: "Alice" }
    }.

    <Return> an <OK: status> for the <startup>.
}
```

**Output:**
```
[Log User Events] [AUDIT] UserCreated: User created
```

#### Installing Pure ARO Plugins

Install like any other plugin:

```bash
aro add https://github.com/arolang/plugin-aro-auditlog.git
```

Or declare in your `aro.yaml`:

```yaml
plugins:
  - source: https://github.com/arolang/plugin-aro-auditlog
```

#### When Pure ARO Isn't Enough

Pure ARO plugins have limitations:

- **No system access**: Can't read files, make HTTP calls, or access hardware directly
- **No custom actions**: Can only use built-in ARO actions and actions from other plugins
- **No performance optimization**: All execution goes through the ARO interpreter

When you hit these limits, it's time to go hybrid—add native code for the capabilities you need while keeping ARO for orchestration.

## 13.2 Hybrid Plugin Architecture

A hybrid plugin contains both native code and ARO files, with a manifest that declares both:

```
auth-plugin/
├── plugin.yaml
├── src/                    # Native code (Swift, Rust, C, etc.)
│   └── AuthService.swift
├── features/               # ARO files
│   ├── authentication.aro
│   ├── password-reset.aro
│   └── session-management.aro
└── tests/
    └── auth-tests.aro
```

### The Manifest Structure

```yaml
# plugin.yaml
name: auth-plugin
version: 1.0.0
description: Hybrid authentication plugin with native crypto and ARO workflows

provides:
  # Native layer - provides the 'auth' service
  - type: swift-plugin
    path: src/
    actions:
      - hashPassword
      - verifyPassword
      - generateToken
      - validateToken

  # ARO layer - provides feature sets
  - type: aro-files
    path: features/
```

### How ARO Loads Hybrid Plugins

When ARO encounters a hybrid plugin:

1. **Load native code first**: The native library is compiled and loaded
2. **Register native actions**: Actions become available via `<Call>`
3. **Parse ARO files**: Feature sets are compiled from `.aro` files
4. **Register feature sets**: ARO feature sets join the plugin's namespace
5. **Link dependencies**: ARO code can now call native actions

```
┌─────────────────────────────────────────────────────────────┐
│                      UnifiedPluginLoader                      │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│   1. Parse plugin.yaml                                        │
│                    │                                          │
│   ┌────────────────┴────────────────┐                        │
│   │                                 │                         │
│   ▼                                 ▼                         │
│ ┌─────────────────┐     ┌─────────────────┐                  │
│ │  Native Loader  │     │  ARO File Loader │                  │
│ │                 │     │                  │                  │
│ │ - Compile Swift │     │ - Parse .aro     │                  │
│ │ - Load .dylib   │     │ - Compile AST    │                  │
│ │ - Register fns  │     │ - Register FS    │                  │
│ └────────┬────────┘     └────────┬─────────┘                  │
│          │                       │                            │
│          └───────────┬───────────┘                            │
│                      │                                        │
│                      ▼                                        │
│          ┌─────────────────────┐                             │
│          │  Unified Plugin     │                             │
│          │                     │                             │
│          │  - auth:hashPassword│                             │
│          │  - auth:verifyPwd   │                             │
│          │  - Authenticate User│                             │
│          │  - Reset Password   │                             │
│          └─────────────────────┘                             │
│                                                               │
└─────────────────────────────────────────────────────────────┘
```

## 13.3 Building a Complete Authentication Plugin

Let's build a production-quality authentication plugin that demonstrates hybrid architecture. This plugin provides:

- **Password hashing** (native): Argon2id for secure password storage
- **Token management** (native): JWT generation and validation
- **Authentication workflows** (ARO): Login, logout, password reset
- **Session management** (ARO): Session creation, validation, refresh

### Project Structure

```
auth-plugin/
├── plugin.yaml
├── Package.swift
├── Sources/
│   └── AuthPlugin/
│       ├── AuthPlugin.swift      # Main entry point
│       ├── PasswordHasher.swift  # Argon2id implementation
│       └── TokenManager.swift    # JWT implementation
├── features/
│   ├── authentication.aro        # Login/logout workflows
│   ├── password-reset.aro        # Password reset flow
│   └── session.aro               # Session management
└── tests/
    └── auth-tests.aro
```

### The Manifest

```yaml
# plugin.yaml
name: auth-plugin
version: 1.0.0
description: Secure authentication with native crypto and ARO workflows
author: ARO Community
license: MIT

aro-version: ">=0.9.0"

provides:
  - type: swift-plugin
    path: Sources/AuthPlugin/
    actions:
      - name: hashPassword
        description: Hash a password with Argon2id
      - name: verifyPassword
        description: Verify password against hash
      - name: generateToken
        description: Generate a JWT token
      - name: validateToken
        description: Validate and decode a JWT token
      - name: generateResetToken
        description: Generate a password reset token

  - type: aro-files
    path: features/
```

### Swift Package Configuration

```swift
// Package.swift
// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "AuthPlugin",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AuthPlugin", type: .dynamic, targets: ["AuthPlugin"])
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/jwt-kit.git", from: "4.0.0"),
        .package(url: "https://github.com/tmthecoder/Argon2Swift.git", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "AuthPlugin",
            dependencies: [
                .product(name: "JWTKit", package: "jwt-kit"),
                .product(name: "Argon2Swift", package: "Argon2Swift")
            ]
        )
    ]
)
```

### Native Implementation

```swift
// Sources/AuthPlugin/AuthPlugin.swift

import Foundation

/// Plugin initialization - returns service metadata
@_cdecl("aro_plugin_info")
public func pluginInfo() -> UnsafePointer<CChar> {
    let metadata = """
    {
        "name": "auth-plugin",
        "version": "1.0.0",
        "actions": [
            {"name": "hashPassword", "symbol": "auth_hash_password"},
            {"name": "verifyPassword", "symbol": "auth_verify_password"},
            {"name": "generateToken", "symbol": "auth_generate_token"},
            {"name": "validateToken", "symbol": "auth_validate_token"},
            {"name": "generateResetToken", "symbol": "auth_generate_reset_token"}
        ]
    }
    """
    return UnsafePointer(strdup(metadata)!)
}

/// Execute an action by name
@_cdecl("aro_plugin_execute")
public func execute(
    _ actionPtr: UnsafePointer<CChar>,
    _ argsPtr: UnsafePointer<CChar>,
    _ resultPtr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32 {
    let action = String(cString: actionPtr)
    let argsJSON = String(cString: argsPtr)

    guard let argsData = argsJSON.data(using: .utf8),
          let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] else {
        return setError(resultPtr, "Invalid arguments JSON")
    }

    switch action {
    case "hashPassword":
        return hashPassword(args: args, resultPtr: resultPtr)
    case "verifyPassword":
        return verifyPassword(args: args, resultPtr: resultPtr)
    case "generateToken":
        return generateToken(args: args, resultPtr: resultPtr)
    case "validateToken":
        return validateToken(args: args, resultPtr: resultPtr)
    case "generateResetToken":
        return generateResetToken(args: args, resultPtr: resultPtr)
    default:
        return setError(resultPtr, "Unknown action: \(action)")
    }
}

@_cdecl("aro_plugin_free")
public func freeMemory(_ ptr: UnsafeMutableRawPointer?) {
    if let ptr = ptr {
        free(ptr)
    }
}

// Helper to return errors
private func setError(
    _ resultPtr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
    _ message: String
) -> Int32 {
    let errorJSON = "{\"error\": \"\(message)\"}"
    resultPtr.pointee = strdup(errorJSON)
    return 1
}

// Helper to return results
private func setResult(
    _ resultPtr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
    _ result: Any
) -> Int32 {
    guard let data = try? JSONSerialization.data(withJSONObject: result),
          let json = String(data: data, encoding: .utf8) else {
        return setError(resultPtr, "Failed to serialize result")
    }
    resultPtr.pointee = strdup(json)
    return 0
}
```

```swift
// Sources/AuthPlugin/PasswordHasher.swift

import Foundation
import Argon2Swift

/// Hash a password using Argon2id
func hashPassword(
    args: [String: Any],
    resultPtr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32 {
    guard let password = args["password"] as? String else {
        return setError(resultPtr, "Missing required argument: password")
    }

    do {
        // Generate salt
        let salt = Salt.newSalt()

        // Hash with Argon2id (recommended for password hashing)
        let result = try Argon2Swift.hashPasswordString(
            password: password,
            salt: salt,
            iterations: 3,
            memory: 65536,  // 64 MB
            parallelism: 4,
            length: 32,
            type: .id       // Argon2id
        )

        // Return hash in PHC format for storage
        let hashString = result.encodedString()

        return setResult(resultPtr, ["hash": hashString])
    } catch {
        return setError(resultPtr, "Password hashing failed: \(error)")
    }
}

/// Verify a password against a stored hash
func verifyPassword(
    args: [String: Any],
    resultPtr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32 {
    guard let password = args["password"] as? String,
          let hash = args["hash"] as? String else {
        return setError(resultPtr, "Missing required arguments: password, hash")
    }

    do {
        let valid = try Argon2Swift.verifyHashString(
            password: password,
            hash: hash,
            type: .id
        )

        return setResult(resultPtr, ["valid": valid])
    } catch {
        // Verification failure is not an error - just return false
        return setResult(resultPtr, ["valid": false])
    }
}
```

```swift
// Sources/AuthPlugin/TokenManager.swift

import Foundation
import JWTKit

// JWT payload structure
struct AuthPayload: JWTPayload {
    let sub: SubjectClaim        // User ID
    let exp: ExpirationClaim     // Expiration
    let iat: IssuedAtClaim       // Issued at
    let jti: IDClaim             // Token ID (for revocation)

    func verify(using signer: JWTSigner) throws {
        try exp.verifyNotExpired()
    }
}

// Get or create JWT signers
private var signers: JWTSigners = {
    let signers = JWTSigners()
    let secret = ProcessInfo.processInfo.environment["JWT_SECRET"] ?? "default-secret-change-me"
    signers.use(.hs256(key: secret))
    return signers
}()

/// Generate a JWT token
func generateToken(
    args: [String: Any],
    resultPtr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32 {
    guard let userId = args["userId"] as? String else {
        return setError(resultPtr, "Missing required argument: userId")
    }

    let expirationMinutes = args["expirationMinutes"] as? Int ?? 60

    let payload = AuthPayload(
        sub: SubjectClaim(value: userId),
        exp: ExpirationClaim(value: Date().addingTimeInterval(Double(expirationMinutes) * 60)),
        iat: IssuedAtClaim(value: Date()),
        jti: IDClaim(value: UUID().uuidString)
    )

    do {
        let token = try signers.sign(payload)
        return setResult(resultPtr, [
            "token": token,
            "expiresAt": ISO8601DateFormatter().string(from: payload.exp.value)
        ])
    } catch {
        return setError(resultPtr, "Token generation failed: \(error)")
    }
}

/// Validate and decode a JWT token
func validateToken(
    args: [String: Any],
    resultPtr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32 {
    guard let token = args["token"] as? String else {
        return setError(resultPtr, "Missing required argument: token")
    }

    do {
        let payload = try signers.verify(token, as: AuthPayload.self)

        return setResult(resultPtr, [
            "valid": true,
            "userId": payload.sub.value,
            "issuedAt": ISO8601DateFormatter().string(from: payload.iat.value),
            "expiresAt": ISO8601DateFormatter().string(from: payload.exp.value),
            "tokenId": payload.jti.value
        ])
    } catch let error as JWTError {
        return setResult(resultPtr, [
            "valid": false,
            "error": error.localizedDescription
        ])
    } catch {
        return setResult(resultPtr, ["valid": false, "error": "Invalid token"])
    }
}

/// Generate a password reset token (short-lived, single-use)
func generateResetToken(
    args: [String: Any],
    resultPtr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32 {
    guard let userId = args["userId"] as? String else {
        return setError(resultPtr, "Missing required argument: userId")
    }

    // Reset tokens expire in 15 minutes
    let payload = AuthPayload(
        sub: SubjectClaim(value: userId),
        exp: ExpirationClaim(value: Date().addingTimeInterval(15 * 60)),
        iat: IssuedAtClaim(value: Date()),
        jti: IDClaim(value: "reset-\(UUID().uuidString)")
    )

    do {
        let token = try signers.sign(payload)
        return setResult(resultPtr, [
            "resetToken": token,
            "expiresAt": ISO8601DateFormatter().string(from: payload.exp.value)
        ])
    } catch {
        return setError(resultPtr, "Reset token generation failed: \(error)")
    }
}
```

### ARO Feature Sets

Now the ARO layer that orchestrates these native capabilities:

```aro
(* features/authentication.aro *)
(* Authentication workflows using native crypto *)

(Login: Authentication Handler) {
    <Extract> the <email> from the <request: body email>.
    <Extract> the <password> from the <request: body password>.

    (* Look up user by email *)
    <Retrieve> the <user> from the <user-repository> where email = <email>.

    (* Verify password using native Argon2id *)
    <Call> the <verification> from the <auth: verifyPassword> with {
        password: <password>,
        hash: <user: passwordHash>
    }.
    <Extract> the <valid> from the <verification: valid>.

    <When> <valid> is false:
        (* Log failed attempt for security monitoring *)
        <Emit> a <LoginFailed: event> with {
            email: <email>,
            timestamp: <now>,
            reason: "invalid_credentials"
        }.
        <Return> a <Forbidden: status> with { error: "Invalid credentials" }.

    (* Generate JWT token *)
    <Call> the <token-result> from the <auth: generateToken> with {
        userId: <user: id>,
        expirationMinutes: 60
    }.
    <Extract> the <token> from the <token-result: token>.
    <Extract> the <expires-at> from the <token-result: expiresAt>.

    (* Create session record *)
    <Create> the <session> with {
        userId: <user: id>,
        token: <token>,
        createdAt: <now>,
        expiresAt: <expires-at>
    }.
    <Store> the <session> into the <session-repository>.

    (* Emit success event *)
    <Emit> a <LoginSucceeded: event> with {
        userId: <user: id>,
        sessionId: <session: id>
    }.

    <Return> an <OK: status> with {
        token: <token>,
        expiresAt: <expires-at>,
        user: {
            id: <user: id>,
            email: <user: email>,
            name: <user: name>
        }
    }.
}

(Logout: Authentication Handler) {
    <Extract> the <token> from the <request: headers Authorization>.
    <Transform> the <clean-token> by removing "Bearer " from <token>.

    (* Validate the token first *)
    <Call> the <validation> from the <auth: validateToken> with {
        token: <clean-token>
    }.
    <Extract> the <valid> from the <validation: valid>.

    <When> <valid> is false:
        <Return> a <Forbidden: status> with { error: "Invalid token" }.

    (* Remove session *)
    <Extract> the <token-id> from the <validation: tokenId>.
    <Delete> from the <session-repository> where tokenId = <token-id>.

    <Return> an <OK: status> with { message: "Logged out successfully" }.
}

(Validate Token: Authentication Handler) {
    <Extract> the <token> from the <request: headers Authorization>.
    <Transform> the <clean-token> by removing "Bearer " from <token>.

    <Call> the <validation> from the <auth: validateToken> with {
        token: <clean-token>
    }.

    <Extract> the <valid> from the <validation: valid>.
    <When> <valid> is false:
        <Return> a <Forbidden: status> with { error: "Invalid or expired token" }.

    <Return> an <OK: status> with <validation>.
}
```

```aro
(* features/password-reset.aro *)
(* Password reset workflow *)

(Request Password Reset: Password Reset Handler) {
    <Extract> the <email> from the <request: body email>.

    (* Find user - don't reveal if email exists *)
    <Retrieve> the <user> from the <user-repository> where email = <email>.

    <When> <user> exists:
        (* Generate reset token *)
        <Call> the <reset-result> from the <auth: generateResetToken> with {
            userId: <user: id>
        }.
        <Extract> the <reset-token> from the <reset-result: resetToken>.

        (* Store reset request *)
        <Create> the <reset-request> with {
            userId: <user: id>,
            token: <reset-token>,
            createdAt: <now>,
            used: false
        }.
        <Store> the <reset-request> into the <password-reset-repository>.

        (* Send email *)
        <Emit> a <SendPasswordResetEmail: event> with {
            email: <email>,
            resetToken: <reset-token>,
            userName: <user: name>
        }.

    (* Always return success to prevent email enumeration *)
    <Return> an <OK: status> with {
        message: "If an account exists with this email, a reset link will be sent."
    }.
}

(Complete Password Reset: Password Reset Handler) {
    <Extract> the <reset-token> from the <request: body resetToken>.
    <Extract> the <new-password> from the <request: body newPassword>.

    (* Validate reset token *)
    <Call> the <validation> from the <auth: validateToken> with {
        token: <reset-token>
    }.
    <Extract> the <valid> from the <validation: valid>.

    <When> <valid> is false:
        <Return> a <BadRequest: status> with { error: "Invalid or expired reset token" }.

    (* Check if token was already used *)
    <Extract> the <token-id> from the <validation: tokenId>.
    <Retrieve> the <reset-request> from the <password-reset-repository>
        where token = <reset-token>.

    <When> <reset-request: used> is true:
        <Return> a <BadRequest: status> with { error: "Reset token already used" }.

    (* Hash new password *)
    <Call> the <hash-result> from the <auth: hashPassword> with {
        password: <new-password>
    }.
    <Extract> the <password-hash> from the <hash-result: hash>.

    (* Update user password *)
    <Extract> the <user-id> from the <validation: userId>.
    <Update> the <user-repository> where id = <user-id> with {
        passwordHash: <password-hash>,
        updatedAt: <now>
    }.

    (* Mark reset token as used *)
    <Update> the <password-reset-repository> where token = <reset-token> with {
        used: true,
        usedAt: <now>
    }.

    (* Invalidate all existing sessions for security *)
    <Delete> from the <session-repository> where userId = <user-id>.

    <Emit> a <PasswordChanged: event> with { userId: <user-id> }.

    <Return> an <OK: status> with { message: "Password updated successfully" }.
}
```

```aro
(* features/session.aro *)
(* Session management and refresh *)

(Refresh Session: Session Handler) {
    <Extract> the <token> from the <request: body refreshToken>.

    (* Validate existing token *)
    <Call> the <validation> from the <auth: validateToken> with {
        token: <token>
    }.
    <Extract> the <valid> from the <validation: valid>.

    <When> <valid> is false:
        <Return> a <Forbidden: status> with { error: "Invalid refresh token" }.

    <Extract> the <user-id> from the <validation: userId>.
    <Extract> the <token-id> from the <validation: tokenId>.

    (* Check session exists *)
    <Retrieve> the <session> from the <session-repository>
        where tokenId = <token-id>.

    <When> <session> does not exist:
        <Return> a <Forbidden: status> with { error: "Session not found" }.

    (* Generate new token *)
    <Call> the <new-token-result> from the <auth: generateToken> with {
        userId: <user-id>,
        expirationMinutes: 60
    }.
    <Extract> the <new-token> from the <new-token-result: token>.
    <Extract> the <expires-at> from the <new-token-result: expiresAt>.

    (* Update session *)
    <Update> the <session-repository> where tokenId = <token-id> with {
        token: <new-token>,
        refreshedAt: <now>,
        expiresAt: <expires-at>
    }.

    <Return> an <OK: status> with {
        token: <new-token>,
        expiresAt: <expires-at>
    }.
}

(List Active Sessions: Session Handler) {
    (* Extract user from validated token *)
    <Extract> the <token> from the <request: headers Authorization>.
    <Transform> the <clean-token> by removing "Bearer " from <token>.

    <Call> the <validation> from the <auth: validateToken> with {
        token: <clean-token>
    }.

    <When> <validation: valid> is false:
        <Return> a <Forbidden: status> with { error: "Invalid token" }.

    <Extract> the <user-id> from the <validation: userId>.

    (* Get all sessions for user *)
    <Retrieve> the <sessions> from the <session-repository>
        where userId = <user-id>.

    (* Remove sensitive data *)
    <Transform> the <safe-sessions> from <sessions> by selecting [
        id, createdAt, expiresAt, lastActivity
    ].

    <Return> an <OK: status> with { sessions: <safe-sessions> }.
}

(Revoke Session: Session Handler) {
    <Extract> the <token> from the <request: headers Authorization>.
    <Transform> the <clean-token> by removing "Bearer " from <token>.
    <Extract> the <session-id> from the <pathParameters: sessionId>.

    (* Validate requesting user's token *)
    <Call> the <validation> from the <auth: validateToken> with {
        token: <clean-token>
    }.

    <When> <validation: valid> is false:
        <Return> a <Forbidden: status> with { error: "Invalid token" }.

    <Extract> the <user-id> from the <validation: userId>.

    (* Verify session belongs to user *)
    <Retrieve> the <session> from the <session-repository>
        where id = <session-id>.

    <When> <session: userId> is not <user-id>:
        <Return> a <Forbidden: status> with { error: "Cannot revoke another user's session" }.

    (* Delete the session *)
    <Delete> from the <session-repository> where id = <session-id>.

    <Return> an <OK: status> with { message: "Session revoked" }.
}
```

## 13.4 State Sharing Between Layers

One of the trickier aspects of hybrid plugins is sharing state between native code and ARO files. Let's explore the patterns that make this work.

### Pattern 1: Stateless Native, Stateful ARO

The simplest pattern keeps native code stateless. All state lives in ARO repositories:

```swift
// Native: pure function, no state
@_cdecl("auth_hash_password")
public func hashPassword(...) -> Int32 {
    // Pure computation - input → output
}
```

```aro
(* ARO: manages all state *)
<Store> the <session> into the <session-repository>.
<Retrieve> the <user> from the <user-repository>.
```

**Advantages**: Simple, testable, no synchronization issues
**Disadvantages**: Can't cache expensive computations in native code

### Pattern 2: Native Cache with ARO Coordination

For performance, native code might cache results. ARO coordinates cache invalidation:

```swift
// Native: maintains internal cache
private var tokenCache: [String: CachedToken] = [:]

@_cdecl("auth_validate_token")
public func validateToken(...) -> Int32 {
    // Check cache first
    if let cached = tokenCache[token], !cached.isExpired {
        return setResult(resultPtr, cached.payload)
    }
    // Validate and cache
    let payload = actuallyValidate(token)
    tokenCache[token] = CachedToken(payload)
    return setResult(resultPtr, payload)
}

@_cdecl("auth_invalidate_token")
public func invalidateToken(...) -> Int32 {
    tokenCache.removeValue(forKey: token)
    return 0
}
```

```aro
(* ARO: coordinates invalidation *)
(Logout: Authentication Handler) {
    (* ... validation ... *)
    <Call> the <_> from the <auth: invalidateToken> with { token: <token> }.
    <Delete> from the <session-repository> where tokenId = <token-id>.
    (* ... *)
}
```

### Pattern 3: Shared State via System Objects

For complex state sharing, use system objects as the synchronization point:

```aro
(* Both native and ARO read/write to Redis *)
<Write> <session> to the <redis: "session:" ++ <session-id>>.
```

Native code can also access the same Redis instance:
```swift
// Native code reads from the same Redis
let session = redisClient.get("session:\(sessionId)")
```

### Pattern 4: Context Passing

Pass context through the entire call chain:

```yaml
# plugin.yaml
provides:
  - type: swift-plugin
    context:
      - requestId    # Passed from ARO to native
      - userId       # Available in both layers
```

```aro
(* ARO: context is automatically passed *)
<Call> the <result> from the <auth: generateToken> with {
    userId: <user: id>
    (* requestId is auto-injected from context *)
}.
```

```swift
// Native: receives context
func generateToken(args: [String: Any], ...) -> Int32 {
    let requestId = args["_context_requestId"] as? String
    // Can use for logging, tracing, etc.
}
```

## 13.5 Testing Hybrid Plugins

Testing hybrid plugins requires coverage at multiple levels.

### Unit Testing Native Code

Test native functions in isolation using the language's test framework:

```swift
// Tests/AuthPluginTests/PasswordHasherTests.swift

import XCTest
@testable import AuthPlugin

final class PasswordHasherTests: XCTestCase {
    func testHashAndVerify() throws {
        var hashResultPtr: UnsafeMutablePointer<CChar>? = nil

        // Hash a password
        let status = hashPassword(
            args: ["password": "secure123"],
            resultPtr: &hashResultPtr
        )
        XCTAssertEqual(status, 0)

        let hashJSON = String(cString: hashResultPtr!)
        let hashResult = try JSONDecoder().decode(
            [String: String].self,
            from: hashJSON.data(using: .utf8)!
        )
        let hash = hashResult["hash"]!

        // Verify correct password
        var verifyResultPtr: UnsafeMutablePointer<CChar>? = nil
        let verifyStatus = verifyPassword(
            args: ["password": "secure123", "hash": hash],
            resultPtr: &verifyResultPtr
        )
        XCTAssertEqual(verifyStatus, 0)

        let verifyJSON = String(cString: verifyResultPtr!)
        XCTAssertTrue(verifyJSON.contains("\"valid\":true"))

        // Verify wrong password
        var wrongResultPtr: UnsafeMutablePointer<CChar>? = nil
        let wrongStatus = verifyPassword(
            args: ["password": "wrong", "hash": hash],
            resultPtr: &wrongResultPtr
        )
        XCTAssertEqual(wrongStatus, 0)

        let wrongJSON = String(cString: wrongResultPtr!)
        XCTAssertTrue(wrongJSON.contains("\"valid\":false"))
    }
}
```

### Integration Testing with ARO

Test the complete workflow using ARO test files:

```aro
(* tests/auth-tests.aro *)

(Application-Start: Auth Tests) {
    <Log> "Running authentication plugin tests..." to the <console>.

    (* Test 1: Password hashing *)
    <Call> the <hash-result> from the <auth: hashPassword> with {
        password: "test-password-123"
    }.
    <Extract> the <hash> from the <hash-result: hash>.
    <Validate> the <hash> is not empty.
    <Log> "Test 1 passed: password hashing" to the <console>.

    (* Test 2: Password verification - correct *)
    <Call> the <verify-result> from the <auth: verifyPassword> with {
        password: "test-password-123",
        hash: <hash>
    }.
    <Extract> the <valid> from the <verify-result: valid>.
    <Validate> the <valid> is true.
    <Log> "Test 2 passed: password verification (correct)" to the <console>.

    (* Test 3: Password verification - incorrect *)
    <Call> the <wrong-result> from the <auth: verifyPassword> with {
        password: "wrong-password",
        hash: <hash>
    }.
    <Extract> the <invalid> from the <wrong-result: valid>.
    <Validate> the <invalid> is false.
    <Log> "Test 3 passed: password verification (incorrect)" to the <console>.

    (* Test 4: Token generation *)
    <Call> the <token-result> from the <auth: generateToken> with {
        userId: "test-user-123",
        expirationMinutes: 5
    }.
    <Extract> the <token> from the <token-result: token>.
    <Validate> the <token> is not empty.
    <Log> "Test 4 passed: token generation" to the <console>.

    (* Test 5: Token validation *)
    <Call> the <validation> from the <auth: validateToken> with {
        token: <token>
    }.
    <Extract> the <token-valid> from the <validation: valid>.
    <Validate> the <token-valid> is true.
    <Extract> the <returned-user-id> from the <validation: userId>.
    <Validate> the <returned-user-id> equals "test-user-123".
    <Log> "Test 5 passed: token validation" to the <console>.

    <Log> "All authentication tests passed!" to the <console>.
    <Return> an <OK: status> for the <tests>.
}
```

### End-to-End Testing

Test the full authentication flow:

```aro
(* tests/e2e-auth-tests.aro *)

(Application-Start: E2E Auth Tests) {
    <Log> "Running end-to-end authentication tests..." to the <console>.

    (* Setup: Create test user *)
    <Call> the <hash-result> from the <auth: hashPassword> with {
        password: "e2e-test-password"
    }.
    <Create> the <test-user> with {
        id: "e2e-test-user",
        email: "e2e@test.com",
        name: "E2E Test User",
        passwordHash: <hash-result: hash>
    }.
    <Store> the <test-user> into the <user-repository>.

    (* Test: Full login flow *)
    <Create> the <login-request> with {
        body: {
            email: "e2e@test.com",
            password: "e2e-test-password"
        }
    }.
    (* Trigger login handler *)
    <Emit> a <Login: event> with <login-request>.

    (* Verify session was created *)
    <Retrieve> the <sessions> from the <session-repository>
        where userId = "e2e-test-user".
    <Validate> the <sessions> is not empty.
    <Log> "E2E Test: Login flow passed" to the <console>.

    (* Cleanup *)
    <Delete> from the <user-repository> where id = "e2e-test-user".
    <Delete> from the <session-repository> where userId = "e2e-test-user".

    <Log> "All E2E tests passed!" to the <console>.
    <Return> an <OK: status> for the <tests>.
}
```

## 13.6 Best Practices for Hybrid Plugins

### Clear Separation of Concerns

Define boundaries clearly:

| Layer | Responsibility |
|-------|---------------|
| Native | Security-critical operations, performance-sensitive code, system integration |
| ARO | Business logic, workflow orchestration, data transformation, error handling |

### Consistent Error Handling

Errors should flow smoothly between layers:

```swift
// Native: return structured errors
return setError(resultPtr, "{\"code\": \"INVALID_TOKEN\", \"message\": \"Token has expired\"}")
```

```aro
(* ARO: handle structured errors *)
<Call> the <result> from the <auth: validateToken> with { token: <token> }.
<When> <result: error> exists:
    <Log> "Auth error: " ++ <result: error message> to the <console>.
    <Return> a <Forbidden: status> with <result: error>.
```

### Versioning Strategy

When native and ARO components evolve independently:

```yaml
# plugin.yaml
name: auth-plugin
version: 2.1.0  # Plugin version

provides:
  - type: swift-plugin
    version: 2.0.0  # Native component version
    path: Sources/

  - type: aro-files
    version: 2.1.0  # ARO component version (can differ)
    path: features/
```

### Documentation

Document the interface between layers:

```yaml
# plugin.yaml
provides:
  - type: swift-plugin
    actions:
      - name: hashPassword
        description: Hash a password with Argon2id
        arguments:
          - name: password
            type: string
            required: true
            description: The password to hash
        returns:
          hash: string  # PHC-formatted hash string
```

## Summary

Hybrid plugins combine the best of both worlds: native performance and security with ARO's expressiveness and maintainability. The key insights from this chapter:

- **Clear boundaries**: Native code for crypto and performance; ARO for workflows
- **State management**: Choose the right pattern for your needs
- **Testing at all levels**: Unit tests for native, integration tests for ARO, E2E for workflows
- **Consistent interfaces**: Structured JSON communication between layers

Hybrid architecture works particularly well for:
- **Authentication systems**: Native crypto + ARO workflows
- **Payment processing**: Native encryption + ARO business rules
- **Data pipelines**: Native parsing + ARO transformation logic
- **ML inference**: Native model execution + ARO orchestration

In the next chapter, we'll explore testing strategies in depth—ensuring your plugins work correctly across all scenarios and environments.
