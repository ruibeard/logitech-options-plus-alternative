#include "device.h"

static const MXDeviceDefinition devices[] = {
    {
        .vendor_id = 0x046d,
        .product_id = 0xb023,
        .name = "MX Master 3 for Mac",
        .button_controls = {0x0052, 0x0053, 0x0056, 0x00c3, 0x00c4},
        .bluetooth_direct = true,
    },
    { .vendor_id=0x046d, .product_id=0x101b, .name="Logitech M705",
      .button_controls={0x0052,0x0053,0x0056,0x0059,0}, .bluetooth_direct=false },
};

size_t mx_device_count(void) {
    return sizeof(devices) / sizeof(devices[0]);
}

const MXDeviceDefinition *mx_device_at(size_t index) {
    return index < mx_device_count() ? &devices[index] : NULL;
}

const MXDeviceDefinition *mx_device_lookup(uint32_t vendor, uint32_t product) {
    for (size_t index = 0; index < mx_device_count(); ++index) {
        if (devices[index].vendor_id == vendor && devices[index].product_id == product)
            return &devices[index];
    }
    return NULL;
}

const MXDeviceDefinition *mx_receiver_mouse(uint8_t slot, const uint8_t *report, size_t length) {
    if (!report || slot < 1 || slot > 6 || length != 20 || report[0] != 0x11 ||
        report[1] != 0xff || report[2] != 0x83 || report[3] != 0xb5 ||
        report[4] != 0x20 + slot - 1 || (report[11] & 0x0f) != 2) return NULL;
    uint16_t wpid = (uint16_t)report[7] << 8 | report[8];
    const MXDeviceDefinition *definition = mx_device_lookup(0x046d, wpid);
    return definition && !definition->bluetooth_direct ? definition : NULL;
}
