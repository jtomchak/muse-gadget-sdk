/* SPDX-License-Identifier: Apache-2.0 */
#include "muse_tilt.h"
bool muse_tilt_update(muse_tilt_t *s, int16_t z, uint32_t now)
{
    if (!s || now - s->last_ms < 100)
        return false;
    s->last_ms = now;
    int az = z < 0 ? -(int)z : z;
    if (az > 6000) {
        s->flat = true;
        s->samples = 0;
    } else if (s->flat && az < 4096) {
        if (++s->samples >= 2) {
            s->flat = false;
            s->samples = 0;
            return true;
        }
    } else
        s->samples = 0;
    return false;
}
