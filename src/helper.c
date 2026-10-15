#include "core.h"
#include "device.h"
#include "storage.h"
#include <CoreGraphics/CoreGraphics.h>
#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/hidsystem/IOHIDLib.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <IOKit/IOMessage.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

/* Model definitions select supported HID++ devices. Never seize a device. */
static struct {
    IOHIDManagerRef manager;
    IOHIDDeviceRef device;
    const MXDeviceDefinition *definition;
    IOHIDDeviceRef pending_device;
    CFRunLoopSourceRef work;
    CFRunLoopTimerRef smooth_timer;
    CGEventSourceRef event_source;
    MXConfig config;
    uint8_t input[MX_REPORT_MAX], response[MX_REPORT_MAX];
    size_t output_sizes[256], response_length;
    uint8_t request_feature, request_tag, software_id;
    uint8_t controls, wheel, thumbwheel, dpi, smartshift, enhanced_shift;
    uint8_t old_wheel, old_thumb[2], multiplier;
    uint16_t thumb_native, thumb_diverted;
    bool old_wheel_valid, old_thumb_valid;
    bool online, connected, configuring, waiting, received, request_failed;
    bool diverted[MX_BUTTON_COUNT], was_pressed[MX_BUTTON_COUNT], divertible[MX_BUTTON_COUNT];
    bool wheel_changed, thumb_changed, reload, stop, removed, probe, verbose;
    bool had_device;
    bool restoration_failed;
    bool initialisation_attempted;
    double fraction[2], smooth_pending[2];
    int lock_fd;
    io_connect_t power;
    IONotificationPortRef power_port;
    io_object_t power_notifier;
} app;

static void schedule_work(void) {
    if (app.work) CFRunLoopSourceSignal(app.work);
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

static void status(const char *state, const char *message) {
    fprintf(stderr, "%s: %s\n", state, message);
    mx_write_status(state, message, app.connected);
}

static bool call(uint8_t feature, uint8_t function, const uint8_t *parameters, size_t length) {
    if (!app.device || !app.online || app.waiting || length > 16) return false;
    uint8_t report_id = length <= 3 && app.output_sizes[0x10] == 6 ? 0x10 : 0x11;
    if (report_id == 0x11 && app.output_sizes[0x11] != 19) return false;
    size_t total = app.output_sizes[report_id] + 1;
    if (total < 4 + length || total > MX_REPORT_MAX) return false;
    uint8_t report[MX_REPORT_MAX] = {0};
    app.software_id = app.software_id % 15 + 1;
    app.request_feature = feature;
    app.request_tag = (uint8_t)((function << 4) | app.software_id);
    report[0] = report_id;
    report[1] = 0xff;
    report[2] = feature;
    report[3] = app.request_tag;
    if (length) memcpy(report + 4, parameters, length);
    app.received = app.request_failed = false;
    app.response_length = 0;
    app.waiting = true;
    IOReturn result = IOHIDDeviceSetReport(app.device, kIOHIDReportTypeOutput,
        report_id, report, (CFIndex)total);
    if (result != kIOReturnSuccess) {
        fprintf(stderr, "HID write failed: 0x%08x\n", (unsigned)result);
        app.waiting = false;
        return false;
    }
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 0.8;
    while (!app.received && app.online && CFAbsoluteTimeGetCurrent() < deadline)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, true);
    app.waiting = false;
    return app.received && !app.request_failed;
}

static uint8_t feature(uint16_t id) {
    uint8_t parameters[] = {(uint8_t)(id >> 8), (uint8_t)id, 0};
    if (!call(0, 0, parameters, sizeof(parameters)) || app.response_length < 5) return 0;
    return app.response[4];
}

