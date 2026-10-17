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

/* One HID transport per interface; one state node per mouse, including receiver slots.
   The main run loop serializes requests. No worker process or polling thread. */
typedef struct Mouse Mouse;
typedef struct Transport {
    struct Transport *next;
    IOHIDDeviceRef device;
    MXReceiverKind receiver_kind;
    uint8_t input[MX_REPORT_MAX];
    uint8_t short_size, long_size;
    Mouse *request;
    CFRunLoopTimerRef scan_timer;
    unsigned scan_delay;
    bool online, removed, scan, mouse_usage, notifications_changed;
    uint8_t old_notifications[3];
    uint32_t product_id, location_id;
    char serial[128];
} Transport;
struct Mouse {
    Mouse *next;
    Transport *transport;
    const MXDeviceDefinition *definition;
    char id[192], name[128], state[32], detail[512];
    uint32_t product_id, unit_id;
    uint8_t identity_feature;
    MXControl controls_info[MX_CONTROL_MAX];
    size_t control_count;
    uint16_t button_controls[MX_BUTTON_COUNT];
    CFRunLoopTimerRef smooth_timer, reconnect_timer;
    unsigned reconnect_delay;
    MXConfig config;
    uint8_t response[MX_REPORT_MAX];
    size_t response_length;
    uint8_t request_feature, request_tag, request_address, address, software_id;
    uint8_t request_error_type, request_error_code;
    bool receiver;
    uint8_t controls, wheel, thumbwheel, dpi, smartshift, enhanced_shift;
    uint8_t battery;
    bool dpi_valid, shift_valid;
    bool battery_unified, battery_percent_supported;
    CFAbsoluteTime battery_checked_at;
    int battery_percent, battery_charging;
    const char *battery_status;
    uint8_t old_wheel, old_thumb[2], multiplier;
    uint16_t thumb_native, thumb_diverted;
    bool old_wheel_valid, old_thumb_valid;
    bool online, connected, configuring, waiting, received, request_failed;
    bool diverted[MX_CONTROL_MAX], was_pressed[MX_CONTROL_MAX];
    bool wheel_changed, thumb_changed, removed;
    bool initialisation_attempted;
    double fraction[2], smooth_pending[2];
};
static struct {
    IOHIDManagerRef manager;
    Transport *transports;
    Mouse *mice, *current;
    CFRunLoopSourceRef work;
    CGEventSourceRef event_source;
    bool reload, stop, probe, verbose, had_device, restoration_failed, battery_requested, working;
    int lock_fd;
    io_connect_t power;
    IONotificationPortRef power_port;
    io_object_t power_notifier;
} runtime;
#define app (*runtime.current)
static void publish_status_snapshot(void);

static void schedule_work(void) {
    if (runtime.work) CFRunLoopSourceSignal(runtime.work);
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

static void cancel_receiver_retry(Transport *transport) {
    if (!transport->scan_timer) return;
    CFRunLoopTimerInvalidate(transport->scan_timer);
    CFRelease(transport->scan_timer); transport->scan_timer = NULL;
}

static void receiver_retry_tick(CFRunLoopTimerRef timer, void *context) {
    (void)timer;
    Transport *transport = context;
    cancel_receiver_retry(transport);
    if (transport->online && !transport->removed && !runtime.stop) {
        transport->scan = true; schedule_work();
    }
}

/* Retry incomplete receiver discovery, including when no mouse node exists yet.
   Empty slots with an explicit protocol error are settled, not timeout failures. */
static void retry_receiver_scan(Transport *transport) {
    if (runtime.probe || runtime.stop || !transport->online || transport->removed || transport->scan_timer) return;
    unsigned delay = transport->scan_delay ? transport->scan_delay : 1;
    transport->scan_delay = delay >= 16 ? 30 : delay * 2;
    transport->scan_timer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + delay,
        0, 0, 0, receiver_retry_tick, &(CFRunLoopTimerContext){.info = transport});
    CFRunLoopAddTimer(CFRunLoopGetMain(), transport->scan_timer, kCFRunLoopDefaultMode);
}

static void cancel_reconnect(void) {
    if (!app.reconnect_timer) return;
    CFRunLoopTimerInvalidate(app.reconnect_timer);
    CFRelease(app.reconnect_timer);
    app.reconnect_timer = NULL;
}

static void reconnect_tick(CFRunLoopTimerRef timer, void *context) {
    (void)timer;
    Mouse *previous = runtime.current; runtime.current = context;
    cancel_reconnect();
    if (app.online && !app.connected && !runtime.stop && !app.removed) {
        app.initialisation_attempted = false; schedule_work();
    }
    runtime.current = previous;
}

/* Discovery can precede a usable Bluetooth link. Retry only failed handshakes,
   backing off to 30 seconds; a healthy connection has no reconnect timer. */
static void retry_connection(void) {
    if (runtime.probe || !app.online || app.connected || runtime.stop || app.removed || app.reconnect_timer) return;
    unsigned delay = app.reconnect_delay ? app.reconnect_delay : 1;
    app.reconnect_delay = delay >= 16 ? 30 : delay * 2;
    app.reconnect_timer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + delay,
        0, 0, 0, reconnect_tick, &(CFRunLoopTimerContext){.info = runtime.current});
    CFRunLoopAddTimer(CFRunLoopGetMain(), app.reconnect_timer, kCFRunLoopDefaultMode);
}

static void status(const char *state, const char *message) {
    bool repeated_waiting = runtime.current && !strcmp(state, "waiting") &&
        !strcmp(app.state, state) && !strcmp(app.detail, message);
    if (!repeated_waiting || runtime.verbose) fprintf(stderr, "%s: %s\n", state, message);
    if (runtime.current) {
        snprintf(app.state, sizeof(app.state), "%s", state);
        snprintf(app.detail, sizeof(app.detail), "%s", message);
    }
    if (!runtime.current && !runtime.mice) mx_write_device_status(state, message, NULL, 0);
    else publish_status_snapshot();
}

