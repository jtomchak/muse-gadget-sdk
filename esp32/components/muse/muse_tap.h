/* SPDX-License-Identifier: Apache-2.0 */
#pragma once
#include <stdbool.h>
#include <stdint.h>
typedef struct {
    bool (*read)(uint8_t reg, uint8_t *value);
    bool (*write)(uint8_t reg, uint8_t value);
    void (*delay_ms)(unsigned ms);
} muse_tap_bus_t;
/* QMI8658A tap engine, accelerometer only. Bounded CTRL9 handshake. */
bool muse_tap_configure(const muse_tap_bus_t *bus);
