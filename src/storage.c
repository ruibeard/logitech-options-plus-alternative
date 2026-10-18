#include "storage.h"
#include <CoreGraphics/CoreGraphics.h>
#include <ApplicationServices/ApplicationServices.h>
#include <IOKit/hidsystem/IOHIDLib.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static bool mx_directory(char output[PATH_MAX]) {
    const char *home = getenv("HOME");
    if (!home || snprintf(output, PATH_MAX, "%s/Library/Application Support/MX Mouse", home) >= PATH_MAX)
        return false;
    return mkdir(output, 0700) == 0 || errno == EEXIST;
}

bool mx_path(char output[PATH_MAX], const char *name) {
    char directory[PATH_MAX];
    return mx_directory(directory) && snprintf(output, PATH_MAX, "%s/%s", directory, name) < PATH_MAX;
}

CFPropertyListRef mx_read_plist(const char *path) {
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return NULL;
    struct stat info;
    /* Multiple device profiles and control inventories can exceed the old
       single-mouse 64 KiB limit. Allocate only the actual file size. */
    if (fstat(fd, &info) || info.st_size <= 0 || info.st_size > 1048576) { close(fd); return NULL; }
    size_t size = (size_t)info.st_size, offset = 0;
    UInt8 *buffer = malloc(size);
    if (!buffer) { close(fd); return NULL; }
    while (offset < size) {
        ssize_t count = read(fd, buffer + offset, size - offset);
        if (count <= 0) break;
        offset += (size_t)count;
    }
    close(fd);
    CFDataRef data = offset == size ? CFDataCreate(kCFAllocatorDefault, buffer, (CFIndex)size) : NULL;
    free(buffer);
    CFPropertyListRef value = data ? CFPropertyListCreateWithData(kCFAllocatorDefault, data,
        kCFPropertyListImmutable, NULL, NULL) : NULL;
    if (data) CFRelease(data);
    return value;
}

bool mx_write_plist(const char *path, CFPropertyListRef value) {
    CFDataRef data = CFPropertyListCreateData(kCFAllocatorDefault, value,
        kCFPropertyListXMLFormat_v1_0, 0, NULL);
    if (!data) return false;
    char temporary[PATH_MAX];
    if (snprintf(temporary, sizeof(temporary), "%s.XXXXXX", path) >= PATH_MAX) { CFRelease(data); return false; }
    int fd = mkstemp(temporary);
    bool success = fd >= 0;
    size_t total = (size_t)CFDataGetLength(data), offset = 0;
    while (success && offset < total) {
        ssize_t count = write(fd, CFDataGetBytePtr(data) + offset, total - offset);
        if (count <= 0) success = false;
        else offset += (size_t)count;
    }
    if (fd >= 0) { if (fsync(fd)) success = false; close(fd); }
    if (success) success = rename(temporary, path) == 0;
    if (!success) unlink(temporary);
    CFRelease(data);
    return success;
}

static bool number(CFDictionaryRef dictionary, CFStringRef key, int minimum, int maximum, int *output) {
    CFTypeRef value = CFDictionaryGetValue(dictionary, key);
    if (!value) return true;
    int result;
    if (CFGetTypeID(value) != CFNumberGetTypeID() ||
        !CFNumberGetValue(value, kCFNumberIntType, &result) || result < minimum || result > maximum) return false;
    *output = result;
    return true;
}

static bool boolean(CFDictionaryRef dictionary, CFStringRef key, bool *output) {
    CFTypeRef value = CFDictionaryGetValue(dictionary, key);
    if (!value) return true;
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
        *output = CFBooleanGetValue(value);
        return true;
    }
    /* The first settings build boxed checkbox comparisons as integer 0/1. */
    int legacy;
    if (CFGetTypeID(value) == CFNumberGetTypeID() && !CFNumberIsFloatType(value) &&
        CFNumberGetValue(value, kCFNumberIntType, &legacy) && (legacy == 0 || legacy == 1)) {
        *output = legacy == 1;
        return true;
    }
    return false;
}