#ifdef MX_HELPER_TEST
static bool (*test_exchange)(uint8_t, uint8_t, uint8_t, const uint8_t *, size_t);
#endif
static bool exchange(uint8_t address, uint8_t feature, uint8_t tag, const uint8_t *parameters, size_t length) {
    app.request_error_type = app.request_error_code = 0;
#ifdef MX_HELPER_TEST
    if (test_exchange) return test_exchange(address, feature, tag, parameters, length);
#endif
    if (!app.transport || !app.transport->device || !app.online || app.waiting || app.transport->request || length > 16) return false;
    uint8_t report_id = length <= 3 && app.transport->short_size == 6 ? 0x10 : 0x11;
    if (report_id == 0x11 && app.transport->long_size != 19) return false;
    size_t total = (report_id == 0x10 ? app.transport->short_size : app.transport->long_size) + 1;
    if (total < 4 + length || total > MX_REPORT_MAX) return false;
    uint8_t report[MX_REPORT_MAX] = {0};
    app.request_feature = feature;
    app.request_tag = tag;
    app.request_address = address;
    report[0] = report_id;
    report[1] = address;
    report[2] = feature;
    report[3] = app.request_tag;
    if (length) memcpy(report + 4, parameters, length);
    app.received = app.request_failed = false;
    app.response_length = 0;
    app.waiting = true;
    app.transport->request = runtime.current;
    IOReturn result = IOHIDDeviceSetReport(app.transport->device, kIOHIDReportTypeOutput,
        report_id, report, (CFIndex)total);
    if (result != kIOReturnSuccess) {
        fprintf(stderr, "HID write failed: 0x%08x\n", (unsigned)result);
        app.waiting = false; app.transport->request = NULL;
        return false;
    }
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 0.8;
    while (!app.received && app.online && CFAbsoluteTimeGetCurrent() < deadline)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, true);
    app.waiting = false; app.transport->request = NULL;
    return app.received && !app.request_failed;
}

static bool call(uint8_t feature, uint8_t function, const uint8_t *parameters, size_t length) {
    app.software_id = app.software_id % 15 + 1;
    return exchange(app.address, feature, (uint8_t)((function << 4) | app.software_id), parameters, length);
}

static uint8_t feature(uint16_t id) {
    uint8_t parameters[] = {(uint8_t)(id >> 8), (uint8_t)id, 0};
    if (!call(0, 0, parameters, sizeof(parameters)) || app.response_length < 5) return 0;
    return app.response[4];
}

static void post_shortcut(const MXBinding *binding) {
    if (binding->action != MX_SHORTCUT || !runtime.event_source) return;
    CGEventFlags flags = CGEventSourceFlagsState(kCGEventSourceStateHIDSystemState) | binding->modifiers;
    CGEventRef down = CGEventCreateKeyboardEvent(runtime.event_source, binding->key, true);
    CGEventRef up = CGEventCreateKeyboardEvent(runtime.event_source, binding->key, false);
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
    if (!runtime.event_source) return;
    app.fraction[0] += vertical;
    app.fraction[1] += horizontal;
    int32_t y = (int32_t)trunc(fmax(-32767, fmin(32767, app.fraction[0])));
    int32_t x = (int32_t)trunc(fmax(-32767, fmin(32767, app.fraction[1])));
    app.fraction[0] -= y;
    app.fraction[1] -= x;
    if (!x && !y) return;
    CGEventRef event = CGEventCreateScrollWheelEvent(runtime.event_source, kCGScrollEventUnitPixel, 2, y, x);
    if (event) { CGEventPost(kCGHIDEventTap, event); CFRelease(event); }
}

static void smooth_tick(CFRunLoopTimerRef timer, void *context) {
    (void)timer;
    Mouse *previous = runtime.current; runtime.current = context;
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
    runtime.current = previous;
}

static void scroll(double vertical, double horizontal) {
    if (!app.config.smooth) { post_scroll(vertical, horizontal); return; }
    app.smooth_pending[0] = fmax(-10000, fmin(10000, app.smooth_pending[0] + vertical));
    app.smooth_pending[1] = fmax(-10000, fmin(10000, app.smooth_pending[1] + horizontal));
    if (!app.smooth_timer) {
        app.smooth_timer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent(), 1.0 / 60, 0, 0, smooth_tick, &(CFRunLoopTimerContext){.info = runtime.current});
        CFRunLoopAddTimer(CFRunLoopGetMain(), app.smooth_timer, kCFRunLoopDefaultMode);
    }
}

