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
    if (fstat(fd, &info) || info.st_size <= 0 || info.st_size > 65536) { close(fd); return NULL; }
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

bool mx_load_config(MXConfig *config, char *error, size_t capacity) {
    mx_defaults(config);
    char path[PATH_MAX];
    if (!mx_path(path, "settings.plist")) return false;
    if (access(path, F_OK) != 0 && errno == ENOENT) return true;
    CFPropertyListRef root = mx_read_plist(path);
    bool success = root && CFGetTypeID(root) == CFDictionaryGetTypeID();
    if (success) {
        CFDictionaryRef dictionary = (CFDictionaryRef)root;
        success = number(dictionary, CFSTR("dpi"), 0, 4000, &config->dpi) &&
            number(dictionary, CFSTR("wheelMode"), 0, 3, &config->wheel_mode) &&
            number(dictionary, CFSTR("smartShift"), 1, 50, &config->smartshift) &&
            number(dictionary, CFSTR("verticalSpeed"), 10, 300, &config->vertical_speed) &&
            number(dictionary, CFSTR("horizontalSpeed"), 10, 300, &config->horizontal_speed) &&
            boolean(dictionary, CFSTR("invertVertical"), &config->invert_vertical) &&
            boolean(dictionary, CFSTR("invertHorizontal"), &config->invert_horizontal) &&
            boolean(dictionary, CFSTR("smooth"), &config->smooth);
        CFTypeRef bindings = CFDictionaryGetValue(dictionary, CFSTR("buttons"));
        if (bindings && CFGetTypeID(bindings) != CFDictionaryGetTypeID()) success = false;
        if (success && bindings) for (size_t i = 0; i < MX_BUTTON_COUNT; ++i) {
            CFStringRef key = CFStringCreateWithCString(NULL, mx_button_keys[i], kCFStringEncodingUTF8);
            CFTypeRef binding = CFDictionaryGetValue(bindings, key);
            CFRelease(key);
            if (!binding) continue;
            if (CFGetTypeID(binding) != CFDictionaryGetTypeID()) { success = false; break; }
            int mode = config->buttons[i].action, code = config->buttons[i].key;
            int modifiers = (int)config->buttons[i].modifiers;
            if (!number(binding, CFSTR("mode"), 0, 2, &mode) ||
                !number(binding, CFSTR("keyCode"), 0, 127, &code) ||
                !number(binding, CFSTR("modifiers"), 0, 0x1e0000, &modifiers) ||
                (modifiers & ~0x1e0000)) { success = false; break; }
            config->buttons[i] = (MXBinding){(MXAction)mode, (uint16_t)code, (uint64_t)modifiers};
        }
    }
    if (root) CFRelease(root);
    if (!success && error && capacity) snprintf(error, capacity, "Invalid settings.plist. Fix it in MX Mouse Settings before starting the helper.");
    return success;
}

bool mx_conflicting_process(char output[256]) {
    pid_t pids[4096];
    int length = proc_listpids(PROC_ALL_PIDS, 0, pids, sizeof(pids));
    for (int i = 0; i < length / (int)sizeof(pid_t); ++i) {
        char name[PROC_PIDPATHINFO_MAXSIZE];
        if (pids[i] <= 0 || pids[i] == getpid() || proc_pidpath(pids[i], name, sizeof(name)) <= 0) continue;
        if (strstr(name, "/openlogi-agent")) { snprintf(output, 256, "OpenLogi Agent is running. Quit OpenLogi before starting MX Mouse."); return true; }
        if (strstr(name, "/logioptionsplus_agent")) { snprintf(output, 256, "Logi Options+ Agent is running. Quit Options+ before starting MX Mouse."); return true; }
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

void mx_write_status(const char *state, const char *detail, bool connected) {
    char path[PATH_MAX];
    if (!mx_path(path, "status.plist")) return;
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
    mx_write_plist(path, root);
    CFRelease(root);
}
