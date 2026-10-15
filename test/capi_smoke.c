/* C smoke test for the krvs container C ABI. Builds against include/krvs.h and the
 * static lib; exercised by `zig build test`. Catches header/ABI drift. */
#include "krvs.h"
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

static int fail(const char *msg) {
    fprintf(stderr, "capi_smoke FAIL: %s\n", msg);
    return 1;
}

int main(void) {
    /* marker roundtrip with two-call size protocol */
    size_t need = 0;
    if (krvs_write_marker(NULL, 0, &need) != KRVS_BUFFER_TOO_SMALL) return fail("marker size query");
    uint8_t *marker = (uint8_t *)malloc(need);
    size_t wrote = 0;
    if (krvs_write_marker(marker, need, &wrote) != KRVS_OK || wrote != need) return fail("marker write");
    size_t consumed = 0;
    if (krvs_parse_marker(marker, wrote, &consumed) != KRVS_OK || consumed != wrote) return fail("marker parse");

    /* cnit roundtrip */
    const uint8_t fourcc[4] = {'t','s','t','0'};
    uint8_t id[16];
    for (int i = 0; i < 16; i++) id[i] = (uint8_t)(0xA0 + i);
    const char *cpay = "opaque-codec-init-bytes";
    size_t cpay_len = strlen(cpay);

    need = 0;
    krvs_write_cnit(fourcc, 7, KRVS_HASH_SHA256_T16, id, 16,
                    (const uint8_t *)cpay, cpay_len, NULL, 0, &need);
    uint8_t *cnit = (uint8_t *)malloc(need);
    if (krvs_write_cnit(fourcc, 7, KRVS_HASH_SHA256_T16, id, 16,
                        (const uint8_t *)cpay, cpay_len, cnit, need, &wrote) != KRVS_OK)
        return fail("cnit write");

    krvs_cnit_view_t cv;
    if (krvs_parse_cnit(cnit, wrote, &cv) != KRVS_OK) return fail("cnit parse");
    if (memcmp(cv.codec_fourcc, fourcc, 4) != 0) return fail("cnit fourcc");
    if (cv.codec_version != 7) return fail("cnit version");
    if (cv.id_len != 16 || memcmp(cv.init_id, id, 16) != 0) return fail("cnit id");
    if (cv.cpay_len != cpay_len || memcmp(cv.cpay, cpay, cpay_len) != 0) return fail("cnit cpay");

    /* kfrm roundtrip */
    const char *fpay = "opaque-frame-bytes";
    size_t fpay_len = strlen(fpay);
    need = 0;
    krvs_write_kfrm(KRVS_HASH_SHA256_T16, id, 16, 42, 0,
                    (const uint8_t *)fpay, fpay_len, NULL, 0, &need);
    uint8_t *kfrm = (uint8_t *)malloc(need);
    if (krvs_write_kfrm(KRVS_HASH_SHA256_T16, id, 16, 42, 0,
                        (const uint8_t *)fpay, fpay_len, kfrm, need, &wrote) != KRVS_OK)
        return fail("kfrm write");
    krvs_kfrm_view_t kv;
    if (krvs_parse_kfrm(kfrm, wrote, &kv) != KRVS_OK) return fail("kfrm parse");
    if (kv.frame_id != 42) return fail("kfrm frame_id");
    if (kv.fpay_len != fpay_len || memcmp(kv.fpay, fpay, fpay_len) != 0) return fail("kfrm fpay");

    /* reserved prev_frame_id must be rejected */
    krvs_write_kfrm(KRVS_HASH_SHA256_T16, id, 16, 1, 7,
                    (const uint8_t *)"x", 1, NULL, 0, &need);
    uint8_t *bad = (uint8_t *)malloc(need);
    krvs_write_kfrm(KRVS_HASH_SHA256_T16, id, 16, 1, 7, (const uint8_t *)"x", 1, bad, need, &wrote);
    krvs_kfrm_view_t kv2;
    if (krvs_parse_kfrm(bad, wrote, &kv2) != KRVS_RESERVED_PREV_FRAME) return fail("prev_frame reject");

    if (krvs_container_version() != 1) return fail("version");

    free(marker); free(cnit); free(kfrm); free(bad);
    printf("capi_smoke OK\n");
    return 0;
}
