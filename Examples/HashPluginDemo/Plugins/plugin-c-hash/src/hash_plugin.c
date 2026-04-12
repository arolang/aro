/**
 * ARO Plugin - C Hash Functions (ARO-0073 ABI)
 *
 * This plugin provides various hash functions for ARO.
 * It implements the ARO-0073 native plugin interface (C ABI).
 *
 * ABI summary:
 *   char* aro_plugin_info(void)
 *   void  aro_plugin_init(void)
 *   void  aro_plugin_shutdown(void)
 *   char* aro_plugin_execute(const char* action, const char* input_json)
 *   void  aro_plugin_free(char* ptr)
 *
 * Input JSON shape (ARO-0073):
 * {
 *   "result":      { "base": "...", "specifiers": [...] },
 *   "source":      { "base": "...", "specifiers": [...] },
 *   "preposition": "from",
 *   "_with":       {},
 *   "_context":    { "featureSet": "...", "activity": "..." }
 * }
 *
 * The value to hash is sourced from the runtime-resolved object, which the
 * runtime passes as the first string value it finds in "_with" or under the
 * "source" key in the resolved-values block.  To stay decoupled from the
 * runtime's value-resolution layer, we look for the following keys in order:
 *   1. _with.<any first string value>
 *   2. source (top-level convenience injection by the runtime)
 *   3. data / object  (legacy fallback)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* ── Minimal JSON helpers ──────────────────────────────────────────────── */

/**
 * Locate the start of a JSON string value for `key` within `json`.
 * Returns a pointer to the first character *inside* the quotes, or NULL.
 * Does NOT handle nested objects or escaped quotes inside values.
 */
static const char* find_json_string_value(const char* json, const char* key) {
    char search[256];
    snprintf(search, sizeof(search), "\"%s\"", key);

    const char* pos = strstr(json, search);
    if (!pos) return NULL;

    /* Advance past the key and its closing quote */
    pos += strlen(search);

    /* Skip optional whitespace then ':' */
    while (*pos == ' ' || *pos == '\t' || *pos == '\n' || *pos == '\r') pos++;
    if (*pos != ':') return NULL;
    pos++;

    /* Skip whitespace after colon */
    while (*pos == ' ' || *pos == '\t' || *pos == '\n' || *pos == '\r') pos++;

    if (*pos != '"') return NULL;
    return pos + 1;  /* pointer to first char inside string */
}

/**
 * Extract a heap-allocated copy of the string value for `key`.
 * Returns NULL if the key is absent or the value is not a string.
 * Caller must free() the result.
 */
static char* extract_json_string(const char* json, const char* key) {
    const char* start = find_json_string_value(json, key);
    if (!start) return NULL;

    /* Find closing quote, honouring simple backslash escapes */
    const char* p = start;
    while (*p && *p != '"') {
        if (*p == '\\' && *(p + 1)) p++;  /* skip escaped char */
        p++;
    }
    if (*p != '"') return NULL;

    size_t len = (size_t)(p - start);
    char* result = malloc(len + 1);
    if (!result) return NULL;
    memcpy(result, start, len);
    result[len] = '\0';
    return result;
}

/**
 * Find the opening '{' of the object value for `key`.
 * Returns a pointer to '{', or NULL.
 */
static const char* find_json_object(const char* json, const char* key) {
    char search[256];
    snprintf(search, sizeof(search), "\"%s\"", key);

    const char* pos = strstr(json, search);
    if (!pos) return NULL;

    pos += strlen(search);
    while (*pos == ' ' || *pos == '\t' || *pos == '\n' || *pos == '\r') pos++;
    if (*pos != ':') return NULL;
    pos++;
    while (*pos == ' ' || *pos == '\t' || *pos == '\n' || *pos == '\r') pos++;
    if (*pos != '{') return NULL;
    return pos;
}

/**
 * Extract the first string value found inside a JSON object located at `obj`.
 * Scans for the pattern  "key": "value"  and returns a copy of `value`.
 * Returns NULL if no string value exists.
 */
