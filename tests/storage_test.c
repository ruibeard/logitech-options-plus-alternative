#include "storage.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static CFMutableDictionaryRef dictionary(void) {
    return CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}
static void set_number(CFMutableDictionaryRef dictionary, CFStringRef key, int value) {
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberIntType, &value);
    CFDictionarySetValue(dictionary, key, number); CFRelease(number);
}

static void device_profiles(const char *path) {
    MXConfig first, second, inherited;
    char error[256];
    CFMutableDictionaryRef root = dictionary(), profiles = dictionary();
    CFMutableDictionaryRef a = dictionary(), b = dictionary(), controls = dictionary(), haptic = dictionary();
    set_number(root, CFSTR("verticalSpeed"), 79);
    set_number(a, CFSTR("verticalSpeed"), 145);
    set_number(b, CFSTR("dpi"), 8000);
    set_number(haptic, CFSTR("mode"), MX_SHORTCUT);
    set_number(haptic, CFSTR("keyCode"), 21);
    set_number(haptic, CFSTR("modifiers"), (1 << 20) | (1 << 17));
    CFDictionarySetValue(controls, CFSTR("01a0"), haptic);
    CFDictionarySetValue(a, CFSTR("controls"), controls);
    CFMutableDictionaryRef defaults = dictionary(), empty = dictionary();
    CFDictionarySetValue(defaults, CFSTR("00ff"), haptic);
    CFDictionarySetValue(root, CFSTR("controls"), defaults);
    CFDictionarySetValue(b, CFSTR("controls"), empty);
    CFRelease(defaults); CFRelease(empty);
    CFDictionarySetValue(profiles, CFSTR("mouse-a"), a);
    CFDictionarySetValue(profiles, CFSTR("mouse-b"), b);
    CFDictionarySetValue(root, CFSTR("devices"), profiles);
    assert(mx_write_plist(path, root));
    assert(mx_load_device_config(&first, "mouse-a", error, sizeof(error)));
    assert(mx_load_device_config(&second, "mouse-b", error, sizeof(error)));
    assert(mx_load_device_config(&inherited, "mouse-c", error, sizeof(error)));
    assert(first.vertical_speed == 145 && first.extra_button_count == 1);
    assert(second.vertical_speed == 79 && second.dpi == 8000 && second.extra_button_count == 0);
    assert(inherited.vertical_speed == 79 && inherited.dpi == 0);
    assert(inherited.extra_button_count == 1 && inherited.extra_buttons[0].cid == 0x00ff);
    assert(mx_binding_for_control(&first, 0x00ff, -1)->action == MX_NATIVE);
    assert(mx_binding_for_control(&first, 0x01a0, -1)->key == 21);
    assert(mx_binding_for_control(&second, 0x01a0, -1)->action == MX_NATIVE);
    assert(mx_binding_for_control(&first, 0x00c3, 3)->action == MX_NATIVE);
    /* A new unit ID of a saved model inherits that model's profile, never another model's. */
    CFMutableDictionaryRef m705 = dictionary(), other = dictionary();
    set_number(m705, CFSTR("verticalSpeed"), 200);
    set_number(other, CFSTR("verticalSpeed"), 150);
    CFDictionarySetValue(profiles, CFSTR("logitech-101b-00140000-1"), m705);
    CFDictionarySetValue(profiles, CFSTR("logitech-406d-0e87b8b8"), other);
    CFRelease(m705); CFRelease(other);
    assert(mx_write_plist(path, root));
    assert(mx_load_device_config(&first, "logitech-101b-fd214577", error, sizeof(error)) && first.vertical_speed == 200);
    assert(mx_load_device_config(&first, "logitech-4082-4d86c824", error, sizeof(error)) && first.vertical_speed == 79);
    CFDictionaryRemoveValue(profiles, CFSTR("logitech-101b-00140000-1"));
    CFDictionaryRemoveValue(profiles, CFSTR("logitech-406d-0e87b8b8"));
    /* Adding saved devices must not hit the former single-profile 64 KiB cap. */
    char archived_data[70001]; memset(archived_data, 'x', sizeof(archived_data) - 1); archived_data[70000] = 0;
    CFStringRef archived = CFStringCreateWithCString(NULL, archived_data, kCFStringEncodingASCII);
    CFDictionarySetValue(profiles, CFSTR("archived-device"), archived); CFRelease(archived);
    assert(mx_write_plist(path, root));
    assert(mx_load_device_config(&first, "mouse-a", error, sizeof(error)));
    /* Invalid unrelated device settings must not disable another mouse. */
    CFDictionarySetValue(profiles, CFSTR("mouse-b"), CFSTR("malformed"));
    assert(mx_write_plist(path, root));
    assert(mx_load_device_config(&first, "mouse-a", error, sizeof(error)));
    assert(!mx_load_device_config(&second, "mouse-b", error, sizeof(error)));
    /* Reject ambiguous duplicate CIDs and malformed keys/binding values. */
    CFDictionarySetValue(controls, CFSTR("01A0"), haptic);
    assert(mx_write_plist(path, root));
    assert(!mx_load_device_config(&first, "mouse-a", error, sizeof(error)));
    CFDictionaryRemoveValue(controls, CFSTR("01A0"));
    CFDictionarySetValue(controls, CFSTR("zzzz"), haptic);
    assert(mx_write_plist(path, root));
    assert(!mx_load_device_config(&first, "mouse-a", error, sizeof(error)));
    CFDictionaryRemoveValue(controls, CFSTR("zzzz"));
    set_number(haptic, CFSTR("modifiers"), 1 << 16);
    assert(mx_write_plist(path, root));
    assert(!mx_load_device_config(&first, "mouse-a", error, sizeof(error)));
    CFRelease(haptic); CFRelease(controls); CFRelease(a); CFRelease(b); CFRelease(profiles); CFRelease(root);
}

