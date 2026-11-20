#ifndef MORPH_ARCHIVE_SHIM_H
#define MORPH_ARCHIVE_SHIM_H

#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>
#include <sys/acl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>

typedef struct archive MorphArchive;
typedef struct archive_entry MorphArchiveEntry;

// Return 1 when an extended ACL exists, 0 when absent/unsupported, and -1
// when the ACL state cannot be inspected safely.
static inline int morph_object_acl_state(int descriptor) {
    acl_t acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED);
    if (acl == NULL) {
        if (errno == ENOENT || errno == EOPNOTSUPP) return 0;
        return -1;
    }
    (void)acl_free(acl);
    return 1;
}

// Bit 0 means an extended allow ACE can add/remove children or change ACLs.
// Bit 1 means an ACL entry can inherit permissions. Return -1 if an existing
// ACL cannot be inspected safely.
static inline int morph_directory_acl_security_flags(int descriptor) {
    acl_t acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED);
    if (acl == NULL) {
        if (errno == ENOENT || errno == EOPNOTSUPP) return 0;
        return -1;
    }
    if (acl_valid(acl) != 0) {
        (void)acl_free(acl);
        return -1;
    }
    int flags = 0;
    acl_entry_t entry;
    int entry_id = ACL_FIRST_ENTRY;
    int entry_status = 0;
    while (1) {
        errno = 0;
        entry_status = acl_get_entry(acl, entry_id, &entry);
        if (entry_status != 0) break;
        entry_id = ACL_NEXT_ENTRY;

        acl_tag_t tag;
        acl_permset_t permissions;
        acl_flagset_t entry_flags;
        if (acl_get_tag_type(entry, &tag) != 0 ||
            acl_get_permset(entry, &permissions) != 0 ||
            acl_get_flagset_np(entry, &entry_flags) != 0) {
            flags = -1;
            break;
        }

        const acl_flag_t inheritance_flags[] = {
            ACL_ENTRY_FILE_INHERIT, ACL_ENTRY_DIRECTORY_INHERIT,
            ACL_ENTRY_LIMIT_INHERIT, ACL_ENTRY_ONLY_INHERIT, ACL_ENTRY_INHERITED
        };
        for (size_t i = 0; i < sizeof(inheritance_flags) / sizeof(inheritance_flags[0]); i++) {
            int inherited = acl_get_flag_np(entry_flags, inheritance_flags[i]);
            if (inherited < 0) {
                flags = -1;
                break;
            }
            if (inherited == 1) flags |= 2;
        }
        if (flags < 0) break;
        if (tag != ACL_EXTENDED_ALLOW) continue;

        const acl_perm_t child_mutation_permissions[] = {
            ACL_ADD_FILE, ACL_ADD_SUBDIRECTORY, ACL_DELETE_CHILD,
            ACL_WRITE_SECURITY, ACL_CHANGE_OWNER
        };
        for (size_t i = 0; i < sizeof(child_mutation_permissions) / sizeof(child_mutation_permissions[0]); i++) {
            int granted = acl_get_perm_np(permissions, child_mutation_permissions[i]);
            if (granted < 0) {
                flags = -1;
                break;
            }
            if (granted == 1) flags |= 1;
        }
        if (flags < 0 || (flags & 1) != 0) break;
    }
    if (entry_status < 0 && errno != EINVAL && flags == 0) flags = -1;
    if (entry_status > 0 && flags == 0) flags = -1;
    (void)acl_free(acl);
    return flags;
}

