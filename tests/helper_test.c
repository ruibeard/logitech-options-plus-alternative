/* Exercise real discovery, reconnect, routing and cleanup without opening HID. */
#include <CoreGraphics/CoreGraphics.h>
#include <assert.h>
static bool test_post_access(void) { return true; }
#define CGPreflightPostEventAccess test_post_access
#define MX_HELPER_TEST
#define main mx_helper_main
#include "../src/helper.c"
#undef main

static unsigned diversions, restorations;
static uint16_t discovered_cid = 0x0052;
static bool replacement_identity;
static bool mock_exchange(uint8_t address, uint8_t index, uint8_t tag,
                          const uint8_t *parameters, size_t length) {
    (void)address;
    memset(app.response, 0, sizeof(app.response));
    app.response_length = 20;
    unsigned function = tag >> 4;
    if (replacement_identity && index == 0x83 && tag == 0xb5) {
        app.response[0] = 0x11; app.response[1] = 0xff; app.response[2] = 0x83; app.response[3] = 0xb5;
        app.response[4] = parameters[0]; app.response[7] = 0x40; app.response[8] = 0x6d; app.response[11] = 2;
        return true;
    }
    if (replacement_identity && index == 2 && function == 0) { app.response[8] = 0x22; return true; }
    if (!index && function == 1) { app.response[4] = 4; app.response[6] = 0xa7; return true; }
    if (!index && function == 0 && length == 3) {
        app.response[4] = parameters[0] == 0x1b && parameters[1] == 4 ? 1 :
            replacement_identity && parameters[0] == 0 && parameters[1] == 3 ? 2 : 0;
        return true;
    }
    if (index == 1 && function == 0) { app.response[4] = 1; return true; }
    if (index == 1 && function == 1) {
        app.response[4] = discovered_cid >> 8; app.response[5] = discovered_cid;
        app.response[8] = 0x20; return true;
    }
    if (index == 1 && function == 3 && length == 5) {
        assert(((uint16_t)parameters[0] << 8 | parameters[1]) == discovered_cid);
        if (parameters[2] == 3) ++diversions; else ++restorations;
        return true;
    }
    return false;
}

static void test_reconnect(void) {
    Mouse mouse = {.online = true, .initialisation_attempted = true};
    Transport transport = {0}; mouse.transport = &transport; runtime.current = &mouse;
    initialise_device();
    assert(!app.connected && !app.configuring);
    assert(app.reconnect_timer && app.reconnect_delay == 2);
    CFRunLoopTimerRef first = app.reconnect_timer;
    retry_connection();
    assert(app.reconnect_timer == first && app.reconnect_delay == 2);
    CFRunLoopTimerSetNextFireDate(first, CFAbsoluteTimeGetCurrent());
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false);
    assert(!app.reconnect_timer && !app.initialisation_attempted);
    const unsigned delays[] = {4, 8, 16, 30, 30};
    for (size_t i = 0; i < sizeof(delays) / sizeof(delays[0]); ++i) {
        retry_connection(); assert(app.reconnect_timer && app.reconnect_delay == delays[i]); cancel_reconnect();
    }
    app.connected = true; retry_connection(); assert(!app.reconnect_timer);
    app.connected = false; retry_connection(); app.online = false; close_device();
    assert(!app.reconnect_timer && !app.reconnect_delay);
    app.online = true; runtime.probe = true; retry_connection(); assert(!app.reconnect_timer);
    runtime.probe = false; runtime.stop = true; retry_connection(); assert(!app.reconnect_timer);
    runtime.stop = false; app.removed = true; retry_connection(); assert(!app.reconnect_timer);
    app.removed = false; app.online = false; retry_connection(); assert(!app.reconnect_timer);
    runtime.current = NULL;
}