static void post_shortcut(const MXBinding *binding) {
    if (binding->action != MX_SHORTCUT || !app.event_source) return;
    CGEventFlags flags = CGEventSourceFlagsState(kCGEventSourceStateHIDSystemState) | binding->modifiers;
    CGEventRef down = CGEventCreateKeyboardEvent(app.event_source, binding->key, true);
    CGEventRef up = CGEventCreateKeyboardEvent(app.event_source, binding->key, false);
    if (down && up) {
        CGEventSetFlags(down, flags);
        CGEventSetFlags(up, flags);
        CGEventPost(kCGHIDEventTap, down);
        CGEventPost(kCGHIDEventTap, up);
    }
    if (down) CFRelease(down);
    if (up) CFRelease(up);
}

static void post_scroll(double vertical, double horizontal) {
    if (!app.event_source) return;
    app.fraction[0] += vertical;
    app.fraction[1] += horizontal;
    int32_t y = (int32_t)trunc(fmax(-32767, fmin(32767, app.fraction[0])));
    int32_t x = (int32_t)trunc(fmax(-32767, fmin(32767, app.fraction[1])));
    app.fraction[0] -= y;
    app.fraction[1] -= x;
    if (!x && !y) return;
    CGEventRef event = CGEventCreateScrollWheelEvent(app.event_source, kCGScrollEventUnitPixel, 2, y, x);
    if (event) { CGEventPost(kCGHIDEventTap, event); CFRelease(event); }
}

static void smooth_tick(CFRunLoopTimerRef timer, void *context) {
    (void)timer; (void)context;
    double y = app.smooth_pending[0] * 0.45, x = app.smooth_pending[1] * 0.45;
    if (fabs(app.smooth_pending[0]) < 0.5 && fabs(app.smooth_pending[1]) < 0.5) {
        y = app.smooth_pending[0]; x = app.smooth_pending[1];
        app.smooth_pending[0] = app.smooth_pending[1] = 0;
        CFRunLoopTimerInvalidate(app.smooth_timer);
        CFRelease(app.smooth_timer); app.smooth_timer = NULL;
    } else {
        app.smooth_pending[0] -= y; app.smooth_pending[1] -= x;
    }
    post_scroll(y, x);
}

static void scroll(double vertical, double horizontal) {
    if (!app.config.smooth) { post_scroll(vertical, horizontal); return; }
    app.smooth_pending[0] = fmax(-10000, fmin(10000, app.smooth_pending[0] + vertical));
    app.smooth_pending[1] = fmax(-10000, fmin(10000, app.smooth_pending[1] + horizontal));
    if (!app.smooth_timer) {
        app.smooth_timer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent(), 1.0 / 60, 0, 0, smooth_tick, NULL);
        CFRunLoopAddTimer(CFRunLoopGetMain(), app.smooth_timer, kCFRunLoopDefaultMode);
    }
}

static void notification(const uint8_t *packet, size_t length) {
    if (!app.connected || app.configuring || length < 5) return;
    /* If posting permission is revoked, return controls to native on the work loop. */
    if (!CGPreflightPostEventAccess()) { app.reload = true; schedule_work(); return; }
    if (packet[2] == app.controls && packet[3] == 0) {
        for (size_t i = 0; i < MX_BUTTON_COUNT; ++i) {
            bool pressed = mx_pressed(packet + 4, length - 4, app.definition->button_controls[i]);
            if (app.diverted[i] && pressed && !app.was_pressed[i]) {
                if (app.verbose) fprintf(stderr, "Button: %s\n", mx_button_keys[i]);
                post_shortcut(&app.config.buttons[i]);
            }
            app.was_pressed[i] = pressed;
        }
    } else if (packet[2] == app.wheel && packet[3] == 0 && app.wheel_changed && length >= 7) {
        int16_t delta = (int16_t)((uint16_t)packet[5] << 8 | packet[6]);
        double multiplier = (packet[4] & 0x10) ? app.multiplier : 1;
        double movement = delta * 32.0 / multiplier * app.config.vertical_speed / 100.0;
        scroll(app.config.invert_vertical ? -movement : movement, 0);
    } else if (packet[2] == app.thumbwheel && packet[3] == 0 && app.thumb_changed && length >= 6) {
        int16_t delta = (int16_t)((uint16_t)packet[4] << 8 | packet[5]);
        double movement = delta * 16.0 * app.thumb_native / app.thumb_diverted * app.config.horizontal_speed / 100.0;
        scroll(0, app.config.invert_horizontal ? -movement : movement);
    }
}