// Return 1 when an extended ACL grants any write or delete permission. This
// deliberately rejects owner-only grants too: Darwin exposes ACL entries as
// allow/deny ACEs, so Morph errs on the side of refusing custom write ACLs.
// Return -1 if the ACL could not be inspected.
static inline int morph_acl_has_write_grant(int descriptor) {
    acl_t acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED);
    if (acl == NULL) {
        if (errno == ENOENT || errno == EOPNOTSUPP) return 0;
        return -1;
    }
    int unsafe = 0;
    acl_entry_t entry;
    int entry_id = ACL_FIRST_ENTRY;
    if (acl_valid(acl) != 0) {
        (void)acl_free(acl);
        return -1;
    }
    int entry_status = 0;
    while (1) {
        errno = 0;
        entry_status = acl_get_entry(acl, entry_id, &entry);
        if (entry_status != 0) break;
        // Advance before any branch that can continue, so harmless read-only
        // and inherit-only ACEs cannot leave the iterator stuck on one entry.
        entry_id = ACL_NEXT_ENTRY;
        acl_tag_t tag;
        acl_permset_t permissions;
        if (acl_get_tag_type(entry, &tag) != 0 || acl_get_permset(entry, &permissions) != 0) {
            unsafe = -1;
            break;
        }
        acl_flagset_t flags;
        if (acl_get_flagset_np(entry, &flags) != 0) {
            unsafe = -1;
            break;
        }
        if (acl_get_flag_np(flags, ACL_ENTRY_ONLY_INHERIT) == 1) continue;
        const acl_perm_t write_permissions[] = {
            ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE, ACL_DELETE_CHILD,
            ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_ATTRIBUTES, ACL_WRITE_SECURITY,
            ACL_CHANGE_OWNER
        };
        int grants_write = 0;
        for (size_t i = 0; i < sizeof(write_permissions) / sizeof(write_permissions[0]); i++) {
            int permission = acl_get_perm_np(permissions, write_permissions[i]);
            if (permission < 0) {
                unsafe = -1;
                break;
            }
            if (permission == 1) grants_write = 1;
        }
        if (unsafe < 0) break;
        if (!grants_write) continue;
        if (tag == ACL_EXTENDED_ALLOW && grants_write) {
            unsafe = 1;
            break;
        }
    }
    if (entry_status < 0 && errno != EINVAL && unsafe == 0) unsafe = -1;
    if (entry_status > 0 && unsafe == 0) unsafe = -1;
    (void)acl_free(acl);
    return unsafe;
}

// A staging directory is new and owned by Morph, so remove inherited ACLs and
// force a private mode before any conversion engine can create its outputs.
static inline int morph_prepare_private_directory(int descriptor) {
    struct stat info;
    if (fstat(descriptor, &info) != 0 || !S_ISDIR(info.st_mode)) return -1;
    errno = 0;
    acl_t existing = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED);
    if (existing != NULL) {
        (void)acl_free(existing);
        acl_t empty = acl_init(0);
        if (empty == NULL) return -1;
        int set_status = acl_set_fd_np(descriptor, empty, ACL_TYPE_EXTENDED);
        int saved_errno = errno;
        (void)acl_free(empty);
        if (set_status != 0) {
            errno = saved_errno;
            return -1;
        }
    } else if (errno != ENOENT && errno != EOPNOTSUPP) {
        return -1;
    }
    if (fchmod(descriptor, 0700) != 0) return -1;
    if (fstat(descriptor, &info) != 0 || !S_ISDIR(info.st_mode) ||
        (info.st_mode & 0777) != 0700) return -1;
    if (morph_object_acl_state(descriptor) != 0) {
        errno = EPERM;
        return -1;
    }
    return 0;
}

MorphArchive *archive_read_new(void);
int archive_read_support_filter_none(MorphArchive *archive);
int archive_read_support_filter_gzip(MorphArchive *archive);
int archive_read_support_filter_bzip2(MorphArchive *archive);
int archive_read_support_filter_xz(MorphArchive *archive);
int archive_read_support_format_zip(MorphArchive *archive);
int archive_read_support_format_zip_seekable(MorphArchive *archive);
int archive_read_support_format_tar(MorphArchive *archive);
int archive_read_support_format_7zip(MorphArchive *archive);
int archive_read_open_filename(MorphArchive *archive, const char *filename, size_t block_size);
int archive_read_next_header(MorphArchive *archive, MorphArchiveEntry **entry);
ssize_t archive_read_data(MorphArchive *archive, void *buffer, size_t length);
int archive_read_data_skip(MorphArchive *archive);
int archive_read_free(MorphArchive *archive);
const char *archive_error_string(MorphArchive *archive);
const char *archive_filter_name(MorphArchive *archive, int filter_index);

