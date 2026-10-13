#ifndef CEFM_H
#define CEFM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - Directory reading (getattrlistbulk)

enum {
    EFM_TYPE_FILE = 0,
    EFM_TYPE_DIR = 1,
    EFM_TYPE_SYMLINK = 2,
    EFM_TYPE_OTHER = 3,
};

typedef struct {
    uint32_t name_off;   // offset into efm_dirbuf.names
    uint16_t name_len;
    uint8_t type;        // EFM_TYPE_*
    uint8_t reserved;
    uint32_t dev;        // st_dev of the child (mount boundary detection)
    int64_t size;        // data fork length, 0 for non-files
    int64_t mtime;       // seconds since 1970
    int64_t ctime;       // creation time, seconds since 1970
} efm_dirent;

typedef struct {
    efm_dirent *ents;
    size_t count, cap;
    char *names;         // child names, not NUL-terminated, addressed via name_off/name_len
    size_t names_len, names_cap;
    void *attrbuf;       // scratch buffer for getattrlistbulk
    size_t attrbuf_cap;
} efm_dirbuf;

void efm_dirbuf_init(efm_dirbuf *buf);
void efm_dirbuf_free(efm_dirbuf *buf);

/// Reads every child of `path` (excluding "." and "..") into `buf` (which is reset first).
/// Returns 0 on success or an errno value.
int efm_read_dir(const char *path, efm_dirbuf *buf);

/// Stats one path without following symlinks. Returns 0 on success or an errno value.
int efm_stat_path(const char *path, efm_dirent *out);

// MARK: - Name matching

enum {
    EFM_MATCH_SUBSTR = 0,
    EFM_MATCH_PREFIX = 1,
    EFM_MATCH_SUFFIX = 2,
    EFM_MATCH_EXACT = 3,
};

/// `blob` holds names back to back, each followed by a 0 byte; name i spans
/// [offsets[i], offsets[i + 1] - 1). For every name in [lo, hi) that matches `needle`
/// (which must not contain 0 bytes), sets bit i in `out_bits`.
/// Returns the number of matching names, or -1 if `cancel` became non-zero.
int64_t efm_match_names(const uint8_t *blob, const uint32_t *offsets,
                        uint32_t lo, uint32_t hi,
                        const uint8_t *needle, size_t needle_len, int kind,
                        uint64_t *out_bits, const volatile int32_t *cancel);

/// Sets bit e in `out_bits` for every entry e in [lo, hi) whose name bit is set and whose
/// flags pass (flags & flag_mask) == flag_value. Returns the number of set bits.
int64_t efm_entries_from_names(const uint32_t *name_ids, const uint8_t *flags,
                               uint32_t lo, uint32_t hi,
                               const uint64_t *name_bits,
                               uint8_t flag_mask, uint8_t flag_value,
                               uint64_t *out_bits);

#ifdef __cplusplus
}
#endif

#endif
