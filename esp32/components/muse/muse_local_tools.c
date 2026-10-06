/* SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 jtomchak
 */
#include "muse_local_tools.h"
#include <stdatomic.h>

static const muse_recipe_t s_recipes[] = {
    {"V60 EXAMPLE", "15g coffee / 250g water\n0:00 bloom to 45g\n0:45 pour to 150g\n1:30 pour to 250g", 180},
    {"AEROPRESS EXAMPLE", "15g coffee / 200g water\nAdd water and stir\n1:30 begin gentle press", 120},
};

bool muse_timer_start(muse_timer_t *t, uint32_t duration_ms, uint32_t now_ms)
{
    if (!t || !duration_ms || duration_ms > MUSE_TIMER_MAX_MS) return false;
    *t = (muse_timer_t){ .remaining_ms = duration_ms, .started_ms = now_ms, .running = true };
    return true;
}

bool muse_timer_update(muse_timer_t *t, uint32_t now_ms)
{
    if (!t || !t->running) return false;
    uint32_t elapsed = now_ms - t->started_ms;
    t->started_ms = now_ms;
    if (elapsed >= t->remaining_ms) {
        t->remaining_ms = 0;
        t->running = false;
        t->finished = true;
        return true;
    }
    t->remaining_ms -= elapsed;
    return false;
}

void muse_timer_pause(muse_timer_t *t, uint32_t now_ms)
{
    muse_timer_update(t, now_ms);
    if (t) t->running = false;
}

void muse_timer_resume(muse_timer_t *t, uint32_t now_ms)
{
    if (t && t->remaining_ms && !t->finished) {
        t->started_ms = now_ms;
        t->running = true;
    }
}

size_t muse_recipe_count(void) { return sizeof(s_recipes) / sizeof(s_recipes[0]); }
const muse_recipe_t *muse_recipe_get(size_t i) { return i < muse_recipe_count() ? &s_recipes[i] : NULL; }

static atomic_uint_least32_t s_deadline;

void muse_tools_alarm_set(bool armed, uint32_t deadline_ms)
{
    /* Zero means disarmed. A deadline exactly at clock wrap shifts by 1 ms,
     * well inside the input task's polling resolution. */
    atomic_store(&s_deadline, armed ? (deadline_ms ? deadline_ms : 1) : 0);
}

bool muse_tools_alarm_take(uint32_t now_ms)
{
    uint_least32_t deadline = atomic_load(&s_deadline);
    if (!deadline || (int32_t)(now_ms - deadline) < 0) return false;
    /* A UI rearm between reading and taking must not be cleared. */
    return atomic_compare_exchange_strong(&s_deadline, &deadline, 0);
}
