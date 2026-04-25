/**
 * ARO Plugin - C Collection Qualifiers
 *
 * Provides first, last, and size qualifiers for lists and strings,
 * written using the ARO C Plugin SDK macro syntax.
 *
 * SDK docs: https://github.com/arolang/aro-plugin-sdk-c
 */

#define ARO_PLUGIN_SDK_IMPLEMENTATION
#include "aro_plugin_sdk.h"

/* ── Plugin identity ───────────────────────────────────────────────────── */

ARO_PLUGIN("plugin-c-collection", "1.0.0")
ARO_HANDLE("List")

/* ── Lifecycle ─────────────────────────────────────────────────────────── */

ARO_INIT() {
    /* Nothing to initialise */
}

ARO_SHUTDOWN() {
    /* Nothing to tear down */
}

/* ── Qualifiers ─────────────────────────────────────────────────────────── */

/*
 * List.first  —  returns the first element of a list
 *
 * ARO usage:
 *   Compute the <item: List.first> from the <items>.
 */
ARO_QUALIFIER("first", "List", "Returns the first element of a list") {
    aro_array* arr = aro_qualifier_array(ctx);
    if (!arr || aro_array_length(arr) == 0)
        return aro_error(ctx, ARO_ERR_INVALID_INPUT,
                         "first requires a non-empty list");

    const char* elem = aro_array_string(arr, 0);
    if (elem)
        return aro_qualifier_result_string(ctx, elem);

    /* Numeric element: fall back to integer representation */
    int64_t n = aro_array_int(arr, 0);
    return aro_qualifier_result_int(ctx, n);
}

/*
 * List.last  —  returns the last element of a list
 *
 * ARO usage:
 *   Compute the <item: List.last> from the <items>.
 */
ARO_QUALIFIER("last", "List", "Returns the last element of a list") {
    aro_array* arr = aro_qualifier_array(ctx);
    if (!arr || aro_array_length(arr) == 0)
        return aro_error(ctx, ARO_ERR_INVALID_INPUT,
                         "last requires a non-empty list");

    size_t idx = aro_array_length(arr) - 1;
    const char* elem = aro_array_string(arr, idx);
    if (elem)
        return aro_qualifier_result_string(ctx, elem);

    int64_t n = aro_array_int(arr, idx);
    return aro_qualifier_result_int(ctx, n);
}

/*
 * List.size  —  returns the number of elements in a list, or characters in a string
 *
 * ARO usage:
 *   Compute the <count: List.size> from the <items>.
 *   Compute the <len: List.size> from the <text>.
 */
ARO_QUALIFIER("size", "List,String", "Returns the size/length of a list or string") {
    /* Try list first */
    aro_array* arr = aro_qualifier_array(ctx);
    if (arr)
        return aro_qualifier_result_int(ctx, (int64_t)aro_array_length(arr));

    /* Fall back to string length */
    const char* str = aro_qualifier_string(ctx);
    if (str)
        return aro_qualifier_result_int(ctx, (int64_t)strlen(str));

    return aro_error(ctx, ARO_ERR_INVALID_INPUT, "size requires a List or String");
}
