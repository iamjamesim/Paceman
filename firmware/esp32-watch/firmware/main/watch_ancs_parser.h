#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

/* PreExisting describes the notification, not whether this event is new.
 * Ignore the initial replay on subscription, but accept later modifications
 * even when the notification still carries that flag. */
static inline bool watch_ancs_should_request_attributes(uint8_t event, uint8_t flags)
{
    const uint8_t added = 0, modified = 1, pre_existing = 1 << 2;
    return event == modified || (event == added && !(flags & pre_existing));
}

/* Get Notification Attributes, requesting AppIdentifier only. Never retrieve
 * message content from other apps. Responses may span arbitrary ATT fragments.
 * Oversized identifiers are drained, not buffered or treated as matches. */
typedef struct {
    uint32_t uid;
    size_t received;
    uint16_t length;
    uint8_t header[8];
    char app[96];
    bool invalid;
} watch_ancs_parser_t;

static inline void watch_ancs_parser_begin(watch_ancs_parser_t *p, uint32_t uid)
{
    memset(p, 0, sizeof(*p));
    p->uid = uid;
}

/* -1 = invalid response, 0 = incomplete, 1 = complete. */
static inline int watch_ancs_parser_feed(watch_ancs_parser_t *p,
                                        const uint8_t *data, size_t length)
{
    for (size_t i = 0; i < length; i++) {
        size_t pos = p->received++;
        if (pos < 8) {
            p->header[pos] = data[i];
            if (pos == 7) {
                uint32_t uid = (uint32_t)p->header[1] |
                    ((uint32_t)p->header[2] << 8) |
                    ((uint32_t)p->header[3] << 16) |
                    ((uint32_t)p->header[4] << 24);
                p->invalid = p->header[0] != 0 || p->header[5] != 0 || uid != p->uid;
                p->length = (uint16_t)p->header[6] | ((uint16_t)p->header[7] << 8);
            }
        } else if (pos - 8 < p->length) {
            if (pos - 8 < sizeof(p->app) - 1) p->app[pos - 8] = (char)data[i];
        } else {
            p->invalid = true;
        }
    }
    if (p->invalid) return -1;
    return p->received >= 8 && p->received == 8u + p->length ? 1 : 0;
}

static inline bool watch_ancs_parser_matches(const watch_ancs_parser_t *p, const char *app)
{
    return !p->invalid && p->received == 8u + p->length &&
        p->length < sizeof(p->app) && strlen(app) == p->length &&
        memcmp(p->app, app, p->length) == 0;
}