static void input_report(void *context, IOReturn result, void *sender, IOHIDReportType type,
                         uint32_t id, uint8_t *report, CFIndex size) {
    (void)context; (void)sender; (void)type;
    if (result != kIOReturnSuccess || size <= 0 || !app.online) return;
    uint8_t packet[MX_REPORT_MAX];
    size_t length = mx_normalize_report(id, report, (size_t)size, packet);
    if (length < 4 || packet[1] != 0xff) return;
    if (app.waiting && packet[2] == app.request_feature && packet[3] == app.request_tag) {
        memcpy(app.response, packet, length);
        app.response_length = length; app.received = true;
    } else if (app.waiting && (packet[2] == 0xff || packet[2] == 0x8f) && length >= 6 &&
               packet[3] == app.request_feature && packet[4] == app.request_tag) {
        app.received = app.request_failed = true;
        fprintf(stderr, "HID++ error 0x%02x for feature %02x, function %02x\n", packet[5], packet[3], packet[4] >> 4);
    } else if ((packet[3] & 0x0f) == 0) notification(packet, length);
}

static bool divert(size_t button, bool enabled) {
    uint8_t parameters[] = {(uint8_t)(app.definition->button_controls[button] >> 8), (uint8_t)app.definition->button_controls[button],
        enabled ? 0x03 : 0x02, 0, 0};
    /* Do not request persistent diversion or remapping. */
    return call(app.controls, 3, parameters, sizeof(parameters));
}

static void clear_scroll(void) {
    if (app.smooth_timer) {
        CFRunLoopTimerInvalidate(app.smooth_timer);
        CFRelease(app.smooth_timer); app.smooth_timer = NULL;
    }
    memset(app.smooth_pending, 0, sizeof(app.smooth_pending));
    memset(app.fraction, 0, sizeof(app.fraction));
}

static bool restore(void) {
    clear_scroll();
    bool restored = true;
    if (app.online && !app.probe) {
        for (size_t i = 0; i < MX_BUTTON_COUNT; ++i) if (app.diverted[i]) {
            if (divert(i, false)) app.diverted[i] = false;
            else restored = false;
        }
        if (app.wheel_changed) {
            if (app.old_wheel_valid && call(app.wheel, 2, &app.old_wheel, 1)) app.wheel_changed = false;
            else restored = false;
        }
        if (app.thumb_changed) {
            if (app.old_thumb_valid && call(app.thumbwheel, 2, app.old_thumb, 2)) app.thumb_changed = false;
            else restored = false;
        }
    } else {
        memset(app.diverted, 0, sizeof(app.diverted));
        app.wheel_changed = app.thumb_changed = false;
    }
    memset(app.was_pressed, 0, sizeof(app.was_pressed));
    return restored;
}

