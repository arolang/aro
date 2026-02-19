# ARO-0035: Configurable Runtime Settings

* Proposal: ARO-0035
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0004

## Abstract

This proposal defines the Configure action for setting runtime configuration values. Configure enables applications to set timeouts, service parameters, and other runtime settings in a declarative way.

## Motivation

Applications need to configure runtime behavior—timeouts, connection limits, retry counts. Without a standardized approach, configuration becomes scattered and inconsistent.

The Configure action provides a declarative way to set configuration values that can be retrieved by other feature sets.

---

## 1. Configure Action

### 1.1 Syntax

```aro
Configure the <setting: qualifier> with <value>.
```

Where:
- `setting` is the configuration category
- `qualifier` is the specific setting name
- `value` is the configuration value

### 1.2 Examples

```aro
(* Set a timeout value *)
Configure the <validation: timeout> with 10.

(* Set HTTP client configuration *)
Configure the <http-client: timeout> with 5000.
Configure the <http-client: retries> with 3.

(* Set custom application settings *)
Configure the <batch: size> with 100.
```

---

## 2. Retrieving Configuration

Configuration values are retrieved using Extract:

```aro
Extract the <timeout> from the <validation: timeout>.
Extract the <batch-size> from the <batch: size>.
```

---

## 3. Configuration Scope

### 3.1 Application Scope

Configuration values are scoped to the application lifetime:

```aro
(Application-Start: My App) {
    (* Set configuration at startup *)
    Configure the <validation: timeout> with 10.
    Return an <OK: status> for the <startup>.
}

(Process Request: Request Handler) {
    (* Configuration available in all feature sets *)
    Extract the <timeout> from the <validation: timeout>.
    Log <timeout> to the <console>.
    Return an <OK: status>.
}
```

### 3.2 Default Values

If a configuration value is not set, Extract returns `nil`. Feature sets should handle missing configuration:

```aro
Extract the <timeout> from the <validation: timeout>.
Create the <effective-timeout> with 5 when <timeout> = nil.
Create the <effective-timeout> with <timeout> when <timeout> != nil.
```

---

## 4. Common Configuration Categories

| Category | Settings | Description |
|----------|----------|-------------|
| `validation` | `timeout` | Validation timeout in seconds |
| `http-client` | `timeout`, `retries` | HTTP client settings |
| `http-server` | `port`, `host` | HTTP server settings |
| `batch` | `size`, `concurrency` | Batch processing settings |

---

## 5. Use Cases

### 5.1 IDE Plugin Timeout

Configure validation timeout for IDE plugin binary path validation:

```aro
(Application-Start: IDE Support) {
    Create the <validation-timeout> with 10.
    Configure the <validation: timeout> with <validation-timeout>.
    Return an <OK: status> for the <startup>.
}
```

### 5.2 HTTP Client Timeout

Configure HTTP client for slow external APIs:

```aro
(Application-Start: External Service) {
    Configure the <http-client: timeout> with 30000.
    Configure the <http-client: retries> with 5.
    Return an <OK: status> for the <startup>.
}
```

### 5.3 Batch Processing

Configure batch sizes for data processing:

```aro
(Application-Start: Data Processor) {
    Configure the <batch: size> with 1000.
    Configure the <batch: concurrency> with 4.
    Return an <OK: status> for the <startup>.
}
```

---

## 6. Implementation

### 6.1 Action Definition

```swift
public struct ConfigureAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["configure", "set"]
    public static let validPrepositions: Set<Preposition> = [.with]
}
```

### 6.2 Configuration Storage

Configuration values are stored in a global configuration registry accessible to all feature sets within the application.

---

## Grammar Extension

```ebnf
configure_statement = "<Configure>" , "the" , "<" , config_target , ">" ,
                      "with" , ( variable | literal ) , "." ;

config_target = category , ":" , setting ;
category = identifier ;
setting = identifier ;
```

---

## Summary

| Aspect | Description |
|--------|-------------|
| **Action** | `<Configure>` |
| **Syntax** | `Configure the <category: setting> with <value>.` |
| **Scope** | Application lifetime |
| **Retrieval** | `Extract the <var> from the <category: setting>.` |

The Configure action provides a standardized way to set and retrieve runtime configuration values.

---

## References

- `Examples/ConfigurableTimeout/` - Timeout configuration example
- ARO-0004: Actions - Action implementation pattern
