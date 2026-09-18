#pragma once

#include <math.h>
#include "watch_face_layout.h"

/* Calibrated on the physical 410x502 watch with a near-flush rim.
 * Keep the outer-edge radius separate from the inset stroke centerline. */
enum {
    WATCH_SCREEN_CORNER_RADIUS = 115,
    WATCH_RIM_INSET = 2,
    WATCH_RIM_POINT_COUNT = 70,
};

static inline void watch_rim_points(lv_point_precise_t *points, int outer_radius, int inset)
{
    const double right = WATCH_FACE_WIDTH - 1;
    const double bottom = WATCH_FACE_HEIGHT - 1;
    const double radius = outer_radius - inset;
    const double cx[] = {right - outer_radius, right - outer_radius, outer_radius, outer_radius};
    const double cy[] = {outer_radius, bottom - outer_radius, bottom - outer_radius, outer_radius};
    unsigned n = 0;
    points[n++] = (lv_point_precise_t){right / 2, inset};
    for (int corner = 0; corner < 4; ++corner) {
        for (int step = 0; step <= 16; ++step) {
            const double angle = (-90 + corner * 90 + step * 90.0 / 16) * 3.141592653589793 / 180;
            /* LVGL uses integer points on the watch. Truncation biases the
             * mirrored curves differently and can turn 9.999... into 9. */
            points[n++] = (lv_point_precise_t){lround(cx[corner] + radius * cos(angle)),
                                              lround(cy[corner] + radius * sin(angle))};
        }
    }
    points[n] = points[0];
}
