/* SPDX-License-Identifier: Apache-2.0 */
#pragma once
#include <stdbool.h>
#include <stdint.h>
typedef struct {bool flat;unsigned samples;uint32_t last_ms;} muse_tilt_t;
/* +/-4g accelerometer Z: arm flat, then two polls below 0.5g, 100 ms apart. */
bool muse_tilt_update(muse_tilt_t *state,int16_t z,uint32_t now_ms);
