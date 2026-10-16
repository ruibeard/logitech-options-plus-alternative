/* Exercise the real reconnect lifecycle without opening HID or posting input. */
#define main mx_helper_main
#include "../src/helper.c"
#undef main
#include <assert.h>

int main(void) {
    app.lock_fd = -1;
    app.online = true;
    app.initialisation_attempted = true;
    /* A failed handshake must arrange another attempt without a settings edit. */
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
        retry_connection();
        assert(app.reconnect_timer && app.reconnect_delay == delays[i]);
        cancel_reconnect();
    }
    /* A successful connection never starts background handshake polling. */
    app.connected = true;
    retry_connection();
    assert(!app.reconnect_timer);
    app.connected = false;

    retry_connection();
    app.online = false;
    close_device();
    assert(!app.reconnect_timer && !app.reconnect_delay);

    app.online = true;
    app.probe = true;
    retry_connection();
    assert(!app.reconnect_timer);
    app.probe = false;
    app.stop = true;
    retry_connection();
    assert(!app.reconnect_timer);
    app.stop = false;
    app.removed = true;
    retry_connection();
    assert(!app.reconnect_timer);
    app.removed = false;
    app.online = false;
    retry_connection();
    assert(!app.reconnect_timer);
    return 0;
}
