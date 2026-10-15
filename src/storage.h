#ifndef MX_STORAGE_H
#define MX_STORAGE_H
#include "core.h"
#include <CoreFoundation/CoreFoundation.h>
#include <limits.h>

bool mx_path(char output[PATH_MAX], const char *name);
CFPropertyListRef mx_read_plist(const char *path) CF_RETURNS_RETAINED;
bool mx_write_plist(const char *path, CFPropertyListRef value);
bool mx_load_config(MXConfig *config, char *error, size_t capacity);
void mx_write_status(const char *state, const char *detail, bool connected);
bool mx_write_permissions(void);
bool mx_conflicting_process(char output[256]);
#endif