static void device_snapshots(void) {
    MXControl master[] = {{0x00c3, 3, true, 0x20}, {0x01a0, -1, true, 0x20}};
    MXControl m705[] = {{0x0052, 0, true, 0x20}, {0x0053, 1, true, 0x20}};
    MXDeviceSnapshot devices[] = {
        {.id="master", .name="MX Master 4", .transport="Bluetooth", .state="running", .detail="Active",
         .connected=true, .capabilities=MX_CAP_BUTTONS|MX_CAP_HIRES_SCROLL|MX_CAP_DPI|MX_CAP_HAPTIC,
         .controls=master, .control_count=2, .battery_percent=75, .battery_charging=0},
        {.id="m705", .name="Logitech M705", .transport="Unifying", .state="running", .detail="Active",
         .connected=true, .capabilities=MX_CAP_BUTTONS, .controls=m705, .control_count=2,
         .battery_percent=-1, .battery_charging=-1, .battery_status="Good"},
    };
    mx_write_device_status("running", "Two mice active", devices, 2);
    char path[PATH_MAX]; assert(mx_path(path, "status.plist"));
    CFDictionaryRef status = (CFDictionaryRef)mx_read_plist(path);
    CFArrayRef list = CFDictionaryGetValue(status, CFSTR("devices"));
    assert(CFArrayGetCount(list) == 2);
    CFDictionaryRef second = CFArrayGetValueAtIndex(list, 1);
    CFArrayRef buttons = CFDictionaryGetValue(second, CFSTR("controls"));
    assert(CFArrayGetCount(buttons) == 2); /* Never fabricate an absent thumb control. */
    CFDictionaryRef capabilities = CFDictionaryGetValue(second, CFSTR("capabilities"));
    assert(CFDictionaryGetValue(capabilities, CFSTR("horizontalScroll")) == kCFBooleanFalse);
    assert(CFDictionaryGetValue(capabilities, CFSTR("dpi")) == kCFBooleanFalse);
    assert(!CFDictionaryContainsKey(second, CFSTR("batteryPercent")));
    CFRelease(status);
    devices[0].connected = false;
    mx_write_device_status("running", "One mouse active", devices, 2);
    status = (CFDictionaryRef)mx_read_plist(path);
    assert(CFEqual(CFDictionaryGetValue(status, CFSTR("deviceName")), CFSTR("Logitech M705")));
    list = CFDictionaryGetValue(status, CFSTR("devices"));
    assert(!CFDictionaryContainsKey(CFArrayGetValueAtIndex(list, 0), CFSTR("batteryPercent")));
    CFRelease(status);
    mx_write_device_status("waiting", "Waiting", NULL, 0);
    status = (CFDictionaryRef)mx_read_plist(path);
    assert(CFArrayGetCount(CFDictionaryGetValue(status, CFSTR("devices"))) == 0);
    assert(CFDictionaryGetValue(status, CFSTR("connected")) == kCFBooleanFalse);
    CFRelease(status);
}