static void test_discovery_and_optional_features(void) {
    Transport transport = {.mouse_usage = true};
    Mouse first = {.transport = &transport, .online = true, .address = 0xff};
    runtime.current = runtime.mice = &first;
    mx_defaults(&first.config);
    first.config.buttons[0] = (MXBinding){.action = MX_SHORTCUT, .key = 20};
    first.config.buttons[3] = (MXBinding){.action = MX_SHORTCUT, .key = 21};
    first.config.smooth = true; /* Missing optional wheel must not undo buttons. */
    test_exchange = mock_exchange;
    initialise_device();
    assert(first.connected && first.control_count == 1);
    assert(first.controls_info[0].cid == 0x52 && first.controls_info[0].slot == 0);
    assert(first.diverted[0] && !first.button_controls[3]);
    assert(!strcmp(first.state, "running") && diversions == 1);
    assert(restore() && restorations == 1 && !first.diverted[0]);
    /* A different M705 exposing only middle click never inherits a phantom thumb. */
    Mouse second = {.transport = &transport, .online = true, .address = 2};
    mx_defaults(&second.config); second.config.buttons[1].action = MX_NATIVE; second.config.buttons[3].action = MX_SHORTCUT;
    first.next = &second; runtime.current = &second; discovered_cid = 0x53;
    initialise_device();
    assert(second.connected && second.control_count == 1 && !second.button_controls[3]);
    assert(diversions == 1 && first.controls_info[0].cid == 0x52);
    test_exchange = NULL; runtime.current = runtime.mice = NULL;
}

static void test_same_model_replacement_does_not_restore_old_controls(void) {
    Transport transport = {.online = true, .mouse_usage = true};
    Mouse mouse = {.transport = &transport, .online = true, .address = 0xff,
        .product_id = 0x406d, .unit_id = 0x11, .control_count = 1,
        .controls = 9, .wheel = 8, .wheel_changed = true, .old_wheel_valid = true};
    mouse.controls_info[0] = (MXControl){.cid = 0x59, .slot = 3, .divertible = true};
    mouse.diverted[0] = true;
    mx_defaults(&mouse.config); mouse.config.buttons[3].action = MX_SHORTCUT;
    runtime.current = runtime.mice = &mouse; replacement_identity = true;
    discovered_cid = 0x52; test_exchange = mock_exchange;
    unsigned before = restorations;
    initialise_device();
    assert(mouse.unit_id == 0x22 && !strcmp(mouse.id, "logitech-406d-00000022"));
    assert(!mouse.diverted[0] && !mouse.wheel_changed && restorations == before);
    assert(!strcmp(mouse.state, "running"));
    replacement_identity = false; test_exchange = NULL; runtime.current = runtime.mice = NULL;
}

/* The M705 101b reports a zero serial through 0x0003; only the receiver knows its unit. */
static bool mock_zero_serial(uint8_t address, uint8_t index, uint8_t tag,
                             const uint8_t *parameters, size_t length) {
    if (index == 0x83 && tag == 0xb5) {
        memset(app.response, 0, sizeof(app.response)); app.response_length = 20;
        app.response[0] = 0x11; app.response[1] = 0xff; app.response[2] = 0x83; app.response[3] = 0xb5;
        app.response[4] = parameters[0];
        if (parameters[0] == 0x20) { app.response[7] = 0x10; app.response[8] = 0x1b; app.response[11] = 2; }
        else { app.response[5] = 0xfd; app.response[6] = 0x21; app.response[7] = 0x45; app.response[8] = 0x77; }
        return true;
    }
    if (!index && (tag >> 4) == 0 && length == 3 && parameters[0] == 0 && parameters[1] == 3) {
        memset(app.response, 0, sizeof(app.response)); app.response_length = 20; app.response[4] = 2;
        return true;
    }
    if (index == 2 && (tag >> 4) == 0) {
        memset(app.response, 0, sizeof(app.response)); app.response_length = 20; app.response[4] = 1;
        return true;
    }
    return mock_exchange(address, index, tag, parameters, length);
}

static void test_receiver_mouse_without_feature_serial_connects(void) {
    Transport transport = {.online = true, .receiver_kind = MX_RECEIVER_UNIFYING};
    Mouse mouse = {.transport = &transport, .online = true, .address = 1, .receiver = true,
        .product_id = 0x101b, .unit_id = 0xfd214577};
    mx_defaults(&mouse.config);
    runtime.current = runtime.mice = &mouse; test_exchange = mock_zero_serial;
    initialise_device();
    assert(mouse.connected && !strcmp(mouse.state, "running"));
    assert(mouse.unit_id == 0xfd214577);
    test_exchange = NULL; runtime.current = runtime.mice = NULL;
}

