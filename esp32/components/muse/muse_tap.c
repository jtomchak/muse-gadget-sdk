/* SPDX-License-Identifier: Apache-2.0
 * QMI8658A datasheet Rev A sections 5.3 and 10. Values match Waveshare's
 * SensorLib tap example (20/50/250 samples, alpha 1/16, gamma 1/4).
 */
#include "muse_tap.h"
static bool handshake(const muse_tap_bus_t *b, bool done)
{
    for (unsigned i = 0; i < 100; i++) {
        uint8_t v;
        if (!b->read(0x2d, &v)) return false;
        if (((v & 0x80) != 0) == done) return true;
        b->delay_ms(1);
    }
    return false;
}
static bool command(const muse_tap_bus_t *b)
{
    return b->write(0x0a, 0x0c) && handshake(b, true)
        && b->write(0x0a, 0) && handshake(b, false);
}
bool muse_tap_configure_threshold(const muse_tap_bus_t *b,unsigned threshold)
{
    if(threshold<400||threshold>2000)return false;
    uint8_t id;
    if (!b->read(0, &id) || id != 0x05) return false;
    /* Auto increment, INT1 enabled; sensors off and non-sync sample mode.
     * CTRL8.bit7 selects STATUS_INT.bit7 for the command handshake. */
    if (!b->write(0x08, 0) || !b->write(0x02, 0x48) || !b->write(0x09, 0x80)) return false;
    const uint8_t phase1[] = {20, 0, 50, 0, 250, 0, 0, 1};
    const uint8_t phase2[] = {8, 32, threshold&255, threshold>>8, (threshold/2)&255, (threshold/2)>>8, 0, 2};
    for (unsigned phase = 0; phase < 2; phase++) {
        const uint8_t *values = phase ? phase2 : phase1;
        for (unsigned i = 0; i < 8; i++) if (!b->write(0x0b+i, values[i])) return false;
        if (!command(b)) return false;
    }
    /* +/-4g, 500 Hz; LPF off; tap mapped to INT1. Gyroscope remains off. */
    return b->write(0x03, 0x14) && b->write(0x06, 0)
        && b->write(0x09, 0xc1) && b->write(0x08, 1);
}

bool muse_tap_configure(const muse_tap_bus_t *b){return muse_tap_configure_threshold(b,800);}
