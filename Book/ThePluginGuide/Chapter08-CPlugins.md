# Chapter 8: C Plugins

*"C is the assembly language of the portable world."*

---

C is the lingua franca of systems programming. Every operating system, every language runtime, every major library speaks C. When you write a C plugin, you're writing at the level ARO's plugin system was designed for—no bridges, no wrappers, just direct communication.

## 8.1 Why C?

C plugins have unique advantages:

**Minimal Overhead**: C compiles to native code with no runtime. Your plugin is just machine code—no garbage collector, no virtual machine, no interpreter.

**Universal Compatibility**: C's ABI is the standard that all other languages target. Swift, Rust, Go—they all generate code compatible with C calling conventions.

**Direct Library Access**: Vast libraries exist in C. OpenSSL, SQLite, FFmpeg, libcurl—you can wrap any C library directly.

**Maximum Control**: You decide exactly how memory is allocated, when it's freed, and how data is structured.

The trade-off is responsibility. C gives you enough rope to hang yourself. Memory management, buffer overflows, null pointer dereferences—these are your problems now.

## 8.2 Project Structure

A C plugin is refreshingly simple:

```
Plugins/
└── plugin-c-hash/
    ├── plugin.yaml
    └── src/
        └── hash_plugin.c
```

No package manager, no build system configuration (beyond what's in `plugin.yaml`). Just source files.

### plugin.yaml

```yaml
name: plugin-c-hash
version: 1.0.0
description: "A C plugin for computing hash functions"
author: "ARO Team"
license: MIT
aro-version: ">=0.1.0"

provides:
  - type: c-plugin
    path: src/
    build:
      compiler: clang
      flags:
        - -O2
        - -fPIC
        - -shared
      output: libhash_plugin.dylib
```

Key build flags:

| Flag | Purpose |
|------|---------|
| `-O2` | Optimization level 2 (good balance of speed and size) |
| `-fPIC` | Position-independent code (required for shared libraries) |
| `-shared` | Build as a shared library |

## 8.3 The Plugin Interface

Every C plugin exports three functions:

### aro_plugin_info

Returns metadata about the plugin:

```c
char* aro_plugin_info(void);
```

Returns a JSON string describing the plugin. The caller is responsible for freeing the returned pointer using `aro_plugin_free`.

### aro_plugin_execute

Executes a plugin action:

```c
char* aro_plugin_execute(const char* action, const char* input_json);
```

- `action`: The method name to execute
- `input_json`: JSON string with input arguments
- Returns: JSON string with the result (caller frees)

### aro_plugin_free

Frees memory allocated by the plugin:

```c
void aro_plugin_free(char* ptr);
```

This is essential for proper memory management. ARO calls this function to free any strings returned by `aro_plugin_info` or `aro_plugin_execute`.

## 8.4 Your First C Plugin: Custom Actions

Let's build a hash function plugin that implements DJB2, FNV-1a, and a simple hash.

### Complete Implementation

```c
/**
 * ARO Plugin - C Hash Functions
 *
 * Provides various non-cryptographic hash functions.
 * Implements the ARO native plugin interface (C ABI).
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* ============================================================
 * JSON Parsing Helpers
 * ============================================================
 * Production plugins should use a proper JSON library like cJSON.
 * These helpers are for demonstration purposes.
 */

/**
 * Find a string value in JSON by key.
 * Returns pointer to the string content (after opening quote).
 */
static const char* find_json_string(const char* json, const char* key) {
    char search[256];
    snprintf(search, sizeof(search), "\"%s\":", key);

    const char* pos = strstr(json, search);
    if (!pos) return NULL;

    pos = strchr(pos, ':');
    if (!pos) return NULL;
    pos++;

    /* Skip whitespace */
    while (*pos == ' ' || *pos == '\t' || *pos == '\n') pos++;

    if (*pos != '"') return NULL;
    return pos + 1;
}

/**
 * Extract a string value from JSON.
 * Caller must free the returned string.
 */
static char* extract_json_string(const char* json, const char* key) {
    const char* start = find_json_string(json, key);
    if (!start) return NULL;

    const char* end = strchr(start, '"');
    if (!end) return NULL;

    size_t len = end - start;
    char* result = malloc(len + 1);
    if (!result) return NULL;

    memcpy(result, start, len);
    result[len] = '\0';
    return result;
}

/* ============================================================
 * Hash Algorithms
 * ============================================================ */

/**
 * DJB2 hash algorithm by Daniel J. Bernstein.
 * Fast, good distribution, widely used.
 */
static uint64_t djb2_hash(const char* str) {
    uint64_t hash = 5381;
    int c;

    while ((c = *str++)) {
        hash = ((hash << 5) + hash) + c;  /* hash * 33 + c */
    }

    return hash;
}

/**
 * FNV-1a (Fowler-Noll-Vo) hash algorithm.
 * Excellent distribution, slightly slower than DJB2.
 */
static uint64_t fnv1a_hash(const char* str) {
    uint64_t hash = 14695981039346656037ULL;
    const uint64_t fnv_prime = 1099511628211ULL;

    while (*str) {
        hash ^= (uint8_t)*str++;
        hash *= fnv_prime;
    }

    return hash;
}

/**
 * Simple multiplicative hash.
 * Fast, produces 32-bit output.
 */
static uint32_t simple_hash(const char* str) {
    uint32_t hash = 0;

    while (*str) {
        hash = hash * 31 + *str++;
    }

    return hash;
}

/* ============================================================
 * Plugin Interface
 * ============================================================ */

/**
 * Return plugin metadata as JSON with custom action definitions.
 *
 * This function is called once when the plugin is loaded.
 * The returned string must be freed by the caller using aro_plugin_free.
 */
char* aro_plugin_info(void) {
    /* Define custom actions with verbs for native ARO syntax */
    const char* info =
        "{"
        "\"name\":\"plugin-c-hash\","
        "\"version\":\"1.0.0\","
        "\"actions\":["
        "  {\"name\":\"Hash\",\"role\":\"own\",\"verbs\":[\"hash\",\"digest\"],\"prepositions\":[\"from\",\"with\"]},"
        "  {\"name\":\"DJB2\",\"role\":\"own\",\"verbs\":[\"djb2\"],\"prepositions\":[\"from\"]},"
        "  {\"name\":\"FNV1a\",\"role\":\"own\",\"verbs\":[\"fnv1a\",\"fnv\"],\"prepositions\":[\"from\"]}"
        "]"
        "}";

    char* result = malloc(strlen(info) + 1);
    if (result) {
        strcpy(result, info);
    }
    return result;
}

/**
 * Execute a plugin action.
 *
 * @param action     The action name (e.g., "djb2", "fnv1a")
 * @param input_json JSON string containing the input arguments
 * @return           JSON string with the result (caller must free)
 */
char* aro_plugin_execute(const char* action, const char* input_json) {
    /* Allocate result buffer */
    char* result = malloc(512);
    if (!result) return NULL;

    /* Extract input data */
    char* data = extract_json_string(input_json, "data");
    if (!data) {
        snprintf(result, 512, "{\"error\":\"Missing 'data' field\"}");
        return result;
    }

    /* Dispatch to appropriate hash function */
    if (strcmp(action, "hash") == 0 || strcmp(action, "simple") == 0) {
        uint32_t hash = simple_hash(data);
        snprintf(result, 512,
                 "{\"hash\":\"%08x\",\"algorithm\":\"simple\",\"input\":\"%s\"}",
                 hash, data);
    }
    else if (strcmp(action, "djb2") == 0) {
        uint64_t hash = djb2_hash(data);
        snprintf(result, 512,
                 "{\"hash\":\"%016llx\",\"algorithm\":\"djb2\",\"input\":\"%s\"}",
                 (unsigned long long)hash, data);
    }
    else if (strcmp(action, "fnv1a") == 0) {
        uint64_t hash = fnv1a_hash(data);
        snprintf(result, 512,
                 "{\"hash\":\"%016llx\",\"algorithm\":\"fnv1a\",\"input\":\"%s\"}",
                 (unsigned long long)hash, data);
    }
    else {
        snprintf(result, 512, "{\"error\":\"Unknown action: %s\"}", action);
    }

    free(data);
    return result;
}

/**
 * Free memory allocated by the plugin.
 *
 * @param ptr Pointer to memory allocated by aro_plugin_info or aro_plugin_execute
 */
void aro_plugin_free(char* ptr) {
    if (ptr) {
        free(ptr);
    }
}
```

### Compilation

ARO compiles the plugin automatically based on `plugin.yaml`, but you can also compile manually:

```bash
# macOS
clang -O2 -fPIC -shared -o libhash_plugin.dylib src/hash_plugin.c

# Linux
gcc -O2 -fPIC -shared -o libhash_plugin.so src/hash_plugin.c

# Windows (with MinGW)
gcc -O2 -shared -o hash_plugin.dll src/hash_plugin.c
```

### Usage in ARO

With custom actions registered, use native ARO syntax:

```aro
(Hash Demo: Application-Start) {
    Create the <message> with "Hello, World!".

    (* Use custom Hash action - feels native! *)
    Hash the <hash-result> from <message>.
    Log "Hash: " with <hash-result: hash> to the <console>.

    (* DJB2 custom action *)
    <DJB2> the <djb2-result> from <message>.
    Log "DJB2: " with <djb2-result: hash> to the <console>.

    (* FNV-1a custom action *)
    <FNV1a> the <fnv-result> from <message>.
    Log "FNV-1a: " with <fnv-result: hash> to the <console>.

    Return an <OK: status> for the <startup>.
}
```

Output:
```
Hash: a8b37ed3
DJB2: 0d4a1185f5b6f969
FNV-1a: 6c155799fdc8eec4
```

The `<Hash>`, `<DJB2>`, and `<FNV1a>` actions integrate seamlessly with ARO's syntax!

## 8.5 Linking System Libraries

C plugins can link against system libraries. Here's an example using OpenSSL for cryptographic hashing:

### plugin.yaml with Dependencies

```yaml
name: plugin-c-crypto
version: 1.0.0
description: "Cryptographic hash functions using OpenSSL"
aro-version: ">=0.1.0"

provides:
  - type: c-plugin
    path: src/
    build:
      compiler: clang
      flags:
        - -O2
        - -fPIC
        - -shared
        - -I/opt/homebrew/include      # macOS Homebrew
        - -I/usr/local/include         # Linux
      link:
        - -L/opt/homebrew/lib
        - -L/usr/local/lib
        - -lssl
        - -lcrypto
      output: libcrypto_plugin.dylib
```

### Implementation with OpenSSL

```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <openssl/sha.h>
#include <openssl/md5.h>
#include <openssl/evp.h>

/* Helper to convert bytes to hex string */
static void bytes_to_hex(const unsigned char* bytes, size_t len, char* hex) {
    for (size_t i = 0; i < len; i++) {
        sprintf(hex + (i * 2), "%02x", bytes[i]);
    }
    hex[len * 2] = '\0';
}

char* aro_plugin_info(void) {
    const char* info =
        "{"
        "\"name\":\"plugin-c-crypto\","
        "\"version\":\"1.0.0\","
        "\"language\":\"c\","
        "\"actions\":[\"sha256\",\"sha512\",\"md5\"]"
        "}";

    return strdup(info);
}

char* aro_plugin_execute(const char* action, const char* input_json) {
    char* result = malloc(1024);
    if (!result) return NULL;

    /* Extract data field */
    char* data = extract_json_string(input_json, "data");
    if (!data) {
        snprintf(result, 1024, "{\"error\":\"Missing 'data' field\"}");
        return result;
    }

    size_t data_len = strlen(data);

    if (strcmp(action, "sha256") == 0) {
        unsigned char hash[SHA256_DIGEST_LENGTH];
        char hex[SHA256_DIGEST_LENGTH * 2 + 1];

        SHA256((unsigned char*)data, data_len, hash);
        bytes_to_hex(hash, SHA256_DIGEST_LENGTH, hex);

        snprintf(result, 1024,
                 "{\"hash\":\"%s\",\"algorithm\":\"sha256\",\"length\":32}",
                 hex);
    }
    else if (strcmp(action, "sha512") == 0) {
        unsigned char hash[SHA512_DIGEST_LENGTH];
        char hex[SHA512_DIGEST_LENGTH * 2 + 1];

        SHA512((unsigned char*)data, data_len, hash);
        bytes_to_hex(hash, SHA512_DIGEST_LENGTH, hex);

        snprintf(result, 1024,
                 "{\"hash\":\"%s\",\"algorithm\":\"sha512\",\"length\":64}",
                 hex);
    }
    else if (strcmp(action, "md5") == 0) {
        unsigned char hash[MD5_DIGEST_LENGTH];
        char hex[MD5_DIGEST_LENGTH * 2 + 1];

        MD5((unsigned char*)data, data_len, hash);
        bytes_to_hex(hash, MD5_DIGEST_LENGTH, hex);

        snprintf(result, 1024,
                 "{\"hash\":\"%s\",\"algorithm\":\"md5\",\"length\":16}",
                 hex);
    }
    else {
        snprintf(result, 1024, "{\"error\":\"Unknown action: %s\"}", action);
    }

    free(data);
    return result;
}

void aro_plugin_free(char* ptr) {
    free(ptr);
}
```

## 8.6 Proper JSON Handling with cJSON

For production plugins, use a real JSON library. cJSON is lightweight and easy to use:

### Adding cJSON

Download cJSON (it's a single header and source file) or include it as a submodule:

```
Plugins/
└── plugin-c-system/
    ├── plugin.yaml
    └── src/
        ├── cJSON.h
        ├── cJSON.c
        └── system_plugin.c
```

### Using cJSON

```c
#include "cJSON.h"
#include <stdlib.h>
#include <string.h>

char* aro_plugin_execute(const char* action, const char* input_json) {
    /* Parse input JSON */
    cJSON* input = cJSON_Parse(input_json);
    if (!input) {
        return strdup("{\"error\":\"Invalid JSON\"}");
    }

    /* Extract fields */
    cJSON* data_field = cJSON_GetObjectItem(input, "data");
    if (!data_field || !cJSON_IsString(data_field)) {
        cJSON_Delete(input);
        return strdup("{\"error\":\"Missing 'data' field\"}");
    }

    const char* data = data_field->valuestring;

    /* Build result */
    cJSON* result = cJSON_CreateObject();
    cJSON_AddStringToObject(result, "input", data);
    cJSON_AddStringToObject(result, "action", action);

    /* Process based on action... */
    if (strcmp(action, "uppercase") == 0) {
        char* upper = strdup(data);
        for (char* p = upper; *p; p++) {
            if (*p >= 'a' && *p <= 'z') *p -= 32;
        }
        cJSON_AddStringToObject(result, "output", upper);
        free(upper);
    }

    /* Convert to string */
    char* result_str = cJSON_PrintUnformatted(result);

    /* Cleanup */
    cJSON_Delete(input);
    cJSON_Delete(result);

    return result_str;
}
```

## 8.7 System Utilities Plugin

Here's a practical example—a plugin that provides system information:

```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/utsname.h>
#include <sys/stat.h>
#include <time.h>
#include <errno.h>

char* aro_plugin_info(void) {
    return strdup(
        "{"
        "\"name\":\"plugin-c-system\","
        "\"version\":\"1.0.0\","
        "\"language\":\"c\","
        "\"actions\":[\"uname\",\"stat\",\"time\",\"env\"]"
        "}"
    );
}

char* aro_plugin_execute(const char* action, const char* input_json) {
    char* result = malloc(4096);
    if (!result) return NULL;

    if (strcmp(action, "uname") == 0) {
        struct utsname info;
        if (uname(&info) == 0) {
            snprintf(result, 4096,
                     "{"
                     "\"system\":\"%s\","
                     "\"node\":\"%s\","
                     "\"release\":\"%s\","
                     "\"version\":\"%s\","
                     "\"machine\":\"%s\""
                     "}",
                     info.sysname, info.nodename, info.release,
                     info.version, info.machine);
        } else {
            snprintf(result, 4096, "{\"error\":\"uname failed\"}");
        }
    }
    else if (strcmp(action, "stat") == 0) {
        char* path = extract_json_string(input_json, "path");
        if (!path) {
            snprintf(result, 4096, "{\"error\":\"Missing 'path' field\"}");
            return result;
        }

        struct stat st;
        if (stat(path, &st) == 0) {
            snprintf(result, 4096,
                     "{"
                     "\"path\":\"%s\","
                     "\"size\":%lld,"
                     "\"mode\":%o,"
                     "\"is_directory\":%s,"
                     "\"is_file\":%s,"
                     "\"modified\":%ld"
                     "}",
                     path,
                     (long long)st.st_size,
                     st.st_mode & 0777,
                     S_ISDIR(st.st_mode) ? "true" : "false",
                     S_ISREG(st.st_mode) ? "true" : "false",
                     (long)st.st_mtime);
        } else {
            snprintf(result, 4096,
                     "{\"error\":\"stat failed: %s\",\"path\":\"%s\"}",
                     strerror(errno), path);
        }
        free(path);
    }
    else if (strcmp(action, "time") == 0) {
        time_t now = time(NULL);
        struct tm* tm_info = gmtime(&now);
        char iso8601[64];
        strftime(iso8601, sizeof(iso8601), "%Y-%m-%dT%H:%M:%SZ", tm_info);

        snprintf(result, 4096,
                 "{"
                 "\"timestamp\":%ld,"
                 "\"iso8601\":\"%s\""
                 "}",
                 (long)now, iso8601);
    }
    else if (strcmp(action, "env") == 0) {
        char* name = extract_json_string(input_json, "name");
        if (!name) {
            snprintf(result, 4096, "{\"error\":\"Missing 'name' field\"}");
            return result;
        }

        const char* value = getenv(name);
        if (value) {
            snprintf(result, 4096,
                     "{\"name\":\"%s\",\"value\":\"%s\",\"exists\":true}",
                     name, value);
        } else {
            snprintf(result, 4096,
                     "{\"name\":\"%s\",\"value\":null,\"exists\":false}",
                     name);
        }
        free(name);
    }
    else {
        snprintf(result, 4096, "{\"error\":\"Unknown action: %s\"}", action);
    }

    return result;
}

void aro_plugin_free(char* ptr) {
    free(ptr);
}
```

Usage (with custom actions `<SystemInfo>`, `<FileStat>`, `<GetEnv>`):

```aro
(System Info: Application-Start) {
    (* Get system information using custom action *)
    <SystemInfo> the <system> from the <uname>.
    Log "Running on: " with <system: system> to the <console>.
    Log "Machine: " with <system: machine> to the <console>.

    (* Check file stats using custom action *)
    <FileStat> the <stats> from "/etc/hosts".
    Log "File size: " with <stats: size> to the <console>.

    (* Get environment variable using custom action *)
    <GetEnv> the <home> from "HOME".
    Log "Home directory: " with <home: value> to the <console>.

    Return an <OK: status> for the <startup>.
}
```

Custom actions make system utilities feel native to ARO!

## 8.8 Memory Management

Memory management in C plugins follows a simple rule: **the allocator frees**.

### Plugin-Allocated Memory

When your plugin allocates memory:

```c
char* aro_plugin_execute(...) {
    char* result = malloc(1024);  /* Plugin allocates */
    // ...
    return result;  /* Returned to ARO */
}

void aro_plugin_free(char* ptr) {
    free(ptr);  /* Plugin frees */
}
```

ARO will call `aro_plugin_free` when it's done with the result.

### ARO-Provided Memory

The `action` and `input_json` parameters are owned by ARO:

```c
char* aro_plugin_execute(const char* action, const char* input_json) {
    /* DON'T free action or input_json - ARO owns them */
    /* DON'T store pointers to them beyond this function call */

    /* DO copy data if you need to keep it */
    char* my_copy = strdup(action);
    // ...
    free(my_copy);  /* Free your copy when done */
}
```

### Common Mistakes

```c
/* WRONG: Returning pointer to stack memory */
char* aro_plugin_execute(...) {
    char result[512];  /* Stack-allocated */
    snprintf(result, sizeof(result), "...");
    return result;  /* UNDEFINED BEHAVIOR: stack memory will be invalid */
}

/* WRONG: Returning string literal (not freeable) */
char* aro_plugin_execute(...) {
    return "{\"result\":\"ok\"}";  /* free() will crash */
}

/* CORRECT: Allocate with malloc, return heap pointer */
char* aro_plugin_execute(...) {
    return strdup("{\"result\":\"ok\"}");  /* strdup uses malloc */
}
```

## 8.9 Thread Safety

ARO may call your plugin from multiple threads simultaneously. Make your plugin thread-safe:

### Stateless Functions

The simplest approach—no shared state:

```c
/* Thread-safe: no shared state */
char* aro_plugin_execute(const char* action, const char* input_json) {
    char* result = malloc(512);  /* Each call gets its own buffer */
    // Process...
    return result;
}
```

### Thread-Local Storage

For state that should be per-thread:

```c
#include <pthread.h>

static pthread_key_t buffer_key;
static pthread_once_t key_once = PTHREAD_ONCE_INIT;

static void create_key(void) {
    pthread_key_create(&buffer_key, free);
}

static char* get_thread_buffer(void) {
    pthread_once(&key_once, create_key);
    char* buffer = pthread_getspecific(buffer_key);
    if (!buffer) {
        buffer = malloc(4096);
        pthread_setspecific(buffer_key, buffer);
    }
    return buffer;
}
```

### Mutex Protection

For shared state:

```c
#include <pthread.h>

static pthread_mutex_t counter_mutex = PTHREAD_MUTEX_INITIALIZER;
static int call_counter = 0;

char* aro_plugin_execute(const char* action, const char* input_json) {
    pthread_mutex_lock(&counter_mutex);
    call_counter++;
    int count = call_counter;
    pthread_mutex_unlock(&counter_mutex);

    char* result = malloc(256);
    snprintf(result, 256, "{\"call_number\":%d}", count);
    return result;
}
```

## 8.10 Error Handling

C doesn't have exceptions. Use return values and error messages:

```c
/* Error result helper */
static char* error_result(const char* message) {
    char* result = malloc(512);
    if (result) {
        snprintf(result, 512, "{\"error\":\"%s\"}", message);
    }
    return result;
}

char* aro_plugin_execute(const char* action, const char* input_json) {
    if (!action) {
        return error_result("Null action");
    }

    if (!input_json) {
        return error_result("Null input");
    }

    char* data = extract_json_string(input_json, "data");
    if (!data) {
        return error_result("Missing required field: data");
    }

    /* Process... */
    if (processing_failed) {
        free(data);
        return error_result("Processing failed");
    }

    /* Success */
    char* result = malloc(1024);
    snprintf(result, 1024, "{\"success\":true}");
    free(data);
    return result;
}
```

## 8.11 Best Practices

### Use Defensive Programming

```c
char* aro_plugin_execute(const char* action, const char* input_json) {
    /* Check all inputs */
    if (!action || !input_json) {
        return strdup("{\"error\":\"Null input\"}");
    }

    /* Allocate with checks */
    char* result = malloc(1024);
    if (!result) {
        return NULL;  /* Out of memory */
    }

    /* Use safe string functions */
    snprintf(result, 1024, "...");  /* Not sprintf */

    return result;
}
```

### Keep It Simple

```c
/* GOOD: Simple, focused functions */
static uint64_t compute_hash(const char* str) {
    uint64_t hash = 5381;
    while (*str) hash = hash * 33 + *str++;
    return hash;
}

/* AVOID: Complex functions that do too much */
```

### Document Memory Contracts

```c
/**
 * Execute a plugin action.
 *
 * @param action     Action name (owned by caller, must not be modified)
 * @param input_json JSON input (owned by caller, must not be modified)
 * @return           JSON result (caller must free using aro_plugin_free)
 *                   Returns NULL on allocation failure
 */
char* aro_plugin_execute(const char* action, const char* input_json);
```

## 8.12 Summary

C plugins are the most direct way to extend ARO:

- **Interface**: Three functions—`aro_plugin_info`, `aro_plugin_execute`, `aro_plugin_free`
- **Memory**: Plugin allocates, plugin frees (via `aro_plugin_free`)
- **JSON**: Use cJSON or similar for robust parsing
- **Thread Safety**: Make plugins stateless or use proper synchronization
- **Libraries**: Link against any C library (OpenSSL, SQLite, etc.)

The simplicity of C's interface is both its strength and its challenge. You have complete control—and complete responsibility.

Next, we'll see how C++ builds on this foundation with object-oriented capabilities.

