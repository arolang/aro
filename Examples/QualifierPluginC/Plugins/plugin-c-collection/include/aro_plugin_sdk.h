/*
 * aro_plugin_sdk.h  -  ARO C/C++ Plugin SDK  (ARO-0073 / ARO-0045)
 * ================================================================
 *
 * Single-header, stb-style SDK for writing ARO plugins in C or C++.
 *
 * QUICK START
 * -----------
 *
 *   // In exactly ONE translation unit define the implementation:
 *   #define ARO_PLUGIN_SDK_IMPLEMENTATION
 *   #include "aro_plugin_sdk.h"
 *
 *   // Declare plugin metadata
 *   ARO_PLUGIN("my-plugin", "1.0.0")
 *   ARO_HANDLE("MyPlugin")
 *
 *   // Optional lifecycle hooks
 *   ARO_INIT()     { // one-time setup - runs before first action call
 *   }
 *   ARO_SHUTDOWN() { // cleanup - runs on plugin unload
 *   }
 *
 *   // Declare an action handler
 *   ARO_ACTION("Greet", "own", "with") {
 *       const char* name = aro_input_string(ctx, "name");
 *       aro_output_string(ctx, "greeting", "Hello!");
 *       return aro_ok(ctx);
 *   }
 *
 *   // Declare a qualifier handler
 *   ARO_QUALIFIER("reverse", "List,String", "Reverse a list or string") {
 *       // ... transform and return
 *       return aro_qualifier_result_string(ctx, reversed);
 *   }
 *
 * The macros auto-generate aro_plugin_info / aro_plugin_execute /
 * aro_plugin_qualifier / aro_plugin_free at link time by walking
 * registration tables populated via __attribute__((constructor)).
 *
 * LICENSE: MIT
 * SPEC:    ARO-0073 (Native Plugin ABI), ARO-0045 (Package Manager)
 */

#ifndef ARO_PLUGIN_SDK_H
#define ARO_PLUGIN_SDK_H

#include <stddef.h>
#include <stdint.h>
#include <stdarg.h>
#include <inttypes.h>

