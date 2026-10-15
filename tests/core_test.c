#include "core.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    /* Actual BLE descriptor observed on this MX Master 3 Mac. It has no short output report. */
    const uint8_t ble[] = {
        0x06,0x43,0xff,0x0a,0x02,0x02,0xa1,0x01,0x85,0x11,0x75,0x08,
        0x95,0x13,0x15,0x00,0x26,0xff,0x00,0x09,0x02,0x81,0x00,0x09,0x02,0x91,0x00,0xc0
    };
    size_t sizes[256];
    assert(mx_output_reports(ble, sizeof(ble), sizes));
    assert(sizes[0x11] == 19 && sizes[0x10] == 0);
    const uint8_t usb[] = {0x06,0x00,0xff,0x85,0x10,0x75,0x08,0x95,0x06,0x91,0x00,
        0xa4,0x85,0x11,0x95,0x13,0x91,0x00,0xb4,0x91,0x00};
    assert(mx_output_reports(usb, sizeof(usb), sizes));
    assert(sizes[0x10] == 12 && sizes[0x11] == 19); /* PUSH / POP restores short report globals. */
    for (size_t i = 1; i < sizeof(ble); ++i) {
        /* Truncation must never read outside the supplied descriptor. */
        (void)mx_output_reports(ble, i, sizes);
    }
    const uint8_t bad[] = {0x75,0x20,0x95,0xff,0x06,0x43,0xff,0x85,0x11,0x91,0x00};
    assert(!mx_output_reports(bad, sizeof(bad), sizes));
    const uint8_t truncated[] = {0xfe,0xff,0};
    assert(!mx_output_reports(truncated, sizeof(truncated), sizes));
    uint8_t report[20] = {0x11,0xff,0x0a,0x00,0x00,0xc3};
    uint8_t output[MX_REPORT_MAX];
    assert(mx_normalize_report(0x11, report, 20, output) == 20);
    assert(!memcmp(report, output, 20));
    assert(mx_normalize_report(0x11, report + 1, 19, output) == 20);
    assert(!memcmp(report, output, 20));
    /* A report-ID-free payload can itself begin 0x11: use length, not first byte. */
    report[1] = 0x11;
    assert(mx_normalize_report(0x11, report + 1, 19, output) == 20);
    assert(output[0] == 0x11 && output[1] == 0x11);
    assert(!mx_normalize_report(0x11, report, 18, output));
    assert(!mx_normalize_report(0x12, report, 20, output));
    const uint8_t pressed[] = {0,0xc3,0,0xc4,0,0x53,0,0,0,0x56};
    assert(mx_pressed(pressed, sizeof(pressed), 0xc3));
    assert(mx_pressed(pressed, sizeof(pressed), 0x53));
    assert(!mx_pressed(pressed, sizeof(pressed), 0x56));
    assert(!mx_pressed(pressed, 1, 0xc3));
    const uint8_t range[] = {0,0,200,0xe0,50,0x0f,0xa0,0,0};
    assert(mx_dpi_allowed(range, sizeof(range), 1000));
    assert(mx_dpi_allowed(range, sizeof(range), 4000));
    assert(!mx_dpi_allowed(range, sizeof(range), 1025));
    assert(!mx_dpi_allowed(range, sizeof(range), 100));
    const uint8_t list[] = {0,0x01,0x90,0x03,0x20,0x06,0x40,0,0};
    assert(mx_dpi_allowed(list, sizeof(list), 800));
    assert(!mx_dpi_allowed(list, sizeof(list), 1000));
    MXConfig config; mx_defaults(&config);
    assert(config.buttons[3].action == MX_NATIVE && config.buttons[3].key == 0 && config.buttons[3].modifiers == 0);
    puts("Descriptor, framing, button state, DPI validation, and native-thumb-default tests passed.");
    return 0;
}