static void close_device(void) {
    app.configuring = true;
    if (!restore()) app.restoration_failed = true;
    app.connected = false;
    if (app.device) {
        IOHIDDeviceRegisterInputReportCallback(app.device, app.input, sizeof(app.input), NULL, NULL);
        IOHIDDeviceUnscheduleFromRunLoop(app.device, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        IOHIDDeviceClose(app.device, kIOHIDOptionsTypeNone);
        CFRelease(app.device); app.device = NULL;
    }
    app.online = app.configuring = false;
    app.controls = app.wheel = app.thumbwheel = app.dpi = app.smartshift = app.enhanced_shift = 0;
    memset(app.diverted, 0, sizeof(app.diverted));
    memset(app.divertible, 0, sizeof(app.divertible));
    app.old_wheel_valid = app.old_thumb_valid = false;
}

static bool configure(void) {
    if (!restore()) {
        status("error", "Could not restore native reporting. Restart the mouse before continuing.");
        return false;
    }
    bool okay = true;
    if (!CGPreflightPostEventAccess()) {
        status("permission", "macOS is denying input-event posting to MX Mouse Helper. Request Access in Settings; if already enabled, re-add the current helper.");
        return false;
    }
    for (size_t i = 0; i < MX_BUTTON_COUNT; ++i) {
        if (app.config.buttons[i].action == MX_NATIVE) continue;
        if (!app.controls || !app.divertible[i]) { okay = false; continue; }
        /* Mark before the request: a lost reply must still trigger restoration. */
        app.diverted[i] = true;
        if (!divert(i, true)) { okay = false; break; }
    }
    bool vertical = app.config.vertical_speed != 100 || app.config.invert_vertical || app.config.smooth;
    bool horizontal = app.config.horizontal_speed != 100 || app.config.invert_horizontal || app.config.smooth;
    if (vertical) {
        if (!app.wheel || !app.old_wheel_valid) okay = false;
        else {
            uint8_t mode = (uint8_t)((app.old_wheel & ~0x07) | 0x03);
            app.wheel_changed = true;
            if (!call(app.wheel, 2, &mode, 1)) okay = false;
        }
    }
    if (horizontal) {
        if (!app.thumbwheel || !app.old_thumb_valid || !app.thumb_native || !app.thumb_diverted) okay = false;
        else {
            uint8_t parameters[] = {1, 0};
            app.thumb_changed = true;
            if (!call(app.thumbwheel, 2, parameters, 2)) okay = false;
        }
    }
    if (app.config.dpi) {
        uint8_t sensor = 0;
        if (!app.dpi || !call(app.dpi, 1, &sensor, 1) ||
            !mx_dpi_allowed(app.response + 4, app.response_length - 4, app.config.dpi)) okay = false;
        else {
            uint8_t parameters[] = {0, (uint8_t)(app.config.dpi >> 8), (uint8_t)app.config.dpi};
            if (!call(app.dpi, 3, parameters, 3)) okay = false;
        }
    }
    if (app.config.wheel_mode) {
        uint8_t index = app.enhanced_shift ? app.enhanced_shift : app.smartshift;
        uint8_t read_function = app.enhanced_shift ? 1 : 0;
        uint8_t write_function = app.enhanced_shift ? 2 : 1;
        if (!index || !call(index, read_function, NULL, 0) || app.response_length < 7) okay = false;
        else {
            /* 255 means permanent ratchet. Zero leaves default threshold / torque unchanged. */
            uint8_t parameters[] = {app.config.wheel_mode == 2 ? 1 : 2,
                app.config.wheel_mode == 3 ? (uint8_t)app.config.smartshift : 255, 0};
            if (!call(index, write_function, parameters, 3)) okay = false;
        }
    }
    if (!okay) {
        bool restored = restore();
        status("error", restored ?
            "A requested setting could not be applied. Button and scroll diversion have been returned to native; see helper.log." :
            "A requested setting and its cleanup failed. Restart the mouse before continuing; see helper.log.");
        return false;
    }
    status("running", "Mouse connected. Custom controls are active.");
    return true;
}

static void initialise_device(void) {
    app.configuring = true;
    bool pinged = false;
    for (int i = 0; i < 3 && app.online && !app.stop; ++i) {
        uint8_t parameters[] = {0, 0, 0xa7};
        if (call(0, 1, parameters, 3) && app.response_length >= 7 && app.response[6] == 0xa7 && app.response[4] >= 2) {
            pinged = true; break;
        }
    }
    if (!pinged) {
        status("error", "No HID++ reply. Wake or reconnect the mouse, then change a setting to retry; check Input Monitoring and other mouse utilities.");
        app.configuring = false;
        return;
    }
    app.controls = feature(0x1b04);
    app.wheel = feature(0x2121);
    app.thumbwheel = feature(0x2150);
    app.dpi = feature(0x2201);
    app.smartshift = feature(0x2110);
    app.enhanced_shift = feature(0x2111);
    if (app.controls && call(app.controls, 0, NULL, 0) && app.response_length >= 5) {
        uint8_t count = app.response[4];
        for (uint8_t i = 0; i < count && i < 64; ++i) {
            if (!call(app.controls, 1, &i, 1) || app.response_length < 9) continue;
            uint16_t cid = (uint16_t)app.response[4] << 8 | app.response[5];
            for (size_t j = 0; j < MX_BUTTON_COUNT; ++j)
                if (cid == app.definition->button_controls[j]) app.divertible[j] = (app.response[8] & 0x20) != 0;
        }
    }
    app.multiplier = 1;
    if (app.wheel) {
        if (call(app.wheel, 0, NULL, 0) && app.response_length >= 5 && app.response[4]) app.multiplier = app.response[4];
        if (call(app.wheel, 1, NULL, 0) && app.response_length >= 5) {
            /* Never restore an orphaned diversion left by a previous utility. */
            app.old_wheel = app.response[4] & (uint8_t)~1; app.old_wheel_valid = true;
        }
    }
    if (app.thumbwheel) {
        if (call(app.thumbwheel, 0, NULL, 0) && app.response_length >= 8) {
            app.thumb_native = (uint16_t)app.response[4] << 8 | app.response[5];
            app.thumb_diverted = (uint16_t)app.response[6] << 8 | app.response[7];
        }
        if (call(app.thumbwheel, 1, NULL, 0) && app.response_length >= 6) {
            app.old_thumb[0] = 0; app.old_thumb[1] = app.response[5] & 1; app.old_thumb_valid = true;
        }
    }
    if (app.online && !app.stop && !app.removed) {
        app.connected = true;
        fprintf(stderr, "Features: controls=%02x wheel=%02x thumb=%02x dpi=%02x shift=%02x/%02x\n",
            app.controls, app.wheel, app.thumbwheel, app.dpi, app.smartshift, app.enhanced_shift);
        if (app.probe) status("probe", "Bluetooth HID++ capability query completed; no settings written.");
        else configure();
    }
    app.configuring = false;
    if (app.probe) { app.stop = true; schedule_work(); }
    if (app.stop || app.removed || app.reload) schedule_work();
}

static void matched(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    (void)context; (void)sender;
    if (result != kIOReturnSuccess || device == app.device) return;
    int vendor=0, product=0;
    CFTypeRef vendor_value=IOHIDDeviceGetProperty(device,CFSTR(kIOHIDVendorIDKey));
    CFTypeRef product_value=IOHIDDeviceGetProperty(device,CFSTR(kIOHIDProductIDKey));
    if (!vendor_value || !product_value || CFGetTypeID(vendor_value)!=CFNumberGetTypeID() ||
        CFGetTypeID(product_value)!=CFNumberGetTypeID() ||
        !CFNumberGetValue(vendor_value,kCFNumberIntType,&vendor) ||
        !CFNumberGetValue(product_value,kCFNumberIntType,&product)) return;
    const MXDeviceDefinition *definition=mx_device_lookup((uint32_t)vendor,(uint32_t)product);
    if (!definition) return;
    if (app.device) {
        if (app.removed && !app.pending_device) app.pending_device = (IOHIDDeviceRef)CFRetain(device);
        return;
    }
    CFTypeRef descriptor = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDReportDescriptorKey));
    if (!descriptor || CFGetTypeID(descriptor) != CFDataGetTypeID() ||
        !mx_output_reports(CFDataGetBytePtr(descriptor), (size_t)CFDataGetLength(descriptor), app.output_sizes)) return;
    IOReturn opened = IOHIDDeviceOpen(device, kIOHIDOptionsTypeNone);
    if (opened != kIOReturnSuccess) { status("error", "Cannot open the mouse. Grant Input Monitoring to MX Mouse Helper."); return; }
    app.device = (IOHIDDeviceRef)CFRetain(device);
    app.definition = definition;
    app.online = app.had_device = true;
    app.initialisation_attempted = false;
    IOHIDDeviceRegisterInputReportCallback(device, app.input, sizeof(app.input), input_report, NULL);
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    schedule_work();
}

