/* SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 jtomchak
 */
#include "muse_experience.h"

#include <stdatomic.h>

static atomic_bool s_pressed;
static atomic_uint_least32_t s_pressed_at;

void muse_experience_press(bool down, uint32_t now_ms)
{
    if (down) atomic_store(&s_pressed_at, now_ms);
    atomic_store(&s_pressed, down);
}

bool muse_experience_preparing(uint32_t now_ms)
{
    /* A stuck or rejected event must not leave a listening indicator behind.
     * Unsigned subtraction also handles the millisecond clock wrapping. */
    return atomic_load(&s_pressed) && now_ms - atomic_load(&s_pressed_at) < 1000;
}

uint32_t muse_experience_avatar_ms(bool audio_active, bool idle, bool battery,
                                 uint32_t normal_ms)
{
    uint32_t period = audio_active ? 120 : idle ? (battery ? 200 : 80) : normal_ms;
    return period > normal_ms ? period : normal_ms;
}

int muse_experience_brightness(int saved_pct, bool battery, bool idle,
                              float idle_secs, bool preview_or_settings)
{
    return battery && idle && idle_secs >= 20 && !preview_or_settings && saved_pct > 30
        ? 30 : saved_pct;
}

int muse_experience_sleep_s(int saved_secs, bool battery)
{
    /* Respect the user's explicit Never setting and shorter sleep choices. */
    return battery && saved_secs > 60 ? 60 : saved_secs;
}