static bool load_binding(CFTypeRef value, MXBinding *binding) {
    if (!value || CFGetTypeID(value) != CFDictionaryGetTypeID()) return false;
    int mode = binding->action, code = binding->key, modifiers = (int)binding->modifiers;
    if (!number(value, CFSTR("mode"), 0, 2, &mode) ||
        !number(value, CFSTR("keyCode"), 0, 127, &code) ||
        !number(value, CFSTR("modifiers"), 0, 0x1e0000, &modifiers) ||
        (modifiers & ~0x1e0000)) return false;
    *binding = (MXBinding){(MXAction)mode, (uint16_t)code, (uint64_t)modifiers};
    return true;
}

static bool apply_config(CFDictionaryRef dictionary, MXConfig *config) {
    if (!number(dictionary, CFSTR("dpi"), 0, 65535, &config->dpi) ||
        !number(dictionary, CFSTR("wheelMode"), 0, 3, &config->wheel_mode) ||
        !number(dictionary, CFSTR("smartShift"), 1, 50, &config->smartshift) ||
        !number(dictionary, CFSTR("verticalSpeed"), 10, 300, &config->vertical_speed) ||
        !number(dictionary, CFSTR("horizontalSpeed"), 10, 300, &config->horizontal_speed) ||
        !boolean(dictionary, CFSTR("invertVertical"), &config->invert_vertical) ||
        !boolean(dictionary, CFSTR("invertHorizontal"), &config->invert_horizontal) ||
        !boolean(dictionary, CFSTR("smooth"), &config->smooth)) return false;
    CFTypeRef bindings = CFDictionaryGetValue(dictionary, CFSTR("buttons"));
    if (bindings && CFGetTypeID(bindings) != CFDictionaryGetTypeID()) return false;
    if (bindings) for (size_t i = 0; i < MX_BUTTON_COUNT; ++i) {
        CFStringRef key = CFStringCreateWithCString(NULL, mx_button_keys[i], kCFStringEncodingUTF8);
        CFTypeRef binding = CFDictionaryGetValue(bindings, key);
        CFRelease(key);
        if (binding && !load_binding(binding, &config->buttons[i])) return false;
    }
    CFTypeRef extra = CFDictionaryGetValue(dictionary, CFSTR("controls"));
    if (!extra) return true;
    if (CFGetTypeID(extra) != CFDictionaryGetTypeID()) return false;
    CFIndex count = CFDictionaryGetCount(extra);
    if (count > MX_EXTRA_BUTTON_COUNT) return false;
    /* A device's explicit CID table replaces inherited hardware-specific CIDs. */
    config->extra_button_count = 0;
    const void *keys[MX_EXTRA_BUTTON_COUNT], *values[MX_EXTRA_BUTTON_COUNT];
    CFDictionaryGetKeysAndValues(extra, keys, values);
    uint16_t seen[MX_EXTRA_BUTTON_COUNT];
    for (CFIndex i = 0; i < count; ++i) {
        char text[8];
        if (CFGetTypeID(keys[i]) != CFStringGetTypeID() ||
            !CFStringGetCString(keys[i], text, sizeof(text), kCFStringEncodingASCII) || strlen(text) != 4) return false;
        for (size_t j = 0; j < 4; ++j)
            if (!((text[j] >= '0' && text[j] <= '9') || (text[j] >= 'a' && text[j] <= 'f') ||
                  (text[j] >= 'A' && text[j] <= 'F'))) return false;
        unsigned long cid = strtoul(text, NULL, 16);
        if (!cid) return false;
        for (CFIndex j = 0; j < i; ++j) if (seen[j] == cid) return false;
        seen[i] = (uint16_t)cid;
        size_t position = 0;
        while (position < config->extra_button_count && config->extra_buttons[position].cid != cid) ++position;
        if (position == config->extra_button_count) {
            if (position == MX_EXTRA_BUTTON_COUNT) return false;
            config->extra_buttons[position] = (MXExtraBinding){(uint16_t)cid, {MX_NATIVE, 0, 0}};
            ++config->extra_button_count;
        }
        if (!load_binding(values[i], &config->extra_buttons[position].binding)) return false;
    }
    return true;
}

/* A unit without its own profile inherits one saved for the same model ("logitech-<product>-"),
   so a new receiver, a re-pairing or an ID format change keeps the user's settings.
   The lowest key wins, so the choice is stable. */