static void notification(const uint8_t *packet, size_t length) {
    if (!app.connected || app.configuring || length < 5) return;
    /* If posting permission is revoked, return controls to native on the work loop. */
    if (!CGPreflightPostEventAccess()) { runtime.reload = true; schedule_work(); return; }
    if (packet[2] == app.controls && packet[3] == 0) {
        for (size_t i = 0; i < app.control_count; ++i) {
            bool pressed = mx_pressed(packet + 4, length - 4, app.controls_info[i].cid);
            if (app.diverted[i] && pressed && !app.was_pressed[i]) {
                if (runtime.verbose) fprintf(stderr, "Control: %04x\n", app.controls_info[i].cid);
                const MXBinding *binding = mx_binding_for_control(&app.config, app.controls_info[i].cid, app.controls_info[i].slot);
                if (binding) post_shortcut(binding);
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

static void clear_scroll(void);

/* HID++ 1.0 receiver routing errors identify an unavailable paired slot.
   HID++ 2.0 errors (0xff), even with the same code, do not mean this. */
static bool receiver_slot_offline(void) {
    return app.receiver && app.address >= 1 && app.address <= 6 &&
        app.request_address == app.address && app.request_feature == 0 &&
        (app.request_tag >> 4) == 1 && app.received && app.request_failed &&
        app.request_error_type == 0x8f &&
        (app.request_error_code == 0x08 || app.request_error_code == 0x09);
}

static void input_report(void *context, IOReturn result, void *sender, IOHIDReportType type,
                         uint32_t id, uint8_t *report, CFIndex size) {
    (void)sender; (void)type;
    Transport *transport = context;
    if (result != kIOReturnSuccess || size <= 0 || !transport->online) return;
    uint8_t packet[MX_REPORT_MAX];
    size_t length = mx_normalize_report(id, report, (size_t)size, packet);
    if (length < 4) return;
    if (transport->receiver_kind && packet[2] == 0x41) {
        transport->scan = true;
        Mouse *changed = NULL;
        for (changed = runtime.mice; changed; changed = changed->next)
            if (changed->transport == transport && changed->address == packet[1]) break;
        if (changed) {
            Mouse *previous = runtime.current; runtime.current = changed;
            changed->connected = false; changed->initialisation_attempted = false;
            clear_scroll(); cancel_reconnect(); runtime.current = previous;
        }
        schedule_work();
    }
    Mouse *mouse = transport->request;
    if (!mouse || packet[1] != mouse->request_address) {
        for (mouse = runtime.mice; mouse; mouse = mouse->next)
            if (mouse->transport == transport && mouse->address == packet[1]) break;
    }
    if (!mouse) return;
    Mouse *previous = runtime.current; runtime.current = mouse;
    if (app.waiting && packet[1] == app.request_address && packet[2] == app.request_feature && packet[3] == app.request_tag) {
        memcpy(app.response, packet, length);
        app.response_length = length; app.received = true;
    } else if (app.waiting && packet[1] == app.request_address && (packet[2] == 0xff || packet[2] == 0x8f) && length >= 6 &&
               packet[3] == app.request_feature && packet[4] == app.request_tag) {
        app.received = app.request_failed = true;
        app.request_error_type = packet[2]; app.request_error_code = packet[5];
        if (runtime.verbose || !receiver_slot_offline()) fprintf(stderr, "HID++ error 0x%02x for feature %02x, function %02x\n", packet[5], packet[3], packet[4] >> 4);
    } else if ((packet[3] & 0x0f) == 0) notification(packet, length);
    runtime.current = previous;
}

static bool divert(size_t button, bool enabled) {
    uint8_t parameters[] = {(uint8_t)(app.controls_info[button].cid >> 8), (uint8_t)app.controls_info[button].cid,
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

/* Pairing may change while the USB receiver itself remains connected. */
static bool receiver_identity_matches(void) {
    if (!app.receiver) return true;
    if (app.address < 1 || app.address > 6) return false;
    uint8_t sub = (uint8_t)((app.transport->receiver_kind == MX_RECEIVER_BOLT ? 0x50 : 0x1f) + app.address);
    MXReceiverPairing pairing;
    if (!exchange(0xff, 0x83, 0xb5, &sub, 1) ||
        !mx_parse_receiver_pairing(app.transport->receiver_kind, app.address, app.response, app.response_length, &pairing) ||
        pairing.product_id != app.product_id) return false;
    if (!app.unit_id) return true;
    if (!app.identity_feature || !call(app.identity_feature, 0, NULL, 0) || app.response_length < 9) return false;
    uint32_t unit = (uint32_t)app.response[5] << 24 | (uint32_t)app.response[6] << 16 |
        (uint32_t)app.response[7] << 8 | app.response[8];
    return unit == app.unit_id;
}

static void read_battery(bool force) {
    if (!app.connected || !app.battery || app.waiting ||
        (!force && CFAbsoluteTimeGetCurrent() - app.battery_checked_at < 60)) return;
    app.battery_checked_at = CFAbsoluteTimeGetCurrent();
    app.battery_percent = app.battery_charging = -1; app.battery_status = NULL;
    if (!receiver_identity_matches() ||
        !call(app.battery, app.battery_unified ? 1 : 0, NULL, 0) ||
        app.response_length < (app.battery_unified ? 8u : 7u)) return;
    unsigned percent = app.response[4], code = app.response[6];
    const char *level = NULL;
    if (app.battery_unified) {
        switch (app.response[5]) {
            case 1: level = "Critical"; break;
            case 2: level = "Low"; break;
            case 4: level = "Good"; break;
            case 8: level = "Full"; break;
        }
    } else if (percent > 0 && percent <= 100) {
        /* Coarse 0x1000 devices report thresholds, not a measured percentage. */
        level = percent < 11 ? "Critical" : percent < 30 ? "Low" : percent < 81 ? "Good" : "Full";
    }
    const char *state = level;
    int charging = -1;
    switch (code) {
        case 0: charging = 0; break;
        case 1: case 2: state = "Charging"; charging = 1; break;
        case 3: state = "Full"; charging = 0; break;
        case 4: state = "Charging slowly"; charging = 1; break;
        case 5: state = "Invalid battery"; break;
        case 6: state = "Battery temperature error"; break;
        case 7: state = "Charging error"; break;
    }
    /* 0 means unknown in 0x1000; unified state-of-charge can explicitly report 0%. */
    int reported = app.battery_percent_supported && percent <= 100 &&
        (app.battery_unified || percent > 0) ? (int)percent : -1;
    app.battery_percent = reported; app.battery_status = state; app.battery_charging = charging;
    if (runtime.probe) fprintf(stderr, "Battery: percent=%d status=%s\n", reported, state ? state : "unknown");
}

static void discover_battery(void) {
    app.battery = feature(0x1000);
    app.battery_unified = false;
    app.battery_percent_supported = false;
    app.battery_checked_at = 0;
    app.battery_percent = app.battery_charging = -1; app.battery_status = NULL;
    if (app.battery) {
        /* Capability: level count and flags; mileage bit distinguishes percentage. */
        if (call(app.battery, 1, NULL, 0) && app.response_length >= 6)
            app.battery_percent_supported = app.response[4] >= 10 && (app.response[5] & 2);
    } else {
        app.battery = feature(0x1004);
        app.battery_unified = app.battery != 0;
        if (app.battery && call(app.battery, 0, NULL, 0) && app.response_length >= 6)
            app.battery_percent_supported = (app.response[5] & 2) != 0;
    }
    read_battery(true);
}

static void publish_status_snapshot(void);

static bool restore(void) {
    clear_scroll();
    bool restored = true;
    if (app.receiver && !runtime.probe && !receiver_identity_matches()) {
        app.connected=false;
        memset(app.diverted,0,sizeof(app.diverted));
        app.wheel_changed=app.thumb_changed=false;
        return true; /* Never send cleanup writes to a replacement/unknown pairing. */
    }
    if (app.online && !runtime.probe) {
        for (size_t i = 0; i < app.control_count; ++i) if (app.diverted[i]) {
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
    cancel_reconnect();
    app.reconnect_delay = 0;
    app.configuring = true;
    if (!restore()) runtime.restoration_failed = true;
    app.connected = false;
    app.battery = 0;
    app.battery_checked_at = 0;
    app.battery_percent = app.battery_charging = -1; app.battery_status = NULL;
    app.online = app.configuring = false;
    app.controls = app.wheel = app.thumbwheel = app.dpi = app.smartshift = app.enhanced_shift = 0;
    memset(app.diverted, 0, sizeof(app.diverted));
    app.old_wheel_valid = app.old_thumb_valid = false;
}

static bool configure(void) {
    if (!restore()) {
        status("error", "Could not restore native reporting. Restart the mouse before continuing.");
        return false;
    }
    if (app.receiver && !app.connected) {
        status("waiting","Receiver pairing changed; waiting for a supported mouse.");
        return false;
    }
    bool okay = true, optional_unavailable = false;
    if (!CGPreflightPostEventAccess()) {
        status("permission", "macOS is denying input-event posting to MX Mouse Helper. Request Access in Settings; if already enabled, re-add the current helper.");
        return false;
    }
    for (size_t i = 0; i < app.control_count; ++i) {
        const MXBinding *binding = mx_binding_for_control(&app.config, app.controls_info[i].cid, app.controls_info[i].slot);
        if (!binding || binding->action == MX_NATIVE || !(app.controls_info[i].flags & 0x20)) continue;
        /* Mark before the request: a lost reply must still trigger restoration. */
        app.diverted[i] = true;
        if (!divert(i, true)) { okay = false; break; }
    }
    bool vertical = app.config.vertical_speed != 100 || app.config.invert_vertical || app.config.smooth;
    bool horizontal = app.config.horizontal_speed != 100 || app.config.invert_horizontal || app.config.smooth;
    if (vertical && app.wheel) {
        if (!app.old_wheel_valid) optional_unavailable = true;
        else {
            uint8_t mode = (uint8_t)((app.old_wheel & ~0x07) | 0x03);
            app.wheel_changed = true;
            if (!call(app.wheel, 2, &mode, 1)) {
                optional_unavailable = true;
                if (call(app.wheel, 2, &app.old_wheel, 1)) app.wheel_changed = false;
                else okay = false;
            }
        }
    }
    if (horizontal && app.thumbwheel) {
        if (!app.old_thumb_valid || !app.thumb_native || !app.thumb_diverted) optional_unavailable = true;
        else {
            uint8_t parameters[] = {1, 0};
            app.thumb_changed = true;
            if (!call(app.thumbwheel, 2, parameters, 2)) {
                optional_unavailable = true;
                if (call(app.thumbwheel, 2, app.old_thumb, 2)) app.thumb_changed = false;
                else okay = false;
            }
        }
    }
    if (app.config.dpi && app.dpi && app.dpi_valid) {
        uint8_t sensor = 0;
        if (!app.dpi || !call(app.dpi, 1, &sensor, 1) ||
            !mx_dpi_allowed(app.response + 4, app.response_length - 4, app.config.dpi)) optional_unavailable = true;
        else {
            uint8_t parameters[] = {0, (uint8_t)(app.config.dpi >> 8), (uint8_t)app.config.dpi};
            if (!call(app.dpi, 3, parameters, 3)) optional_unavailable = true;
        }
    }
    if (app.config.wheel_mode && app.shift_valid) {
        uint8_t index = app.enhanced_shift ? app.enhanced_shift : app.smartshift;
        uint8_t read_function = app.enhanced_shift ? 1 : 0;
        uint8_t write_function = app.enhanced_shift ? 2 : 1;
        if (!index || !call(index, read_function, NULL, 0) || app.response_length < 7) optional_unavailable = true;
        else {
            /* 255 means permanent ratchet. Zero leaves default threshold / torque unchanged. */
            uint8_t parameters[] = {app.config.wheel_mode == 2 ? 1 : 2,
                app.config.wheel_mode == 3 ? (uint8_t)app.config.smartshift : 255, 0};
            if (!call(index, write_function, parameters, 3)) optional_unavailable = true;
        }
    }
    if (!okay) {
        bool restored = restore();
        status("error", restored ?
            "A requested setting could not be applied. Button and scroll diversion have been returned to native; see helper.log." :
            "A requested setting and its cleanup failed. Restart the mouse before continuing; see helper.log.");
        return false;
    }
    status("running", optional_unavailable ? "Mouse connected. Custom controls are active; some optional settings were unavailable." : "Mouse connected. Custom controls are active.");
    return true;
}

static void initialise_device(void) {
    app.configuring = true;
    bool pinged = false, paired_offline = false;
    for (int i = 0; i < 3 && app.online && !runtime.stop; ++i) {
        uint8_t parameters[] = {0, 0, 0xa7};
        if (call(0, 1, parameters, 3) && app.response_length >= 7 && app.response[6] == 0xa7 && app.response[4] >= 2) {
            pinged = true; break;
        }
        if (receiver_slot_offline()) { paired_offline = true; break; }
    }
    if (!pinged) {
        if (paired_offline) status("waiting", "Paired mouse is asleep or disconnected. Wake it to reconnect automatically.");
        else status("error", "Mouse controls are inactive: no HID++ reply. Retrying automatically; wake the mouse and check Input Monitoring or other mouse utilities if this continues.");
        retry_connection();
        app.configuring = false;
        if (runtime.stop || app.removed || runtime.reload) schedule_work();
        return;
    }
    uint8_t name_feature = feature(0x0005);
    bool typed = name_feature && call(name_feature, 2, NULL, 0) && app.response_length >= 5;
    if (typed && app.response[4] != 3 && app.response[4] != 5) {
        status("unsupported", "This HID++ interface is not a mouse or trackball.");
        app.removed = true;
        if (!app.receiver) app.transport->removed = true;
        app.configuring = false; schedule_work(); return;
    }
    if (!typed && !app.receiver && !app.definition && !app.transport->mouse_usage) {
        status("waiting", "Waiting for positive HID++ mouse identification; controls remain native.");
        retry_connection(); app.configuring = false; return;
    }
    if (name_feature && call(name_feature, 0, NULL, 0) && app.response_length >= 5) {
        size_t total = app.response[4], offset = 0;
        if (total >= sizeof(app.name)) total = sizeof(app.name) - 1;
        while (offset < total) {
            uint8_t index = (uint8_t)offset;
            if (!call(name_feature, 1, &index, 1) || app.response_length <= 4) break;
            size_t size = app.response_length - 4;
            if (size > total - offset) size = total - offset;
            memcpy(app.name + offset, app.response + 4, size); offset += size;
        }
        if (offset) app.name[offset] = 0;
    }
    app.identity_feature = feature(0x0003);
    if (app.identity_feature && call(app.identity_feature, 0, NULL, 0) && app.response_length >= 9) {
        uint32_t unit = (uint32_t)app.response[5] << 24 | (uint32_t)app.response[6] << 16 |
            (uint32_t)app.response[7] << 8 | app.response[8];
        if (unit) {
            if (app.unit_id && app.unit_id != unit) {
                /* The old mouse is gone; do not restore its settings on a replacement. */
                memset(app.diverted, 0, sizeof(app.diverted));
                memset(app.was_pressed, 0, sizeof(app.was_pressed));
                app.wheel_changed = app.thumb_changed = false;
                app.old_wheel_valid = app.old_thumb_valid = false; clear_scroll();
            }
            app.unit_id = unit;
            snprintf(app.id, sizeof(app.id), "logitech-%04x-%08x", app.product_id, unit);
            char error[256];
            if (!mx_load_device_config(&app.config, app.id, error, sizeof(error))) {
                status("error", error); app.configuring = false; return;
            }
        }
    }
    /* Clean up the previous live session before replacing its control inventory. */
    if (!runtime.probe && !restore()) {
        status("error", "Could not restore the previous control session. Restart this mouse.");
        app.configuring = false; return;
    }
    app.controls = feature(0x1b04);
    app.wheel = feature(0x2121);
    app.thumbwheel = feature(0x2150);
    app.dpi = feature(0x2201);
    app.smartshift = feature(0x2110);
    app.enhanced_shift = feature(0x2111);
    uint8_t sensor = 0;
    app.dpi_valid = app.dpi && call(app.dpi, 1, &sensor, 1) && app.response_length >= 6;
    uint8_t shift_index = app.enhanced_shift ? app.enhanced_shift : app.smartshift;
    app.shift_valid = shift_index && call(shift_index, app.enhanced_shift ? 1 : 0, NULL, 0) && app.response_length >= 7;
    app.control_count = 0;
    memset(app.button_controls, 0, sizeof(app.button_controls));
    if (app.controls && call(app.controls, 0, NULL, 0) && app.response_length >= 5) {
        uint8_t count = app.response[4];
        for (uint8_t i = 0; i < count && i < 64; ++i) {
            MXControl control;
            if (!call(app.controls, 1, &i, 1) || !mx_control_from_report(app.response + 4, app.response_length - 4, &control)) continue;
            if (app.control_count < MX_CONTROL_MAX) app.controls_info[app.control_count++] = control;
            else if (control.divertible) {
                /* Keep later programmable buttons ahead of read-only controls. */
                for (size_t j = 0; j < app.control_count; ++j) if (!app.controls_info[j].divertible) {
                    app.controls_info[j] = control; break;
                }
            }
        }
        for (size_t i = 0; i < app.control_count; ++i) {
            int slot = app.controls_info[i].slot;
            if (slot >= 0 && slot < MX_BUTTON_COUNT) {
                if (app.button_controls[slot]) app.controls_info[i].slot = -1;
                else app.button_controls[slot] = app.controls_info[i].cid;
            }
        }
    }
    app.old_wheel_valid = app.old_thumb_valid = false;
    app.thumb_native = app.thumb_diverted = 0;

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
    if (app.online && !runtime.stop && !app.removed) {
        app.connected = true;
        cancel_reconnect();
        app.reconnect_delay = 0;
        discover_battery();
        fprintf(stderr, "Features: controls=%02x wheel=%02x thumb=%02x dpi=%02x shift=%02x/%02x\n",
            app.controls, app.wheel, app.thumbwheel, app.dpi, app.smartshift, app.enhanced_shift);
        if (runtime.probe) status("probe", "Bluetooth HID++ capability query completed; no settings written.");
        else configure();
    }
    app.configuring = false;
    if (runtime.stop || app.removed || runtime.reload) schedule_work();
}

static Mouse *find_mouse(Transport *transport, uint8_t address) {
    for (Mouse *mouse = runtime.mice; mouse; mouse = mouse->next)
        if (mouse->transport == transport && mouse->address == address) return mouse;
    return NULL;
}

static Mouse *add_mouse(Transport *transport, uint8_t address, uint32_t product) {
    Mouse *mouse = calloc(1, sizeof(*mouse));
    if (!mouse) return NULL;
    mouse->transport = transport; mouse->address = address;
    mouse->receiver = transport->receiver_kind != MX_RECEIVER_NONE;
    mouse->product_id = product; mouse->online = true;
    mouse->definition = mx_device_lookup(0x046d, product);
    snprintf(mouse->name, sizeof(mouse->name), "%s", mouse->definition ? mouse->definition->name : "Logitech HID++ mouse");
    snprintf(mouse->id, sizeof(mouse->id), "logitech-%04x-%s%08x-%u", product, transport->serial, transport->location_id, address);
    mouse->battery_percent = mouse->battery_charging = -1;
    char error[256];
    if (!mx_load_device_config(&mouse->config, mouse->id, error, sizeof(error))) {
        fprintf(stderr, "%s\n", error); free(mouse); return NULL;
    }
    mouse->next = runtime.mice; runtime.mice = mouse; runtime.had_device = true;
    return mouse;
}

static void scan_receiver(Transport *transport) {
    /* Temporary stack query context does not register callbacks or allocate state. */
    Mouse query = {.transport = transport, .online = true, .address = 0xff};
    Mouse *previous = runtime.current; runtime.current = &query;
    bool complete = true;
    if (!runtime.probe && !transport->notifications_changed && exchange(0xff, 0x81, 0x00, NULL, 0) && query.response_length >= 7) {
        memcpy(transport->old_notifications, query.response + 4, 3);
        uint8_t flags[3]; memcpy(flags, transport->old_notifications, 3); flags[1] |= 0x09;
        if (memcmp(flags, transport->old_notifications, 3)) {
            /* A lost reply still requires restoration when closing this receiver. */
            transport->notifications_changed = true;
            exchange(0xff, 0x80, 0x00, flags, sizeof(flags));
        }
    }
    for (uint8_t slot = 1; slot <= 6 && transport->online && !runtime.stop; ++slot) {
        uint8_t sub = (uint8_t)((transport->receiver_kind == MX_RECEIVER_BOLT ? 0x50 : 0x1f) + slot);
        MXReceiverPairing pairing;
        query.received = query.request_failed = false;
        if (!exchange(0xff, 0x83, 0xb5, &sub, 1)) {
            if (!query.received || !query.request_failed) complete = false;
            continue;
        }
        bool paired = mx_parse_receiver_pairing(transport->receiver_kind, slot, query.response, query.response_length, &pairing);
        Mouse *mouse = find_mouse(transport, slot);
        if (mouse && (!paired || pairing.product_id != mouse->product_id || (transport->receiver_kind == MX_RECEIVER_BOLT && mouse->unit_id &&
            ((uint32_t)pairing.unit_id[0] << 24 | (uint32_t)pairing.unit_id[1] << 16 | (uint32_t)pairing.unit_id[2] << 8 | pairing.unit_id[3]) != mouse->unit_id) || (pairing.kind != 2 && pairing.kind != 3))) {
            /* Pairing replacement: never clean up an unrelated device at the old address. */
            mouse->online = false; mouse->removed = true; schedule_work(); mouse = NULL;
        }
        if (!paired || (pairing.kind != 2 && pairing.kind != 3)) continue;
        if (!mouse) mouse = add_mouse(transport, slot, pairing.product_id);
        if (mouse && !mouse->connected) { mouse->initialisation_attempted = false; mouse->online = true; }
    }
    runtime.current = previous;
    if (complete) { cancel_receiver_retry(transport); transport->scan_delay = 0; }
    else retry_receiver_scan(transport);
}

static void matched(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    (void)context; (void)sender;
    if (result != kIOReturnSuccess) return;
    for (Transport *transport = runtime.transports; transport; transport = transport->next)
        if (transport->device == device) return;
    int vendor = 0, product = 0;
    CFTypeRef vendor_value = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDVendorIDKey));
    CFTypeRef product_value = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductIDKey));
    if (!vendor_value || !product_value || CFGetTypeID(vendor_value) != CFNumberGetTypeID() ||
        CFGetTypeID(product_value) != CFNumberGetTypeID() ||
        !CFNumberGetValue(vendor_value, kCFNumberIntType, &vendor) ||
        !CFNumberGetValue(product_value, kCFNumberIntType, &product) || vendor != 0x046d) return;
    CFTypeRef descriptor = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDReportDescriptorKey));
    size_t sizes[256];
    if (!descriptor || CFGetTypeID(descriptor) != CFDataGetTypeID() ||
        !mx_output_reports(CFDataGetBytePtr(descriptor), (size_t)CFDataGetLength(descriptor), sizes) ||
        (sizes[0x10] != 6 && sizes[0x11] != 19)) return;
    Transport *transport = calloc(1, sizeof(*transport));
    if (!transport) return;
    IOReturn opened = IOHIDDeviceOpen(device, kIOHIDOptionsTypeNone);
    if (opened != kIOReturnSuccess) { free(transport); status("error", "Cannot open Logitech HID interface. Grant Input Monitoring to MX Mouse Helper."); return; }
    transport->device = (IOHIDDeviceRef)CFRetain(device); transport->online = true;
    transport->receiver_kind = mx_receiver_kind((uint32_t)product); transport->product_id = (uint32_t)product;
    transport->mouse_usage = IOHIDDeviceConformsTo(device, 1, 2);
    transport->short_size = (uint8_t)sizes[0x10]; transport->long_size = (uint8_t)sizes[0x11];
    CFTypeRef location = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDLocationIDKey));
    if (location && CFGetTypeID(location) == CFNumberGetTypeID()) CFNumberGetValue(location, kCFNumberSInt32Type, &transport->location_id);
    CFTypeRef serial = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDSerialNumberKey));
    if (serial && CFGetTypeID(serial) == CFStringGetTypeID()) CFStringGetCString(serial, transport->serial, sizeof(transport->serial), kCFStringEncodingUTF8);
    transport->next = runtime.transports; runtime.transports = transport;
    IOHIDDeviceRegisterInputReportCallback(device, transport->input, sizeof(transport->input), input_report, transport);
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    if (transport->receiver_kind) transport->scan = true;
    else add_mouse(transport, 0xff, (uint32_t)product);
    schedule_work();
}

