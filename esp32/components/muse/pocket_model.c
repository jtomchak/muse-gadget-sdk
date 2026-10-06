/* SPDX-License-Identifier: Apache-2.0 */
#include "pocket_model.h"
#include "cJSON.h"
#include <math.h>
#include <stdio.h>
#include <string.h>
static const cJSON *get(const cJSON *o, const char *key)
{
    return cJSON_GetObjectItemCaseSensitive(o, key);
}
static bool text(const cJSON *o, const char *key, char *out, size_t size, bool required)
{
    const cJSON *v = get(o, key);
    if (!cJSON_IsString(v) || !v->valuestring || (required && !*v->valuestring) ||
        strlen(v->valuestring) >= size)
        return false;
    memcpy(out, v->valuestring, strlen(v->valuestring) + 1);
    return true;
}
static bool number(const cJSON *o, const char *key, int64_t lo, int64_t hi, int64_t *out)
{
    const cJSON *v = get(o, key);
    if (!cJSON_IsNumber(v) || !isfinite(v->valuedouble) ||
        floor(v->valuedouble) != v->valuedouble || v->valuedouble < lo || v->valuedouble > hi)
        return false;
    *out = (int64_t)v->valuedouble;
    return true;
}
static bool integer(const cJSON *o, const char *key, int lo, int hi, int *out)
{
    int64_t value;
    if (!number(o, key, lo, hi, &value))
        return false;
    *out = (int)value;
    return true;
}
static bool flag(const cJSON *o, const char *key, bool *out)
{
    const cJSON *v = get(o, key);
    if (!cJSON_IsBool(v))
        return false;
    *out = cJSON_IsTrue(v);
    return true;
}
static int fail(char *error, size_t capacity, const char *message)
{
    snprintf(error, capacity, "%s", message);
    return -1;
}
void pocket_settings_init(pocket_settings_t *s)
{
    *s = (pocket_settings_t){.clock = true,
                             .clock24 = true,
                             .tapThreshold = 800,
                             .nightStart = 1320,
                             .nightEnd = 420,
                             .accent = 0xb8a3ff,
                             .name = "Moe",
                             .timezone = "MST7"};
}
void pocket_model_init(pocket_model_t *m)
{
    memset(m, 0, sizeof(*m));
    pocket_settings_init(&m->settings);
}
bool pocket_night_contains(bool enabled, int start, int end, int minute)
{
    return enabled && start != end &&
           (start < end ? minute >= start && minute < end : minute >= start || minute < end);
}
int pocket_model_apply(pocket_model_t *m, const char *method, const cJSON *p, char *error,
                       size_t cap)
{
    if (!m || !method || !cJSON_IsObject(p))
        return fail(error, cap, "Invalid request parameters");
    if (!strcmp(method, "hello") || !strcmp(method, "status") || !strcmp(method, "diagnostics"))
        return POCKET_QUERY;
    if (!strcmp(method, "settings.set")) {
        pocket_settings_t s = {0};
        if (!flag(p, "clock", &s.clock) || !flag(p, "tap", &s.tap) || !flag(p, "tilt", &s.tilt) ||
            !flag(p, "night", &s.night) || !flag(p, "clock24", &s.clock24) ||
            !flag(p, "notifications", &s.notifications) || !flag(p, "relay", &s.relay) ||
            !integer(p, "shortcut", 0, 2, &s.shortcut) ||
            !integer(p, "tapThreshold", 400, 2000, &s.tapThreshold) ||
            !integer(p, "nightStart", 0, 1439, &s.nightStart) ||
            !integer(p, "nightEnd", 0, 1439, &s.nightEnd) ||
            !integer(p, "accent", 0, 0xffffff, &s.accent) ||
            !integer(p, "avatar", 0, 3, &s.avatar) ||
            !text(p, "name", s.name, sizeof(s.name), true) ||
            !text(p, "timezone", s.timezone, sizeof(s.timezone), true))
            return fail(error, cap, "Invalid settings or value outside device limits");
        m->settings = s;
        return POCKET_SETTINGS;
    }
    if (!strcmp(method, "preset.put")) {
        pocket_preset_t item = {0};
        if (!text(p, "id", item.id, sizeof(item.id), true) ||
            !text(p, "title", item.title, sizeof(item.title), true) ||
            !text(p, "detail", item.detail, sizeof(item.detail), false) ||
            !integer(p, "seconds", 1, 86400, &item.seconds))
            return fail(error, cap, "Invalid preset");
        int index = 0;
        while (index < m->preset_count && strcmp(item.id, m->presets[index].id))
            index++;
        if (index == POCKET_ITEMS)
            return fail(error, cap, "Moe can store eight presets");
        m->presets[index] = item;
        if (index == m->preset_count)
            m->preset_count++;
        return POCKET_PRESETS;
    }
    if (!strcmp(method, "card.put")) {
        pocket_card_t item = {0};
        if (!text(p, "id", item.id, sizeof(item.id), true) ||
            !text(p, "title", item.title, sizeof(item.title), true) ||
            !text(p, "body", item.body, sizeof(item.body), false) ||
            !text(p, "source", item.source, sizeof(item.source), false) ||
            !number(p, "expires", 0, 253402300799LL, &item.expires))
            return fail(error, cap, "Invalid card");
        int index = 0;
        while (index < m->card_count && strcmp(item.id, m->cards[index].id))
            index++;
        if (index == POCKET_ITEMS)
            return fail(error, cap, "Moe can store eight cards");
        m->cards[index] = item;
        if (index == m->card_count)
            m->card_count++;
        return POCKET_CARDS;
    }
    if (!strcmp(method, "preset.delete") || !strcmp(method, "card.delete") ||
        !strcmp(method, "card.show") || !strcmp(method, "timer.start")) {
        char id[37];
        if (!text(p, "id", id, sizeof(id), true))
            return fail(error, cap, "An item ID is required");
        bool preset = !strncmp(method, "preset.", 7) || !strcmp(method, "timer.start");
        int count = preset ? m->preset_count : m->card_count, index = 0;
        while (index < count && strcmp(id, preset ? m->presets[index].id : m->cards[index].id))
            index++;
        if (index == count)
            return fail(error, cap, "The item is no longer on Moe; refresh first");
        if (!strcmp(method, "timer.start"))
            return POCKET_TIMER_START;
        if (!strcmp(method, "card.show"))
            return POCKET_CARD_SHOW;
        if (preset) {
            memmove(m->presets + index, m->presets + index + 1,
                    (size_t)(count - index - 1) * sizeof(m->presets[0]));
            m->preset_count--;
            return POCKET_PRESETS;
        }
        memmove(m->cards + index, m->cards + index + 1,
                (size_t)(count - index - 1) * sizeof(m->cards[0]));
        m->card_count--;
        return POCKET_CARDS;
    }
    const char *methods[] = {"timer.pause",
                             "timer.resume",
                             "timer.reset",
                             "find",
                             "sleep",
                             "time.set",
                             "avatar.upload",
                             "ota",
                             "reply.begin",
                             "reply.part",
                             "reply.end",
                             "reply.text",
                             "notification.action"};
    const int actions[] = {POCKET_TIMER_PAUSE, POCKET_TIMER_RESUME, POCKET_TIMER_RESET,
                           POCKET_FIND,        POCKET_SLEEP,        POCKET_TIME,
                           POCKET_AVATAR,      POCKET_OTA,          POCKET_REPLY_BEGIN,
                           POCKET_REPLY_PART,  POCKET_REPLY_END,    POCKET_REPLY_TEXT,
                           POCKET_ANCS_ACTION};
    for (size_t i = 0; i < sizeof(actions) / sizeof(actions[0]); i++)
        if (!strcmp(method, methods[i]))
            return actions[i];
    return fail(error, cap, "Unknown MusePocket method");
}
static cJSON *settings_json(const pocket_settings_t *s)
{
    cJSON *o = cJSON_CreateObject();
    if (!o)
        return NULL;
#define FLAG(k) cJSON_AddBoolToObject(o, #k, s->k)
    FLAG(clock);
    FLAG(tap);
    FLAG(tilt);
    FLAG(night);
    FLAG(clock24);
    FLAG(notifications);
    FLAG(relay);
#undef FLAG
#define INT(k) cJSON_AddNumberToObject(o, #k, s->k)
    INT(shortcut);
    INT(tapThreshold);
    INT(nightStart);
    INT(nightEnd);
    INT(accent);
    INT(avatar);
#undef INT
    cJSON_AddStringToObject(o, "name", s->name);
    cJSON_AddStringToObject(o, "timezone", s->timezone);
    return o;
}
cJSON *pocket_model_json(const pocket_model_t *m)
{
    cJSON *o = cJSON_CreateObject();
    if (!o)
        return NULL;
    cJSON_AddItemToObject(o, "settings", settings_json(&m->settings));
    cJSON *presets = cJSON_AddArrayToObject(o, "presets"),
          *cards = cJSON_AddArrayToObject(o, "cards");
    for (int i = 0; i < m->preset_count; i++) {
        const pocket_preset_t *p = m->presets + i;
        cJSON *v = cJSON_CreateObject();
        cJSON_AddStringToObject(v, "id", p->id);
        cJSON_AddStringToObject(v, "title", p->title);
        cJSON_AddStringToObject(v, "detail", p->detail);
        cJSON_AddNumberToObject(v, "seconds", p->seconds);
        cJSON_AddItemToArray(presets, v);
    }
    for (int i = 0; i < m->card_count; i++) {
        const pocket_card_t *p = m->cards + i;
        cJSON *v = cJSON_CreateObject();
        cJSON_AddStringToObject(v, "id", p->id);
        cJSON_AddStringToObject(v, "title", p->title);
        cJSON_AddStringToObject(v, "body", p->body);
        cJSON_AddStringToObject(v, "source", p->source);
        cJSON_AddNumberToObject(v, "expires", (double)p->expires);
        cJSON_AddItemToArray(cards, v);
    }
    return o;
}
