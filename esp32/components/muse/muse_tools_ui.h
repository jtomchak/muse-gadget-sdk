/* SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 jtomchak
 */
#pragma once
#include "lvgl.h"
/* LVGL task / display lock only. */
void muse_tools_ui_build(lv_obj_t *tile);
void muse_tools_ui_tick(void);
