#include <assert.h>
#include <stdio.h>
#include "watch_ancs_parser.h"

int main(void)
{
    /* Notification present before subscription: its initial replay must not
     * wake the phone. Replacing that same notification with Finished must wake
     * it even if iOS retains PreExisting alongside the action flags. */
    assert(!watch_ancs_should_request_attributes(0, 0x14));
    assert(watch_ancs_should_request_attributes(1, 0x14));
    assert(watch_ancs_should_request_attributes(1, 0x1c));
    /* New notifications and ordinary modifications work; removal is not a
     * source state change and unknown event types must not trigger a fetch. */
    assert(watch_ancs_should_request_attributes(0, 0x10));
    assert(watch_ancs_should_request_attributes(1, 0x10));
    assert(!watch_ancs_should_request_attributes(2, 0x10));
    assert(!watch_ancs_should_request_attributes(3, 0));

    const char *app = "ai.paceman.app";
    uint8_t wire[256] = {0, 0x78, 0x56, 0x34, 0x12, 0, 0, 0};
    wire[6] = strlen(app);
    memcpy(wire + 8, app, strlen(app));
    size_t length = 8 + strlen(app);
    watch_ancs_parser_t parser;
    /* Every ATT boundary, including splits inside UID and length fields. */
    for (size_t split = 1; split < length; split++) {
        watch_ancs_parser_begin(&parser, 0x12345678);
        assert(watch_ancs_parser_feed(&parser, wire, split) == 0);
        assert(watch_ancs_parser_feed(&parser, wire + split, length - split) == 1);
        assert(watch_ancs_parser_matches(&parser, app));
        assert(!watch_ancs_parser_matches(&parser, "com.example.other"));
    }
    watch_ancs_parser_begin(&parser, 0x12345678);
    for (size_t i = 0; i < length; i++)
        assert(watch_ancs_parser_feed(&parser, wire + i, 1) == (i + 1 == length));
    assert(watch_ancs_parser_matches(&parser, app));
    /* Wrong notification, command, attribute and trailing bytes fail closed. */
    watch_ancs_parser_begin(&parser, 42);
    assert(watch_ancs_parser_feed(&parser, wire, length) == -1);
    wire[0] = 1;
    watch_ancs_parser_begin(&parser, 0x12345678);
    assert(watch_ancs_parser_feed(&parser, wire, length) == -1);
    wire[0] = 0; wire[5] = 3;
    watch_ancs_parser_begin(&parser, 0x12345678);
    assert(watch_ancs_parser_feed(&parser, wire, length) == -1);
    wire[5] = 0;
    watch_ancs_parser_begin(&parser, 0x12345678);
    assert(watch_ancs_parser_feed(&parser, wire, length + 1) == -1);
    /* Missing/hidden identifier cannot match. */
    wire[6] = 0;
    watch_ancs_parser_begin(&parser, 0x12345678);
    assert(watch_ancs_parser_feed(&parser, wire, 8) == 1);
    assert(!watch_ancs_parser_matches(&parser, app));
    /* Drain oversized values without overflow or prefix matches. */
    wire[6] = 200;
    watch_ancs_parser_begin(&parser, 0x12345678);
    assert(watch_ancs_parser_feed(&parser, wire, 208) == 1);
    assert(!watch_ancs_parser_matches(&parser, app));
    puts("ANCS event filtering and attribute parser passed");
    return 0;
}
