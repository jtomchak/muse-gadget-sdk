/* SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 jtomchak
 */
#include "muse_tools_ui.h"
#include "muse_settings.h"
#include "muse_state.h"
#include "muse_local_tools.h"
#include "muse_ui.h"
#include "esp_timer.h"
#include "sdkconfig.h"
#if !CONFIG_MUSE_BOARD_SIMULATOR
#include "nvs.h"
#endif
#include <stdio.h>
#include <string.h>

static lv_obj_t *s_value, *s_title, *s_action, *s_detail;
static unsigned s_tool;
static muse_timer_t s_timer;
static unsigned s_timer_tool;
static bool s_completion_pending;

enum { TOOL_BRIGHTNESS, TOOL_SPEAKER, TOOL_FOCUS, TOOL_RECIPE_FIRST };

static uint32_t now_ms(void) { return (uint32_t)(esp_timer_get_time() / 1000); }

static void changed_text(lv_obj_t *label, const char *text)
{
    if (strcmp(lv_label_get_text(label), text)) lv_label_set_text(label, text);
}

static void save_tool(void)
{
#if !CONFIG_MUSE_BOARD_SIMULATOR
    nvs_handle_t handle;
    if (nvs_open("muse_tools", NVS_READWRITE, &handle) == ESP_OK) {
        if (nvs_set_u8(handle, "selected", s_tool) == ESP_OK) nvs_commit(handle);
        nvs_close(handle);
    }
#endif
}

static void refresh(void)
{
    char value[24];
    const char *title, *action, *detail = "";
    if (s_tool == TOOL_BRIGHTNESS) {
        title = "BRIGHTNESS";
        snprintf(value, sizeof(value), "%d%%", muse_settings_brightness());
        action = "CHANGE";
    } else if (s_tool == TOOL_SPEAKER) {
        title = "SPEAKER";
        snprintf(value, sizeof(value), "%s", muse_settings_speaker_on() ? "ON" : "OFF");
        action = "TOGGLE";
    } else {
        const muse_recipe_t *recipe = s_tool >= TOOL_RECIPE_FIRST ? muse_recipe_get(s_tool - TOOL_RECIPE_FIRST) : NULL;
        title = recipe ? recipe->name : "FOCUS TIMER";
        detail = recipe ? recipe->instructions : "25 minutes, one task";
        bool mine = s_timer_tool == s_tool;
        uint32_t secs = mine && (s_timer.running || s_timer.remaining_ms || s_timer.finished)
            ? (s_timer.remaining_ms + 999) / 1000 : recipe ? recipe->seconds : 25 * 60;
        snprintf(value, sizeof(value), "%02u:%02u%s", (unsigned)(secs / 60), (unsigned)(secs % 60),
                 mine && s_timer.finished ? " DONE" : "");
        action = mine && s_timer.running ? "PAUSE" : mine && s_timer.remaining_ms ? "RESUME" : "START";
    }
    changed_text(s_title, title);
    changed_text(s_value, value);
    changed_text(s_action, action);
    changed_text(s_detail, detail);
}

static void next(lv_event_t *e)
{
    (void)e;
    muse_tools_ui_next();
}

static void act(lv_event_t *e)
{
    (void)e;
    muse_tools_ui_act();
}

void muse_tools_ui_next(void)
{
    muse_state_poke();
    s_tool = (s_tool + 1) % (TOOL_RECIPE_FIRST + muse_recipe_count());
    save_tool();
    refresh();
}

void muse_tools_ui_act(void)
{
    muse_state_poke();
    if (s_tool == TOOL_BRIGHTNESS) {
        int brightness = muse_settings_brightness();
        muse_settings_set_brightness(brightness >= 100 ? 20 : brightness + 20);
    } else if (s_tool == TOOL_SPEAKER) {
        muse_settings_set_speaker_on(!muse_settings_speaker_on());
    } else {
        uint32_t now = now_ms();
        if (s_timer.running && s_timer_tool != s_tool) {
            /* One timer at a time: expose the running one instead of silently
             * replacing it when browsing a different preset. */
            s_tool = s_timer_tool;
            refresh();
            return;
        }
        if (s_timer_tool == s_tool && s_timer.running) {
            muse_timer_pause(&s_timer, now);
        } else if (s_timer_tool == s_tool && s_timer.remaining_ms && !s_timer.finished) {
            muse_timer_resume(&s_timer, now);
        } else {
            const muse_recipe_t *recipe = s_tool >= TOOL_RECIPE_FIRST ? muse_recipe_get(s_tool - TOOL_RECIPE_FIRST) : NULL;
            s_timer_tool = s_tool;
            muse_timer_start(&s_timer, (recipe ? recipe->seconds : 25 * 60) * 1000, now);
        }
        muse_tools_alarm_set(s_timer.running, now + s_timer.remaining_ms);
        s_completion_pending = s_timer.finished;
    }
    refresh();
}

void muse_tools_ui_reset(void)
{
    muse_state_poke();
    s_timer = (muse_timer_t){0};
    s_completion_pending = false;
    muse_tools_alarm_set(false, 0);
    refresh();
}

static void reset(lv_event_t *e) { (void)e; muse_tools_ui_reset(); }

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
    s_title = label(tile, -140, &lv_font_montserrat_14);
    s_value = label(tile, -95, &lv_font_unscii_16);
    s_detail = label(tile, -20, &lv_font_montserrat_14);
    lv_obj_set_width(s_detail, 280);
    lv_obj_set_style_text_align(s_detail, LV_TEXT_ALIGN_CENTER, 0);
    s_action = button(tile, 65, "", act);
    button(tile, 120, "NEXT TOOL", next);
    lv_obj_t *reset_label = button(tile, 169, "RESET TIMER", reset);
    lv_obj_set_size(lv_obj_get_parent(reset_label), 180, 36);
#if !CONFIG_MUSE_BOARD_SIMULATOR
    nvs_handle_t handle;
    uint8_t selected = 0;
    if (nvs_open("muse_tools", NVS_READONLY, &handle) == ESP_OK) {
        nvs_get_u8(handle, "selected", &selected);
        nvs_close(handle);
        if (selected < TOOL_RECIPE_FIRST + muse_recipe_count()) s_tool = selected;
    }
#endif
    refresh();
}

void muse_tools_ui_tick(void)
{
    if (!s_value) return;
    if (muse_timer_update(&s_timer, now_ms())) {
        muse_tools_alarm_set(false, 0);
        s_completion_pending = true;
    }
    /* Visual completion never interrupts recording/playback or pairing. */
    if (s_completion_pending && muse_state_mode(NULL) == MUSE_MODE_IDLE) {
        s_completion_pending = false;
        s_tool = s_timer_tool;
        muse_state_set_asleep(false);
        muse_state_poke();
        muse_ui_show_page(1);
    }
    refresh();
}

const char *muse_tools_ui_value(void) { return s_value ? lv_label_get_text(s_value) : ""; }
