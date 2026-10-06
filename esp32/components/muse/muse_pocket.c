/* SPDX-License-Identifier: Apache-2.0
 * MusePocket v1: bounded messages, one worker, and no BLE work on audio/UI
 * tasks.
 */
#include "muse_pocket.h"
#include "cJSON.h"
#include "esp_heap_caps.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/idf_additions.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "mbedtls/base64.h"
#include "muse_adpcm.h"
#include "muse_ble.h"
#include "muse_board.h"
#include "muse_link.h"
#include "muse_mem.h"
#include "muse_pocket_ancs.h"
#include "muse_standby.h"
#include "muse_state.h"
#include "muse_tools_ui.h"
#include "muse_ui.h"
#include "muse_voice.h"
#include "nvs.h"
#include "pocket_frame.h"
#include <math.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>

typedef struct {
    uint32_t generation;
    uint16_t size;
    uint8_t data[512];
} packet_t;
typedef struct {
    char event[32], detail[192];
} event_t;
static QueueHandle_t s_packets, s_events;
static SemaphoreHandle_t s_lock;
static pocket_model_t *s_model;
static TaskHandle_t s_worker;
void muse_pocket_kick(void)
{
    if (s_worker)
        xTaskNotifyGive(s_worker);
}
static pocket_rx_t *s_rx;
static atomic_bool s_secure, s_initialized;
static atomic_uint s_generation;
static uint16_t s_transfer;
static char s_notice[401];
static uint8_t *s_avatar, *s_in_audio, *s_note;
static size_t s_in_size, s_in_used, s_in_frames, s_note_frames;
static uint32_t s_in_crc, s_turn, s_note_turn, s_note_generation;
static int16_t *s_reply;
static size_t s_reply_frames;
static int64_t s_in_began;
static lv_obj_t *s_avatar_obj, *s_avatar_canvas;
static lv_image_dsc_t s_avatar_dsc;
static int s_draw_avatar = -1, s_draw_accent = -1;
static int64_t s_draw_next;
static const cJSON *get(const cJSON *o, const char *key)
{
    return cJSON_GetObjectItemCaseSensitive(o, key);
}
static const char *str(const cJSON *o, const char *key)
{
    const cJSON *v = get(o, key);
    return cJSON_IsString(v) ? v->valuestring : NULL;
}
static bool num(const cJSON *o, const char *key, int64_t lo, int64_t hi, int64_t *out)
{
    const cJSON *v = get(o, key);
    if (!cJSON_IsNumber(v) || !isfinite(v->valuedouble) ||
        floor(v->valuedouble) != v->valuedouble || v->valuedouble < lo || v->valuedouble > hi)
        return false;
    *out = (int64_t)v->valuedouble;
    return true;
}
static void *psram(size_t n) { return heap_caps_malloc(n, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT); }
static bool save(const pocket_model_t *model)
{
    cJSON *json = pocket_model_json(model);
    char *text = json ? cJSON_PrintUnformatted(json) : NULL;
    cJSON_Delete(json);
    if (!text)
        return false;
    nvs_handle_t h;
    esp_err_t e = nvs_open("muse_pocket", NVS_READWRITE, &h);
    if (e == ESP_OK) {
        e = nvs_set_str(h, "model", text);
        if (e == ESP_OK)
            e = nvs_commit(h);
        nvs_close(h);
    }
    cJSON_free(text);
    return e == ESP_OK;
}
void muse_pocket_settings(pocket_settings_t *out)
{
    if (!out)
        return;
    if (!atomic_load(&s_initialized)) {
        pocket_settings_init(out);
        return;
    }
    xSemaphoreTake(s_lock, portMAX_DELAY);
    *out = s_model->settings;
    xSemaphoreGive(s_lock);
    out->clock = muse_standby_clock_preference();
    out->tap = muse_standby_tap_enabled();
    out->shortcut = muse_standby_shortcut();
}
void muse_pocket_connection(uint16_t handle, bool secure)
{
    (void)handle;
    bool old = atomic_exchange(&s_secure, secure);
    if (old != secure || !secure)
        atomic_fetch_add(&s_generation, 1);
}
int muse_pocket_write(const uint8_t *data, size_t size)
{
    if (!s_packets || !atomic_load(&s_initialized) || !atomic_load(&s_secure) || size <= 12 ||
        size > 512)
        return -1;
    packet_t packet = {.generation = atomic_load(&s_generation), .size = size};
    memcpy(packet.data, data, size);
    if (xQueueSend(s_packets, &packet, 0) != pdTRUE)
        return -1;
    muse_pocket_kick();
    return 0;
}
static bool send_json(uint8_t kind, const cJSON *json, uint32_t generation)
{
    char *text = cJSON_PrintUnformatted(json);
    if (!text)
        return false;
    size_t size = strlen(text), mtu = muse_ble_pocket_mtu();
    bool ok = size > 0 && size <= POCKET_FRAME_LIMIT && mtu > 12;
    uint8_t packet[512];
    uint16_t transfer = ++s_transfer;
    size_t count = ok ? (size + mtu - 13) / (mtu - 12) : 0;
    for (size_t i = 0; ok && i < count; i++) {
        size_t n = pocket_frame_encode(packet, mtu, kind, transfer, i, text, size);
        bool sent = false;
        for (int retry = 0; retry < 50 && !sent; retry++) {
            if (!atomic_load(&s_secure) || generation != atomic_load(&s_generation)) {
                ok = false;
                break;
            }
            sent = muse_ble_pocket_send(packet, n) == 0;
            if (!sent)
                vTaskDelay(pdMS_TO_TICKS(10));
        }
        if (!sent)
            ok = false;
        else
            vTaskDelay(pdMS_TO_TICKS(3));
    }
    cJSON_free(text);
    return ok;
}
static bool event_json(const char *event, cJSON *data, uint32_t generation)
{
    cJSON *o = cJSON_CreateObject();
    if (!o) {
        cJSON_Delete(data);
        return false;
    }
    cJSON_AddNumberToObject(o, "v", 1);
    cJSON_AddStringToObject(o, "event", event);
    cJSON_AddItemToObject(o, "data", data);
    bool ok = send_json(POCKET_EVENT, o, generation);
    cJSON_Delete(o);
    return ok;
}
void muse_pocket_send_event(const char *event, const char *detail)
{
    if (!s_events)
        return;
    event_t e = {0};
    snprintf(e.event, sizeof(e.event), "%s", event ? event : "");
    snprintf(e.detail, sizeof(e.detail), "%s", detail ? detail : "");
    xQueueSend(s_events, &e, 0);
    muse_pocket_kick();
}
static void notice(const char *title, const char *body)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    snprintf(s_notice, sizeof(s_notice), "%s\n%s", title, body ? body : "");
    xSemaphoreGive(s_lock);
    muse_state_set_asleep(false);
    muse_state_poke();
}
void muse_pocket_notification(uint32_t uid, const char *title, const char *body, bool removed)
{
    (void)uid;
    pocket_settings_t settings;
    muse_pocket_settings(&settings);
    if (settings.notifications && !removed)
        notice(title, body);
}
static cJSON *snapshot(void)
{
    pocket_model_t *copy = psram(sizeof(*copy));
    if (!copy)
        return NULL;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    *copy = *s_model;
    xSemaphoreGive(s_lock);
    muse_pocket_settings(&copy->settings);
    cJSON *o = pocket_model_json(copy);
    free(copy);
    if (!o)
        return NULL;
    cJSON *caps = cJSON_AddArrayToObject(o, "capabilities");
    const char *names[] = {"settings", "clock", "gestures", "timers", "cards",
                           "avatar",   "find",  "ota",      "ancs",   "relay"};
    for (unsigned i = 0; i < sizeof(names) / sizeof(names[0]); i++)
        cJSON_AddItemToArray(caps, cJSON_CreateString(names[i]));
    char status[2048];
    int n = muse_ble_status_json(status, sizeof(status));
    cJSON *device = n > 0 && n < sizeof(status) ? cJSON_Parse(status) : NULL;
    cJSON_AddItemToObject(o, "device", device ? device : cJSON_CreateObject());
    bool running;
    unsigned remaining;
    const char *title;
    muse_board->display_lock(-1);
    muse_tools_ui_timer_status(&running, &remaining, &title);
    cJSON *timer = cJSON_AddObjectToObject(o, "timer");
    cJSON_AddBoolToObject(timer, "running", running);
    cJSON_AddNumberToObject(timer, "remaining", remaining);
    cJSON_AddStringToObject(timer, "title", title);
    muse_board->display_unlock();
    cJSON *diag = cJSON_AddObjectToObject(o, "diagnostics");
    cJSON_AddNumberToObject(diag, "internalFree", heap_caps_get_free_size(MALLOC_CAP_INTERNAL));
    cJSON_AddNumberToObject(diag, "psramFree", heap_caps_get_free_size(MALLOC_CAP_SPIRAM));
    cJSON_AddNumberToObject(diag, "uptimeSeconds", esp_timer_get_time() / 1000000);
    cJSON_AddBoolToObject(diag, "ancs", muse_pocket_ancs_ready());
    return o;
}
static uint8_t *decode(const cJSON *p, size_t limit, size_t *n)
{
    const char *data = str(p, "data");
    if (!data || strlen(data) > ((limit + 2) / 3) * 4)
        return NULL;
    uint8_t *bytes = psram(limit);
    if (!bytes)
        return NULL;
    if (mbedtls_base64_decode(bytes, limit, n, (const unsigned char *)data, strlen(data)) != 0 ||
        !*n) {
        free(bytes);
        return NULL;
    }
    return bytes;
}
static bool persist(pocket_model_t *candidate)
{
    if (!save(candidate))
        return false;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    *s_model = *candidate;
    xSemaphoreGive(s_lock);
    return true;
}
static const char *apply(int action, pocket_model_t *candidate, const cJSON *params)
{
    if (action == POCKET_SETTINGS) {
        if (candidate->settings.avatar == 3 && !s_avatar)
            return "Upload an avatar before selecting it";
        if (!persist(candidate))
            return "Settings storage failed";
        muse_standby_configure(&candidate->settings);
        muse_pocket_ancs_enable(candidate->settings.notifications);
        return NULL;
    }
    if (action == POCKET_PRESETS) {
        muse_board->display_lock(-1);
        bool running;
        unsigned rem;
        const char *title;
        muse_tools_ui_timer_status(&running, &rem, &title);
        bool ok = !running && !rem && save(candidate) &&
                  muse_tools_ui_set_presets(candidate->presets, candidate->preset_count);
        muse_board->display_unlock();
        if (!ok)
            return "Reset the timer before editing presets, or check storage";
        xSemaphoreTake(s_lock, portMAX_DELAY);
        *s_model = *candidate;
        xSemaphoreGive(s_lock);
        return NULL;
    }
    if (action == POCKET_CARDS)
        return persist(candidate) ? NULL : "Card storage failed";
    if (action == POCKET_TIMER_START) {
        if (muse_state_mode(NULL) != MUSE_MODE_IDLE)
            return "Wait until voice playback or recording finishes";
        const char *id = str(params, "id");
        for (int i = 0; i < candidate->preset_count; i++)
            if (!strcmp(candidate->presets[i].id, id)) {
                muse_board->display_lock(-1);
                bool ok = muse_tools_ui_timer_start(candidate->presets + i);
                muse_board->display_unlock();
                return ok ? NULL : "Reset the existing timer before starting another";
            }
    }
    if (action >= POCKET_TIMER_PAUSE && action <= POCKET_TIMER_RESET) {
        muse_board->display_lock(-1);
        if (action == POCKET_TIMER_PAUSE)
            muse_tools_ui_timer_pause();
        else if (action == POCKET_TIMER_RESUME)
            muse_tools_ui_timer_resume();
        else
            muse_tools_ui_reset();
        muse_board->display_unlock();
        return NULL;
    }
    if (action == POCKET_CARD_SHOW) {
        const char *id = str(params, "id");
        for (int i = 0; i < candidate->card_count; i++)
            if (!strcmp(candidate->cards[i].id, id)) {
                pocket_card_t *c = candidate->cards + i;
                time_t now = time(NULL);
                if (c->expires && (now < 1704067200 || now >= c->expires))
                    return "This card expired or Moe's clock needs synchronization";
                notice(c->title, c->body);
                return NULL;
            }
    }
    if (action == POCKET_FIND) {
        muse_state_set_asleep(false);
        muse_state_poke();
        muse_voice_request_chirp();
        notice("HERE I AM", "Moe is nearby");
        return NULL;
    }
    if (action == POCKET_SLEEP) {
        if (muse_state_mode(NULL) != MUSE_MODE_IDLE)
            return "Wait until voice finishes";
        muse_state_set_asleep(true);
        return NULL;
    }
    if (action == POCKET_TIME) {
        const char *timezone = str(params, "timezone");
        if (!timezone || !*timezone || strlen(timezone) > 63)
            return "Invalid phone timezone";
        int64_t epoch;
        if (!num(params, "epoch", 1704067200LL, 4102444800LL, &epoch))
            return "Invalid phone time";
        snprintf(candidate->settings.timezone, sizeof(candidate->settings.timezone), "%s",
                 timezone);
        if (!persist(candidate))
            return "Timezone storage failed";
        muse_standby_configure(&candidate->settings);
        struct timeval tv = {.tv_sec = epoch};
        if (settimeofday(&tv, NULL) != 0)
            return "Clock synchronization failed";
        muse_standby_exit();
        return NULL;
    }
    if (action == POCKET_AVATAR) {
        int64_t crc;
        size_t n = 0;
        uint8_t *bytes = decode(params, 8192, &n);
        if (!bytes || n != 8192 || !num(params, "crc", 0, UINT32_MAX, &crc) ||
            pocket_crc32(bytes, n) != (uint32_t)crc) {
            free(bytes);
            return "Invalid avatar pixels or checksum";
        }
        nvs_handle_t h;
        esp_err_t err = nvs_open("muse_pocket", NVS_READWRITE, &h);
        if (err == ESP_OK) {
            err = nvs_set_blob(h, "avatar", bytes, n);
            if (err == ESP_OK)
                err = nvs_commit(h);
            nvs_close(h);
        }
        if (err != ESP_OK) {
            free(bytes);
            return "Avatar storage failed";
        }
        muse_board->display_lock(-1);
        free(s_avatar);
        s_avatar = bytes;
        s_draw_avatar = -1;
        muse_board->display_unlock();
        return NULL;
    }
    if (action == POCKET_OTA) {
        const char *board = str(params, "board"), *url = str(params, "url"),
                   *sha = str(params, "sha256");
        if (!board || strcmp(board, "waveshare_s3_175c") || !url || strncmp(url, "https://", 8) ||
            strlen(url) > 1024 || strchr(url, '@') || !sha || strlen(sha) != 64)
            return "Incompatible update manifest";
        for (int i = 0; i < 64; i++)
            if (!((sha[i] >= '0' && sha[i] <= '9') || (sha[i] >= 'a' && sha[i] <= 'f') ||
                  (sha[i] >= 'A' && sha[i] <= 'F')))
                return "Invalid update checksum";
        return muse_link_pocket_ota(url, sha) ? NULL : "OTA is unavailable or already running";
    }
    if (action == POCKET_REPLY_TEXT) {
        const char *text = str(params, "text");
        if (!text || !*text || strlen(text) > 360)
            return "Reply text is too long";
        notice("MOE", text);
        return NULL;
    }
    if (action == POCKET_REPLY_BEGIN) {
        int64_t frames, crc, turn;
        if (!num(params, "frames", 1, 240000, &frames) ||
            !num(params, "crc", 0, UINT32_MAX, &crc) || !num(params, "turn", 0, UINT32_MAX, &turn))
            return "Invalid reply audio";
        xSemaphoreTake(s_lock, portMAX_DELAY);
        bool busy = s_reply != NULL;
        xSemaphoreGive(s_lock);
        if (busy)
            return "Moe is still waiting to play a reply";
        free(s_in_audio);
        s_in_size = (frames + 1) / 2;
        s_in_audio = psram(s_in_size);
        s_in_used = 0;
        s_in_frames = frames;
        s_in_crc = crc;
        s_turn = turn;
        s_in_began = esp_timer_get_time();
        return s_in_audio ? NULL : "Not enough audio memory";
    }
    if (action == POCKET_REPLY_PART) {
        int64_t turn, offset;
        size_t n = 0;
        uint8_t *bytes = decode(params, 2048, &n);
        if (!bytes || !s_in_audio || !num(params, "turn", 0, UINT32_MAX, &turn) || turn != s_turn ||
            !num(params, "offset", 0, 120000, &offset) || offset != s_in_used ||
            s_in_used + n > s_in_size) {
            free(bytes);
            return "Reply audio packet is missing or out of order";
        }
        memcpy(s_in_audio + s_in_used, bytes, n);
        s_in_used += n;
        free(bytes);
        return NULL;
    }
    if (action == POCKET_REPLY_END) {
        int64_t turn;
        if (!s_in_audio || !num(params, "turn", 0, UINT32_MAX, &turn) || turn != s_turn ||
            s_in_used != s_in_size || pocket_crc32(s_in_audio, s_in_size) != s_in_crc)
            return "Reply audio transfer is incomplete";
        int16_t *pcm = psram(s_in_size * 4);
        if (!pcm)
            return "Not enough playback memory";
        muse_adpcm_t state = {0};
        muse_adpcm_decode_block(&state, s_in_audio, s_in_size * 2, pcm);
        free(s_in_audio);
        s_in_audio = NULL;
        xSemaphoreTake(s_lock, portMAX_DELAY);
        free(s_reply);
        s_reply = pcm;
        s_reply_frames = s_in_frames;
        xSemaphoreGive(s_lock);
        muse_state_set_asleep(false);
        muse_state_poke();
        return NULL;
    }
    if (action == POCKET_ANCS_ACTION) {
        int64_t uid, positive;
        if (!num(params, "uid", 0, UINT32_MAX, &uid) || !num(params, "action", 0, 1, &positive))
            return "Invalid notification action";
        return muse_pocket_ancs_action(uid, positive) ? NULL : "Notification action is unavailable";
    }
    return action == POCKET_QUERY ? NULL : "Unsupported device action";
}
static void command(void)
{
    if (!pocket_json_depth_valid(s_rx->data, s_rx->size))
        return;
    const char *end = NULL;
    cJSON *request = cJSON_ParseWithLengthOpts((char *)s_rx->data, s_rx->size, &end, false);
    while (end && end < (const char *)s_rx->data + s_rx->size &&
           (*end == ' ' || *end == '\n' || *end == '\r' || *end == '\t'))
        end++;
    if (end != (const char *)s_rx->data + s_rx->size) {
        cJSON_Delete(request);
        return;
    }
    const char *id = str(request, "id"), *method = str(request, "method");
    int64_t version;
    if (!id || strlen(id) > 36 || !method || strlen(method) > 40 ||
        !num(request, "v", 1, 1, &version)) {
        cJSON_Delete(request);
        return;
    }
    uint32_t generation = atomic_load(&s_generation);
    pocket_model_t *candidate = psram(sizeof(*candidate));
    char error[128] = {0};
    const char *failure = "Not enough device memory";
    int action = -1;
    if (candidate) {
        xSemaphoreTake(s_lock, portMAX_DELAY);
        *candidate = *s_model;
        xSemaphoreGive(s_lock);
        muse_pocket_settings(&candidate->settings);
        action =
            pocket_model_apply(candidate, method, get(request, "params"), error, sizeof(error));
        failure = action < 0 ? error : apply(action, candidate, get(request, "params"));
        free(candidate);
    }
    cJSON *response = cJSON_CreateObject();
    cJSON_AddNumberToObject(response, "v", 1);
    cJSON_AddStringToObject(response, "id", id);
    cJSON_AddBoolToObject(response, "ok", !failure);
    if (failure)
        cJSON_AddStringToObject(response, "error", failure);
    else {
        cJSON *result = action == POCKET_QUERY ? snapshot() : cJSON_CreateObject();
        if (action != POCKET_QUERY)
            cJSON_AddBoolToObject(result, "accepted", true);
        if (!result) {
            cJSON_ReplaceItemInObject(response, "ok", cJSON_CreateBool(false));
            cJSON_AddStringToObject(response, "error", "Not enough snapshot memory");
        } else
            cJSON_AddItemToObject(response, "result", result);
    }
    send_json(POCKET_RESPONSE, response, generation);
    cJSON_Delete(response);
    cJSON_Delete(request);
}
bool muse_pocket_relay_ready(void)
{
    pocket_settings_t s;
    muse_pocket_settings(&s);
    return s.relay && atomic_load(&s_secure) && muse_ble_pocket_subscribed();
}
bool muse_pocket_relay_recording(const int16_t *pcm, size_t frames)
{
    if (!pcm || !frames || frames > 240000 || !muse_pocket_relay_ready())
        return false;
    size_t size = (frames + 1) / 2;
    uint8_t *bytes = psram(size);
    if (!bytes)
        return false;
    muse_adpcm_t state = {0};
    muse_adpcm_encode_block(&state, pcm, frames & ~1u, bytes);
    if (frames & 1) {
        int16_t last[] = {pcm[frames - 1], 0};
        muse_adpcm_encode_block(&state, last, 2, bytes + size - 1);
    }
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (s_note) {
        xSemaphoreGive(s_lock);
        free(bytes);
        return false;
    }
    s_note = bytes;
    s_note_frames = frames;
    s_note_turn = esp_random();
    s_note_generation = atomic_load(&s_generation);
    xSemaphoreGive(s_lock);
    muse_pocket_kick();
    return true;
}
int16_t *muse_pocket_take_reply(size_t *frames)
{
    if (!s_lock)
        return NULL;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    int16_t *pcm = s_reply;
    if (pcm) {
        *frames = s_reply_frames;
        s_reply = NULL;
    }
    xSemaphoreGive(s_lock);
    return pcm;
}
static void note_send(uint8_t *bytes, size_t frames, uint32_t turn, uint32_t generation)
{
    cJSON *data = cJSON_CreateObject();
    cJSON_AddNumberToObject(data, "turn", turn);
    bool ok = event_json("voice.begin", data, generation);
    size_t size = (frames + 1) / 2;
    for (size_t offset = 0; ok && offset < size; offset += 1024) {
        size_t n = size - offset < 1024 ? size - offset : 1024;
        unsigned char text[1369];
        size_t written;
        mbedtls_base64_encode(text, sizeof(text) - 1, &written, bytes + offset, n);
        text[written] = 0;
        data = cJSON_CreateObject();
        cJSON_AddNumberToObject(data, "turn", turn);
        cJSON_AddNumberToObject(data, "offset", offset);
        cJSON_AddStringToObject(data, "data", (char *)text);
        ok = event_json("voice.chunk", data, generation);
    }
    if (ok) {
        data = cJSON_CreateObject();
        cJSON_AddNumberToObject(data, "turn", turn);
        cJSON_AddNumberToObject(data, "frames", frames);
        cJSON_AddNumberToObject(data, "crc", pocket_crc32(bytes, size));
        ok = event_json("voice.end", data, generation);
    }
    free(bytes);
    if (!ok)
        notice("PHONE TRANSFER FAILED", "Try recording again after reconnecting");
}
static void worker(void *arg)
{
    (void)arg;
    uint32_t generation = atomic_load(&s_generation);
    packet_t packet;
    event_t event;
    for (;;) {
        ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(1000));
        muse_pocket_ancs_poll();
        if (generation != atomic_load(&s_generation)) {
            generation = atomic_load(&s_generation);
            memset(s_rx, 0, sizeof(*s_rx));
            free(s_in_audio);
            s_in_audio = NULL;
        }
        if (s_in_audio && esp_timer_get_time() - s_in_began > 120000000) {
            free(s_in_audio);
            s_in_audio = NULL;
        }
        while (xQueueReceive(s_packets, &packet, 0) == pdTRUE) {
            if (packet.generation != generation || !atomic_load(&s_secure))
                continue;
            int result =
                pocket_frame_receive(s_rx, packet.data, packet.size, esp_timer_get_time() / 1000);
            if (result == 1)
                command();
        }
        while (xQueueReceive(s_events, &event, 0) == pdTRUE) {
            cJSON *data = cJSON_CreateObject();
            cJSON_AddStringToObject(data, "detail", event.detail);
            event_json(event.event, data, generation);
        }
        xSemaphoreTake(s_lock, portMAX_DELAY);
        uint8_t *note = s_note;
        size_t frames = s_note_frames;
        uint32_t turn = s_note_turn;
        uint32_t note_generation = s_note_generation;
        s_note = NULL;
        xSemaphoreGive(s_lock);
        if (note)
            note_send(note, frames, turn, note_generation);
    }
}
esp_err_t muse_pocket_init(void)
{
    s_model = psram(sizeof(*s_model));
    if (!s_model)
        return ESP_ERR_NO_MEM;
    pocket_model_init(s_model);
    s_lock = xSemaphoreCreateMutex();
    s_packets = xQueueCreate(8, sizeof(packet_t));
    s_events = xQueueCreate(8, sizeof(event_t));
    s_rx = psram(sizeof(*s_rx));
    if (!s_lock || !s_packets || !s_events || !s_rx)
        return ESP_ERR_NO_MEM;
    memset(s_rx, 0, sizeof(*s_rx));
    nvs_handle_t h;
    if (nvs_open("muse_pocket", NVS_READONLY, &h) == ESP_OK) {
        size_t size = 0;
        if (nvs_get_str(h, "model", NULL, &size) == ESP_OK && size <= POCKET_FRAME_LIMIT) {
            char *text = psram(size);
            if (text && nvs_get_str(h, "model", text, &size) == ESP_OK) {
                cJSON *json = cJSON_Parse(text);
                char err[64];
                pocket_model_t candidate;
                pocket_model_init(&candidate);
                if (pocket_model_apply(&candidate, "settings.set", get(json, "settings"), err,
                                       sizeof(err)) >= 0) {
                    bool ok = true;
                    const cJSON *item;
                    cJSON_ArrayForEach(
                        item, get(json, "presets")) if (pocket_model_apply(&candidate, "preset.put",
                                                                           item, err, sizeof(err)) <
                                                        0) ok = false;
                    cJSON_ArrayForEach(
                        item, get(json, "cards")) if (pocket_model_apply(&candidate, "card.put",
                                                                         item, err, sizeof(err)) <
                                                      0) ok = false;
                    if (ok)
                        *s_model = candidate;
                }
                cJSON_Delete(json);
            }
            free(text);
        }
        size = 8192;
        s_avatar = psram(size);
        if (!s_avatar || nvs_get_blob(h, "avatar", s_avatar, &size) != ESP_OK || size != 8192) {
            free(s_avatar);
            s_avatar = NULL;
        }
        nvs_close(h);
    }
    s_model->settings.clock = muse_standby_clock_preference();
    s_model->settings.tap = muse_standby_tap_enabled();
    s_model->settings.shortcut = muse_standby_shortcut();
    if (s_model->settings.avatar == 3 && !s_avatar)
        s_model->settings.avatar = 0;
    muse_standby_configure(&s_model->settings);
    muse_board->display_lock(-1);
    muse_tools_ui_set_presets(s_model->presets, s_model->preset_count);
    muse_board->display_unlock();
    muse_pocket_ancs_enable(s_model->settings.notifications);
    bool created = xTaskCreateWithCaps(worker, "muse_pocket", 8192, NULL, 3, &s_worker,
                                       MUSE_BIG_CAPS) == pdPASS;
    atomic_store(&s_initialized, created);
    return created ? ESP_OK : ESP_ERR_NO_MEM;
}
bool muse_pocket_avatar_visible(void)
{
    return s_avatar_obj && !lv_obj_has_flag(s_avatar_obj, LV_OBJ_FLAG_HIDDEN);
}
static void avatar_clicked(lv_event_t *event)
{
    (void)event;
    lv_obj_send_event(s_avatar_canvas, LV_EVENT_CLICKED, NULL);
}
void muse_pocket_avatar_build(lv_obj_t *canvas)
{
    s_avatar_canvas = canvas;
    s_avatar_obj = lv_image_create(lv_obj_get_parent(canvas));
    lv_obj_add_flag(s_avatar_obj, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(s_avatar_obj, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_add_event_cb(s_avatar_obj, avatar_clicked, LV_EVENT_CLICKED, NULL);
}
void muse_pocket_tick(void)
{
    if (!atomic_load(&s_initialized) || xSemaphoreTake(s_lock, 0) != pdTRUE)
        return;
    pocket_settings_t settings = s_model->settings;
    char message[401];
    snprintf(message, sizeof(message), "%s", s_notice);
    bool show = *message && muse_state_mode(NULL) == MUSE_MODE_IDLE;
    if (show)
        s_notice[0] = 0;
    xSemaphoreGive(s_lock);
    if (show) {
        muse_state_set_caption("%s", message);
        muse_ui_show_page(0);
    }
    if (!s_avatar_obj)
        return;
    bool visible = settings.avatar != 0 && !muse_state_asleep();
    if (!visible) {
        lv_obj_add_flag(s_avatar_obj, LV_OBJ_FLAG_HIDDEN);
        lv_obj_remove_flag(s_avatar_canvas, LV_OBJ_FLAG_HIDDEN);
        return;
    }
    static uint16_t *pixels;
    if (!pixels)
        pixels = psram(8192);
    if (!pixels)
        return;
    int64_t now = esp_timer_get_time();
    if (settings.avatar != s_draw_avatar || settings.accent != s_draw_accent ||
        now >= s_draw_next) {
        uint16_t c = ((settings.accent >> 19) & 31) << 11 | ((settings.accent >> 10) & 63) << 5 |
                     ((settings.accent >> 3) & 31);
        if (settings.avatar == 3 && s_avatar)
            memcpy(pixels, s_avatar, 8192);
        else {
            memset(pixels, 0, 8192);
            for (int y = 0; y < 64; y++)
                for (int x = 0; x < 64; x++) {
                    int dx = x - 32, dy = y - 32;
                    bool on =
                        settings.avatar == 1
                            ? dx * dx + dy * dy < 260
                            : ((x > 18 && x < 24 && y > 24 && y < 36) ||
                               (x > 40 && x < 46 && y > 24 && y < 36) ||
                               (x > 27 && x < 37 && y > 42 && y < 45) ||
                               (y > 12 && y < 23 && ((x > 12 && x < 23) || (x > 41 && x < 52))));
                    if (on)
                        pixels[y * 64 + x] = c;
                }
        }
        s_avatar_dsc = (lv_image_dsc_t){.header = {.magic = LV_IMAGE_HEADER_MAGIC,
                                                   .cf = LV_COLOR_FORMAT_RGB565,
                                                   .w = 64,
                                                   .h = 64,
                                                   .stride = 128},
                                        .data_size = 8192,
                                        .data = (uint8_t *)pixels};
        lv_image_set_src(s_avatar_obj, &s_avatar_dsc);
        lv_obj_invalidate(s_avatar_obj);
        s_draw_avatar = settings.avatar;
        s_draw_accent = settings.accent;
        s_draw_next = now + 200000;
    }
    const lv_image_dsc_t *src = lv_image_get_src(s_avatar_canvas);
    lv_image_set_scale(s_avatar_obj, src->header.w * 256 / 64);
    lv_obj_align(s_avatar_obj, LV_ALIGN_CENTER, 0,
                 lv_obj_get_style_y(s_avatar_canvas, LV_PART_MAIN));
    lv_obj_add_flag(s_avatar_canvas, LV_OBJ_FLAG_HIDDEN);
    lv_obj_remove_flag(s_avatar_obj, LV_OBJ_FLAG_HIDDEN);
}
