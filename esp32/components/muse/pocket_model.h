/* SPDX-License-Identifier: Apache-2.0 */
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
typedef struct cJSON cJSON;
#define POCKET_ITEMS 8
typedef struct {
    bool clock,tap,tilt,night,clock24,notifications,relay;
    int shortcut,tapThreshold,nightStart,nightEnd,accent,avatar;
    char name[25],timezone[64];
} pocket_settings_t;
typedef struct { char id[37],title[33],detail[161]; int seconds; } pocket_preset_t;
typedef struct { char id[37],title[33],body[161],source[33]; int64_t expires; } pocket_card_t;
typedef struct { pocket_settings_t settings; pocket_preset_t presets[POCKET_ITEMS]; pocket_card_t cards[POCKET_ITEMS]; int preset_count,card_count; } pocket_model_t;
enum { POCKET_QUERY,POCKET_SETTINGS,POCKET_PRESETS,POCKET_CARDS,POCKET_TIMER_START,POCKET_TIMER_PAUSE,POCKET_TIMER_RESUME,POCKET_TIMER_RESET,POCKET_CARD_SHOW,POCKET_FIND,POCKET_SLEEP,POCKET_TIME,POCKET_AVATAR,POCKET_OTA,POCKET_REPLY_BEGIN,POCKET_REPLY_PART,POCKET_REPLY_END,POCKET_REPLY_TEXT,POCKET_ANCS_ACTION };
void pocket_model_init(pocket_model_t *model);
/* Validate atomically before updating. Returns action or -1 with safe error. */
int pocket_model_apply(pocket_model_t *model,const char *method,const cJSON *params,char *error,size_t capacity);
cJSON *pocket_model_json(const pocket_model_t *model);
bool pocket_night_contains(bool enabled,int start,int end,int minute);

void pocket_settings_init(pocket_settings_t *settings);
