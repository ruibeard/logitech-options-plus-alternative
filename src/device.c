#include "device.h"

static const MXDeviceDefinition devices[] = {
    {
        .vendor_id = 0x046d,
        .product_id = 0xb023,
        .name = "MX Master 3 for Mac",
        .button_controls = {0x0052, 0x0053, 0x0056, 0x00c3, 0x00c4},
        .bluetooth_direct = true,
    },
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
