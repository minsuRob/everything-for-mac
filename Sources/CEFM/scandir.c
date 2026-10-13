#include "CEFM.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/stat.h>
#include <sys/vnode.h>
#include <unistd.h>

void efm_dirbuf_init(efm_dirbuf *buf) {
    memset(buf, 0, sizeof(*buf));
}

void efm_dirbuf_free(efm_dirbuf *buf) {
    free(buf->ents);
    free(buf->names);
    free(buf->attrbuf);
    memset(buf, 0, sizeof(*buf));
}

static int push_entry(efm_dirbuf *buf, const char *name, size_t len, const efm_dirent *proto) {
    if (buf->count == buf->cap) {
        size_t cap = buf->cap ? buf->cap * 2 : 64;
        efm_dirent *ents = realloc(buf->ents, cap * sizeof(efm_dirent));
        if (!ents) return ENOMEM;
        buf->ents = ents;
        buf->cap = cap;
    }
    if (buf->names_len + len > buf->names_cap) {
        size_t cap = buf->names_cap ? buf->names_cap * 2 : 2048;
        while (cap < buf->names_len + len) cap *= 2;
        char *names = realloc(buf->names, cap);
        if (!names) return ENOMEM;
        buf->names = names;
        buf->names_cap = cap;
    }
    if (len > UINT16_MAX) len = UINT16_MAX;
    memcpy(buf->names + buf->names_len, name, len);
    efm_dirent *e = &buf->ents[buf->count++];
    *e = *proto;
    e->name_off = (uint32_t)buf->names_len;
    e->name_len = (uint16_t)len;
    buf->names_len += len;
    return 0;
}

static uint8_t map_type(uint32_t objtype) {
    switch (objtype) {
        case VREG: return EFM_TYPE_FILE;
        case VDIR: return EFM_TYPE_DIR;
        case VLNK: return EFM_TYPE_SYMLINK;
        default: return EFM_TYPE_OTHER;
    }
}

// Attribute layout returned by getattrlistbulk with FSOPT_PACK_INVAL_ATTRS (fixed order by bit value):
//   u32 length, attribute_set_t returned, attrreference_t name, dev_t devid, fsobj_type_t objtype,
//   timespec crtime, timespec modtime, off_t datalength
int efm_read_dir(const char *path, efm_dirbuf *buf) {
    buf->count = 0;
    buf->names_len = 0;

    int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return errno;

    if (!buf->attrbuf) {
        buf->attrbuf_cap = 256 * 1024;
        buf->attrbuf = malloc(buf->attrbuf_cap);
        if (!buf->attrbuf) {
            close(fd);
            return ENOMEM;
        }
    }

    struct attrlist al;
    memset(&al, 0, sizeof(al));
    al.bitmapcount = ATTR_BIT_MAP_COUNT;
    al.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE |
                    ATTR_CMN_CRTIME | ATTR_CMN_MODTIME;
    al.fileattr = ATTR_FILE_DATALENGTH;

    int err = 0;
    for (;;) {
        int n = getattrlistbulk(fd, &al, buf->attrbuf, buf->attrbuf_cap, FSOPT_PACK_INVAL_ATTRS);
        if (n < 0) {
            err = errno;
            break;
        }
        if (n == 0) break;
        char *p = buf->attrbuf;
        for (int i = 0; i < n; i++) {
            char *entry = p;
            uint32_t length = *(uint32_t *)p;
            p += sizeof(uint32_t);
            attribute_set_t returned = *(attribute_set_t *)p;
            p += sizeof(attribute_set_t);
            attrreference_t nameref = *(attrreference_t *)p;
            char *name = p + nameref.attr_dataoffset;
            p += sizeof(attrreference_t);
            dev_t dev = *(dev_t *)p;
            p += sizeof(dev_t);
            fsobj_type_t objtype = *(fsobj_type_t *)p;
            p += sizeof(fsobj_type_t);
            struct timespec crtime = *(struct timespec *)p;
            p += sizeof(struct timespec);
            struct timespec modtime = *(struct timespec *)p;
            p += sizeof(struct timespec);
            off_t datalen = *(off_t *)p;

            size_t namelen = nameref.attr_length > 0 ? nameref.attr_length - 1 : 0; // drop NUL
            efm_dirent proto = {0};
            proto.type = map_type(objtype);
            proto.dev = (uint32_t)dev;
            proto.ctime = crtime.tv_sec;
            proto.mtime = modtime.tv_sec;
            proto.size = (proto.type == EFM_TYPE_FILE && (returned.fileattr & ATTR_FILE_DATALENGTH)) ? datalen : 0;
            if (namelen > 0 && (returned.commonattr & ATTR_CMN_NAME)) {
                int perr = push_entry(buf, name, namelen, &proto);
                if (perr) {
                    close(fd);
                    return perr;
                }
            }
            p = entry + length;
        }
    }
    close(fd);
    return err;
}

int efm_stat_path(const char *path, efm_dirent *out) {
    struct stat st;
    if (lstat(path, &st) != 0) return errno;
    memset(out, 0, sizeof(*out));
    if (S_ISREG(st.st_mode)) out->type = EFM_TYPE_FILE;
    else if (S_ISDIR(st.st_mode)) out->type = EFM_TYPE_DIR;
    else if (S_ISLNK(st.st_mode)) out->type = EFM_TYPE_SYMLINK;
    else out->type = EFM_TYPE_OTHER;
    out->dev = (uint32_t)st.st_dev;
    out->size = out->type == EFM_TYPE_FILE ? st.st_size : 0;
    out->mtime = st.st_mtimespec.tv_sec;
    out->ctime = st.st_birthtimespec.tv_sec;
    return 0;
}
