#include "device.h"
#include <assert.h>
#include <string.h>

int main(void) {
    assert(mx_device_count() == 2);
    const MXDeviceDefinition *mouse = mx_device_lookup(0x046d, 0xb023);
    assert(mouse && mouse == mx_device_at(0));
    assert(strcmp(mouse->name, "MX Master 3 for Mac") == 0);
    assert(mouse->bluetooth_direct);
    const uint16_t controls[MX_BUTTON_COUNT] = {0x0052, 0x0053, 0x0056, 0x00c3, 0x00c4};
    assert(memcmp(mouse->button_controls, controls, sizeof(controls)) == 0);
    const MXDeviceDefinition *m705=mx_device_lookup(0x046d,0x101b);
    assert(m705 && !m705->bluetooth_direct && m705->button_controls[3]==0x59 && !m705->button_controls[4]);
    /* Captured from the connected c52b receiver: slot 1, WPID 101b, mouse kind 2. */
    const uint8_t pairing[20] = {0x11,0xff,0x83,0xb5,0x20,0x18,0x08,0x10,0x1b,0x04,0,0x02,0x06};
    assert(mx_receiver_mouse(1,pairing,sizeof(pairing)) == m705);
    for (size_t length=0; length<sizeof(pairing); ++length)
        assert(!mx_receiver_mouse(1,pairing,length));
    assert(!mx_receiver_mouse(1,pairing,sizeof(pairing)+1));
    assert(!mx_receiver_mouse(0,pairing,sizeof(pairing)));
    assert(!mx_receiver_mouse(7,pairing,sizeof(pairing)));
    assert(!mx_receiver_mouse(2,pairing,sizeof(pairing))); /* Reply belongs to slot 1. */
    assert(!mx_receiver_mouse(1,NULL,sizeof(pairing)));
    uint8_t invalid[sizeof(pairing)];
    memcpy(invalid,pairing,sizeof(pairing));
    invalid[11]=1; /* A keyboard must never select the mouse controller. */
    assert(!mx_receiver_mouse(1,invalid,sizeof(invalid)));
    memcpy(invalid,pairing,sizeof(pairing));
    invalid[7]=0x40; invalid[8]=0x69; /* Unregistered wireless product. */
    assert(!mx_receiver_mouse(1,invalid,sizeof(invalid)));
    invalid[7]=0xb0; invalid[8]=0x23; /* Bluetooth product IDs are not receiver WPIDs. */
    assert(!mx_receiver_mouse(1,invalid,sizeof(invalid)));
    for (size_t field=0; field<4; ++field) {
        memcpy(invalid,pairing,sizeof(pairing));
        invalid[field]^=1;
        assert(!mx_receiver_mouse(1,invalid,sizeof(invalid)));
    }
    memcpy(invalid,pairing,sizeof(pairing));
    invalid[4]=0x25;
    assert(mx_receiver_mouse(6,invalid,sizeof(invalid)) == m705);
    assert(!mx_device_lookup(0x046d, 0xffff));
    assert(!mx_device_lookup(0xffff, 0xb023));
    assert(!mx_device_lookup(0x1046d, 0xb023));
    assert(!mx_device_at(mx_device_count()));
    assert(!mx_device_at(SIZE_MAX));
    return 0;
}
