#include <assert.h>
#include <stdio.h>
#include "watch_rim_geometry.h"

int main(void)
{
    for (int radius = 50; radius <= 120; radius += 5) {
        lv_point_precise_t points[WATCH_RIM_POINT_COUNT];
        watch_rim_points(points, radius, WATCH_RIM_INSET);
        for (int corner = 0; corner < 4; ++corner) {
            for (int step = 0; step <= 16; ++step) {
                lv_point_precise_t p = points[1 + corner * 17 + step];
                lv_point_precise_t mirror = points[1 + (3 - corner) * 17 + 16 - step];
                assert(p.x + mirror.x == WATCH_FACE_WIDTH - 1);
                assert(p.y == mirror.y);
                assert(p.x >= WATCH_RIM_INSET);
                assert(p.x <= WATCH_FACE_WIDTH - 1 - WATCH_RIM_INSET);
                assert(p.y >= WATCH_RIM_INSET);
                assert(p.y <= WATCH_FACE_HEIGHT - 1 - WATCH_RIM_INSET);
            }
        }
        assert(points[0].x == points[WATCH_RIM_POINT_COUNT - 1].x);
        assert(points[0].y == points[WATCH_RIM_POINT_COUNT - 1].y);
    }
    puts("Rim geometry: symmetric and within inset for all calibration radii");
}
