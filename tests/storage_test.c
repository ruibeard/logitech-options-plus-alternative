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
    unlink(path);
    mx_set_battery(-1,"Good",0);
    mx_write_status("running","Connected",true);
    assert(mx_path(path,"status.plist"));
    CFDictionaryRef status=(CFDictionaryRef)mx_read_plist(path);
    assert(status && CFEqual(CFDictionaryGetValue(status,CFSTR("batteryStatus")),CFSTR("Good")));
    assert(!CFDictionaryContainsKey(status,CFSTR("batteryPercent")));
    CFRelease(status);
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