static unsigned pairing_generation;
static bool mock_pairing(uint8_t address, uint8_t index, uint8_t tag, const uint8_t *parameters, size_t length) {
    assert(address == 0xff && index == 0x83 && tag == 0xb5 && length == 1);
    if (parameters[0] >= 0x30 && parameters[0] <= 0x31) {
        memset(app.response, 0, sizeof(app.response)); app.response_length = 20;
        app.response[0]=0x11; app.response[1]=0xff; app.response[2]=0x83; app.response[3]=0xb5;
        app.response[4]=parameters[0]; app.response[5]=0x0e; app.response[6]=0x87;
        app.response[7]=0xb8; app.response[8]=(parameters[0]==0x30 ? 0xb8 : 0xb9);
        return true;
    }
    unsigned slot = parameters[0] - 0x1f;
    if (slot > 3) return false;
    memset(app.response, 0, sizeof(app.response)); app.response_length = 20;
    app.response[0] = 0x11; app.response[1] = 0xff; app.response[2] = 0x83; app.response[3] = 0xb5;
    app.response[4] = parameters[0]; app.response[11] = slot == 3 ? 1 : 2;
    uint16_t product = slot == 1 ? (pairing_generation ? 0x101b : 0x406d) : 0xb123;
    app.response[7] = product >> 8; app.response[8] = product;
    return true;
}

static void test_all_receiver_slots(void) {
    Transport transport = {.online = true, .receiver_kind = MX_RECEIVER_UNIFYING};
    runtime.probe = true; test_exchange = mock_pairing;
    scan_receiver(&transport);
    Mouse *first = find_mouse(&transport, 1), *second = find_mouse(&transport, 2);
    assert(first && first->product_id == 0x406d && second && second->product_id == 0xb123);
    assert(!strcmp(first->id, "logitech-406d-0e87b8b8"));
    assert(!strcmp(second->id, "logitech-b123-0e87b8b9"));
    assert(!first->connected && first->unit_id == 0x0e87b8b8);
    runtime.current=first;
    assert(receiver_identity_matches());
    first->unit_id++; assert(!receiver_identity_matches()); first->unit_id--;
    runtime.current=NULL;
    assert(!find_mouse(&transport, 3)); /* Keyboard on the same receiver stays untouched. */
    assert(first != second && first->definition && strstr(first->name, "M705"));
    pairing_generation = 1; scan_receiver(&transport);
    assert(first->removed && !first->online);
    assert(find_mouse(&transport, 1) != first && find_mouse(&transport, 2) == second);
    while (runtime.mice) { Mouse *next = runtime.mice->next; free(runtime.mice); runtime.mice = next; }
    runtime.current = NULL; runtime.probe = false; test_exchange = NULL;
}

static bool first_pairing_timeout, settle_empty;
static unsigned pairing_requests;
static bool mock_transient_pairing(uint8_t address, uint8_t index, uint8_t tag,
                                    const uint8_t *parameters, size_t length) {
    assert(address == 0xff && index == 0x83 && tag == 0xb5 && length == 1);
    ++pairing_requests;
    if (parameters[0] == 0x20 && !settle_empty) {
        if (first_pairing_timeout) { first_pairing_timeout = false; return false; }
        app.received = true;
        return mock_pairing(address, index, tag, parameters, length);
    }
    app.received = app.request_failed = true; /* Explicit unknown-slot error is healthy. */
    return false;
}

static void test_receiver_scan_retry_and_wake(void) {
    Transport transport = {.online = true, .receiver_kind = MX_RECEIVER_UNIFYING,
        .notifications_changed = true};
    runtime.transports = &transport; test_exchange = mock_transient_pairing;
    first_pairing_timeout = true; settle_empty = false; pairing_generation = 0;
    scan_receiver(&transport);
    assert(!runtime.mice && transport.scan_timer && transport.scan_delay == 2);
    CFRunLoopTimerRef timer = transport.scan_timer;
    retry_receiver_scan(&transport);
    assert(transport.scan_timer == timer && transport.scan_delay == 2);
    CFRunLoopTimerSetNextFireDate(timer, CFAbsoluteTimeGetCurrent());
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false);
    assert(!transport.scan_timer && transport.scan);
    transport.scan = false; scan_receiver(&transport);
    assert(find_mouse(&transport, 1) && !transport.scan_timer && !transport.scan_delay);
    while (runtime.mice) { Mouse *next = runtime.mice->next; free(runtime.mice); runtime.mice = next; }
    settle_empty = true;
    scan_receiver(&transport);
    assert(!runtime.mice && !transport.scan_timer); /* Healthy empty receiver never polls. */
    retry_receiver_scan(&transport);
    assert(transport.scan_timer);
    unsigned before = pairing_requests;
    runtime.reload = true; work(NULL);
    assert(pairing_requests == before + 6 && !transport.scan_timer && !transport.scan_delay);
    before = pairing_requests;
    power_changed(NULL, 0, kIOMessageSystemHasPoweredOn, NULL); work(NULL);
    assert(pairing_requests == before + 6 && !transport.scan_timer);
    retry_receiver_scan(&transport); assert(transport.scan_timer);
    removed(NULL, kIOReturnSuccess, NULL, NULL);
    assert(!transport.scan_timer && transport.removed && !transport.online);
    transport.online = true; transport.removed = false;
    retry_receiver_scan(&transport); assert(transport.scan_timer);
    runtime.stop = true;
    receiver_retry_tick(transport.scan_timer, &transport);
    assert(!transport.scan_timer && !transport.scan);
    runtime.stop = false; runtime.transports = NULL; runtime.current = NULL; test_exchange = NULL;
}

