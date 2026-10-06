/* SPDX-License-Identifier: Apache-2.0 */
#include "sdkconfig.h"
#include "muse_standby.h"
#include "esp_timer.h"
#include <stdatomic.h>
#include <stdio.h>
#include <time.h>
#if !CONFIG_MUSE_BOARD_SIMULATOR
#include "nvs.h"
#include "esp_netif_sntp.h"
#include "esp_log.h"
#include <stdlib.h>
#endif
static atomic_bool s_enabled = true;
static atomic_bool s_active;
/* Experimental until sensitivity is measured on the assembled enclosure. */
static atomic_bool s_tap;
static atomic_bool s_24=true,s_night;
static atomic_int s_night_start=1320,s_night_end=420;
static atomic_int s_shortcut;
static atomic_uint_least32_t s_rendered;
static atomic_int s_rendered_minute = -1;
static void save(void)
{
#if !CONFIG_MUSE_BOARD_SIMULATOR
    nvs_handle_t h;
    if (nvs_open("muse_standby", NVS_READWRITE, &h) != ESP_OK) return;
    nvs_set_u8(h, "clock", atomic_load(&s_enabled));
    nvs_set_u8(h, "tap", atomic_load(&s_tap));
    nvs_set_u8(h, "shortcut", atomic_load(&s_shortcut));
    nvs_commit(h);
    nvs_close(h);
#endif
}
void muse_standby_init(void)
{
#if !CONFIG_MUSE_BOARD_SIMULATOR
    nvs_handle_t h;
    if (nvs_open("muse_standby", NVS_READONLY, &h) == ESP_OK) {
        uint8_t v;
        if (nvs_get_u8(h, "clock", &v) == ESP_OK) atomic_store(&s_enabled, v != 0);
        if (nvs_get_u8(h, "tap", &v) == ESP_OK) atomic_store(&s_tap, v != 0);
        if (nvs_get_u8(h, "shortcut", &v) == ESP_OK && v < 3) atomic_store(&s_shortcut, v);
        nvs_close(h);
    }
    setenv("TZ", CONFIG_MUSE_CLOCK_TIMEZONE, 1);
    tzset();
    esp_sntp_config_t cfg = ESP_NETIF_SNTP_DEFAULT_CONFIG("pool.ntp.org");
    esp_err_t err = esp_netif_sntp_init(&cfg);
    if (err != ESP_OK) ESP_LOGW("standby", "clock sync unavailable: %s", esp_err_to_name(err));
#endif
}
bool muse_standby_clock_preference(void) {return atomic_load(&s_enabled);}
bool muse_standby_enabled(void) {
    time_t now=time(NULL);struct tm t;localtime_r(&now,&t);
    int m=t.tm_hour*60+t.tm_min,a=atomic_load(&s_night_start),b=atomic_load(&s_night_end);
    bool night=t.tm_year>=124 && atomic_load(&s_night) && a!=b && (a<b?m>=a&&m<b:m>=a||m<b);
    return atomic_load(&s_enabled) && !night;
}
void muse_standby_toggle(void) { atomic_store(&s_enabled, !atomic_load(&s_enabled)); save(); }
bool muse_standby_tap_enabled(void) { return atomic_load(&s_tap); }
void muse_standby_toggle_tap(void) { atomic_store(&s_tap, !muse_standby_tap_enabled()); save(); }
int muse_standby_shortcut(void) { return atomic_load(&s_shortcut); }
void muse_standby_next_shortcut(void) { atomic_store(&s_shortcut, (muse_standby_shortcut()+1)%3); save(); }
void muse_standby_clock(char out[6], int *minute)
{
    time_t now;
#if CONFIG_MUSE_BOARD_SIMULATOR
    /* A deterministic 12:00 start for screenshots and minute-boundary tests. */
    now = 1767614400 + esp_timer_get_time()/1000000;
    struct tm t;
    gmtime_r(&now, &t);
#else
    time(&now);
    struct tm t;
    localtime_r(&now, &t);
#endif
    *minute = t.tm_hour*60+t.tm_min;
    if (t.tm_year < 124) { snprintf(out, 6, "--:--"); return; }
    strftime(out, 6, atomic_load(&s_24) ? "%H:%M" : "%I:%M", &t);
}
void muse_standby_rendered(uint32_t now_ms)
{
    char text[6]; int minute;
    muse_standby_clock(text, &minute);
    atomic_store(&s_rendered, now_ms);
    atomic_store(&s_rendered_minute, minute);
    atomic_store(&s_active, true);
}
bool muse_standby_can_pause(uint32_t now_ms)
{
    char text[6]; int minute;
    muse_standby_clock(text, &minute);
    return atomic_load(&s_active) && minute == atomic_load(&s_rendered_minute)
        && now_ms - atomic_load(&s_rendered) >= 250;
}
void muse_standby_exit(void) { atomic_store(&s_active, false); }

void muse_standby_configure(const pocket_settings_t *s) {
    atomic_store(&s_enabled,s->clock);atomic_store(&s_tap,s->tap);atomic_store(&s_shortcut,s->shortcut);
    atomic_store(&s_24,s->clock24);atomic_store(&s_night,s->night);
    atomic_store(&s_night_start,s->nightStart);atomic_store(&s_night_end,s->nightEnd);
#if !CONFIG_MUSE_BOARD_SIMULATOR
    setenv("TZ",s->timezone,1);tzset();save();
#endif
    muse_standby_exit();
}
