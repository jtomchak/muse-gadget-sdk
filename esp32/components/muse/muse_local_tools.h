/* SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 jtomchak
 */
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#define MUSE_TIMER_MAX_MS (24u * 60 * 60 * 1000)
typedef struct {
    uint32_t remaining_ms, started_ms;
    bool running, finished;
} muse_timer_t;

bool muse_timer_start(muse_timer_t *timer, uint32_t duration_ms, uint32_t now_ms);
bool muse_timer_update(muse_timer_t *timer, uint32_t now_ms);
void muse_timer_pause(muse_timer_t *timer, uint32_t now_ms);
void muse_timer_resume(muse_timer_t *timer, uint32_t now_ms);

typedef struct {
    const char *name, *instructions;
    uint32_t seconds;
} muse_recipe_t;
size_t muse_recipe_count(void);
const muse_recipe_t *muse_recipe_get(size_t index);

/* UI owns the timer; the input task only takes this independent alarm to wake
 * the display. No network, heap allocation, or rendering on the input task. */
void muse_tools_alarm_set(bool armed, uint32_t deadline_ms);
bool muse_tools_alarm_take(uint32_t now_ms);
uint32_t muse_tools_alarm_wait_ms(uint32_t now_ms, uint32_t max_wait_ms);