static CFTypeRef model_profile(CFDictionaryRef profiles, const char *device_id) {
    const char *dash = strchr(device_id, '-');
    dash = dash ? strchr(dash + 1, '-') : NULL;
    if (!dash) return NULL;
    size_t prefix = (size_t)(dash - device_id) + 1;
    CFIndex count = CFDictionaryGetCount(profiles);
    const void **keys = malloc(sizeof(*keys) * (size_t)(count ? count : 1));
    const void **values = malloc(sizeof(*values) * (size_t)(count ? count : 1));
    CFTypeRef found = NULL;
    char best[192] = {0};
    if (keys && values) {
        CFDictionaryGetKeysAndValues(profiles, keys, values);
        for (CFIndex i = 0; i < count; ++i) {
            char text[192];
            if (CFGetTypeID(keys[i]) != CFStringGetTypeID() ||
                !CFStringGetCString(keys[i], text, sizeof(text), kCFStringEncodingUTF8) ||
                strncmp(text, device_id, prefix) || (found && strcmp(text, best) >= 0)) continue;
            found = values[i]; snprintf(best, sizeof(best), "%s", text);
        }
    }
    free(keys); free(values);
    return found;
}

bool mx_load_device_config(MXConfig *config, const char *device_id, char *error, size_t capacity) {
    mx_defaults(config);
    if (error && capacity) error[0] = 0;
    char path[PATH_MAX];
    if (!mx_path(path, "settings.plist")) return false;
    if (access(path, F_OK) != 0 && errno == ENOENT) return true;
    CFPropertyListRef root = mx_read_plist(path);
    bool success = root && CFGetTypeID(root) == CFDictionaryGetTypeID();
    if (success) success = apply_config(root, config);
    if (success && device_id && *device_id) {
        CFTypeRef profiles = CFDictionaryGetValue(root, CFSTR("devices"));
        if (profiles && CFGetTypeID(profiles) != CFDictionaryGetTypeID()) success = false;
        if (success && profiles) {
            CFStringRef key = CFStringCreateWithCString(NULL, device_id, kCFStringEncodingUTF8);
            CFTypeRef profile = key ? CFDictionaryGetValue(profiles, key) : NULL;
            if (key) CFRelease(key);
            if (!profile) profile = model_profile(profiles, device_id);
            if (profile) success = CFGetTypeID(profile) == CFDictionaryGetTypeID() && apply_config(profile, config);
        }
    }
    if (root) CFRelease(root);
    if (!success && error && capacity) snprintf(error, capacity,
        "Invalid settings.plist%s. Fix it in MX Mouse Settings before starting mouse controls.",
        device_id && *device_id ? " device profile" : "");
    return success;
}

bool mx_load_config(MXConfig *config, char *error, size_t capacity) {
    return mx_load_device_config(config, NULL, error, capacity);
}

bool mx_conflicting_process(char output[256]) {
    pid_t pids[4096];
    int length = proc_listpids(PROC_ALL_PIDS, 0, pids, sizeof(pids));
    for (int i = 0; i < length / (int)sizeof(pid_t); ++i) {
        char name[PROC_PIDPATHINFO_MAXSIZE];
        if (pids[i] <= 0 || pids[i] == getpid() || proc_pidpath(pids[i], name, sizeof(name)) <= 0) continue;
        const char *executable = strrchr(name, '/');
        executable = executable ? executable + 1 : name;
        if (!strcmp(executable, "openlogi-agent")) { snprintf(output, 256, "OpenLogi Agent is running. Quit OpenLogi before starting MX Mouse."); return true; }
        if (!strcmp(executable, "logioptionsplus_agent")) { snprintf(output, 256, "Logi Options+ Agent is running. Quit Options+ before starting MX Mouse."); return true; }
    }
    return false;
}

bool mx_write_permissions(void) {
    char path[PATH_MAX];
    if (!mx_path(path, "permissions.plist")) return false;
    CFMutableDictionaryRef root = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!root) return false;
    CFDictionarySetValue(root, CFSTR("inputMonitoring"),
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted ? kCFBooleanTrue : kCFBooleanFalse);
    CFDictionarySetValue(root, CFSTR("accessibility"),
        AXIsProcessTrusted() ? kCFBooleanTrue : kCFBooleanFalse);
    CFDictionarySetValue(root, CFSTR("postEventAccess"),
        CGPreflightPostEventAccess() ? kCFBooleanTrue : kCFBooleanFalse);
    CFAbsoluteTime checked_at = CFAbsoluteTimeGetCurrent();
    CFNumberRef timestamp = CFNumberCreate(NULL, kCFNumberDoubleType, &checked_at);
    if (!timestamp) { CFRelease(root); return false; }
    CFDictionarySetValue(root, CFSTR("checkedAt"), timestamp);
    CFRelease(timestamp);
    bool written = mx_write_plist(path, root);
    CFRelease(root);
    return written;
}