static void removed(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    (void)context; (void)result; (void)sender;
    if (device == app.pending_device) { CFRelease(app.pending_device); app.pending_device = NULL; }
    if (device == app.device) {
        app.online = false; app.removed = true;
        schedule_work();
    }
}

static void work(void *context) {
    (void)context;
    if (app.configuring || app.waiting) return;
    if (app.stop) {
        close_device();
        if (app.pending_device) { CFRelease(app.pending_device); app.pending_device = NULL; }
        CFRunLoopStop(CFRunLoopGetMain()); return;
    }
    if (app.removed) {
        app.removed = false; close_device();
        status("waiting", "Mouse disconnected. Waiting for a supported mouse over Bluetooth.");
        if (app.pending_device) {
            IOHIDDeviceRef device = app.pending_device;
            app.pending_device = NULL;
            matched(NULL, kIOReturnSuccess, NULL, device);
            CFRelease(device);
        }
    }
    if (app.reload) {
        app.reload = false;
        char error[256] = {0}; MXConfig replacement;
        if (!mx_load_config(&replacement, error, sizeof(error))) { status("error", error); return; }
        app.configuring = true;
        if (!restore()) {
            status("error", "Could not restore native reporting. Restart the mouse before applying settings.");
            app.configuring = false;
            if (app.stop || app.removed || app.reload) schedule_work();
            return;
        }
        app.config = replacement;
        /* A settings reload or system wake permits one new bounded handshake. */
        if (!app.connected) app.initialisation_attempted = false;
        if (app.connected && !app.probe) configure();
        app.configuring = false;
        if (app.stop || app.removed || app.reload) schedule_work();
    }
    if (app.device && app.online && !app.connected && !app.initialisation_attempted) {
        app.initialisation_attempted = true;
        initialise_device();
    }
}

