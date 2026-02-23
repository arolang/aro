/**
 * ARO Plugin - C Collection Qualifiers
 *
 * This plugin provides collection qualifiers for ARO.
 * It implements the ARO native plugin interface (C ABI) with qualifier support.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* Initialize random seed */
static int random_initialized = 0;
static void init_random(void) {
    if (!random_initialized) {
        srand((unsigned int)time(NULL));
        random_initialized = 1;
    }
}

/* Simple JSON parsing helpers */
static const char* find_json_value(const char* json, const char* key) {
    char search[256];
    snprintf(search, sizeof(search), "\"%s\":", key);

    const char* pos = strstr(json, search);
    if (!pos) return NULL;

    pos = strchr(pos, ':');
    if (!pos) return NULL;
    pos++;

    /* Skip whitespace */
    while (*pos == ' ' || *pos == '\t' || *pos == '\n') pos++;

    return pos;
}

static char* extract_json_string(const char* json, const char* key) {
    const char* start = find_json_value(json, key);
    if (!start || *start != '"') return NULL;
    start++;

    const char* end = strchr(start, '"');
    if (!end) return NULL;

    size_t len = end - start;
    char* result = malloc(len + 1);
    if (!result) return NULL;

    memcpy(result, start, len);
    result[len] = '\0';
    return result;
}

/* Extract JSON array as string (including brackets) */
static char* extract_json_array(const char* json, const char* key) {
    const char* start = find_json_value(json, key);
    if (!start || *start != '[') return NULL;

    /* Find matching closing bracket */
    int depth = 1;
    const char* end = start + 1;
    while (*end && depth > 0) {
        if (*end == '[') depth++;
        else if (*end == ']') depth--;
        end++;
    }

    size_t len = end - start;
    char* result = malloc(len + 1);
    if (!result) return NULL;

    memcpy(result, start, len);
    result[len] = '\0';
    return result;
}

/* Count elements in a JSON array string */
static int count_array_elements(const char* array_str) {
    if (!array_str || *array_str != '[') return 0;

    int count = 0;
    int depth = 0;
    int in_string = 0;

    for (const char* p = array_str; *p; p++) {
        if (*p == '"' && (p == array_str || *(p-1) != '\\')) {
            in_string = !in_string;
        }
        if (!in_string) {
            if (*p == '[' || *p == '{') depth++;
            else if (*p == ']' || *p == '}') depth--;
            else if (depth == 1 && (*p == ',' || (depth == 1 && p == array_str + 1 && *p != ']'))) {
                if (*p == ',') count++;
            }
        }
    }

    /* Count first element if array is non-empty */
    if (strlen(array_str) > 2) count++;

    return count;
}

/* Plugin info - returns JSON with plugin metadata and qualifiers */
char* aro_plugin_info(void) {
    const char* info =
        "{"
        "\"name\":\"plugin-c-collection\","
        "\"version\":\"1.0.0\","
        "\"language\":\"c\","
        "\"actions\":[],"
        "\"qualifiers\":["
            "{\"name\":\"first\",\"inputTypes\":[\"List\"],\"description\":\"Returns the first element of a list\"},"
            "{\"name\":\"last\",\"inputTypes\":[\"List\"],\"description\":\"Returns the last element of a list\"},"
            "{\"name\":\"size\",\"inputTypes\":[\"List\",\"String\"],\"description\":\"Returns the size/length\"}"
        "]"
        "}";

    char* result = malloc(strlen(info) + 1);
    if (result) {
        strcpy(result, info);
    }
    return result;
}

