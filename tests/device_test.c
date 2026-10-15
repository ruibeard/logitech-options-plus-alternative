#include "device.h"
#include <assert.h>
#include <string.h>

int main(void) {
    assert(mx_device_count() == 1);
    const MXDeviceDefinition *mouse = mx_device_lookup(0x046d, 0xb023);
    assert(mouse && mouse == mx_device_at(0));
    assert(strcmp(mouse->name, "MX Master 3 for Mac") == 0);
    assert(mouse->bluetooth_direct);
    const uint16_t controls[MX_BUTTON_COUNT] = {0x0052, 0x0053, 0x0056, 0x00c3, 0x00c4};
    assert(memcmp(mouse->button_controls, controls, sizeof(controls)) == 0);
    assert(!mx_device_lookup(0x046d, 0xffff));
    assert(!mx_device_lookup(0xffff, 0xb023));
    assert(!mx_device_lookup(0x1046d, 0xb023));
    assert(!mx_device_at(mx_device_count()));
    assert(!mx_device_at(SIZE_MAX));
    return 0;
}
