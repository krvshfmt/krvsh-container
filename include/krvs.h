/* krvs — codec-agnostic container C ABI.
 *
 * Hand-written to match src/c_api.zig. A C smoke test (test/capi_smoke.c) includes this
 * header and links the static library; it runs under `zig build test` so header/ABI
 * drift is caught.
 *
 * Conventions:
 *   - All buffers are caller-owned. Nothing the library allocates crosses the boundary.
 *   - Write functions use a two-call size/fill protocol: call with out=NULL (or a cap
 *     smaller than needed) to get the required size in *written and KRVS_BUFFER_TOO_SMALL,
 *     then call again with a buffer of that size.
 *   - Parse functions fill a view struct whose pointers BORROW the input buffer.
 */
#ifndef KRVS_H
#define KRVS_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    KRVS_OK = 0,
    KRVS_BUFFER_TOO_SMALL = 1,
    KRVS_SHORT_BUFFER = 2,
    KRVS_BAD_BOX = 3,
    KRVS_BAD_CHILD = 4,
    KRVS_MISSING_CHILD = 5,
    KRVS_UNSUPPORTED_VERSION = 6,
    KRVS_RESERVED_PREV_FRAME = 7,
    KRVS_INIT_NOT_RESOLVED = 8,
    KRVS_ID_TOO_LONG = 9,
    KRVS_BAD_SIZE = 10,
    KRVS_INTERNAL = 255
} krvs_status_t;

/* Hash-algo codes for the opaque init id (the container does not compute the hash). */
#define KRVS_HASH_SHA256_T16 1
#define KRVS_MAX_ID_LEN 32

/* ---- marker ---- */
krvs_status_t krvs_write_marker(uint8_t *out, size_t out_cap, size_t *written);
krvs_status_t krvs_parse_marker(const uint8_t *buf, size_t len, size_t *consumed);

/* ---- cnit (codec-init record) ---- */
krvs_status_t krvs_write_cnit(const uint8_t *codec_fourcc, /* 4 bytes */
                              uint32_t codec_version,
                              uint8_t hash_algo,
                              const uint8_t *init_id, size_t id_len,
                              const uint8_t *cpay, size_t cpay_len,
                              uint8_t *out, size_t out_cap, size_t *written);

typedef struct {
    uint8_t codec_fourcc[4];
    uint32_t codec_version;
    uint8_t hash_algo;
    const uint8_t *init_id; /* borrows input */
    size_t id_len;
    const uint8_t *cpay;    /* borrows input */
    size_t cpay_len;
    size_t total_size;
} krvs_cnit_view_t;

krvs_status_t krvs_parse_cnit(const uint8_t *buf, size_t len, krvs_cnit_view_t *view);

/* ---- kfrm (frame record) ---- */
krvs_status_t krvs_write_kfrm(uint8_t hash_algo,
                              const uint8_t *init_id, size_t id_len,
                              uint64_t frame_id, uint64_t prev_frame_id,
                              const uint8_t *fpay, size_t fpay_len,
                              uint8_t *out, size_t out_cap, size_t *written);

typedef struct {
    uint8_t hash_algo;
    const uint8_t *init_id; /* borrows input */
    size_t id_len;
    uint64_t frame_id;
    uint64_t prev_frame_id;
    const uint8_t *fpay;    /* borrows input */
    size_t fpay_len;
    size_t total_size;
} krvs_kfrm_view_t;

krvs_status_t krvs_parse_kfrm(const uint8_t *buf, size_t len, krvs_kfrm_view_t *view);

/* ---- misc ---- */
uint8_t krvs_container_version(void);

#ifdef __cplusplus
}
#endif

#endif /* KRVS_H */
