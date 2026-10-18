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
    /* Names only. Modern controls must come from the device's feature table. */
    { .vendor_id=0x046d, .product_id=0x406d, .name="Logitech M705 (M-R0073)" },
    { .vendor_id=0x046d, .product_id=0xb034, .name="MX Master 3S", .bluetooth_direct=true },
    { .vendor_id=0x046d, .product_id=0xb042, .name="MX Master 4", .bluetooth_direct=true },
    { .vendor_id=0x046d, .product_id=0xb012, .name="MX Master", .bluetooth_direct=true },
    { .vendor_id=0x046d, .product_id=0x4041, .name="MX Master" },
    { .vendor_id=0x046d, .product_id=0xb019, .name="MX Master 2S", .bluetooth_direct=true },
    { .vendor_id=0x046d, .product_id=0x4069, .name="MX Master 2S" },
    { .vendor_id=0x046d, .product_id=0x4082, .name="MX Master 3" },
    { .vendor_id=0x046d, .product_id=0xb020, .name="MX Vertical", .bluetooth_direct=true },
    { .vendor_id=0x046d, .product_id=0xc08a, .name="MX Vertical" },
    { .vendor_id=0x046d, .product_id=0x407b, .name="MX Vertical" },
    { .vendor_id=0x046d, .product_id=0x404a, .name="MX Anywhere 2" },
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
    MXReceiverPairing pairing;
    if (!mx_parse_receiver_pairing(MX_RECEIVER_UNIFYING, slot, report, length, &pairing) ||
        pairing.kind != 2) return NULL;
    const MXDeviceDefinition *definition = mx_device_lookup(0x046d, pairing.product_id);
    return definition && !definition->bluetooth_direct ? definition : NULL;
}

/* Protocol identities cross-checked against OpenLogi 42af6f4's receiver registry.
 * A transport match permits interrogation, not a promise of configurable controls. */
MXReceiverKind mx_receiver_kind(uint32_t product) {
    switch (product) {
        case 0xc548: return MX_RECEIVER_BOLT;
        case 0xc52b: case 0xc532: case 0xc534: case 0xc537:
        case 0xc539: case 0xc53a: case 0xc53f: case 0xc541:
        case 0xc547: case 0xc54d: return MX_RECEIVER_UNIFYING;
        default: return MX_RECEIVER_NONE;
    }
}

bool mx_parse_receiver_pairing(MXReceiverKind kind, uint8_t slot,
                               const uint8_t *report, size_t length,
                               MXReceiverPairing *out) {
    if (!report || !out || slot < 1 || slot > 6 || length != 20 ||
        report[0] != 0x11 || report[1] != 0xff ||
        report[2] != 0x83 || report[3] != 0xb5) return false;
    MXReceiverPairing result = {0};
    if (kind == MX_RECEIVER_UNIFYING) {
        if (report[4] != 0x20 + slot - 1) return false;
        result.product_id = (uint16_t)report[7] << 8 | report[8];
        result.kind = report[11] & 0x0f;
        /* Legacy pairing info has no reliable current connection status. */
        result.online = false;
    } else if (kind == MX_RECEIVER_BOLT) {
        if (report[4] != 0x50 + slot) return false;
        result.product_id = (uint16_t)report[7] << 8 | report[6];
        result.kind = report[5] & 0x0f;
        result.online = !(report[5] & 0x40);
        for (size_t i = 0; i < sizeof(result.unit_id); ++i)
            result.unit_id[i] = report[8+i];
    } else return false;
    if (!result.product_id) return false;
    *out = result;
    return true;
}

uint32_t mx_receiver_serial(uint8_t slot, const uint8_t *report, size_t length) {
    if (!report || slot < 1 || slot > 6 || length != 20 ||
        report[0] != 0x11 || report[1] != 0xff || report[2] != 0x83 ||
        report[3] != 0xb5 || report[4] != 0x2f + slot) return 0;
    uint32_t serial = (uint32_t)report[5] << 24 | (uint32_t)report[6] << 16 |
        (uint32_t)report[7] << 8 | report[8];
    return serial == UINT32_MAX ? 0 : serial;
}

int mx_control_slot(uint16_t cid) {
    switch (cid) {
        case 0x0052: return 0;
        case 0x0053: case 0x0054: case 0x0055:
        case 0x00bd: case 0x00ce: case 0x00db: return 1;
        case 0x0056: case 0x0057: case 0x0058: case 0x00cf: return 2;
        case 0x0059: case 0x00c3: return 3;
        case 0x00c4: case 0x00ed: case 0x00fd: return 4;
        default: return -1;
    }
}

const char *mx_control_name(uint16_t cid) {
    switch (cid) {
        case 0x0050: return "Left button";
        case 0x0051: return "Right button";
        case 0x0052: return "Middle button";
        case 0x0053: case 0x0054: case 0x0055:
        case 0x00bd: case 0x00ce: case 0x00db: return "Back button";
        case 0x0056: case 0x0057: case 0x0058: case 0x00cf: return "Forward button";
        case 0x0059: return "Thumb button";
        case 0x005a: case 0x005b: return "Wheel tilt left";
        case 0x005c: case 0x005d: return "Wheel tilt right";
        case 0x005e: return "Button 9";
        case 0x005f: return "Button 10";
        case 0x00c3: return "Gesture button";
        case 0x00c4: return "Wheel mode button";
        case 0x00ed: case 0x00fd: return "DPI button";
        case 0x01a0: return "Haptic panel";
        default: return NULL;
    }
}

bool mx_control_from_report(const uint8_t *payload, size_t length, MXControl *out) {
    if (!payload || !out || length < 9) return false;
    uint16_t cid = (uint16_t)payload[0] << 8 | payload[1];
    if (!cid) return false;
    uint16_t flags = payload[4] | (uint16_t)payload[8] << 8;
    *out = (MXControl){ .cid=cid, .slot=(int8_t)mx_control_slot(cid),
                       .divertible=(flags & 0x20) != 0, .flags=flags };
    return true;
}
