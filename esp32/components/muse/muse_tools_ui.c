/* SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 jtomchak
 */
#include "muse_tools_ui.h"
#include "muse_settings.h"
#include "muse_state.h"
#include <stdio.h>
#include <string.h>

static lv_obj_t *s_value, *s_title, *s_action;
static unsigned s_tool;

static void refresh(void)
{
    char value[24];
    if (s_tool == 0) {
        lv_label_set_text(s_title, "BRIGHTNESS");
        snprintf(value, sizeof(value), "%d%%", muse_settings_brightness());
        lv_label_set_text(s_action, "CHANGE");
    } else {
        lv_label_set_text(s_title, "SPEAKER");
        snprintf(value, sizeof(value), "%s", muse_settings_speaker_on() ? "ON" : "OFF");
        lv_label_set_text(s_action, "TOGGLE");
    }
    if (strcmp(lv_label_get_text(s_value), value)) lv_label_set_text(s_value, value);
}

static void next(lv_event_t *e)
{
    (void)e;
    muse_state_poke();
    s_tool = (s_tool + 1) % 2;
    refresh();
}

static void act(lv_event_t *e)
{
    (void)e;
    muse_state_poke();
    if (s_tool == 0) {
        int brightness = muse_settings_brightness();
        muse_settings_set_brightness(brightness >= 100 ? 20 : brightness + 20);
    } else {
        muse_settings_set_speaker_on(!muse_settings_speaker_on());
    }
    refresh();
}

static lv_obj_t *label(lv_obj_t *tile, int y, const lv_font_t *font)
{
    lv_obj_t *obj = lv_label_create(tile);
    lv_obj_set_style_text_font(obj, font, 0);
    lv_obj_set_style_text_color(obj, lv_color_hex(0xd8d2ff), 0);
    lv_obj_align(obj, LV_ALIGN_CENTER, 0, y);
    return obj;
}

static lv_obj_t *button(lv_obj_t *tile, int y, const char *text, lv_event_cb_t cb)
{
    lv_obj_t *obj = lv_button_create(tile);
    lv_obj_set_size(obj, 220, 48);
    lv_obj_align(obj, LV_ALIGN_CENTER, 0, y);
    lv_obj_set_style_bg_color(obj, lv_color_hex(0x201a35), 0);
    lv_obj_t *lbl = lv_label_create(obj);
    lv_label_set_text(lbl, text);
    lv_obj_center(lbl);
    lv_obj_add_event_cb(obj, cb, LV_EVENT_CLICKED, NULL);
    return lbl;
}

void muse_tools_ui_build(lv_obj_t *tile)
{
    lv_obj_set_style_bg_color(tile, lv_color_black(), 0);
    lv_obj_set_style_bg_opa(tile, LV_OPA_COVER, 0);
    lv_obj_remove_flag(tile, LV_OBJ_FLAG_SCROLLABLE);
    s_title = label(tile, -105, &lv_font_montserrat_14);
    s_value = label(tile, -25, &lv_font_unscii_16);
    s_action = button(tile, 60, "", act);
    button(tile, 122, "NEXT TOOL", next);
    refresh();
}

void muse_tools_ui_tick(void)
{
    if (s_value) refresh();
}
