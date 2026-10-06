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

uint32_t muse_experience_avatar_ms(bool audio_active, uint32_t normal_ms)
{
    return audio_active && normal_ms < 120 ? 120 : normal_ms;
}
