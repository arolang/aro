# ARO: The Plugin Developer's Guide

## Structure

This book provides a comprehensive guide to extending ARO through plugins written in multiple programming languages.

### Part I: Understanding Plugins

| Chapter | Title | Description |
|---------|-------|-------------|
| Foreword | | Early stage disclaimer, ecosystem vision |
| 01 | The Plugin Philosophy | Why plugins? When to use them? |
| 02 | Plugin Architecture | C ABI, JSON communication, memory |
| 03 | Using Plugins in ARO | Installation, Call action, extraction |
| 04 | The plugin.yaml Manifest | Complete reference |
| 05 | Providing Custom Actions | Actions vs services, custom verbs |

### Part II: Writing Plugins by Language

| Chapter | Title | Description |
|---------|-------|-------------|
| 06 | Swift Plugins | Foundation types, @_cdecl, formatting |
| 07 | Rust Plugins | Performance, Cargo, FFI |
| 08 | C Plugins | Direct ABI, cryptography, system utils |
| 09 | C++ Plugins | extern "C", audio, math |
| 10 | Python Plugins | LLM inference, transformers |

### Part III: Advanced Topics

| Chapter | Title | Description |
|---------|-------|-------------|
| 11 | Plugins with Dependencies | SPM, Cargo, system libraries |
| 12 | The FFmpeg Plugin | Complete video processing example |
| 13 | System Objects Plugins | Redis, Elasticsearch custom objects |
| 14 | Hybrid Plugins | Pure ARO plugins, native code + ARO files |
| 15 | Testing Plugins | Unit and integration testing |
| 16 | Publishing Plugins | Git structure, versioning, community |

### Appendices

| Appendix | Title | Description |
|----------|-------|-------------|
| A | plugin.yaml Reference | Complete schema |
| B | C ABI Function Signatures | All required functions |
| C | Error Codes and Handling | Standard error format |

## Building

```bash
./build-pdf.sh
```

Output files will be in `output/`:
- `ARO-Plugin-Guide.pdf` - Print-ready PDF
- `ARO-Plugin-Guide.html` - Web version