MorphArchive *archive_write_new(void);
int archive_write_add_filter_none(MorphArchive *archive);
int archive_write_add_filter_gzip(MorphArchive *archive);
int archive_write_add_filter_bzip2(MorphArchive *archive);
int archive_write_add_filter_xz(MorphArchive *archive);
int archive_write_set_format_zip(MorphArchive *archive);
int archive_write_set_format_pax_restricted(MorphArchive *archive);
int archive_write_open2(MorphArchive *archive, void *client_data,
                        int (*open_callback)(MorphArchive *, void *),
                        ssize_t (*write_callback)(MorphArchive *, void *, const void *, size_t),
                        int (*close_callback)(MorphArchive *, void *),
                        int (*free_callback)(MorphArchive *, void *));
int archive_write_header(MorphArchive *archive, MorphArchiveEntry *entry);
ssize_t archive_write_data(MorphArchive *archive, const void *buffer, size_t length);
int archive_write_finish_entry(MorphArchive *archive);
int archive_write_close(MorphArchive *archive);
int archive_write_free(MorphArchive *archive);
MorphArchiveEntry *archive_entry_new(void);
void archive_entry_free(MorphArchiveEntry *entry);
void archive_entry_set_pathname_utf8(MorphArchiveEntry *entry, const char *path);
void archive_entry_set_size(MorphArchiveEntry *entry, int64_t size);
void archive_entry_set_filetype(MorphArchiveEntry *entry, mode_t type);
void archive_entry_set_perm(MorphArchiveEntry *entry, mode_t permissions);
void archive_entry_set_uid(MorphArchiveEntry *entry, int64_t uid);
void archive_entry_set_gid(MorphArchiveEntry *entry, int64_t gid);
void archive_entry_set_uname(MorphArchiveEntry *entry, const char *name);
void archive_entry_set_gname(MorphArchiveEntry *entry, const char *name);
time_t archive_entry_mtime(MorphArchiveEntry *entry);
long archive_entry_mtime_nsec(MorphArchiveEntry *entry);
int archive_entry_mtime_is_set(MorphArchiveEntry *entry);
void archive_entry_set_mtime(MorphArchiveEntry *entry, time_t seconds, long nanoseconds);

typedef struct MorphArchiveOutputContext { int descriptor; } MorphArchiveOutputContext;

static inline int morph_archive_output_open(MorphArchive *archive, void *client_data) {
    (void)archive;
    (void)client_data;
    return 0;
}

static inline ssize_t morph_archive_output_write(MorphArchive *archive, void *client_data,
                                                  const void *buffer, size_t length) {
    (void)archive;
    MorphArchiveOutputContext *context = (MorphArchiveOutputContext *)client_data;
    const char *cursor = (const char *)buffer;
    size_t remaining = length;
    while (remaining > 0) {
        ssize_t written = write(context->descriptor, cursor, remaining);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return -1;
        cursor += written;
        remaining -= (size_t)written;
    }
    return (ssize_t)length;
}

static inline int morph_archive_output_close(MorphArchive *archive, void *client_data) {
    (void)archive;
    (void)client_data;
    return 0;
}

static inline int morph_archive_output_free(MorphArchive *archive, void *client_data) {
    (void)archive;
    free(client_data);
    return 0;
}

static inline int morph_archive_write_open_descriptor(MorphArchive *archive, int descriptor) {
    MorphArchiveOutputContext *context = (MorphArchiveOutputContext *)malloc(sizeof(*context));
    if (context == NULL) return -1;
    context->descriptor = descriptor;
    return archive_write_open2(archive, context, morph_archive_output_open,
                               morph_archive_output_write, morph_archive_output_close,
                               morph_archive_output_free);
}

const char *archive_entry_pathname_utf8(MorphArchiveEntry *entry);
const char *archive_entry_pathname(MorphArchiveEntry *entry);
const char *archive_entry_hardlink_utf8(MorphArchiveEntry *entry);
const char *archive_entry_hardlink(MorphArchiveEntry *entry);
const char *archive_entry_symlink_utf8(MorphArchiveEntry *entry);
const char *archive_entry_symlink(MorphArchiveEntry *entry);
mode_t archive_entry_filetype(MorphArchiveEntry *entry);
mode_t archive_entry_perm(MorphArchiveEntry *entry);
int archive_entry_size_is_set(MorphArchiveEntry *entry);
int64_t archive_entry_size(MorphArchiveEntry *entry);

#endif
