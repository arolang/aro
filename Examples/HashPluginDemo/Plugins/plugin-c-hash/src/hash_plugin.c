/**
 * ARO Plugin - C Hash Functions
 *
 * Provides djb2, fnv1a, and simple polynomial hash functions for ARO,
 * written using the ARO C Plugin SDK macro syntax.
 *
 * SDK docs: https://github.com/arolang/aro-plugin-sdk-c
 */

#define ARO_PLUGIN_SDK_IMPLEMENTATION
#include "aro_plugin_sdk.h"

#include <stdint.h>

/* ── Plugin identity ───────────────────────────────────────────────────── */

ARO_PLUGIN("plugin-c-hash", "1.0.0")
ARO_HANDLE("Hash")

/* ── Lifecycle ─────────────────────────────────────────────────────────── */

ARO_INIT() {
    /* Nothing to initialise */
}

ARO_SHUTDOWN() {
    /* Nothing to tear down */
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
    uint64_t hash            = 14695981039346656037ULL;
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

/* ── Actions ────────────────────────────────────────────────────────────── */

/*
 * Hash.Hash  —  simple 32-bit polynomial hash
 *
 * ARO usage:
 *   Compute the <hash: Hash.Hash> from the <data>.
 */
ARO_ACTION("Hash", "own", "from,with,for") {
    const char* data = aro_input_string(ctx, "data");
    if (!data) data = aro_input_string(ctx, "source");
    if (!data) data = aro_input_string(ctx, "value");
    if (!data) return aro_error(ctx, ARO_ERR_INVALID_INPUT,
                                "No hashable value found in input");

    uint32_t h = simple_hash(data);
    char buf[32];
    snprintf(buf, sizeof(buf), "%08x", h);
    aro_output_string(ctx, "hash", buf);
    aro_output_string(ctx, "algorithm", "simple");
    aro_output_string(ctx, "input", data);
    return aro_ok(ctx);
}

/*
 * Hash.DJB2  —  64-bit DJB2 hash
 *
 * ARO usage:
 *   Compute the <hash: Hash.DJB2> from the <data>.
 */
ARO_ACTION("DJB2", "own", "from,with,for") {
    const char* data = aro_input_string(ctx, "data");
    if (!data) data = aro_input_string(ctx, "source");
    if (!data) data = aro_input_string(ctx, "value");
    if (!data) return aro_error(ctx, ARO_ERR_INVALID_INPUT,
                                "No hashable value found in input");

    uint64_t h = djb2_hash(data);
    char buf[32];
    snprintf(buf, sizeof(buf), "%016llx", (unsigned long long)h);
    aro_output_string(ctx, "hash", buf);
    aro_output_string(ctx, "algorithm", "djb2");
    aro_output_string(ctx, "input", data);
    return aro_ok(ctx);
}

/*
 * Hash.FNV1a  —  64-bit FNV-1a hash
 *
 * ARO usage:
 *   Compute the <hash: Hash.FNV1a> from the <data>.
 */
ARO_ACTION("FNV1a", "own", "from,with,for") {
    const char* data = aro_input_string(ctx, "data");
    if (!data) data = aro_input_string(ctx, "source");
    if (!data) data = aro_input_string(ctx, "value");
    if (!data) return aro_error(ctx, ARO_ERR_INVALID_INPUT,
                                "No hashable value found in input");

    uint64_t h = fnv1a_hash(data);
    char buf[32];
    snprintf(buf, sizeof(buf), "%016llx", (unsigned long long)h);
    aro_output_string(ctx, "hash", buf);
    aro_output_string(ctx, "algorithm", "fnv1a");
    aro_output_string(ctx, "input", data);
    return aro_ok(ctx);
}