/* Minimal control-info rows from OpenLogi reviewed 3S/MX4 fixtures; hardware remains unverified. */
static const uint8_t inventory_3s[][9] = {
    {0x00,0x50,0x00,0x38,0x01,0x00,0x01,0x01,0x04},
    {0x00,0x51,0x00,0x39,0x01,0x00,0x01,0x01,0x04},
    {0x00,0x52,0x00,0x3a,0x31,0x00,0x02,0x03,0x05},
    {0x00,0x53,0x00,0x3c,0x31,0x00,0x02,0x03,0x05},
    {0x00,0x56,0x00,0x3e,0x31,0x00,0x02,0x03,0x05},
    {0x00,0xc3,0x00,0xa9,0x31,0x00,0x02,0x03,0x05},
    {0x00,0xc4,0x00,0x9d,0x31,0x00,0x02,0x03,0x05},
    {0x00,0xd7,0x00,0xb4,0xa0,0x00,0x03,0x00,0x03},
};
static const uint8_t inventory_4[][9] = {
    {0x00,0x50,0x00,0x38,0x01,0x00,0x01,0x00,0x04},
    {0x00,0x51,0x00,0x39,0x01,0x00,0x01,0x00,0x04},
    {0x00,0x52,0x00,0x3a,0x31,0x00,0x02,0x03,0x05},
    {0x00,0x53,0x00,0x3c,0x31,0x00,0x02,0x03,0x05},
    {0x00,0x56,0x00,0x3e,0x31,0x00,0x02,0x03,0x05},
    {0x00,0xc3,0x00,0x9c,0x31,0x00,0x02,0x03,0x05},
    {0x00,0xc4,0x00,0x9d,0x31,0x00,0x02,0x03,0x05},
    {0x01,0xa0,0x01,0x09,0x31,0x00,0x02,0x03,0x05},
    {0x00,0xd7,0x00,0xb4,0xa0,0x00,0x03,0x00,0x03},
};
static const uint8_t (*inventory_rows)[9];
static size_t inventory_count;
static unsigned gesture_diverted, haptic_diverted;
static bool mock_inventory(uint8_t address, uint8_t index, uint8_t tag,
                           const uint8_t *parameters, size_t length) {
    unsigned function = tag >> 4;
    if (index == 1 && function == 0) {
        memset(app.response, 0, sizeof(app.response)); app.response_length = 20;
        app.response[4] = (uint8_t)inventory_count; return true;
    }
    if (index == 1 && function == 1) {
        assert(length == 1 && parameters[0] < inventory_count);
        memset(app.response, 0, sizeof(app.response)); app.response_length = 20;
        memcpy(app.response + 4, inventory_rows[parameters[0]], 9); return true;
    }
    if (index == 1 && function == 3) {
        assert(length == 5);
        uint16_t cid = (uint16_t)parameters[0] << 8 | parameters[1];
        assert(cid == 0xc3 || cid == 0x1a0);
        if (parameters[2] == 3) {
            if (cid == 0xc3) ++gesture_diverted; else ++haptic_diverted;
        }
        return true;
    }
    return mock_exchange(address, index, tag, parameters, length);
}

