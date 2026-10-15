#ifndef MX_DEVICE_H
#define MX_DEVICE_H

#include "core.h"

typedef struct {
    uint32_t vendor_id;
    uint32_t product_id;
    const char *name;
    /* Middle, back, forward, thumb button, top button: MXConfig order. */
    uint16_t button_controls[MX_BUTTON_COUNT];
    bool bluetooth_direct;
} MXDeviceDefinition;

/* Definitions have static lifetime. Unknown IDs and out-of-range indices return NULL. */
const MXDeviceDefinition *mx_device_lookup(uint32_t vendor, uint32_t product);
size_t mx_device_count(void);
const MXDeviceDefinition *mx_device_at(size_t index);

#endif
