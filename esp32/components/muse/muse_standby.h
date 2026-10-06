/* SPDX-License-Identifier: Apache-2.0 */
#pragma once
#include <stdbool.h>
#include <stdint.h>
void muse_standby_init(void);
bool muse_standby_enabled(void);
void muse_standby_toggle(void);
bool muse_standby_tap_enabled(void);
void muse_standby_toggle_tap(void);
/* 0: tools, 1: speaker mute, 2: phone setup. */
int muse_standby_shortcut(void);
void muse_standby_next_shortcut(void);
void muse_standby_clock(char out[6], int *minute);
/* Input task pauses LVGL only after it has had time to flush the clock. */
bool muse_standby_can_pause(uint32_t now_ms);
void muse_standby_rendered(uint32_t now_ms);
void muse_standby_exit(void);