static void test_reviewed_inventory_retention(void) {
    for (unsigned model = 0; model < 2; ++model) {
        inventory_rows = model ? inventory_4 : inventory_3s;
        inventory_count = model ? sizeof(inventory_4) / 9 : sizeof(inventory_3s) / 9;
        Transport transport = {.mouse_usage = true};
        Mouse mouse = {.transport = &transport, .online = true, .address = 0xff};
        mx_defaults(&mouse.config); memset(mouse.config.buttons, 0, sizeof(mouse.config.buttons));
        mouse.config.buttons[3] = (MXBinding){.action = MX_SHORTCUT, .key = 20};
        mouse.config.extra_button_count = 1;
        mouse.config.extra_buttons[0] = (MXExtraBinding){.cid = 0x1a0,
            .binding = {.action = MX_SHORTCUT, .key = 21}};
        runtime.current = runtime.mice = &mouse; test_exchange = mock_inventory;
        gesture_diverted = haptic_diverted = 0;
        initialise_device();
        assert(mouse.connected && mouse.control_count == inventory_count);
        assert(!mouse.controls_info[0].divertible && !mouse.controls_info[1].divertible);
        assert(!mouse.diverted[0] && !mouse.diverted[1]);
        assert(gesture_diverted == 1 && haptic_diverted == model);
        bool retained_unknown = false, retained_haptic = false;
        for (size_t i = 0; i < mouse.control_count; ++i) {
            MXControl *control = &mouse.controls_info[i];
            if (control->cid == 0xc3) assert(control->slot == 3 && mouse.diverted[i]);
            if (control->cid == 0x1a0) { retained_haptic = true; assert(control->slot == -1 && mouse.diverted[i]); }
            if (control->cid == 0xd7) { retained_unknown = true; assert(control->slot == -1); }
        }
        assert(retained_unknown && retained_haptic == (model != 0));
        assert(restore());
        runtime.current = runtime.mice = NULL; test_exchange = NULL;
    }
}

static uint8_t simulated_error_type, simulated_error_code;
static bool simulated_error_mismatch;
static unsigned offline_ping_attempts;
static bool mock_ping_error_report(uint8_t address, uint8_t index, uint8_t tag,
                                   const uint8_t *parameters, size_t length) {
    (void)parameters; (void)length;
    assert(index == 0 && (tag >> 4) == 1);
    ++offline_ping_attempts;
    app.request_address = address; app.request_feature = index; app.request_tag = tag;
    app.waiting = true; app.received = app.request_failed = false;
    app.transport->request = runtime.current;
    uint8_t packet[7] = {0x10, address, simulated_error_type, index, tag, simulated_error_code, 0};
    if (simulated_error_mismatch) packet[1] = address == 1 ? 2 : 1;
    input_report(app.transport, kIOReturnSuccess, NULL, kIOHIDReportTypeInput, 0x10, packet, sizeof(packet));
    app.waiting = false; app.transport->request = NULL;
    return false;
}

static void test_offline_receiver_slot_errors(void) {
    const struct { uint8_t type, code; bool receiver, mismatch, offline; } cases[] = {
        {0x8f, 0x09, true, false, true},
        {0x8f, 0x08, true, false, true},
        {0xff, 0x09, true, false, false}, /* HID++ 2.0 resource error is not an offline slot. */
        {0x8f, 0x07, true, false, false},
        {0x8f, 0x09, false, false, false},
        {0x8f, 0x09, true, true, false}, /* Different slot cannot satisfy this request. */
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i) {
        Transport transport = {.online = true, .receiver_kind = MX_RECEIVER_UNIFYING};
        Mouse mouse = {.transport = &transport, .online = true, .address = 1,
            .receiver = cases[i].receiver, .initialisation_attempted = true};
        runtime.current = runtime.mice = &mouse;
        simulated_error_type = cases[i].type; simulated_error_code = cases[i].code;
        simulated_error_mismatch = cases[i].mismatch; offline_ping_attempts = 0;
        test_exchange = mock_ping_error_report;
        initialise_device();
        assert(!mouse.connected && !mouse.configuring && mouse.reconnect_timer);
        assert(offline_ping_attempts == (cases[i].offline ? 1u : 3u));
        assert(!strcmp(mouse.state, cases[i].offline ? "waiting" : "error"));
        assert(receiver_slot_offline() == cases[i].offline);
        if (cases[i].mismatch) assert(!mouse.request_error_type && !mouse.received);
        else assert(mouse.request_error_type == cases[i].type && mouse.request_error_code == cases[i].code);
        if (cases[i].offline) {
            /* A receiver arrival immediately cancels backoff and schedules a new handshake. */
            uint8_t arrival[7] = {0x10, 1, 0x41, 0, 0, 0, 0};
            input_report(&transport, kIOReturnSuccess, NULL, kIOHIDReportTypeInput, 0x10, arrival, sizeof(arrival));
            assert(!mouse.reconnect_timer && !mouse.initialisation_attempted && transport.scan);
            /* The next exchange must clear the previous error classification. */
            test_exchange = mock_exchange;
            const uint8_t feature_id[3] = {0x1b, 4, 0};
            assert(exchange(1, 0, 1, feature_id, sizeof(feature_id)));
            assert(!mouse.request_error_type && !mouse.request_error_code && !receiver_slot_offline());
        }
        cancel_reconnect(); runtime.current = runtime.mice = NULL; test_exchange = NULL;
    }
}