#ifdef __cplusplus
extern "C" {
#endif

/* =========================================================================
 * 1. VERSION
 * ========================================================================= */

#define ARO_PLUGIN_SDK_VERSION_MAJOR 1
#define ARO_PLUGIN_SDK_VERSION_MINOR 0
#define ARO_PLUGIN_SDK_VERSION_PATCH 0
#define ARO_PLUGIN_SDK_VERSION "1.0.0"


/* =========================================================================
 * 2. COMPILER / EXPORT HELPERS
 * ========================================================================= */

#if defined(_WIN32) || defined(__CYGWIN__)
  #ifdef ARO_PLUGIN_EXPORT
    #define ARO_API __declspec(dllexport)
  #else
    #define ARO_API __declspec(dllimport)
  #endif
#else
  #define ARO_API __attribute__((visibility("default")))
#endif

/* Silence unused-parameter warnings inside action/qualifier bodies. */
#define ARO_UNUSED(x) ((void)(x))


/* =========================================================================
 * 3. OPAQUE TYPES
 * ========================================================================= */

/** Execution context passed to every action and qualifier handler. */
typedef struct aro_ctx aro_ctx;

/** A JSON array value parsed from input. */
typedef struct aro_array aro_array;


/* =========================================================================
 * 4. ERROR CODES  (mirrors PluginErrorCode in the ARO runtime)
 * ========================================================================= */

#define ARO_ERR_SUCCESS            0   /* Operation completed successfully.            */
#define ARO_ERR_INVALID_INPUT      1   /* Input was invalid or malformed.              */
#define ARO_ERR_NOT_FOUND          2   /* Requested resource could not be found.       */
#define ARO_ERR_PERMISSION_DENIED  3   /* Caller lacks permission.                     */
#define ARO_ERR_TIMEOUT            4   /* Operation timed out.                         */
#define ARO_ERR_CONNECTION_FAILED  5   /* Network/service connection failed.           */
#define ARO_ERR_EXECUTION_FAILED   6   /* Plugin failed during execution.              */
#define ARO_ERR_INVALID_STATE      7   /* Plugin or resource in invalid state.         */
#define ARO_ERR_RESOURCE_EXHAUSTED 8   /* Memory, handles, or connections exhausted.   */
#define ARO_ERR_UNSUPPORTED        9   /* Action/feature not supported by this plugin. */
#define ARO_ERR_RATE_LIMITED       10  /* Caller exceeded allowed request rate.        */


/* =========================================================================
 * 5. CONTEXT HELPERS - reading input
 * ========================================================================= */

/*
 * Read a string value from the resolved _with / input map.
 * Returns NULL if the key is absent.
 */
const char* aro_input_string(aro_ctx* ctx, const char* key);

/* Read an integer value. Returns 0 if absent or not numeric. */
int64_t aro_input_int(aro_ctx* ctx, const char* key);

/* Read a double value. Returns 0.0 if absent or not numeric. */
double aro_input_double(aro_ctx* ctx, const char* key);

/* Read a boolean value. Returns 0 if absent or not boolean. */
int aro_input_bool(aro_ctx* ctx, const char* key);

/* Read an array value. Returns NULL if absent or not an array. */
aro_array* aro_input_array(aro_ctx* ctx, const char* key);

/* ---- Descriptor accessors ---------------------------------------------- */

/* Base identifier of the result binding (e.g. "greeting" in <greeting: ...>). */
const char* aro_input_result_base(aro_ctx* ctx);

/* Base identifier of the source object (e.g. "name" in: from the <name>). */
const char* aro_input_source_base(aro_ctx* ctx);

/* Preposition used in the statement ("from", "with", "for", "to", etc.). */
const char* aro_input_preposition(aro_ctx* ctx);

/* ---- With-clause params -------------------------------------------------- */

/* Read a string from the _with clause, returning def if absent. */
const char* aro_with_string(aro_ctx* ctx, const char* key, const char* def);

/* Read an integer from the _with clause, returning def if absent. */
int64_t aro_with_int(aro_ctx* ctx, const char* key, int64_t def);

/* ---- Execution context --------------------------------------------------- */

/* Read a string from the _context map (e.g. "featureSet", "activity"). */
const char* aro_context_string(aro_ctx* ctx, const char* key);


/* =========================================================================
 * 6. ARRAY ACCESS
 * ========================================================================= */

/* Number of elements in the array. */
size_t aro_array_length(aro_array* arr);

/* Get element at index as a string. Returns NULL if out of range or wrong type. */
const char* aro_array_string(aro_array* arr, size_t idx);

/* Get element at index as an integer. Returns 0 if out of range or wrong type. */
int64_t aro_array_int(aro_array* arr, size_t idx);

/* Get element at index as a double. Returns 0.0 if out of range or wrong type. */
double aro_array_double(aro_array* arr, size_t idx);


/* =========================================================================
 * 7. OUTPUT HELPERS
 * ========================================================================= */

void aro_output_string(aro_ctx* ctx, const char* key, const char* val);
void aro_output_int(aro_ctx* ctx, const char* key, int64_t val);
void aro_output_double(aro_ctx* ctx, const char* key, double val);
void aro_output_bool(aro_ctx* ctx, const char* key, int val);

/*
 * Append a JSON array of strings to the output.
 * items is a pointer to an array of count C string pointers.
 */
void aro_output_string_array(aro_ctx* ctx, const char* key,
                              const char** items, size_t count);


/* =========================================================================
 * 8. RESULT BUILDERS
 * ========================================================================= */

/* Serialise the output map accumulated via aro_output_* and return it. */
const char* aro_ok(aro_ctx* ctx);

/*
 * Build and return a JSON error response.
 * fmt is a printf-style format string for the human-readable message.
 * Example: return aro_error(ctx, ARO_ERR_NOT_FOUND, "User %s not found", id);
 */
const char* aro_error(aro_ctx* ctx, int code, const char* fmt, ...);


/* =========================================================================
 * 9. QUALIFIER HELPERS
 * ========================================================================= */

/* Input value as a string (for String-typed qualifiers). */
const char* aro_qualifier_string(aro_ctx* ctx);

/* Input value as an array (for List-typed qualifiers). */
aro_array*  aro_qualifier_array(aro_ctx* ctx);

/* Input value as an integer (for Int-typed qualifiers). */
int64_t     aro_qualifier_int(aro_ctx* ctx);

/* Return a transformed string result from a qualifier. */
const char* aro_qualifier_result_string(aro_ctx* ctx, const char* val);

/* Return a transformed integer result from a qualifier. */
const char* aro_qualifier_result_int(aro_ctx* ctx, int64_t val);

/* Return a transformed array result from a qualifier. */
const char* aro_qualifier_result_array(aro_ctx* ctx, aro_array* val);

/* Read a parameter from the qualifier's with-clause (integer). */
int64_t     aro_qualifier_param_int(aro_ctx* ctx, const char* key, int64_t def);

/* Read a parameter from the qualifier's with-clause (string). */
const char* aro_qualifier_param_string(aro_ctx* ctx, const char* key,
                                        const char* def);


/* =========================================================================
 * 10. INTERNAL REGISTRATION TYPES
 * =========================================================================
 * These types are part of the SDK's internal machinery.  Plugins do not
 * interact with them directly - use the macros in section 11 instead.
 * ========================================================================= */

/* Per-action registration entry */
typedef struct {
    const char* name;
    const char* role;
    const char* prepositions;   /* comma-separated */
    const char* (*handler)(aro_ctx* ctx);
} aro__action_entry;

/* Per-qualifier registration entry */
typedef struct {
    const char* name;
    const char* input_types;    /* comma-separated ARO types */
    const char* description;
    int         accepts_parameters;
    const char* (*handler)(aro_ctx* ctx);
} aro__qualifier_entry;

/* System-object registration entry */
typedef struct {
    const char* name;
    const char* capabilities;   /* comma-separated: "read", "write", "list" */
} aro__sysobj_entry;

/* Registration tables - defined in the IMPLEMENTATION section */
extern aro__action_entry*    aro__action_table[];
extern aro__qualifier_entry* aro__qualifier_table[];
extern aro__sysobj_entry*    aro__sysobj_table[];
extern int                   aro__action_count;
extern int                   aro__qualifier_count;
extern int                   aro__sysobj_count;

/* Plugin identity globals - set by ARO_PLUGIN() and ARO_HANDLE() */
extern const char*           aro__plugin_name;
extern const char*           aro__plugin_version;
extern const char*           aro__plugin_handle;

/* Internal registration functions called by constructors */
void aro__register_action(aro__action_entry* e);
void aro__register_qualifier(aro__qualifier_entry* e);
void aro__register_sysobj(aro__sysobj_entry* e);
void aro__set_plugin_name(const char* name, const char* version);
void aro__set_plugin_handle(const char* handle);


/* =========================================================================
 * 11. REGISTRATION MACROS
 * =========================================================================
 *
 * ARO_HANDLE(name)
 *   Set the plugin handle (PascalCase, e.g. "Hash").
 *
 * ARO_PLUGIN(name, ver)
 *   Declare plugin identity (name + version string). Place once at file scope.
 *
 * ARO_INIT()
 *   Define the one-time initialisation body (runs before first action call).
 *   Usage:  ARO_INIT() { your_setup_code(); }
 *
 * ARO_SHUTDOWN()
 *   Define the cleanup body (runs on plugin unload).
 *   Usage:  ARO_SHUTDOWN() { your_cleanup_code(); }
 *
 * ARO_ACTION(name, role, prep)
 *   Declare and define an action handler.
 *     name : action name (e.g. "Greet")
 *     role : "request" | "own" | "response" | "export"
 *     prep : comma-separated prepositions (e.g. "from,with")
 *   The body receives (aro_ctx* ctx) and must return const char*.
 *
 * ARO_QUALIFIER(name, types, desc)
 *   Declare and define a qualifier without parameters.
 *     name  : qualifier name (e.g. "reverse")
 *     types : comma-separated ARO types (e.g. "List,String")
 *     desc  : short description string
 *
 * ARO_QUALIFIER_WITH_PARAMS(name, types, desc)
 *   Same as ARO_QUALIFIER but marks accepts_parameters = true.
 *
 * ARO_SYSTEM_OBJECT(name, caps)
 *   Declare a system object.
 *     name : identifier (e.g. "config-store")
 *     caps : comma-separated capabilities (e.g. "read,write")
 *
 * ========================================================================= */

/* Unique-name helpers */
#define ARO__CAT(a,b)    a##b
#define ARO__XCAT(a,b)   ARO__CAT(a,b)
#define ARO__UNIQ(pfx)   ARO__XCAT(pfx, __LINE__)

/* ---- ARO_HANDLE ---------------------------------------------------------- */
#define ARO_HANDLE(h) \
    static void ARO__UNIQ(aro__handle_ctor_)(void) \
        __attribute__((constructor)); \
    static void ARO__UNIQ(aro__handle_ctor_)(void) { \
        aro__set_plugin_handle(h); \
    }

/* ---- ARO_PLUGIN ---------------------------------------------------------- */
#define ARO_PLUGIN(name_, ver_) \
    static void ARO__UNIQ(aro__plugin_ctor_)(void) \
        __attribute__((constructor)); \
    static void ARO__UNIQ(aro__plugin_ctor_)(void) { \
        aro__set_plugin_name((name_), (ver_)); \
    }

/* ---- ARO_INIT ------------------------------------------------------------ */
/*
 * Expands to the aro_plugin_init function signature + body.
 * Usage:  ARO_INIT() { your_setup_code(); }
 */
#define ARO_INIT() \
    ARO_API void aro_plugin_init(void)

/* ---- ARO_SHUTDOWN -------------------------------------------------------- */
/*
 * Expands to the aro_plugin_shutdown function signature + body.
 * Usage:  ARO_SHUTDOWN() { your_cleanup_code(); }
 */
#define ARO_SHUTDOWN() \
    ARO_API void aro_plugin_shutdown(void)

/* ---- ARO_ACTION ---------------------------------------------------------- */
/*
 * Declares, registers, and defines an action handler.
 *
 * The handler receives (aro_ctx* ctx) and must return const char*.
 * Use aro_ok(ctx) or aro_error(ctx, code, fmt, ...) as the return value.
 *
 * Example:
 *   ARO_ACTION("Greet", "own", "with") {
 *       const char* name = aro_input_string(ctx, "name");
 *       aro_output_string(ctx, "greeting", "Hello!");
 *       return aro_ok(ctx);
 *   }
 */
#define ARO_ACTION(name_, role_, prep_) \
    static const char* ARO__UNIQ(aro__action_fn_)(aro_ctx* ctx); \
    static aro__action_entry ARO__UNIQ(aro__action_entry_) = { \
        (name_), (role_), (prep_), NULL \
    }; \
    static void ARO__UNIQ(aro__action_ctor_)(void) \
        __attribute__((constructor)); \
    static void ARO__UNIQ(aro__action_ctor_)(void) { \
        ARO__UNIQ(aro__action_entry_).handler = ARO__UNIQ(aro__action_fn_); \
        aro__register_action(&ARO__UNIQ(aro__action_entry_)); \
    } \
    static const char* ARO__UNIQ(aro__action_fn_)(aro_ctx* ctx)

/* ---- ARO_QUALIFIER -------------------------------------------------------- */
#define ARO_QUALIFIER(name_, types_, desc_) \
    static const char* ARO__UNIQ(aro__qual_fn_)(aro_ctx* ctx); \
    static aro__qualifier_entry ARO__UNIQ(aro__qual_entry_) = { \
        (name_), (types_), (desc_), 0, NULL \
    }; \
    static void ARO__UNIQ(aro__qual_ctor_)(void) \
        __attribute__((constructor)); \
    static void ARO__UNIQ(aro__qual_ctor_)(void) { \
        ARO__UNIQ(aro__qual_entry_).handler = ARO__UNIQ(aro__qual_fn_); \
        aro__register_qualifier(&ARO__UNIQ(aro__qual_entry_)); \
    } \
    static const char* ARO__UNIQ(aro__qual_fn_)(aro_ctx* ctx)

#define ARO_QUALIFIER_WITH_PARAMS(name_, types_, desc_) \
    static const char* ARO__UNIQ(aro__qual_fn_)(aro_ctx* ctx); \
    static aro__qualifier_entry ARO__UNIQ(aro__qual_entry_) = { \
        (name_), (types_), (desc_), 1, NULL \
    }; \
    static void ARO__UNIQ(aro__qual_ctor_)(void) \
        __attribute__((constructor)); \
    static void ARO__UNIQ(aro__qual_ctor_)(void) { \
        ARO__UNIQ(aro__qual_entry_).handler = ARO__UNIQ(aro__qual_fn_); \
        aro__register_qualifier(&ARO__UNIQ(aro__qual_entry_)); \
    } \
    static const char* ARO__UNIQ(aro__qual_fn_)(aro_ctx* ctx)

/* ---- ARO_SYSTEM_OBJECT --------------------------------------------------- */
#define ARO_SYSTEM_OBJECT(name_, caps_) \
    static aro__sysobj_entry ARO__UNIQ(aro__sysobj_entry_) = { (name_), (caps_) }; \
    static void ARO__UNIQ(aro__sysobj_ctor_)(void) \
        __attribute__((constructor)); \
    static void ARO__UNIQ(aro__sysobj_ctor_)(void) { \
        aro__register_sysobj(&ARO__UNIQ(aro__sysobj_entry_)); \
    }


/* =========================================================================
 * 12. IMPLEMENTATION
 * =========================================================================
 * Define ARO_PLUGIN_SDK_IMPLEMENTATION in exactly one translation unit
 * before including this header.
 * ========================================================================= */
#ifdef ARO_PLUGIN_SDK_IMPLEMENTATION

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- Max registrations per table ---------------------------------------- */
#ifndef ARO_MAX_ACTIONS
#define ARO_MAX_ACTIONS     128
#endif
#ifndef ARO_MAX_QUALIFIERS
#define ARO_MAX_QUALIFIERS  128
#endif
#ifndef ARO_MAX_SYSOBJS
#define ARO_MAX_SYSOBJS     32
#endif

/* ---- Output buffer size -------------------------------------------------- */
#ifndef ARO_OUTPUT_BUF
#define ARO_OUTPUT_BUF      (64 * 1024)  /* 64 KB default output buffer */
#endif

/* ---- Registration tables ------------------------------------------------- */
aro__action_entry*    aro__action_table[ARO_MAX_ACTIONS];
aro__qualifier_entry* aro__qualifier_table[ARO_MAX_QUALIFIERS];
aro__sysobj_entry*    aro__sysobj_table[ARO_MAX_SYSOBJS];
int                   aro__action_count    = 0;
int                   aro__qualifier_count = 0;
int                   aro__sysobj_count    = 0;
const char*           aro__plugin_name     = "unnamed-plugin";
const char*           aro__plugin_version  = "0.0.0";
const char*           aro__plugin_handle   = NULL; /* NULL means use name */

/* ---- Registration helpers ------------------------------------------------ */
void aro__register_action(aro__action_entry* e) {
    if (aro__action_count < ARO_MAX_ACTIONS)
        aro__action_table[aro__action_count++] = e;
}

void aro__register_qualifier(aro__qualifier_entry* e) {
    if (aro__qualifier_count < ARO_MAX_QUALIFIERS)
        aro__qualifier_table[aro__qualifier_count++] = e;
}

void aro__register_sysobj(aro__sysobj_entry* e) {
    if (aro__sysobj_count < ARO_MAX_SYSOBJS)
        aro__sysobj_table[aro__sysobj_count++] = e;
}

void aro__set_plugin_name(const char* name, const char* version) {
    aro__plugin_name    = name;
    aro__plugin_version = version;
}

void aro__set_plugin_handle(const char* handle) {
    aro__plugin_handle = handle;
}

/* =========================================================================
 * MINIMAL JSON PARSER (arena-backed, read-only)
 * =========================================================================
 * Supports the subset of JSON produced by the ARO runtime:
 *   - objects, arrays, strings, integers, doubles, booleans, null
 *   - UTF-8 strings (\uXXXX sequences are passed through verbatim)
 *   - no duplicate-key handling (first match wins)
 * ========================================================================= */

typedef enum {
    ARO__JSON_NULL,
    ARO__JSON_BOOL,
    ARO__JSON_INT,
    ARO__JSON_DOUBLE,
    ARO__JSON_STRING,
    ARO__JSON_ARRAY,
    ARO__JSON_OBJECT,
    ARO__JSON_ERROR
} aro__json_type;

typedef struct aro__json_value aro__json_value;
typedef struct aro__json_kv    aro__json_kv;

struct aro__json_value {
    aro__json_type type;
    union {
        int         b;      /* boolean */
        int64_t     i;      /* integer */
        double      d;      /* double  */
        const char* s;      /* string (NUL-terminated copy in arena) */
        struct {            /* array   */
            aro__json_value* items;
            size_t           count;
        } arr;
        struct {            /* object  */
            aro__json_kv* pairs;
            size_t        count;
        } obj;
    } v;
};

struct aro__json_kv {
    const char*     key;
    aro__json_value val;
};

/* ---- Arena allocator ----------------------------------------------------- */
typedef struct {
    char*  buf;
    size_t cap;
    size_t used;
} aro__arena;

static void* aro__arena_alloc(aro__arena* a, size_t n) {
    size_t aligned = (n + 7) & ~(size_t)7;
    if (a->used + aligned > a->cap) return NULL;
    void* p = a->buf + a->used;
    a->used += aligned;
    memset(p, 0, n);
    return p;
}

/* ---- JSON tokenizer helpers ---------------------------------------------- */
static const char* aro__skip_ws(const char* p) {
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
    return p;
}

/*
 * Parse a JSON string starting at p (which points at the opening '"').
 * Copies unescaped content into the arena.  Returns pointer past closing '"'.
 * dst receives a NUL-terminated C string in the arena.
 */
static const char* aro__parse_string(const char* p, aro__arena* a,
                                     const char** dst) {
    if (*p != '"') { *dst = NULL; return p; }
    p++; /* skip opening quote */

    /* First pass: measure output length */
    size_t len = 0;
    const char* q = p;
    while (*q && *q != '"') {
        if (*q == '\\') { q++; if (!*q) break; }
        len++; q++;
    }

    char* buf = (char*)aro__arena_alloc(a, len + 1);
    if (!buf) { *dst = NULL; return q + 1; }

    /* Second pass: copy with escape handling */
    char* out = buf;
    q = p;
    while (*q && *q != '"') {
        if (*q == '\\') {
            q++;
            switch (*q) {
                case '"':  *out++ = '"';  break;
                case '\\': *out++ = '\\'; break;
                case '/':  *out++ = '/';  break;
                case 'n':  *out++ = '\n'; break;
                case 'r':  *out++ = '\r'; break;
                case 't':  *out++ = '\t'; break;
                case 'b':  *out++ = '\b'; break;
                case 'f':  *out++ = '\f'; break;
                case 'u':
                    /* Pass \uXXXX through verbatim */
                    *out++ = '\\'; *out++ = 'u';
                    if (q[1]) { *out++ = *++q; }
                    if (q[1]) { *out++ = *++q; }
                    if (q[1]) { *out++ = *++q; }
                    if (q[1]) { *out++ = *++q; }
                    break;
                default:   *out++ = *q;   break;
            }
        } else {
            *out++ = *q;
        }
        q++;
    }
    *out = '\0';
    *dst = buf;
    return (*q == '"') ? q + 1 : q;
}

/* Forward declaration */
static const char* aro__parse_value(const char* p, aro__arena* a,
                                    aro__json_value* out);

static const char* aro__parse_array(const char* p, aro__arena* a,
                                    aro__json_value* out) {
    p = aro__skip_ws(p + 1); /* skip '[' */
    out->type = ARO__JSON_ARRAY;
    out->v.arr.items = NULL;
    out->v.arr.count = 0;

    if (*p == ']') return p + 1;

#define ARO__MAX_ARRAY_ITEMS 4096
    aro__json_value* tmp = (aro__json_value*)aro__arena_alloc(
        a, sizeof(aro__json_value) * ARO__MAX_ARRAY_ITEMS);
    if (!tmp) { out->type = ARO__JSON_ERROR; return p; }

    size_t count = 0;
    while (*p) {
        p = aro__skip_ws(p);
        if (*p == ']') { p++; break; }
        if (count >= ARO__MAX_ARRAY_ITEMS) break;
        p = aro__parse_value(p, a, &tmp[count++]);
        p = aro__skip_ws(p);
        if (*p == ',') p++;
    }
    out->v.arr.items = tmp;
    out->v.arr.count = count;
    return p;
}

static const char* aro__parse_object(const char* p, aro__arena* a,
                                     aro__json_value* out) {
    p = aro__skip_ws(p + 1); /* skip '{' */
    out->type = ARO__JSON_OBJECT;
    out->v.obj.pairs = NULL;
    out->v.obj.count = 0;

    if (*p == '}') return p + 1;

#define ARO__MAX_OBJECT_PAIRS 256
    aro__json_kv* tmp = (aro__json_kv*)aro__arena_alloc(
        a, sizeof(aro__json_kv) * ARO__MAX_OBJECT_PAIRS);
    if (!tmp) { out->type = ARO__JSON_ERROR; return p; }

    size_t count = 0;
    while (*p) {
        p = aro__skip_ws(p);
        if (*p == '}') { p++; break; }
        if (count >= ARO__MAX_OBJECT_PAIRS) break;

        /* Key */
        const char* key = NULL;
        p = aro__parse_string(p, a, &key);
        if (!key) break;

        p = aro__skip_ws(p);
        if (*p != ':') break;
        p++;
        p = aro__skip_ws(p);

        /* Value */
        p = aro__parse_value(p, a, &tmp[count].val);
        tmp[count].key = key;
        count++;

        p = aro__skip_ws(p);
        if (*p == ',') p++;
    }
    out->v.obj.pairs = tmp;
    out->v.obj.count = count;
    return p;
}

static const char* aro__parse_value(const char* p, aro__arena* a,
                                    aro__json_value* out) {
    p = aro__skip_ws(p);
    memset(out, 0, sizeof(*out));

    if (*p == '"') {
        out->type = ARO__JSON_STRING;
        p = aro__parse_string(p, a, &out->v.s);
    } else if (*p == '[') {
        p = aro__parse_array(p, a, out);
    } else if (*p == '{') {
        p = aro__parse_object(p, a, out);
    } else if (*p == 't' && strncmp(p, "true", 4) == 0) {
        out->type = ARO__JSON_BOOL; out->v.b = 1; p += 4;
    } else if (*p == 'f' && strncmp(p, "false", 5) == 0) {
        out->type = ARO__JSON_BOOL; out->v.b = 0; p += 5;
    } else if (*p == 'n' && strncmp(p, "null", 4) == 0) {
        out->type = ARO__JSON_NULL; p += 4;
    } else if (*p == '-' || (*p >= '0' && *p <= '9')) {
        char* end;
        int64_t i = (int64_t)strtoll(p, &end, 10);
        if (*end == '.' || *end == 'e' || *end == 'E') {
            out->type = ARO__JSON_DOUBLE;
            out->v.d  = strtod(p, &end);
        } else {
            out->type = ARO__JSON_INT;
            out->v.i  = i;
        }
        p = end;
    } else {
        out->type = ARO__JSON_ERROR;
    }
    return p;
}

/* ---- Look up a key in a JSON object ------------------------------------- */
static const aro__json_value* aro__obj_get(const aro__json_value* obj,
                                           const char* key) {
    if (!obj || obj->type != ARO__JSON_OBJECT) return NULL;
    for (size_t i = 0; i < obj->v.obj.count; i++) {
        if (strcmp(obj->v.obj.pairs[i].key, key) == 0)
            return &obj->v.obj.pairs[i].val;
    }
    return NULL;
}

/* =========================================================================
 * CONTEXT STRUCTURE
 * ========================================================================= */

#define ARO__CTX_ARENA_SIZE (256 * 1024)   /* 256 KB per invocation */

struct aro_ctx {
    /* Parsed input root object */
    aro__json_value input_root;

    /* Sub-objects cached after first access */
    const aro__json_value* with_obj;
    const aro__json_value* context_obj;
    const aro__json_value* result_obj;
    const aro__json_value* source_obj;

    /* Output buffer: key/value pairs accumulated as a JSON fragment */
    char   out_buf[ARO_OUTPUT_BUF];
    size_t out_len;
    int    out_has_keys;

    /* Qualifier mode: input value is in the "value" key */
    int    qualifier_mode;

    /* Arena for all input allocations */
    char      arena_buf[ARO__CTX_ARENA_SIZE];
    aro__arena arena;

    /*
     * Return buffer - allocated with malloc so the runtime can free it via
     * aro_plugin_free().  Ownership transfers out of the ctx on destruction.
     */
    char*  ret_buf;
    size_t ret_cap;
};

/* ---- Internal: ensure return buffer has at least need bytes -------------- */
static int aro__ret_ensure(aro_ctx* ctx, size_t need) {
    if (ctx->ret_cap >= need) return 1;
    size_t new_cap = need + 1024;
    char* nb = (char*)realloc(ctx->ret_buf, new_cap);
    if (!nb) return 0;
    ctx->ret_buf = nb;
    ctx->ret_cap = new_cap;
    return 1;
}

/* ---- Create a fresh context from input JSON ----------------------------- */
static aro_ctx* aro__ctx_create(const char* input_json, int qualifier_mode) {
    aro_ctx* ctx = (aro_ctx*)calloc(1, sizeof(aro_ctx));
    if (!ctx) return NULL;

    ctx->arena.buf  = ctx->arena_buf;
    ctx->arena.cap  = sizeof(ctx->arena_buf);
    ctx->arena.used = 0;

    aro__parse_value(input_json, &ctx->arena, &ctx->input_root);

    ctx->with_obj    = aro__obj_get(&ctx->input_root, "_with");
    ctx->context_obj = aro__obj_get(&ctx->input_root, "_context");
    ctx->result_obj  = aro__obj_get(&ctx->input_root, "result");
    ctx->source_obj  = aro__obj_get(&ctx->input_root, "source");

    ctx->out_buf[0]  = '\0';
    ctx->out_len     = 0;
    ctx->out_has_keys = 0;
    ctx->qualifier_mode = qualifier_mode;

    ctx->ret_buf = NULL;
    ctx->ret_cap = 0;

    return ctx;
}

static void aro__ctx_destroy(aro_ctx* ctx) {
    /* ret_buf has been transferred to the caller; do NOT free it here */
    free(ctx);
}

/* =========================================================================
 * CONTEXT HELPER IMPLEMENTATIONS
 * ========================================================================= */

static const char* aro__value_as_string(const aro__json_value* v) {
    if (!v || v->type != ARO__JSON_STRING) return NULL;
    return v->v.s;
}

const char* aro_input_string(aro_ctx* ctx, const char* key) {
    if (!ctx || !key) return NULL;
    if (ctx->with_obj) {
        const aro__json_value* v = aro__obj_get(ctx->with_obj, key);
        if (v) return aro__value_as_string(v);
    }
    const aro__json_value* v = aro__obj_get(&ctx->input_root, key);
    return aro__value_as_string(v);
}

int64_t aro_input_int(aro_ctx* ctx, const char* key) {
    if (!ctx || !key) return 0;
    const aro__json_value* v = NULL;
    if (ctx->with_obj) v = aro__obj_get(ctx->with_obj, key);
    if (!v) v = aro__obj_get(&ctx->input_root, key);
    if (!v) return 0;
    if (v->type == ARO__JSON_INT)    return v->v.i;
    if (v->type == ARO__JSON_DOUBLE) return (int64_t)v->v.d;
    if (v->type == ARO__JSON_STRING) return (int64_t)strtoll(v->v.s, NULL, 10);
    return 0;
}

double aro_input_double(aro_ctx* ctx, const char* key) {
    if (!ctx || !key) return 0.0;
    const aro__json_value* v = NULL;
    if (ctx->with_obj) v = aro__obj_get(ctx->with_obj, key);
    if (!v) v = aro__obj_get(&ctx->input_root, key);
    if (!v) return 0.0;
    if (v->type == ARO__JSON_DOUBLE) return v->v.d;
    if (v->type == ARO__JSON_INT)    return (double)v->v.i;
    if (v->type == ARO__JSON_STRING) return strtod(v->v.s, NULL);
    return 0.0;
}

int aro_input_bool(aro_ctx* ctx, const char* key) {
    if (!ctx || !key) return 0;
    const aro__json_value* v = NULL;
    if (ctx->with_obj) v = aro__obj_get(ctx->with_obj, key);
    if (!v) v = aro__obj_get(&ctx->input_root, key);
    if (!v) return 0;
    if (v->type == ARO__JSON_BOOL) return v->v.b;
    if (v->type == ARO__JSON_INT)  return (int)(v->v.i != 0);
    return 0;
}

aro_array* aro_input_array(aro_ctx* ctx, const char* key) {
    if (!ctx || !key) return NULL;
    const aro__json_value* v = NULL;
    if (ctx->with_obj) v = aro__obj_get(ctx->with_obj, key);
    if (!v) v = aro__obj_get(&ctx->input_root, key);
    if (!v || v->type != ARO__JSON_ARRAY) return NULL;
    return (aro_array*)(uintptr_t)v;
}

const char* aro_input_result_base(aro_ctx* ctx) {
    if (!ctx || !ctx->result_obj) return NULL;
    return aro__value_as_string(aro__obj_get(ctx->result_obj, "base"));
}

const char* aro_input_source_base(aro_ctx* ctx) {
    if (!ctx || !ctx->source_obj) return NULL;
    return aro__value_as_string(aro__obj_get(ctx->source_obj, "base"));
}

const char* aro_input_preposition(aro_ctx* ctx) {
    if (!ctx) return NULL;
    return aro__value_as_string(aro__obj_get(&ctx->input_root, "preposition"));
}

const char* aro_with_string(aro_ctx* ctx, const char* key, const char* def) {
    if (!ctx || !ctx->with_obj) return def;
    const char* s = aro__value_as_string(aro__obj_get(ctx->with_obj, key));
    return s ? s : def;
}

int64_t aro_with_int(aro_ctx* ctx, const char* key, int64_t def) {
    if (!ctx || !ctx->with_obj) return def;
    const aro__json_value* v = aro__obj_get(ctx->with_obj, key);
    if (!v) return def;
    if (v->type == ARO__JSON_INT)    return v->v.i;
    if (v->type == ARO__JSON_DOUBLE) return (int64_t)v->v.d;
    return def;
}

const char* aro_context_string(aro_ctx* ctx, const char* key) {
    if (!ctx || !ctx->context_obj || !key) return NULL;
    return aro__value_as_string(aro__obj_get(ctx->context_obj, key));
}

/* =========================================================================
 * ARRAY ACCESS IMPLEMENTATIONS
 * ========================================================================= */

size_t aro_array_length(aro_array* arr) {
    if (!arr) return 0;
    const aro__json_value* v = (const aro__json_value*)(uintptr_t)arr;
    if (v->type != ARO__JSON_ARRAY) return 0;
    return v->v.arr.count;
}

const char* aro_array_string(aro_array* arr, size_t idx) {
    if (!arr) return NULL;
    const aro__json_value* v = (const aro__json_value*)(uintptr_t)arr;
    if (v->type != ARO__JSON_ARRAY || idx >= v->v.arr.count) return NULL;
    return aro__value_as_string(&v->v.arr.items[idx]);
}

int64_t aro_array_int(aro_array* arr, size_t idx) {
    if (!arr) return 0;
    const aro__json_value* v = (const aro__json_value*)(uintptr_t)arr;
    if (v->type != ARO__JSON_ARRAY || idx >= v->v.arr.count) return 0;
    const aro__json_value* el = &v->v.arr.items[idx];
    if (el->type == ARO__JSON_INT)    return el->v.i;
    if (el->type == ARO__JSON_DOUBLE) return (int64_t)el->v.d;
    return 0;
}

double aro_array_double(aro_array* arr, size_t idx) {
    if (!arr) return 0.0;
    const aro__json_value* v = (const aro__json_value*)(uintptr_t)arr;
    if (v->type != ARO__JSON_ARRAY || idx >= v->v.arr.count) return 0.0;
    const aro__json_value* el = &v->v.arr.items[idx];
    if (el->type == ARO__JSON_DOUBLE) return el->v.d;
    if (el->type == ARO__JSON_INT)    return (double)el->v.i;
    return 0.0;
}

/* =========================================================================
 * JSON BUILDER - output accumulation
 * ========================================================================= */

#define ARO__OUT_APPEND(ctx, str) \
    do { \
        size_t _n = strlen(str); \
        if ((ctx)->out_len + _n + 1 < sizeof((ctx)->out_buf)) { \
            memcpy((ctx)->out_buf + (ctx)->out_len, (str), _n); \
            (ctx)->out_len += _n; \
            (ctx)->out_buf[(ctx)->out_len] = '\0'; \
        } \
    } while (0)

static void aro__append_escaped(aro_ctx* ctx, const char* s) {
    if (!s) { ARO__OUT_APPEND(ctx, "null"); return; }
    char tmp[8];
    while (*s) {
        if (*s == '"') {
            ARO__OUT_APPEND(ctx, "\\\"");
        } else if (*s == '\\') {
            ARO__OUT_APPEND(ctx, "\\\\");
        } else if (*s == '\n') {
            ARO__OUT_APPEND(ctx, "\\n");
        } else if (*s == '\r') {
            ARO__OUT_APPEND(ctx, "\\r");
        } else if (*s == '\t') {
            ARO__OUT_APPEND(ctx, "\\t");
        } else if ((unsigned char)*s < 0x20) {
            snprintf(tmp, sizeof(tmp), "\\u%04x", (unsigned char)*s);
            ARO__OUT_APPEND(ctx, tmp);
        } else {
            tmp[0] = *s; tmp[1] = '\0';
            ARO__OUT_APPEND(ctx, tmp);
        }
        s++;
    }
}

static void aro__output_comma_if_needed(aro_ctx* ctx) {
    if (ctx->out_has_keys) ARO__OUT_APPEND(ctx, ",");
    ctx->out_has_keys = 1;
}

static void aro__output_key(aro_ctx* ctx, const char* key) {
    aro__output_comma_if_needed(ctx);
    ARO__OUT_APPEND(ctx, "\"");
    aro__append_escaped(ctx, key);
    ARO__OUT_APPEND(ctx, "\":");
}

void aro_output_string(aro_ctx* ctx, const char* key, const char* val) {
    aro__output_key(ctx, key);
    ARO__OUT_APPEND(ctx, "\"");
    aro__append_escaped(ctx, val);
    ARO__OUT_APPEND(ctx, "\"");
}

void aro_output_int(aro_ctx* ctx, const char* key, int64_t val) {
    char tmp[32];
    snprintf(tmp, sizeof(tmp), "%" PRId64, val);
    aro__output_key(ctx, key);
    ARO__OUT_APPEND(ctx, tmp);
}

void aro_output_double(aro_ctx* ctx, const char* key, double val) {
    char tmp[64];
    snprintf(tmp, sizeof(tmp), "%.17g", val);
    aro__output_key(ctx, key);
    ARO__OUT_APPEND(ctx, tmp);
}

void aro_output_bool(aro_ctx* ctx, const char* key, int val) {
    aro__output_key(ctx, key);
    ARO__OUT_APPEND(ctx, val ? "true" : "false");
}

void aro_output_string_array(aro_ctx* ctx, const char* key,
                              const char** items, size_t count) {
    aro__output_key(ctx, key);
    ARO__OUT_APPEND(ctx, "[");
    for (size_t i = 0; i < count; i++) {
        if (i > 0) ARO__OUT_APPEND(ctx, ",");
        ARO__OUT_APPEND(ctx, "\"");
        aro__append_escaped(ctx, items[i]);
        ARO__OUT_APPEND(ctx, "\"");
    }
    ARO__OUT_APPEND(ctx, "]");
}

/* =========================================================================
 * RESULT BUILDERS
 * ========================================================================= */

const char* aro_ok(aro_ctx* ctx) {
    size_t total = ctx->out_len + 3; /* { + } + NUL */
    if (!aro__ret_ensure(ctx, total)) return "{\"error\":\"out of memory\"}";

    ctx->ret_buf[0] = '{';
    memcpy(ctx->ret_buf + 1, ctx->out_buf, ctx->out_len);
    ctx->ret_buf[1 + ctx->out_len]     = '}';
    ctx->ret_buf[1 + ctx->out_len + 1] = '\0';
    return ctx->ret_buf;
}

const char* aro_error(aro_ctx* ctx, int code, const char* fmt, ...) {
    char msg[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);

    char raw[2048];
    int raw_len = snprintf(raw, sizeof(raw),
                           "{\"error_code\":%d,\"error\":\"", code);
    if (raw_len < 0 || (size_t)raw_len >= sizeof(raw))
        return "{\"error_code\":8}";

    /* Append escaped message */
    const char* s = msg;
    while (*s && (size_t)raw_len + 10 < sizeof(raw)) {
        if (*s == '"')       { raw[raw_len++] = '\\'; raw[raw_len++] = '"';  }
        else if (*s == '\\') { raw[raw_len++] = '\\'; raw[raw_len++] = '\\'; }
        else if (*s == '\n') { raw[raw_len++] = '\\'; raw[raw_len++] = 'n';  }
        else                 { raw[raw_len++] = *s; }
        s++;
    }
    raw[raw_len++] = '"';
    raw[raw_len++] = '}';
    raw[raw_len]   = '\0';

    if (!aro__ret_ensure(ctx, (size_t)raw_len + 1))
        return "{\"error_code\":8}";
    memcpy(ctx->ret_buf, raw, (size_t)raw_len + 1);
    return ctx->ret_buf;
}

/* =========================================================================
 * QUALIFIER HELPERS
 * ========================================================================= */

const char* aro_qualifier_string(aro_ctx* ctx) {
    if (!ctx) return NULL;
    return aro__value_as_string(aro__obj_get(&ctx->input_root, "value"));
}

aro_array* aro_qualifier_array(aro_ctx* ctx) {
    if (!ctx) return NULL;
    const aro__json_value* v = aro__obj_get(&ctx->input_root, "value");
    if (!v || v->type != ARO__JSON_ARRAY) return NULL;
    return (aro_array*)(uintptr_t)v;
}

int64_t aro_qualifier_int(aro_ctx* ctx) {
    if (!ctx) return 0;
    const aro__json_value* v = aro__obj_get(&ctx->input_root, "value");
    if (!v) return 0;
    if (v->type == ARO__JSON_INT)    return v->v.i;
    if (v->type == ARO__JSON_DOUBLE) return (int64_t)v->v.d;
    return 0;
}

static const char* aro__qual_result_raw(aro_ctx* ctx, const char* json_val) {
    size_t need = strlen(json_val) + 16;
    if (!aro__ret_ensure(ctx, need)) return "{\"error\":\"oom\"}";
    snprintf(ctx->ret_buf, ctx->ret_cap, "{\"result\":%s}", json_val);
    return ctx->ret_buf;
}

const char* aro_qualifier_result_string(aro_ctx* ctx, const char* val) {
    if (!val) return aro__qual_result_raw(ctx, "null");
    char tmp[ARO_OUTPUT_BUF];
    size_t pos = 0;
    tmp[pos++] = '"';
    for (const char* s = val; *s && pos + 10 < sizeof(tmp); s++) {
        if (*s == '"')       { tmp[pos++] = '\\'; tmp[pos++] = '"';  }
        else if (*s == '\\') { tmp[pos++] = '\\'; tmp[pos++] = '\\'; }
        else if (*s == '\n') { tmp[pos++] = '\\'; tmp[pos++] = 'n';  }
        else                 { tmp[pos++] = (char)*s; }
    }
    tmp[pos++] = '"';
    tmp[pos]   = '\0';
    return aro__qual_result_raw(ctx, tmp);
}

const char* aro_qualifier_result_int(aro_ctx* ctx, int64_t val) {
    char tmp[32];
    snprintf(tmp, sizeof(tmp), "%" PRId64, val);
    return aro__qual_result_raw(ctx, tmp);
}

const char* aro_qualifier_result_array(aro_ctx* ctx, aro_array* val) {
    if (!val) return aro__qual_result_raw(ctx, "[]");

    const aro__json_value* v = (const aro__json_value*)(uintptr_t)val;
    if (v->type != ARO__JSON_ARRAY) return aro__qual_result_raw(ctx, "[]");

    char* buf = (char*)malloc(ARO_OUTPUT_BUF);
    if (!buf) return aro__qual_result_raw(ctx, "[]");

    size_t pos = 0;
    buf[pos++] = '[';
    for (size_t i = 0; i < v->v.arr.count; i++) {
        if (i > 0 && pos + 2 < ARO_OUTPUT_BUF) buf[pos++] = ',';
        const aro__json_value* el = &v->v.arr.items[i];
        char tmp[256];
        if (el->type == ARO__JSON_STRING) {
            snprintf(tmp, sizeof(tmp), "\"%s\"", el->v.s ? el->v.s : "");
        } else if (el->type == ARO__JSON_INT) {
            snprintf(tmp, sizeof(tmp), "%" PRId64, el->v.i);
        } else if (el->type == ARO__JSON_DOUBLE) {
            snprintf(tmp, sizeof(tmp), "%.17g", el->v.d);
        } else if (el->type == ARO__JSON_BOOL) {
            snprintf(tmp, sizeof(tmp), "%s", el->v.b ? "true" : "false");
        } else {
            snprintf(tmp, sizeof(tmp), "null");
        }
        size_t tl = strlen(tmp);
        if (pos + tl + 4 < ARO_OUTPUT_BUF) {
            memcpy(buf + pos, tmp, tl);
            pos += tl;
        }
    }
    if (pos + 2 < ARO_OUTPUT_BUF) buf[pos++] = ']';
    buf[pos] = '\0';

    const char* result = aro__qual_result_raw(ctx, buf);
    free(buf);
    return result;
}

int64_t aro_qualifier_param_int(aro_ctx* ctx, const char* key, int64_t def) {
    return aro_with_int(ctx, key, def);
}

const char* aro_qualifier_param_string(aro_ctx* ctx, const char* key,
                                        const char* def) {
    return aro_with_string(ctx, key, def);
}

/* =========================================================================
 * INFO STRING BUILDER
 * =========================================================================
 * Builds the JSON returned by aro_plugin_info():
 *
 * {
 *   "name": "...",
 *   "version": "...",
 *   "language": "c",
 *   "handle": "...",
 *   "actions": [
 *     { "name": "Greet", "verbs": ["Handle.Greet","greet"],
 *       "role": "own", "prepositions": ["with"] }
 *   ],
 *   "qualifiers": [
 *     { "name": "reverse", "inputTypes": ["List","String"],
 *       "description": "...", "accepts_parameters": false }
 *   ],
 *   "system_objects": [...]
 * }
 * ========================================================================= */

typedef struct {
    char*  buf;
    size_t cap;
    size_t len;
} aro__sb;

static void aro__sb_init(aro__sb* sb) {
    sb->buf = (char*)malloc(4096);
    sb->cap = sb->buf ? 4096 : 0;
    sb->len = 0;
    if (sb->buf) sb->buf[0] = '\0';
}

static void aro__sb_grow(aro__sb* sb, size_t need) {
    if (sb->len + need + 1 <= sb->cap) return;
    size_t new_cap = (sb->cap + need + 1) * 2;
    char* nb = (char*)realloc(sb->buf, new_cap);
    if (nb) { sb->buf = nb; sb->cap = new_cap; }
}

static void aro__sb_append(aro__sb* sb, const char* s) {
    size_t n = strlen(s);
    aro__sb_grow(sb, n);
    if (sb->len + n + 1 <= sb->cap) {
        memcpy(sb->buf + sb->len, s, n + 1);
        sb->len += n;
    }
}

static void aro__sb_append_escaped(aro__sb* sb, const char* s) {
    if (!s) { aro__sb_append(sb, "null"); return; }
    aro__sb_append(sb, "\"");
    for (; *s; s++) {
        char tmp[4] = { '\\', '\0', '\0', '\0' };
        if (*s == '"')       { tmp[1] = '"';  aro__sb_append(sb, tmp); }
        else if (*s == '\\') { tmp[1] = '\\'; aro__sb_append(sb, tmp); }
        else if (*s == '\n') { tmp[1] = 'n';  aro__sb_append(sb, tmp); }
        else { char c[2] = { *s, '\0' }; aro__sb_append(sb, c); }
    }
    aro__sb_append(sb, "\"");
}

static void aro__sb_append_csv_as_array(aro__sb* sb, const char* csv) {
    aro__sb_append(sb, "[");
    if (csv && *csv) {
        char buf[1024];
        strncpy(buf, csv, sizeof(buf) - 1);
        buf[sizeof(buf) - 1] = '\0';

        int first = 1;
        char* tok = strtok(buf, ",");
        while (tok) {
            while (*tok == ' ') tok++;
            char* end = tok + strlen(tok) - 1;
            while (end > tok && *end == ' ') *end-- = '\0';

            if (!first) aro__sb_append(sb, ",");
            aro__sb_append_escaped(sb, tok);
            first = 0;
            tok = strtok(NULL, ",");
        }
    }
    aro__sb_append(sb, "]");
}

static char* aro__build_info_json(void) {
    aro__sb sb;
    aro__sb_init(&sb);
    if (!sb.buf) return NULL;

    const char* handle = aro__plugin_handle ? aro__plugin_handle
                                             : aro__plugin_name;

    aro__sb_append(&sb, "{");
    aro__sb_append(&sb, "\"name\":");
    aro__sb_append_escaped(&sb, aro__plugin_name);
    aro__sb_append(&sb, ",\"version\":");
    aro__sb_append_escaped(&sb, aro__plugin_version);
    aro__sb_append(&sb, ",\"language\":\"c\"");
    aro__sb_append(&sb, ",\"handle\":");
    aro__sb_append_escaped(&sb, handle);

    /* Actions */
    aro__sb_append(&sb, ",\"actions\":[");
    for (int i = 0; i < aro__action_count; i++) {
        if (i > 0) aro__sb_append(&sb, ",");
        aro__action_entry* e = aro__action_table[i];

        aro__sb_append(&sb, "{\"name\":");
        aro__sb_append_escaped(&sb, e->name);

        /* verbs: ["Handle.Name", "lowercase-name"] */
        aro__sb_append(&sb, ",\"verbs\":[");
        char namespaced[256];
        snprintf(namespaced, sizeof(namespaced), "%s.%s", handle, e->name);
        aro__sb_append_escaped(&sb, namespaced);

        char lower[256];
        strncpy(lower, e->name, sizeof(lower) - 1);
        lower[sizeof(lower) - 1] = '\0';
        for (char* p = lower; *p; p++) {
            if (*p >= 'A' && *p <= 'Z') *p = (char)(*p + 32);
        }
        aro__sb_append(&sb, ",");
        aro__sb_append_escaped(&sb, lower);
        aro__sb_append(&sb, "]");

        aro__sb_append(&sb, ",\"role\":");
        aro__sb_append_escaped(&sb, e->role);
        aro__sb_append(&sb, ",\"prepositions\":");
        aro__sb_append_csv_as_array(&sb, e->prepositions);
        aro__sb_append(&sb, "}");
    }
    aro__sb_append(&sb, "]");

    /* Qualifiers */
    aro__sb_append(&sb, ",\"qualifiers\":[");
    for (int i = 0; i < aro__qualifier_count; i++) {
        if (i > 0) aro__sb_append(&sb, ",");
        aro__qualifier_entry* e = aro__qualifier_table[i];

        aro__sb_append(&sb, "{\"name\":");
        aro__sb_append_escaped(&sb, e->name);
        aro__sb_append(&sb, ",\"inputTypes\":");
        aro__sb_append_csv_as_array(&sb, e->input_types);
        aro__sb_append(&sb, ",\"description\":");
        aro__sb_append_escaped(&sb, e->description);
        aro__sb_append(&sb, ",\"accepts_parameters\":");
        aro__sb_append(&sb, e->accepts_parameters ? "true" : "false");
        aro__sb_append(&sb, "}");
    }
    aro__sb_append(&sb, "]");

    /* System objects */
    aro__sb_append(&sb, ",\"system_objects\":[");
    for (int i = 0; i < aro__sysobj_count; i++) {
        if (i > 0) aro__sb_append(&sb, ",");
        aro__sysobj_entry* e = aro__sysobj_table[i];

        aro__sb_append(&sb, "{\"name\":");
        aro__sb_append_escaped(&sb, e->name);
        aro__sb_append(&sb, ",\"capabilities\":");
        aro__sb_append_csv_as_array(&sb, e->capabilities);
        aro__sb_append(&sb, "}");
    }
    aro__sb_append(&sb, "]");

    aro__sb_append(&sb, "}");
    return sb.buf; /* caller must free via aro_plugin_free() */
}

/* =========================================================================
 * AUTO-GENERATED ABI ENTRY POINTS
 * =========================================================================
 * These four functions are the only symbols the ARO runtime looks for.
 * They are generated once by the SDK and delegate to the registration tables.
 * ========================================================================= */

ARO_API char* aro_plugin_info(void) {
    return aro__build_info_json();
}

ARO_API char* aro_plugin_execute(const char* action, const char* input_json) {
    if (!action || !input_json) return NULL;

    aro_ctx* ctx = aro__ctx_create(input_json, 0);
    if (!ctx) return NULL;

    const char* result = NULL;
    const char* handle = aro__plugin_handle ? aro__plugin_handle
                                             : aro__plugin_name;

    for (int i = 0; i < aro__action_count; i++) {
        aro__action_entry* e = aro__action_table[i];

        /* Build namespaced and lowercased verb variants */
        char namespaced[256];
        snprintf(namespaced, sizeof(namespaced), "%s.%s", handle, e->name);

        char lower[256];
        strncpy(lower, e->name, sizeof(lower) - 1);
        lower[sizeof(lower) - 1] = '\0';
        for (char* p = lower; *p; p++) {
            if (*p >= 'A' && *p <= 'Z') *p = (char)(*p + 32);
        }

        if (strcmp(action, e->name)    == 0 ||
            strcmp(action, namespaced) == 0 ||
            strcmp(action, lower)      == 0)
        {
            result = e->handler(ctx);
            break;
        }
    }

    if (!result) {
        char* err = (char*)malloc(256);
        if (err) {
            snprintf(err, 256,
                     "{\"error_code\":%d,\"error\":\"Unknown action: %s\"}",
                     ARO_ERR_UNSUPPORTED, action);
        }
        aro__ctx_destroy(ctx);
        return err;
    }

    /* Transfer ownership of ret_buf out of ctx */
    char* owned = ctx->ret_buf;
    ctx->ret_buf = NULL;
    aro__ctx_destroy(ctx);

    if (!owned) {
        /* result points into static/arena memory; copy to heap */
        size_t n = strlen(result) + 1;
        owned = (char*)malloc(n);
        if (owned) memcpy(owned, result, n);
    }
    return owned;
}

ARO_API char* aro_plugin_qualifier(const char* qualifier,
                                   const char* input_json) {
    if (!qualifier || !input_json) return NULL;

    aro_ctx* ctx = aro__ctx_create(input_json, 1);
    if (!ctx) return NULL;

    const char* result = NULL;
    for (int i = 0; i < aro__qualifier_count; i++) {
        aro__qualifier_entry* e = aro__qualifier_table[i];
        if (strcmp(qualifier, e->name) == 0) {
            result = e->handler(ctx);
            break;
        }
    }

    if (!result) {
        char* err = (char*)malloc(256);
        if (err) {
            snprintf(err, 256,
                     "{\"error\":\"Unknown qualifier: %s\"}", qualifier);
        }
        aro__ctx_destroy(ctx);
        return err;
    }

    char* owned = ctx->ret_buf;
    ctx->ret_buf = NULL;
    aro__ctx_destroy(ctx);

    if (!owned) {
        size_t n = strlen(result) + 1;
        owned = (char*)malloc(n);
        if (owned) memcpy(owned, result, n);
    }
    return owned;
}

ARO_API void aro_plugin_free(char* ptr) {
    free(ptr);
}

/*
 * aro_plugin_init and aro_plugin_shutdown are OPTIONAL symbols.
 * The ARO runtime resolves them with dlsym and skips the call when they
 * are absent.  Plugins only need to define them via ARO_INIT() /
 * ARO_SHUTDOWN() when they have actual setup / teardown work to do.
 *
 * No default implementations are provided here: if the user omits
 * ARO_INIT() / ARO_SHUTDOWN(), the symbols simply will not be exported
 * and the runtime handles that gracefully.
 */

#endif /* ARO_PLUGIN_SDK_IMPLEMENTATION */

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ARO_PLUGIN_SDK_H */
