/* SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 jtomchak
 */
#pragma once
#include "lvgl.h"
/* LVGL task / display lock only. */
void muse_tools_ui_build(lv_obj_t *tile);
void muse_tools_ui_tick(void);
/* Same actions as the touch controls, also usable by the desktop preview. */
void muse_tools_ui_next(void);
void muse_tools_ui_act(void);
void muse_tools_ui_reset(void);
const char *muse_tools_ui_value(void);

#include "pocket_model.h"
bool muse_tools_ui_set_presets(const pocket_preset_t *items,int count);
bool muse_tools_ui_timer_start(const pocket_preset_t *preset);
void muse_tools_ui_timer_pause(void);
void muse_tools_ui_timer_resume(void);
void muse_tools_ui_timer_status(bool *running,unsigned *remaining,const char **title);