static void notify(CFNotificationCenterRef center, void *observer, CFStringRef name,
                   const void *object, CFDictionaryRef user_info) {
    (void)center; (void)observer; (void)object; (void)user_info;
    if (CFEqual(name, CFSTR("local.mxmouse.reload"))) app.reload = true;
    else if (CFEqual(name, CFSTR("local.mxmouse.stop"))) app.stop = true;
    else if (CFEqual(name, CFSTR("local.mxmouse.status"))) {
        char path[PATH_MAX];
        if (mx_path(path, "status.plist")) {
            CFPropertyListRef previous = mx_read_plist(path);
            char state[64] = "waiting", detail[512] = "Waiting for the mouse.";
            if (previous && CFGetTypeID(previous) == CFDictionaryGetTypeID()) {
                CFTypeRef s = CFDictionaryGetValue(previous, CFSTR("state"));
                CFTypeRef d = CFDictionaryGetValue(previous, CFSTR("detail"));
                if (s && CFGetTypeID(s) == CFStringGetTypeID()) CFStringGetCString(s, state, sizeof(state), kCFStringEncodingUTF8);
                if (d && CFGetTypeID(d) == CFStringGetTypeID()) CFStringGetCString(d, detail, sizeof(detail), kCFStringEncodingUTF8);
            }
            if (previous) CFRelease(previous);
            mx_write_status(state, detail, app.connected);
        }
        return;
    }
    schedule_work();
}

static void finish_timer(CFRunLoopTimerRef timer, void *context) {
    (void)timer; (void)context;
    app.stop = true; schedule_work();
}

static void power_changed(void *context, io_service_t service, natural_t message, void *argument) {
    (void)context; (void)service;
    if (message == kIOMessageCanSystemSleep || message == kIOMessageSystemWillSleep)
        IOAllowPowerChange(app.power, (intptr_t)argument);
    else if (message == kIOMessageSystemHasPoweredOn && app.device) {
        app.reload = true; schedule_work();
    }
}

static void redirect_log(void) {
    char path[PATH_MAX];
    if (!mx_path(path, "helper.log")) return;
    struct stat info;
    if (!stat(path, &info) && info.st_size > 131072) {
        char previous[PATH_MAX];
        if (mx_path(previous, "helper.previous.log")) rename(path, previous);
    }
    int fd = open(path, O_CREAT | O_APPEND | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd >= 0) { dup2(fd, STDERR_FILENO); close(fd); setvbuf(stderr, NULL, _IOLBF, 0); }
}

