#ifndef MX_STORAGE_H
#define MX_STORAGE_H
#include "core.h"
#include "device.h"
#include <CoreFoundation/CoreFoundation.h>
#include <limits.h>

bool mx_path(char output[PATH_MAX], const char *name);
CFPropertyListRef mx_read_plist(const char *path) CF_RETURNS_RETAINED;
bool mx_write_plist(const char *path, CFPropertyListRef value);
bool mx_load_config(MXConfig *config, char *error, size_t capacity);
/* Device profiles overlay legacy global settings; missing profiles inherit them. */
bool mx_load_device_config(MXConfig *config, const char *device_id, char *error, size_t capacity);
typedef struct {
    const char *id, *name, *transport, *state, *detail;
    bool connected;
    uint32_t capabilities;
    const MXControl *controls;
    size_t control_count;
    int battery_percent, battery_charging;
    const char *battery_status;
} MXDeviceSnapshot;
/* Snapshots are serialized immediately; no caller pointers are retained. */
void mx_write_device_status(const char *state, const char *detail,
    const MXDeviceSnapshot *devices, size_t count);
void mx_set_device_name(const char *name);
/* -1 omits an unknown percentage or charging state; status has static lifetime. */
void mx_set_battery(int percent, const char *status, int charging);
void mx_write_status(const char *state, const char *detail, bool connected);
bool mx_write_permissions(void);
bool mx_conflicting_process(char output[256]);
#endif