static const char *device_name;
void mx_set_device_name(const char *name) { device_name=name; }
static int battery_percent = -1, battery_charging = -1;
static const char *battery_status;
void mx_set_battery(int percent, const char *status, int charging) {
    battery_percent = percent;
    battery_status = status;
    battery_charging = charging;
}

static CFMutableDictionaryRef make_status(const char *state, const char *detail, bool connected) {
    CFMutableDictionaryRef root = CFDictionaryCreateMutable(NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFStringRef value = CFStringCreateWithCString(NULL, state, kCFStringEncodingUTF8);
    CFDictionarySetValue(root, CFSTR("state"), value); CFRelease(value);
    value = CFStringCreateWithCString(NULL, detail, kCFStringEncodingUTF8);
    CFDictionarySetValue(root, CFSTR("detail"), value); CFRelease(value);
    if (device_name) {
        CFStringRef name=CFStringCreateWithCString(NULL,device_name,kCFStringEncodingUTF8);
        CFDictionarySetValue(root,CFSTR("deviceName"),name); CFRelease(name);
    }
    int pid = getpid();
    CFNumberRef number_value = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    CFDictionarySetValue(root, CFSTR("pid"), number_value); CFRelease(number_value);
    CFDictionarySetValue(root, CFSTR("connected"), connected ? kCFBooleanTrue : kCFBooleanFalse);
    if (connected && battery_percent >= 0 && battery_percent <= 100) {
        number_value = CFNumberCreate(NULL, kCFNumberIntType, &battery_percent);
        CFDictionarySetValue(root, CFSTR("batteryPercent"), number_value); CFRelease(number_value);
    }
    if (connected && battery_status) {
        value = CFStringCreateWithCString(NULL, battery_status, kCFStringEncodingUTF8);
        CFDictionarySetValue(root, CFSTR("batteryStatus"), value); CFRelease(value);
    }
    if (connected && (battery_charging == 0 || battery_charging == 1))
        CFDictionarySetValue(root, CFSTR("batteryCharging"), battery_charging ? kCFBooleanTrue : kCFBooleanFalse);
    task_vm_info_data_t info = {0}; mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS) {
        int64_t footprint = (int64_t)info.phys_footprint;
        number_value = CFNumberCreate(NULL, kCFNumberSInt64Type, &footprint);
        CFDictionarySetValue(root, CFSTR("footprintBytes"), number_value); CFRelease(number_value);
    }
    CFDictionarySetValue(root, CFSTR("inputMonitoring"),
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted ? kCFBooleanTrue : kCFBooleanFalse);
    CFDictionarySetValue(root, CFSTR("accessibility"),
        AXIsProcessTrusted() ? kCFBooleanTrue : kCFBooleanFalse);
    CFDictionarySetValue(root, CFSTR("postEventAccess"),
        CGPreflightPostEventAccess() ? kCFBooleanTrue : kCFBooleanFalse);
    return root;
}

void mx_write_status(const char *state, const char *detail, bool connected) {
    char path[PATH_MAX];
    if (!mx_path(path, "status.plist")) return;
    CFMutableDictionaryRef root = make_status(state, detail, connected);
    mx_write_plist(path, root);
    CFRelease(root);
}

static void set_text(CFMutableDictionaryRef dictionary, CFStringRef key, const char *text) {
    if (!text) return;
    CFStringRef value = CFStringCreateWithCString(NULL, text, kCFStringEncodingUTF8);
    if (value) { CFDictionarySetValue(dictionary, key, value); CFRelease(value); }
}

static void set_integer(CFMutableDictionaryRef dictionary, CFStringRef key, int value) {
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberIntType, &value);
    CFDictionarySetValue(dictionary, key, number); CFRelease(number);
}