/* Execute qualifier transformation */
char* aro_plugin_qualifier(const char* qualifier, const char* input_json) {
    char* result = malloc(4096);
    if (!result) return NULL;

    init_random();

    /* Get the type from input */
    char* type = extract_json_string(input_json, "type");

    if (strcmp(qualifier, "first") == 0) {
        /* Get array from input */
        char* array_str = extract_json_array(input_json, "value");
        if (!array_str || strlen(array_str) <= 2) {
            snprintf(result, 4096, "{\"error\":\"first requires a non-empty list\"}");
            free(type);
            free(array_str);
            return result;
        }

        /* Find first element (skip '[' and whitespace) */
        const char* start = array_str + 1;
        while (*start == ' ' || *start == '\t' || *start == '\n') start++;

        /* Find end of first element */
        const char* end = start;
        int depth = 0;
        int in_string = 0;
        while (*end) {
            if (*end == '"' && (end == start || *(end-1) != '\\')) in_string = !in_string;
            if (!in_string) {
                if (*end == '[' || *end == '{') depth++;
                else if (*end == ']' || *end == '}') {
                    if (depth == 0) break;
                    depth--;
                }
                else if (*end == ',' && depth == 0) break;
            }
            end++;
        }

        /* Copy first element */
        size_t elem_len = end - start;
        char* first_elem = malloc(elem_len + 1);
        memcpy(first_elem, start, elem_len);
        first_elem[elem_len] = '\0';

        snprintf(result, 4096, "{\"result\":%s}", first_elem);
        free(first_elem);
        free(array_str);
    }
    else if (strcmp(qualifier, "last") == 0) {
        /* Get array from input */
        char* array_str = extract_json_array(input_json, "value");
        if (!array_str || strlen(array_str) <= 2) {
            snprintf(result, 4096, "{\"error\":\"last requires a non-empty list\"}");
            free(type);
            free(array_str);
            return result;
        }

        /* Find last element by walking backwards from ']' */
        size_t len = strlen(array_str);
        const char* end = array_str + len - 1;
        while (end > array_str && (*end == ']' || *end == ' ' || *end == '\t' || *end == '\n')) end--;
        end++;

        /* Find start of last element */
        const char* start = end - 1;
        int depth = 0;
        int in_string = 0;
        while (start > array_str) {
            if (*start == '"' && *(start-1) != '\\') in_string = !in_string;
            if (!in_string) {
                if (*start == ']' || *start == '}') depth++;
                else if (*start == '[' || *start == '{') {
                    if (depth == 0) break;
                    depth--;
                }
                else if (*start == ',' && depth == 0) {
                    start++;
                    break;
                }
            }
            start--;
        }
        if (*start == '[') start++;
        while (*start == ' ' || *start == '\t' || *start == '\n') start++;

        /* Copy last element */
        size_t elem_len = end - start;
        char* last_elem = malloc(elem_len + 1);
        memcpy(last_elem, start, elem_len);
        last_elem[elem_len] = '\0';

        snprintf(result, 4096, "{\"result\":%s}", last_elem);
        free(last_elem);
        free(array_str);
    }
    else if (strcmp(qualifier, "size") == 0) {
        if (type && strcmp(type, "List") == 0) {
            char* array_str = extract_json_array(input_json, "value");
            int count = count_array_elements(array_str);
            snprintf(result, 4096, "{\"result\":%d}", count);
            free(array_str);
        }
        else if (type && strcmp(type, "String") == 0) {
            char* str = extract_json_string(input_json, "value");
            size_t len = str ? strlen(str) : 0;
            snprintf(result, 4096, "{\"result\":%zu}", len);
            free(str);
        }
        else {
            snprintf(result, 4096, "{\"error\":\"size requires List or String\"}");
        }
    }
    else {
        snprintf(result, 4096, "{\"error\":\"Unknown qualifier: %s\"}", qualifier);
    }

    free(type);
    return result;
}

/* Execute action (not used but required) */
char* aro_plugin_execute(const char* action, const char* input_json) {
    char* result = malloc(256);
    if (result) {
        snprintf(result, 256, "{\"error\":\"No actions defined\"}");
    }
    return result;
}

/* Free memory allocated by the plugin */
void aro_plugin_free(char* ptr) {
    if (ptr) {
        free(ptr);
    }
}