static void removed(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    (void)context; (void)result; (void)sender;
    for (Transport *transport = runtime.transports; transport; transport = transport->next) {
        if (transport->device != device) continue;
        transport->online = false; transport->removed = true; cancel_receiver_retry(transport);
        for (Mouse *mouse = runtime.mice; mouse; mouse = mouse->next)
            if (mouse->transport == transport) { mouse->online = false; mouse->removed = true; }
        schedule_work();
    }
}

static void release_transport(Transport *transport) {
    cancel_receiver_retry(transport);
    if (transport->online && transport->notifications_changed && !runtime.probe) {
        Mouse query = {.transport = transport, .online = true, .address = 0xff};
        Mouse *previous = runtime.current; runtime.current = &query;
        if (!exchange(0xff, 0x80, 0x00, transport->old_notifications, 3)) runtime.restoration_failed = true;
        runtime.current = previous;
    }
    IOHIDDeviceRegisterInputReportCallback(transport->device, transport->input, sizeof(transport->input), NULL, NULL);
    IOHIDDeviceUnscheduleFromRunLoop(transport->device, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    IOHIDDeviceClose(transport->device, kIOHIDOptionsTypeNone);
    CFRelease(transport->device); free(transport);
}

static void work(void *context) {
    (void)context;
    if (runtime.working) return;
    runtime.working = true;
    bool reload = runtime.reload, battery = runtime.battery_requested;
    runtime.reload = runtime.battery_requested = false;
    if (!runtime.stop) for (Transport *transport = runtime.transports; transport; transport = transport->next) {
        if (reload && transport->receiver_kind) {
            cancel_receiver_retry(transport); transport->scan_delay = 0; transport->scan = true;
        }
        if (transport->scan && transport->online) { transport->scan = false; scan_receiver(transport); }
    }
    Mouse **link = &runtime.mice;
    while (*link) {
        Mouse *mouse = *link; runtime.current = mouse;
        if (runtime.stop || mouse->removed) {
            close_device();
            /* Matching callbacks may prepend a mouse while restore pumps the run loop. */
            link = &runtime.mice;
            while (*link && *link != mouse) link = &(*link)->next;
            if (*link) *link = mouse->next;
            free(mouse); runtime.current = NULL; continue;
        }
        if (reload) {
            char error[256] = {0}; MXConfig replacement;
            if (!mx_load_device_config(&replacement, mouse->id, error, sizeof(error))) status("error", error);
            else {
                mouse->configuring = true;
                if (restore()) {
                    mouse->config = replacement;
                    if (mouse->connected && !runtime.probe) configure();
                    else { cancel_reconnect(); mouse->reconnect_delay = 0; mouse->initialisation_attempted = false; }
                } else status("error", "Could not restore native reporting. Restart the mouse before applying settings.");
                mouse->configuring = false;
            }
        }
        if (mouse->online && !mouse->connected && !mouse->initialisation_attempted) {
            mouse->initialisation_attempted = true; initialise_device();
        }
        if (runtime.stop || mouse->removed) continue;
        if (battery) read_battery(false);
        link = &mouse->next;
    }
    runtime.current = NULL;
    Transport **transport_link = &runtime.transports;
    while (*transport_link) {
        Transport *transport = *transport_link;
        if (runtime.stop || transport->removed) {
            *transport_link = transport->next; release_transport(transport); continue;
        }
        transport_link = &transport->next;
    }
    publish_status_snapshot();
    runtime.working = false;
    bool pending = false;
    for (Mouse *mouse = runtime.mice; mouse; mouse = mouse->next)
        pending |= mouse->removed || (mouse->online && !mouse->connected && !mouse->initialisation_attempted);
    for (Transport *transport = runtime.transports; transport; transport = transport->next) pending |= transport->scan || transport->removed;
    if (runtime.stop) CFRunLoopStop(CFRunLoopGetMain());
    else if (pending || runtime.reload || runtime.battery_requested) schedule_work();
}

static const char *connection_name(const Mouse *mouse) {
    if(mouse->receiver) return mouse->transport->receiver_kind == MX_RECEIVER_BOLT ? "Bolt" : "Unifying";
    CFTypeRef transport=mouse->transport->device ? IOHIDDeviceGetProperty(mouse->transport->device,CFSTR(kIOHIDTransportKey)) : NULL;
    if(transport && CFGetTypeID(transport)==CFStringGetTypeID()) {
        if(CFStringHasPrefix(transport,CFSTR("Bluetooth"))) return "Bluetooth";
        if(CFEqual(transport,CFSTR("USB"))) return "USB";
    }
    return "Direct HID++";
}

static void publish_status_snapshot(void) {
    size_t count = 0;
    for (Mouse *mouse = runtime.mice; mouse; mouse = mouse->next) ++count;
    MXDeviceSnapshot *snapshots = count ? calloc(count, sizeof(*snapshots)) : NULL;
    if (count && !snapshots) return;
    size_t i = 0; bool connected = false;
    const char *summary_state = "waiting", *summary_detail = "Waiting for Logitech HID++ mice.";
    for (Mouse *mouse = runtime.mice; mouse; mouse = mouse->next) {
        uint32_t capabilities = (mouse->control_count ? MX_CAP_BUTTONS : 0) | (mouse->wheel && mouse->old_wheel_valid ? MX_CAP_HIRES_SCROLL : 0) |
            (mouse->thumbwheel && mouse->old_thumb_valid && mouse->thumb_native && mouse->thumb_diverted ? MX_CAP_THUMBWHEEL : 0) | (mouse->dpi_valid ? MX_CAP_DPI : 0) |
            (mouse->shift_valid ? MX_CAP_SMARTSHIFT : 0) | (mouse->battery ? MX_CAP_BATTERY : 0);
        for (size_t j = 0; j < mouse->control_count; ++j)
            if (mouse->controls_info[j].cid == 0x01a0) capabilities |= MX_CAP_HAPTIC;
        snapshots[i++] = (MXDeviceSnapshot){.id = mouse->id, .name = mouse->name,
            .transport = connection_name(mouse),
            .state = mouse->state, .detail = mouse->detail, .connected = mouse->connected, .capabilities = capabilities,
            .controls = mouse->controls_info, .control_count = mouse->control_count,
            .battery_percent = mouse->battery_percent, .battery_charging = mouse->battery_charging, .battery_status = mouse->battery_status};
        if (!strcmp(mouse->state, "running")) connected = true;
        else if (!connected && mouse->state[0]) { summary_state = mouse->state; summary_detail = mouse->detail; }
    }
    mx_write_device_status(runtime.stop ? "stopped" : connected ? "running" : summary_state,
        runtime.stop ? "Helper stopped. Native reporting restored where connected." : connected ? "Connected mice are active." : summary_detail, snapshots, count);
    free(snapshots);
}

static void notify(CFNotificationCenterRef center, void *observer, CFStringRef name,
                   const void *object, CFDictionaryRef user_info) {
    (void)center; (void)observer; (void)object; (void)user_info;
    if (CFEqual(name, CFSTR("local.mxmouse.reload"))) runtime.reload = true;
    else if (CFEqual(name, CFSTR("local.mxmouse.stop"))) runtime.stop = true;
    else if (CFEqual(name, CFSTR("local.mxmouse.status"))) {
        runtime.battery_requested = true;
    }
    schedule_work();
}

static void finish_timer(CFRunLoopTimerRef timer, void *context) {
    (void)timer; (void)context;
    runtime.stop = true; schedule_work();
}

static void power_changed(void *context, io_service_t service, natural_t message, void *argument) {
    (void)context; (void)service;
    if (message == kIOMessageCanSystemSleep || message == kIOMessageSystemWillSleep)
        IOAllowPowerChange(runtime.power, (intptr_t)argument);
    else if (message == kIOMessageSystemHasPoweredOn && runtime.transports) {
        runtime.reload = true; schedule_work();
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
        if (!strcmp(argv[i], "--probe")) { runtime.probe = true; duration = 15; }
        else if (!strcmp(argv[i], "--permissions")) permissions = true;
        else if (!strcmp(argv[i], "--check-permissions")) check_permissions = true;
        else if (!strcmp(argv[i], "--baseline")) baseline = true;
        else if (!strcmp(argv[i], "--offline")) offline = true;
        else if (!strcmp(argv[i], "--verbose")) runtime.verbose = true;
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
        runtime.manager = IOHIDManagerCreate(NULL, kIOHIDOptionsTypeNone);
        runtime.event_source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
        mx_write_status("baseline", "Framework baseline only; mouse not opened.", false);
        if (duration) {
            CFRunLoopSourceContext context = {0};
            runtime.work = CFRunLoopSourceCreate(NULL, 0, &context);
            CFRunLoopAddSource(CFRunLoopGetMain(), runtime.work, kCFRunLoopDefaultMode);
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, duration, false);
        }
        mx_write_status("baseline", "Framework baseline only; mouse not opened.", false);
        if (runtime.work) CFRelease(runtime.work);
        if (runtime.event_source) CFRelease(runtime.event_source);
        CFRelease(runtime.manager); return 0;
    }
    runtime.lock_fd = acquire_lock();
    if (runtime.lock_fd < 0) { fprintf(stderr, "Another MX Mouse helper is already running, or its lock is unavailable.\n"); return 73; }
    char message[256] = {0};
    if (!offline && mx_conflicting_process(message)) { status("conflict", message); close(runtime.lock_fd); return 75; }
    MXConfig initial_config;
    if (!mx_load_config(&initial_config, message, sizeof(message))) { status("error", message); close(runtime.lock_fd); return 65; }
    if (!offline && IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted) {
        status("permission", "Grant Input Monitoring to MX Mouse Helper using the settings app, then restart the helper.");
        close(runtime.lock_fd); return 77;
    }
    runtime.event_source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    CFRunLoopSourceContext context = {.perform = work};
    runtime.work = CFRunLoopSourceCreate(NULL, 0, &context);
    CFRunLoopAddSource(CFRunLoopGetMain(), runtime.work, kCFRunLoopDefaultMode);
    CFNotificationCenterRef center = CFNotificationCenterGetDistributedCenter();
    CFNotificationCenterAddObserver(center, NULL, notify, CFSTR("local.mxmouse.reload"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(center, NULL, notify, CFSTR("local.mxmouse.stop"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(center, NULL, notify, CFSTR("local.mxmouse.status"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN); signal(SIGHUP, SIG_IGN);
    dispatch_source_t termination = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(termination, ^{ runtime.stop = true; schedule_work(); }); dispatch_resume(termination);
    dispatch_source_t interrupt = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(interrupt, ^{ runtime.stop = true; schedule_work(); }); dispatch_resume(interrupt);
    dispatch_source_t reload = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGHUP, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(reload, ^{ runtime.reload = true; schedule_work(); }); dispatch_resume(reload);
    runtime.manager = IOHIDManagerCreate(NULL, kIOHIDOptionsTypeNone);
    runtime.power = IORegisterForSystemPower(NULL, &runtime.power_port, power_changed, &runtime.power_notifier);
    if (runtime.power) CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(runtime.power_port), kCFRunLoopDefaultMode);
    int vendor = 0x046d;
    CFNumberRef vendor_number = CFNumberCreate(NULL, kCFNumberIntType, &vendor);
    const void *keys[] = {CFSTR(kIOHIDVendorIDKey)};
    const void *values[] = {vendor_number};
    CFDictionaryRef match = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!offline) IOHIDManagerSetDeviceMatching(runtime.manager, match);
    CFRelease(match); CFRelease(vendor_number);
    if (!offline) {
        IOHIDManagerRegisterDeviceMatchingCallback(runtime.manager, matched, NULL);
        IOHIDManagerRegisterDeviceRemovalCallback(runtime.manager, removed, NULL);
        IOHIDManagerScheduleWithRunLoop(runtime.manager, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    }
    status("waiting", offline ? "Offline measurement: HID device access is disabled." : "Waiting for a supported Bluetooth or receiver mouse. The settings app can be closed.");
    IOReturn opened = offline ? kIOReturnSuccess : IOHIDManagerOpen(runtime.manager, kIOHIDOptionsTypeNone);
    if (opened != kIOReturnSuccess) {
        status("error", "Cannot open the HID manager. Check Input Monitoring for MX Mouse Helper.");
        runtime.stop = true; schedule_work();
    }
    CFRunLoopTimerRef timer = NULL;
    if (duration) {
        timer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + duration, 0, 0, 0, finish_timer, NULL);
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, kCFRunLoopDefaultMode);
    }
    CFRunLoopRun();
    runtime.stop = true; work(NULL);
    if (!offline) {
        IOHIDManagerUnscheduleFromRunLoop(runtime.manager, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        IOHIDManagerClose(runtime.manager, kIOHIDOptionsTypeNone);
    }
    CFRelease(runtime.manager);
    if (timer) { CFRunLoopTimerInvalidate(timer); CFRelease(timer); }
    CFNotificationCenterRemoveEveryObserver(center, NULL);
    CFRunLoopRemoveSource(CFRunLoopGetMain(), runtime.work, kCFRunLoopDefaultMode); CFRelease(runtime.work);
    if (runtime.event_source) CFRelease(runtime.event_source);
    if (runtime.power) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(runtime.power_port), kCFRunLoopDefaultMode);
        IODeregisterForSystemPower(&runtime.power_notifier);
        IOServiceClose(runtime.power);
        IONotificationPortDestroy(runtime.power_port);
    }
    dispatch_source_cancel(termination); dispatch_source_cancel(interrupt); dispatch_source_cancel(reload);
    status("stopped", runtime.restoration_failed ? "Helper stopped, but native reporting could not be restored. Restart the mouse." :
        runtime.probe && !runtime.had_device ? "Probe ended without a connected mouse." : "Helper stopped. Native button and wheel reporting restored where connected.");
    close(runtime.lock_fd);
    return runtime.probe && !runtime.had_device ? 69 : 0;
}
