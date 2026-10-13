#include "CEFM.h"

#include <string.h>

#if defined(__ARM_NEON) || defined(__ARM_NEON__)
#include <arm_neon.h>
#define EFM_NEON 1
#endif

static inline void set_bit(uint64_t *bits, uint32_t i) {
    bits[i >> 6] |= 1ull << (i & 63);
}

static inline int test_bit(const uint64_t *bits, uint32_t i) {
    return (bits[i >> 6] >> (i & 63)) & 1;
}

// Substring search over the contiguous name blob. Names are separated by 0 bytes and the
// needle has none, so a match never spans two names. Once a name matches we jump to the next
// name, so each byte is examined at most once.
// SIMD filter: compare the first and last needle byte at 16 positions at once
// (W. Muła, "SIMD-friendly algorithms for substring searching").
static int64_t match_substr(const uint8_t *blob, const uint32_t *offsets, uint32_t lo, uint32_t hi,
                            const uint8_t *needle, size_t n, uint64_t *out_bits,
                            const volatile int32_t *cancel) {
    const uint8_t *p = blob + offsets[lo];
    const uint8_t *end = blob + offsets[hi];
    uint32_t cur = lo;
    int64_t count = 0;
    const uint8_t *next_cancel_check = p + (1 << 16);

#define EFM_FOUND(pos)                                                     \
    do {                                                                   \
        uint32_t off_ = (uint32_t)((pos) - blob);                          \
        while (offsets[cur + 1] <= off_) cur++;                            \
        set_bit(out_bits, cur);                                            \
        count++;                                                           \
        p = blob + offsets[cur + 1];                                       \
        goto next;                                                         \
    } while (0)

    while (p + n <= end) {
        if (p >= next_cancel_check) {
            if (cancel && *cancel) return -1;
            next_cancel_check = p + (1 << 16);
        }
#ifdef EFM_NEON
        if (p + n - 1 + 16 <= end) {
            uint8x16_t first = vdupq_n_u8(needle[0]);
            uint8x16_t last = vdupq_n_u8(needle[n - 1]);
            const uint8_t *limit = end - (n - 1) - 16;
            while (p <= limit) {
                uint8x16_t b0 = vld1q_u8(p);
                uint8x16_t b1 = vld1q_u8(p + n - 1);
                uint8x16_t m = vandq_u8(vceqq_u8(b0, first), vceqq_u8(b1, last));
                uint64_t bits = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(m), 4)), 0);
                while (bits) {
                    int k = __builtin_ctzll(bits) >> 2;
                    const uint8_t *cand = p + k;
                    if (n <= 2 || memcmp(cand + 1, needle + 1, n - 2) == 0) EFM_FOUND(cand);
                    bits &= ~(0xFull << (k * 4));
                }
                p += 16;
                if (p >= next_cancel_check) break;
            }
            continue;
        }
#endif
        if (p[0] == needle[0] && memcmp(p, needle, n) == 0) EFM_FOUND(p);
        p++;
    next:;
    }
#undef EFM_FOUND
    return count;
}

int64_t efm_match_names(const uint8_t *blob, const uint32_t *offsets, uint32_t lo, uint32_t hi,
                        const uint8_t *needle, size_t n, int kind, uint64_t *out_bits,
                        const volatile int32_t *cancel) {
    if (lo >= hi) return 0;
    if (n == 0) {
        for (uint32_t i = lo; i < hi; i++) set_bit(out_bits, i);
        return hi - lo;
    }
    if (kind == EFM_MATCH_SUBSTR) return match_substr(blob, offsets, lo, hi, needle, n, out_bits, cancel);

    int64_t count = 0;
    for (uint32_t i = lo; i < hi; i++) {
        if (((i - lo) & 0xFFFF) == 0 && cancel && *cancel) return -1;
        const uint8_t *s = blob + offsets[i];
        size_t len = offsets[i + 1] - offsets[i] - 1;
        if (len < n) continue;
        int ok;
        switch (kind) {
            case EFM_MATCH_PREFIX: ok = memcmp(s, needle, n) == 0; break;
            case EFM_MATCH_SUFFIX: ok = memcmp(s + len - n, needle, n) == 0; break;
            default: ok = len == n && memcmp(s, needle, n) == 0; break;
        }
        if (ok) {
            set_bit(out_bits, i);
            count++;
        }
    }
    return count;
}

int64_t efm_entries_from_names(const uint32_t *name_ids, const uint8_t *flags, uint32_t lo, uint32_t hi,
                               const uint64_t *name_bits, uint8_t flag_mask, uint8_t flag_value,
                               uint64_t *out_bits) {
    // lo is a multiple of 64, so whole output words belong to this call.
    int64_t count = 0;
    for (uint32_t base = lo; base < hi; base += 64) {
        uint32_t stop = base + 64 < hi ? base + 64 : hi;
        uint64_t word = 0;
        for (uint32_t e = base; e < stop; e++) {
            uint64_t ok = ((flags[e] & flag_mask) == flag_value) & (uint64_t)test_bit(name_bits, name_ids[e]);
            word |= ok << (e - base);
        }
        out_bits[base >> 6] = word;
        count += __builtin_popcountll(word);
    }
    return count;
}
