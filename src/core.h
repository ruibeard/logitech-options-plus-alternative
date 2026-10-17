#ifndef MX_CORE_H
#define MX_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define MX_BUTTON_COUNT 5
#define MX_EXTRA_BUTTON_COUNT 32
#define MX_REPORT_MAX 64

typedef enum { MX_NATIVE, MX_SHORTCUT, MX_DISABLED } MXAction;
typedef struct {
    MXAction action;
    uint16_t key;
    uint64_t modifiers;
} MXBinding;

typedef struct {
    uint16_t cid;
    MXBinding binding;
} MXExtraBinding;

typedef struct {
    MXBinding buttons[MX_BUTTON_COUNT];
    int dpi;                 /* 0 leaves the sensor setting unchanged. */
    int wheel_mode;          /* 0 unchanged, 1 ratchet, 2 free, 3 automatic. */
    int smartshift;
    int vertical_speed;      /* Percent of native movement. */
    int horizontal_speed;
    bool invert_vertical;
    bool invert_horizontal;
    bool smooth;
    /* Sparse CID overrides cover controls beyond the legacy five slots. */
    MXExtraBinding extra_buttons[MX_EXTRA_BUTTON_COUNT];
    size_t extra_button_count;
} MXConfig;

extern const char *const mx_button_keys[MX_BUTTON_COUNT];

/* Descriptor sizes exclude the report ID; HID++ packets include it. */
bool mx_output_reports(const uint8_t *descriptor, size_t length, size_t sizes[256]);
size_t mx_normalize_report(uint32_t report_id, const uint8_t *input,
                           size_t length, uint8_t output[MX_REPORT_MAX]);
bool mx_pressed(const uint8_t *payload, size_t length, uint16_t control);
bool mx_dpi_allowed(const uint8_t *payload, size_t length, int dpi);
void mx_defaults(MXConfig *config);
/* Explicit CID overrides take precedence; unknown controls stay native. */
const MXBinding *mx_binding_for_control(const MXConfig *config, uint16_t cid, int slot);

#endif
