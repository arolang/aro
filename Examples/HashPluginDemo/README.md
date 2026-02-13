# Hash Plugin Demo

This example demonstrates how to install and use a C FFI plugin for computing hash values.

## Plugin Used

- **plugin-c-hash**: A C plugin providing various hash functions
  - Repository: https://github.com/arolang/plugin-c-hash

## Actions Provided

| Action | Description | Output |
|--------|-------------|--------|
| `hash` | Simple 32-bit hash | 8-character hex string |
| `djb2` | DJB2 64-bit hash | 16-character hex string |
| `fnv1a` | FNV-1a 64-bit hash | 16-character hex string |

## Installation

Install the plugin using the ARO package manager:

```bash
cd Examples/HashPluginDemo
aro add https://github.com/arolang/plugin-c-hash.git
```

## Requirements

- Clang compiler (for building the plugin)

## Expected Output

```
=== Hash Plugin Demo ===

1. Simple hash algorithm:
   Input: Hello, ARO!
   Hash:  a1b2c3d4

2. DJB2 hash algorithm:
   Hash:  0123456789abcdef

3. FNV-1a hash algorithm:
   Hash:  fedcba9876543210

4. Hash comparison for different inputs:
   apple  -> 0b87d13b4f7c3e21
   banana -> 1a2b3c4d5e6f7890
   cherry -> 9876543210fedcba

Hash plugin demo completed!
```

## Use Cases

- Password hashing (for demonstration, not production security)
- Data integrity checks
- Hash table implementations
- Content fingerprinting