void mx_write_device_status(const char *state, const char *detail,
                           const MXDeviceSnapshot *devices, size_t count) {
    char path[PATH_MAX];
    if (!mx_path(path, "status.plist")) return;
    const MXDeviceSnapshot *primary = count ? &devices[0] : NULL;
    size_t connected_count = 0;
    for (size_t i = 0; i < count; ++i) if (devices[i].connected) {
        if (!connected_count) primary = &devices[i];
        ++connected_count;
    }
    mx_set_device_name(primary ? primary->name : NULL);
    mx_set_battery(primary ? primary->battery_percent : -1,
        primary ? primary->battery_status : NULL, primary ? primary->battery_charging : -1);
    CFMutableDictionaryRef root = make_status(state, detail, connected_count != 0);
    set_integer(root, CFSTR("connectedCount"), (int)connected_count);
    CFMutableArrayRef list = CFArrayCreateMutable(NULL, (CFIndex)count, &kCFTypeArrayCallBacks);
    for (size_t i = 0; i < count; ++i) {
        const MXDeviceSnapshot *device = &devices[i];
        CFMutableDictionaryRef entry = CFDictionaryCreateMutable(NULL, 0,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        set_text(entry, CFSTR("id"), device->id);
        set_text(entry, CFSTR("name"), device->name);
        set_text(entry, CFSTR("transport"), device->transport);
        set_text(entry, CFSTR("state"), device->state);
        set_text(entry, CFSTR("detail"), device->detail);
        CFDictionarySetValue(entry, CFSTR("connected"), device->connected ? kCFBooleanTrue : kCFBooleanFalse);
        if (device->connected) {
            if (device->battery_percent >= 0 && device->battery_percent <= 100)
                set_integer(entry, CFSTR("batteryPercent"), device->battery_percent);
            set_text(entry, CFSTR("batteryStatus"), device->battery_status);
            if (device->battery_charging == 0 || device->battery_charging == 1)
                CFDictionarySetValue(entry, CFSTR("batteryCharging"), device->battery_charging ? kCFBooleanTrue : kCFBooleanFalse);
        }
        CFMutableDictionaryRef capabilities = CFDictionaryCreateMutable(NULL, 0,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        const CFStringRef names[] = {CFSTR("buttons"), CFSTR("verticalScroll"), CFSTR("horizontalScroll"),
            CFSTR("dpi"), CFSTR("wheelMode"), CFSTR("smartShift"), CFSTR("battery"), CFSTR("haptic")};
        const uint32_t bits[] = {MX_CAP_BUTTONS, MX_CAP_HIRES_SCROLL, MX_CAP_THUMBWHEEL, MX_CAP_DPI,
            MX_CAP_SMARTSHIFT, MX_CAP_SMARTSHIFT, MX_CAP_BATTERY, MX_CAP_HAPTIC};
        for (size_t j = 0; j < sizeof(bits) / sizeof(bits[0]); ++j)
            CFDictionarySetValue(capabilities, names[j], device->capabilities & bits[j] ? kCFBooleanTrue : kCFBooleanFalse);
        CFDictionarySetValue(entry, CFSTR("capabilities"), capabilities); CFRelease(capabilities);
        CFMutableArrayRef controls = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
        for (size_t j = 0; j < device->control_count && j < MX_CONTROL_MAX; ++j) {
            const MXControl *control = &device->controls[j];
            CFMutableDictionaryRef row = CFDictionaryCreateMutable(NULL, 0,
                &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            set_integer(row, CFSTR("cid"), control->cid);
            set_integer(row, CFSTR("slot"), control->slot);
            const char *name = mx_control_name(control->cid);
            char fallback[32];
            snprintf(fallback, sizeof(fallback), "Button %04x", control->cid);
            set_text(row, CFSTR("name"), name ? name : fallback);
            CFDictionarySetValue(row, CFSTR("divertible"), control->divertible ? kCFBooleanTrue : kCFBooleanFalse);
            CFArrayAppendValue(controls, row); CFRelease(row);
        }
        CFDictionarySetValue(entry, CFSTR("controls"), controls); CFRelease(controls);
        CFArrayAppendValue(list, entry); CFRelease(entry);
    }
    CFDictionarySetValue(root, CFSTR("devices"), list); CFRelease(list);
    mx_write_plist(path, root); CFRelease(root);
    mx_set_device_name(NULL);
    mx_set_battery(-1, NULL, -1);
}