static void test_response_routing(void) {
    Transport transport = {.online = true};
    Mouse first = {.transport = &transport, .online = true, .address = 1,
        .waiting = true, .request_address = 1, .request_feature = 3, .request_tag = 0x17};
    Mouse second = {.transport = &transport, .online = true, .address = 2};
    first.next = &second; runtime.mice = &first; runtime.current = &second;
    transport.request = &first;
    uint8_t packet[20] = {0x11, 2, 3, 0x17};
    input_report(&transport, kIOReturnSuccess, NULL, kIOHIDReportTypeInput, 0x11, packet, sizeof(packet));
    assert(!first.received && !second.received && runtime.current == &second);
    packet[1] = 1;
    input_report(&transport, kIOReturnSuccess, NULL, kIOHIDReportTypeInput, 0x11, packet, sizeof(packet));
    assert(first.received && first.response_length == sizeof(packet) && !second.received);
    assert(runtime.current == &second);
    /* A separate transport using the same receiver slot cannot satisfy the request. */
    Transport other = {.online = true}; first.received = false;
    input_report(&other, kIOReturnSuccess, NULL, kIOHIDReportTypeInput, 0x11, packet, sizeof(packet));
    assert(!first.received);
    runtime.mice = runtime.current = NULL;
}

static uint8_t battery_reply[3];
static bool battery_exchange(uint8_t address, uint8_t index, uint8_t tag,
                             const uint8_t *parameters, size_t length) {
    (void)address; (void)index; (void)tag; (void)parameters; (void)length;
    memset(app.response,0,sizeof(app.response)); app.response_length=20;
    memcpy(app.response+4,battery_reply,sizeof(battery_reply)); return true;
}
static void test_battery_levels(void) {
    Mouse mouse={.connected=true,.battery=1}; runtime.current=&mouse;
    test_exchange=battery_exchange;
    battery_reply[0]=90; battery_reply[1]=50; battery_reply[2]=0;
    read_battery(true);
    assert(mouse.battery_percent==-1 && !strcmp(mouse.battery_status,"High (approx.)"));
    mouse.battery_percent_supported=true; read_battery(true);
    assert(mouse.battery_percent==90);
    battery_reply[2]=3; read_battery(true);
    assert(!strcmp(mouse.battery_status,"Full") && mouse.battery_charging==0);
    mouse.battery_unified=true; mouse.battery_percent_supported=false;
    battery_reply[0]=0; battery_reply[1]=8; battery_reply[2]=0; read_battery(true);
    assert(mouse.battery_percent==-1 && !strcmp(mouse.battery_status,"High (approx.)"));
    battery_reply[2]=1; read_battery(true);
    assert(!strcmp(mouse.battery_status,"Charging") && mouse.battery_charging==1);
    mouse.battery_percent_supported=true; battery_reply[2]=0; read_battery(true);
    assert(mouse.battery_percent==0);
    test_exchange=NULL; runtime.current=NULL;
}

int main(void) {
    runtime.lock_fd = -1;
    test_battery_levels();
    test_reconnect(); test_discovery_and_optional_features(); test_same_model_replacement_does_not_restore_old_controls(); test_receiver_mouse_without_feature_serial_connects(); test_all_receiver_slots(); test_receiver_scan_retry_and_wake(); test_reviewed_inventory_retention(); test_offline_receiver_slot_errors(); test_response_routing();
    fprintf(stderr, "Helper state: mouse=%zu transport=%zu bytes\n", sizeof(Mouse), sizeof(Transport));
    return 0;
}
