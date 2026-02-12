/**
 * ARO Plugin - C Hash Functions
 *
 * This plugin provides various hash functions for ARO.
 * It implements the ARO native plugin interface (C ABI).
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* Simple JSON parsing helpers (for demo purposes) */
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
    return pos + 1;  /* Return pointer to string content */
}

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

/* DJB2 hash algorithm */
static uint64_t djb2_hash(const char* str) {
    uint64_t hash = 5381;
    int c;

    while ((c = *str++)) {
        hash = ((hash << 5) + hash) + c;  /* hash * 33 + c */
    }

    return hash;
}

/* FNV-1a hash algorithm */
static uint64_t fnv1a_hash(const char* str) {
    uint64_t hash = 14695981039346656037ULL;
    const uint64_t fnv_prime = 1099511628211ULL;

    while (*str) {
        hash ^= (uint8_t)*str++;
        hash *= fnv_prime;
    }

    return hash;
}

/* Simple string hash (for shorter outputs) */
static uint32_t simple_hash(const char* str) {
    uint32_t hash = 0;

    while (*str) {
        hash = hash * 31 + *str++;
    }

    return hash;
}

/* Plugin info - returns JSON with plugin metadata */
char* aro_plugin_info(void) {
    const char* info =
        "{"
        "\"name\":\"plugin-c-hash\","
        "\"version\":\"1.0.0\","
        "\"language\":\"c\","
        "\"actions\":["
            "{\"name\":\"Hash\",\"role\":\"own\",\"verbs\":[\"hash\"],\"prepositions\":[\"with\",\"for\"]},"
            "{\"name\":\"DJB2\",\"role\":\"own\",\"verbs\":[\"djb2\"],\"prepositions\":[\"with\",\"for\"]},"
            "{\"name\":\"FNV1A\",\"role\":\"own\",\"verbs\":[\"fnv1a\"],\"prepositions\":[\"with\",\"for\"]}"
        "]"
        "}";

    char* result = malloc(strlen(info) + 1);
    if (result) {
        strcpy(result, info);
    }
    return result;
}

/* Execute action */
char* aro_plugin_execute(const char* action, const char* input_json) {
    char* result = malloc(512);
    if (!result) return NULL;

    char* data = extract_json_string(input_json, "data");
    if (!data) {
        data = extract_json_string(input_json, "object");
    }

    if (!data) {
        snprintf(result, 512, "{\"error\":\"Missing 'data' field\"}");
        return result;
    }

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

/* Free memory allocated by the plugin */
void aro_plugin_free(char* ptr) {
    if (ptr) {
        free(ptr);
    }
}