static char* first_string_in_object(const char* obj) {
    if (!obj || *obj != '{') return NULL;
    const char* p = obj + 1;  /* skip '{' */

    while (*p && *p != '}') {
        /* Skip whitespace */
        while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
        if (*p != '"') { p++; continue; }

        /* Found start of a key */
        p++;  /* skip opening quote of key */
        while (*p && *p != '"') { if (*p == '\\') p++; p++; }
        if (*p != '"') break;
        p++;  /* skip closing quote of key */

        /* Expect ':' */
        while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
        if (*p != ':') continue;
        p++;
        while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;

        if (*p == '"') {
            /* This is a string value — extract it */
            const char* start = p + 1;
            const char* q = start;
            while (*q && *q != '"') { if (*q == '\\') q++; q++; }
            if (*q != '"') break;
            size_t len = (size_t)(q - start);
            char* result = malloc(len + 1);
            if (!result) return NULL;
            memcpy(result, start, len);
            result[len] = '\0';
            return result;
        }

        /* Skip over non-string value (number, bool, null, nested obj/array) */
        if (*p == '{' || *p == '[') {
            /* Naively skip balanced braces/brackets */
            char open = *p, close = (*p == '{') ? '}' : ']';
            int depth = 1;
            p++;
            while (*p && depth > 0) {
                if (*p == open)  depth++;
                else if (*p == close) depth--;
                p++;
            }
        } else {
            while (*p && *p != ',' && *p != '}') p++;
        }

        /* Skip comma */
        while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
        if (*p == ',') p++;
    }

    return NULL;
}

/**
 * Resolve the input value to hash from the ARO-0073 input JSON.
 *
 * Priority order:
 *   1. First string value inside "_with" object
 *   2. Top-level "source" string (runtime convenience injection)
 *   3. Top-level "data" string  (legacy)
 *   4. Top-level "object" string (legacy)
 */
static char* resolve_input_value(const char* input_json) {
    /* 1. Look inside "_with": { ... } for any string value */
    const char* with_obj = find_json_object(input_json, "_with");
    if (with_obj) {
        char* val = first_string_in_object(with_obj);
        if (val) return val;
    }

    /* 2. Top-level "source" string */
    char* val = extract_json_string(input_json, "source");
    if (val) return val;

    /* 3. Legacy "data" */
    val = extract_json_string(input_json, "data");
    if (val) return val;

    /* 4. Legacy "object" */
    return extract_json_string(input_json, "object");
}

/* ── Hash algorithm implementations ────────────────────────────────────── */

/* DJB2 — 64-bit */
static uint64_t djb2_hash(const char* str) {
    uint64_t hash = 5381;
    int c;
    while ((c = (unsigned char)*str++)) {
        hash = ((hash << 5) + hash) + c;  /* hash * 33 + c */
    }
    return hash;
}

/* FNV-1a — 64-bit */
static uint64_t fnv1a_hash(const char* str) {
    uint64_t hash      = 14695981039346656037ULL;
    const uint64_t fnv_prime = 1099511628211ULL;
    while (*str) {
        hash ^= (uint8_t)*str++;
        hash *= fnv_prime;
    }
    return hash;
}

/* Simple — 32-bit (polynomial hash) */
static uint32_t simple_hash(const char* str) {
    uint32_t hash = 0;
    while (*str) {
        hash = hash * 31 + (unsigned char)*str++;
    }
    return hash;
}

/* ── ARO-0073 ABI ───────────────────────────────────────────────────────── */

/**
 * aro_plugin_info — REQUIRED
 *
 * Returns a heap-allocated JSON string describing the plugin and its actions.
 * Each action entry contains: name, verbs, role, prepositions.
 */