int main(void) {
    char path[PATH_MAX], error[256]; MXConfig config;
    assert(mx_path(path, "settings.plist"));
    assert(mx_load_config(&config, error, sizeof(error)));
    assert(config.buttons[3].action == MX_NATIVE && config.buttons[3].key == 0 && config.buttons[3].modifiers == 0);
    CFMutableDictionaryRef root = dictionary();
    set_number(root, CFSTR("verticalSpeed"), 125);
    CFDictionarySetValue(root, CFSTR("invertHorizontal"), kCFBooleanTrue);
    assert(mx_write_plist(path, root));
    assert(mx_load_config(&config, error, sizeof(error)));
    assert(config.vertical_speed == 125 && config.invert_horizontal);
    /* Accept the integer checkbox values written by the first settings UI. */
    set_number(root, CFSTR("invertHorizontal"), 0);
    set_number(root, CFSTR("invertVertical"), 1);
    set_number(root, CFSTR("smooth"), 0);
    assert(mx_write_plist(path, root));
    assert(mx_load_config(&config, error, sizeof(error)));
    assert(!config.invert_horizontal && config.invert_vertical && !config.smooth);
    set_number(root, CFSTR("smooth"), 2);
    assert(mx_write_plist(path, root));
    assert(!mx_load_config(&config, error, sizeof(error)));
    CFDictionarySetValue(root, CFSTR("smooth"), kCFBooleanFalse);
    set_number(root, CFSTR("verticalSpeed"), 0);
    assert(mx_write_plist(path, root));
    assert(!mx_load_config(&config, error, sizeof(error)));
    set_number(root, CFSTR("verticalSpeed"), 100);
    CFDictionarySetValue(root, CFSTR("invertHorizontal"), CFSTR("true"));
    assert(mx_write_plist(path, root));
    assert(!mx_load_config(&config, error, sizeof(error)));
    CFDictionarySetValue(root, CFSTR("invertHorizontal"), kCFBooleanFalse);
    CFMutableDictionaryRef bindings = dictionary(), thumb = dictionary();
    set_number(thumb, CFSTR("mode"), MX_SHORTCUT);
    set_number(thumb, CFSTR("keyCode"), 21);
    set_number(thumb, CFSTR("modifiers"), 1 << 16); /* Caps-lock is not an allowed shortcut modifier. */
    CFDictionarySetValue(bindings, CFSTR("thumb"), thumb);
    CFDictionarySetValue(root, CFSTR("buttons"), bindings);
    assert(mx_write_plist(path, root));
    assert(!mx_load_config(&config, error, sizeof(error)));
    set_number(thumb, CFSTR("modifiers"), (1 << 20) | (1 << 17));
    assert(mx_write_plist(path, root));
    assert(mx_load_config(&config, error, sizeof(error)));
    assert(config.buttons[3].key == 21);
    set_number(thumb, CFSTR("keyCode"), 128);
    assert(mx_write_plist(path, root));
    assert(!mx_load_config(&config, error, sizeof(error)));
    CFRelease(thumb); CFRelease(bindings); CFRelease(root);
    FILE *file = fopen(path, "w"); assert(file);
    fputs("broken plist", file); fclose(file);
    assert(!mx_load_config(&config, error, sizeof(error)));
    assert(error[0]);
    device_profiles(path);
    unlink(path);
    mx_set_battery(-1,"Good",0);
    mx_write_status("running","Connected",true);
    assert(mx_path(path,"status.plist"));
    CFDictionaryRef status=(CFDictionaryRef)mx_read_plist(path);
    assert(status && CFEqual(CFDictionaryGetValue(status,CFSTR("batteryStatus")),CFSTR("Good")));
    assert(!CFDictionaryContainsKey(status,CFSTR("batteryPercent")));
    CFRelease(status);
    device_snapshots();
    mx_set_battery(75,NULL,1);
    mx_write_status("running","Connected",true);
    status=(CFDictionaryRef)mx_read_plist(path);
    assert(CFDictionaryContainsKey(status,CFSTR("batteryPercent")));
    assert(CFDictionaryGetValue(status,CFSTR("batteryCharging"))==kCFBooleanTrue);
    CFRelease(status);
    mx_write_status("stopped","Disconnected",false);
    status=(CFDictionaryRef)mx_read_plist(path);
    assert(!CFDictionaryContainsKey(status,CFSTR("batteryPercent")));
    assert(!CFDictionaryContainsKey(status,CFSTR("batteryCharging")));
    CFRelease(status);
    puts("Atomic settings storage, defaults, malformed input, and binding validation tests passed.");
    return 0;
}
