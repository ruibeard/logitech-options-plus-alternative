#ifndef MX_DEVICE_H
#define MX_DEVICE_H

#include "core.h"

#define MX_CONTROL_MAX 32

typedef struct {
    uint16_t cid;
    int8_t slot; /* Legacy logical binding, or -1 for an additional control. */
    bool divertible;
    uint16_t flags;
} MXControl;

typedef enum {
    MX_RECEIVER_NONE,
    MX_RECEIVER_UNIFYING,
    MX_RECEIVER_BOLT,
} MXReceiverKind;

typedef struct {
    uint16_t product_id;
    uint8_t kind; /* HID++ device kind: mouse=2, trackball=3, touchpad=4. */
    bool online;
    uint8_t unit_id[4]; /* Bolt unit ID; zero for legacy pairing reply. */
} MXReceiverPairing;

enum {
    MX_CAP_BUTTONS = 1u << 0,
    MX_CAP_HIRES_SCROLL = 1u << 1,
    MX_CAP_THUMBWHEEL = 1u << 2,
    MX_CAP_DPI = 1u << 3,
    MX_CAP_SMARTSHIFT = 1u << 4,
    MX_CAP_BATTERY = 1u << 5,
    MX_CAP_HAPTIC = 1u << 6,
};

MXReceiverKind mx_receiver_kind(uint32_t product);
bool mx_parse_receiver_pairing(MXReceiverKind kind, uint8_t slot,
                               const uint8_t *report, size_t length,
                               MXReceiverPairing *out);
/* Payload begins at report byte 4. Requires the complete V4 control-info row. */
bool mx_control_from_report(const uint8_t *payload, size_t length, MXControl *out);
int mx_control_slot(uint16_t cid);
const char *mx_control_name(uint16_t cid);

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
/* Only a complete Unifying pairing reply for this slot can select a supported mouse. */
const MXDeviceDefinition *mx_receiver_mouse(uint8_t slot, const uint8_t *report, size_t length);
size_t mx_device_count(void);
const MXDeviceDefinition *mx_device_at(size_t index);

#endif