char* aro_plugin_info(void) {
    const char* info =
        "{"
            "\"name\":\"plugin-c-hash\","
            "\"version\":\"1.0.0\","
            "\"language\":\"c\","
            "\"handle\":\"Hash\","
            "\"actions\":["
                "{"
                    "\"name\":\"Hash\","
                    "\"verbs\":[\"Hash.Hash\",\"hash\"],"
                    "\"role\":\"own\","
                    "\"prepositions\":[\"from\",\"with\",\"for\"]"
                "},"
                "{"
                    "\"name\":\"DJB2\","
                    "\"verbs\":[\"Hash.DJB2\",\"djb2\"],"
                    "\"role\":\"own\","
                    "\"prepositions\":[\"from\",\"with\",\"for\"]"
                "},"
                "{"
                    "\"name\":\"FNV1a\","
                    "\"verbs\":[\"Hash.FNV1a\",\"fnv1a\"],"
                    "\"role\":\"own\","
                    "\"prepositions\":[\"from\",\"with\",\"for\"]"
                "}"
            "]"
        "}";

    char* result = malloc(strlen(info) + 1);
    if (result) strcpy(result, info);
    return result;
}

/**
 * aro_plugin_init — lifecycle hook (no-op for this plugin)
 */
void aro_plugin_init(void) {
    /* Nothing to initialise */
}

/**
 * aro_plugin_shutdown — lifecycle hook (no-op for this plugin)
 */
void aro_plugin_shutdown(void) {
    /* Nothing to tear down */
}

/**
 * aro_plugin_execute — REQUIRED
 *
 * Dispatches to the appropriate hash algorithm based on `action`.
 * `input_json` conforms to ARO-0073 shape:
 *
 *   {
 *     "result":      { "base": "simple-result", "specifiers": [] },
 *     "source":      { "base": "test-string",   "specifiers": [] },
 *     "preposition": "from",
 *     "_with":       { "test-string": "Hello, ARO!" },
 *     "_context":    { "featureSet": "Application-Start", "activity": "Hash Plugin Demo" }
 *   }
 *
 * Returns a heap-allocated JSON string.  The caller (ARO runtime) must call
 * aro_plugin_free() on the returned pointer when it is done with it.
 */
char* aro_plugin_execute(const char* action, const char* input_json) {
    /* Buffer large enough for any hash result + metadata */
    const size_t BUF = 512;
    char* result = malloc(BUF);
    if (!result) return NULL;

    /* Resolve the string value we should hash */
    char* data = resolve_input_value(input_json);
    if (!data) {
        snprintf(result, BUF,
                 "{\"error\":\"No hashable value found in input\","
                  "\"action\":\"%s\"}", action);
        return result;
    }

    if (strcmp(action, "Hash.Hash") == 0 ||
        strcmp(action, "hash")      == 0 ||
        strcmp(action, "simple")    == 0)
    {
        uint32_t h = simple_hash(data);
        snprintf(result, BUF,
                 "{\"hash\":\"%08x\",\"algorithm\":\"simple\",\"input\":\"%s\"}",
                 h, data);
    }
    else if (strcmp(action, "Hash.DJB2") == 0 ||
             strcmp(action, "djb2")      == 0)
    {
        uint64_t h = djb2_hash(data);
        snprintf(result, BUF,
                 "{\"hash\":\"%016llx\",\"algorithm\":\"djb2\",\"input\":\"%s\"}",
                 (unsigned long long)h, data);
    }
    else if (strcmp(action, "Hash.FNV1a") == 0 ||
             strcmp(action, "fnv1a")      == 0)
    {
        uint64_t h = fnv1a_hash(data);
        snprintf(result, BUF,
                 "{\"hash\":\"%016llx\",\"algorithm\":\"fnv1a\",\"input\":\"%s\"}",
                 (unsigned long long)h, data);
    }
    else {
        snprintf(result, BUF,
                 "{\"error\":\"Unknown action\",\"action\":\"%s\"}", action);
    }

    free(data);
    return result;
}

/**
 * aro_plugin_free — REQUIRED
 *
 * Frees memory that was allocated by this plugin and returned to the runtime.
 * The runtime must call this instead of free() directly so that the plugin
 * owns its own heap (important when crossing DLL/dylib boundaries).
 */
void aro_plugin_free(char* ptr) {
    free(ptr);
}
