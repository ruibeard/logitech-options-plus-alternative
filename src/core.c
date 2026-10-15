#include "core.h"
#include <string.h>

const char *const mx_button_keys[MX_BUTTON_COUNT] = {"middle", "back", "forward", "thumb", "top"};

void mx_defaults(MXConfig *config) {
    memset(config, 0, sizeof(*config));
    const uint64_t command = 1ULL << 20, control = 1ULL << 18;
    config->buttons[1] = (MXBinding){MX_SHORTCUT, 33, command};
    config->buttons[2] = (MXBinding){MX_SHORTCUT, 30, command};
    config->buttons[4] = (MXBinding){MX_SHORTCUT, 50, control};
    config->smartshift = 20;
    config->vertical_speed = config->horizontal_speed = 100;
}

bool mx_output_reports(const uint8_t *data, size_t length, size_t sizes[256]) {
    struct Globals { uint32_t page, id, bits, count; } globals = {0}, stack[16];
    size_t depth = 0;
    uint64_t report_bits[256] = {0};
    memset(sizes, 0, 256 * sizeof(*sizes));
    for (size_t i = 0; i < length;) {
        uint8_t prefix = data[i++];
        if (prefix == 0xfe) {
            if (length - i < 2 || (size_t)data[i] + 2 > length - i) return false;
            i += (size_t)data[i] + 2;
            continue;
        }
        size_t size = (prefix & 3) == 3 ? 4 : prefix & 3;
        if (size > length - i) return false;
        uint32_t value = 0;
        for (size_t j = 0; j < size; ++j) value |= (uint32_t)data[i + j] << (j * 8);
        i += size;
        unsigned type = (prefix >> 2) & 3, tag = prefix >> 4;
        if (type == 1) {
            switch (tag) {
                case 0: globals.page = value; break;
                case 7: globals.bits = value; break;
                case 8: if (value > 255) return false; globals.id = value; break;
                case 9: globals.count = value; break;
                case 10:
                    if (depth == 16) return false;
                    stack[depth++] = globals;
                    break;
                case 11:
                    if (!depth) return false;
                    globals = stack[--depth];
                    break;
            }
        } else if (type == 0 && tag == 9 && globals.id &&
                   (globals.page == 0xff00 || globals.page == 0xff43)) {
            uint64_t bits = (uint64_t)globals.bits * globals.count;
            if (bits > (MX_REPORT_MAX - 1) * 8 || report_bits[globals.id] + bits > (MX_REPORT_MAX - 1) * 8)
                return false;
            report_bits[globals.id] += bits;
        }
    }
    bool found = false;
    for (size_t i = 1; i < 256; ++i) {
        sizes[i] = (size_t)((report_bits[i] + 7) / 8);
        if ((i == 0x10 || i == 0x11) && sizes[i]) found = true;
    }
    return found;
}

size_t mx_normalize_report(uint32_t id, const uint8_t *input, size_t length,
                           uint8_t output[MX_REPORT_MAX]) {
    if ((id != 0x10 && id != 0x11) || !length) return 0;
    size_t expected = id == 0x10 ? 7 : 20;
    if (length == expected && input[0] == id) {
        memcpy(output, input, length);
        return length;
    }
    if (length == expected - 1) {
        output[0] = (uint8_t)id;
        memcpy(output + 1, input, length);
        return length + 1;
    }
    return 0;
}

bool mx_pressed(const uint8_t *data, size_t length, uint16_t control) {
    /* ReprogControlsV4 publishes at most four held CIDs. */
    if (length > 8) length = 8;
    for (size_t i = 0; i + 1 < length; i += 2)
        if (((uint16_t)data[i] << 8 | data[i + 1]) == control) return true;
    return false;
}

bool mx_dpi_allowed(const uint8_t *data, size_t length, int dpi) {
    int minimum = 0, maximum = 0, step = 0;
    bool explicit_match = false;
    for (size_t i = 1; i + 1 < length; i += 2) {
        int value = ((int)data[i] << 8) | data[i + 1];
        if (!value) break;
        if ((value & 0xe000) == 0xe000) step = value & 0x1fff;
        else {
            if (!minimum) minimum = value;
            maximum = value;
            if (dpi == value) explicit_match = true;
        }
    }
    if (step) return minimum > 0 && maximum >= minimum && dpi >= minimum && dpi <= maximum && (dpi - minimum) % step == 0;
    return explicit_match;
}