static int acquire_lock(void) {
    char path[PATH_MAX];
    if (!mx_path(path, "helper.lock")) return -1;
    int fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    if (flock(fd, LOCK_EX | LOCK_NB)) { close(fd); return -1; }
    return fd;
}

int main(int argc, char **argv) {
    if (argc == 1 && !isatty(STDERR_FILENO)) redirect_log();
    double duration = 0;
    bool permissions = false, check_permissions = false, baseline = false, offline = false;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--probe")) { app.probe = true; duration = 15; }
        else if (!strcmp(argv[i], "--permissions")) permissions = true;
        else if (!strcmp(argv[i], "--check-permissions")) check_permissions = true;
        else if (!strcmp(argv[i], "--baseline")) baseline = true;
        else if (!strcmp(argv[i], "--offline")) offline = true;
        else if (!strcmp(argv[i], "--verbose")) app.verbose = true;
        else if (!strcmp(argv[i], "--duration") && i + 1 < argc) {
            char *end; duration = strtod(argv[++i], &end);
            if (*end || !isfinite(duration) || duration <= 0 || duration > 3600) return 64;
        } else { fprintf(stderr, "Usage: mxmouse-helper [--probe | --permissions | --check-permissions | --baseline | --offline] [--duration seconds] [--verbose]\n"); return 64; }
    }
    if (check_permissions) {
        if (!mx_write_permissions()) {
            fprintf(stderr, "Could not write permissions.plist. Check the Application Support folder.\n");
            return 74;
        }
        return 0;
    }
    if (permissions) {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent);
        CGRequestPostEventAccess();
        bool written = mx_write_permissions();
        if (!written) fprintf(stderr, "Could not write permissions.plist. Check the Application Support folder.\n");
        return written ? 0 : 74;
    }
    if (baseline) {
        app.manager = IOHIDManagerCreate(NULL, kIOHIDOptionsTypeNone);
        app.event_source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
        mx_write_status("baseline", "Framework baseline only; mouse not opened.", false);
        if (duration) {
            CFRunLoopSourceContext context = {0};
            app.work = CFRunLoopSourceCreate(NULL, 0, &context);
            CFRunLoopAddSource(CFRunLoopGetMain(), app.work, kCFRunLoopDefaultMode);
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, duration, false);
        }
        mx_write_status("baseline", "Framework baseline only; mouse not opened.", false);
        if (app.work) CFRelease(app.work);
        if (app.event_source) CFRelease(app.event_source);
        CFRelease(app.manager); return 0;
    }
    app.lock_fd = acquire_lock();
    if (app.lock_fd < 0) { fprintf(stderr, "Another MX Mouse helper is already running, or its lock is unavailable.\n"); return 73; }
    char message[256] = {0};
    if (!offline && mx_conflicting_process(message)) { status("conflict", message); close(app.lock_fd); return 75; }
    if (!mx_load_config(&app.config, message, sizeof(message))) { status("error", message); close(app.lock_fd); return 65; }
    if (!offline && IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted) {
        status("permission", "Grant Input Monitoring to MX Mouse Helper using the settings app, then restart the helper.");
        close(app.lock_fd); return 77;
    }
    app.event_source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    CFRunLoopSourceContext context = {.perform = work};
    app.work = CFRunLoopSourceCreate(NULL, 0, &context);
    CFRunLoopAddSource(CFRunLoopGetMain(), app.work, kCFRunLoopDefaultMode);
    CFNotificationCenterRef center = CFNotificationCenterGetDistributedCenter();
    CFNotificationCenterAddObserver(center, NULL, notify, CFSTR("local.mxmouse.reload"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(center, NULL, notify, CFSTR("local.mxmouse.stop"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(center, NULL, notify, CFSTR("local.mxmouse.status"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN); signal(SIGHUP, SIG_IGN);
    dispatch_source_t termination = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(termination, ^{ app.stop = true; schedule_work(); }); dispatch_resume(termination);
    dispatch_source_t interrupt = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(interrupt, ^{ app.stop = true; schedule_work(); }); dispatch_resume(interrupt);
    dispatch_source_t reload = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGHUP, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(reload, ^{ app.reload = true; schedule_work(); }); dispatch_resume(reload);
    app.manager = IOHIDManagerCreate(NULL, kIOHIDOptionsTypeNone);
    app.power = IORegisterForSystemPower(NULL, &app.power_port, power_changed, &app.power_notifier);
    if (app.power) CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(app.power_port), kCFRunLoopDefaultMode);
    CFMutableArrayRef matches=CFArrayCreateMutable(NULL,0,&kCFTypeArrayCallBacks);
    for(size_t i=0;i<mx_device_count();++i) {
        const MXDeviceDefinition *definition=mx_device_at(i);
        int vendor=(int)definition->vendor_id, product=(int)definition->product_id;
        CFNumberRef vendor_number=CFNumberCreate(NULL,kCFNumberIntType,&vendor);
        CFNumberRef product_number=CFNumberCreate(NULL,kCFNumberIntType,&product);
        const void *keys[]={CFSTR(kIOHIDVendorIDKey),CFSTR(kIOHIDProductIDKey)};
        const void *values[]={vendor_number,product_number};
        CFDictionaryRef match=CFDictionaryCreate(NULL,keys,values,2,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
        CFArrayAppendValue(matches,match);
        CFRelease(match); CFRelease(vendor_number); CFRelease(product_number);
    }
    if (!offline) IOHIDManagerSetDeviceMatchingMultiple(app.manager,matches);
    CFRelease(matches);
    if (!offline) {
        IOHIDManagerRegisterDeviceMatchingCallback(app.manager, matched, NULL);
        IOHIDManagerRegisterDeviceRemovalCallback(app.manager, removed, NULL);
        IOHIDManagerScheduleWithRunLoop(app.manager, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    }
    status("waiting", offline ? "Offline measurement: HID device access is disabled." : "Waiting for a supported mouse over Bluetooth. The settings app can be closed.");
    IOReturn opened = offline ? kIOReturnSuccess : IOHIDManagerOpen(app.manager, kIOHIDOptionsTypeNone);
    if (opened != kIOReturnSuccess) {
        status("error", "Cannot open the HID manager. Check Input Monitoring for MX Mouse Helper.");
        app.stop = true; schedule_work();
    }
    CFRunLoopTimerRef timer = NULL;
    if (duration) {
        timer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + duration, 0, 0, 0, finish_timer, NULL);
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, kCFRunLoopDefaultMode);
    }
    CFRunLoopRun();
    close_device();
    if (!offline) {
        IOHIDManagerUnscheduleFromRunLoop(app.manager, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        IOHIDManagerClose(app.manager, kIOHIDOptionsTypeNone);
    }
    CFRelease(app.manager);
    if (timer) { CFRunLoopTimerInvalidate(timer); CFRelease(timer); }
    CFNotificationCenterRemoveEveryObserver(center, NULL);
    CFRunLoopRemoveSource(CFRunLoopGetMain(), app.work, kCFRunLoopDefaultMode); CFRelease(app.work);
    if (app.event_source) CFRelease(app.event_source);
    if (app.power) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(app.power_port), kCFRunLoopDefaultMode);
        IODeregisterForSystemPower(&app.power_notifier);
        IOServiceClose(app.power);
        IONotificationPortDestroy(app.power_port);
    }
    dispatch_source_cancel(termination); dispatch_source_cancel(interrupt); dispatch_source_cancel(reload);
    status("stopped", app.restoration_failed ? "Helper stopped, but native reporting could not be restored. Restart the mouse." :
        app.probe && !app.had_device ? "Probe ended without a connected mouse." : "Helper stopped. Native button and wheel reporting restored where connected.");
    close(app.lock_fd);
    return app.probe && !app.had_device ? 69 : 0;
}
