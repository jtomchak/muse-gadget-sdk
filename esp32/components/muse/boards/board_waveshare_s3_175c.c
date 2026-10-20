/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/*
 * Waveshare ESP32-S3-Touch-AMOLED-1.75C: round 466 px CO5300 AMOLED with
 * CST9217 touch, ES8311 speaker + ES7210 dual mic, AXP2101 PMU. The top
 * button (PWR) is wired to the PMU and, through an inverter, to GPIO3; the
 * bottom one is BOOT (GPIO0).
 *
 * The ESP32-S3-Touch-AMOLED-1.75 (CONFIG_MUSE_BOARD_WAVESHARE_S3_175) runs
 * this driver too. Its BSP moves the panel and touch resets to GPIO 39 and 40
 * and MCLK to 42. GPIO 1 to 3 go to its SD slot, so PWR is read from the PMU's
 * key latch, and BOOT talks: held long, PWR makes the PMU cut power.
 */
#include "bsp/display.h"
#include "bsp/esp-bsp.h"
#include "bsp/touch.h"
#include "driver/gpio.h"
#include "esp_check.h"
#include "esp_lcd_panel_io.h"
#include "esp_log.h"
#include "esp_lv_adapter.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "muse_board.h"
#include "muse_lcd_bands.h"
#include "muse_mem.h"
#include "muse_pmu.h"
#if CONFIG_MUSE_OPTIMIZED_EXPERIENCE
#include "muse_standby.h"
#include "muse_state.h"
#include "muse_tap.h"
#include "muse_pocket.h"
#include "muse_tilt.h"
#include "esp_timer.h"
#include <stdatomic.h>
#endif

static const char *TAG = "board";

#define DRAW_BUF_LINES 118      /* four bands to the screen (muse_lcd_bands.h) */
#define LCD_CHUNK_BYTES (BSP_LCD_H_RES * 8 * 2)
#if CONFIG_MUSE_BOARD_WAVESHARE_S3_175
#define PMU_KEY_EVERY 2         /* poll the PMU over I2C every 20 ms */
#else
#define PWR_GPIO GPIO_NUM_3    /* high while PWR is held (a BSS138 inverts it) */
#endif

static esp_lcd_panel_io_handle_t s_io;
static esp_lcd_touch_handle_t s_tp;
static muse_gpio_button_t s_boot;
#if !CONFIG_MUSE_BOARD_WAVESHARE_S3_175
static muse_gpio_button_t s_pwr;
#endif

static esp_err_t init(void)
{
    ESP_RETURN_ON_ERROR(bsp_i2c_init(), TAG, "i2c init");
    ESP_RETURN_ON_ERROR(muse_gpio_button_init(&s_boot, GPIO_NUM_0), TAG, "boot button");
#if CONFIG_MUSE_BOARD_WAVESHARE_S3_175
    /* Only the PMU sees PWR: latch its edges for poll_buttons(). */
    esp_err_t err = muse_pmu_init(bsp_i2c_get_handle(), true);
#else
    ESP_RETURN_ON_ERROR(muse_gpio_button_init_high(&s_pwr, PWR_GPIO), TAG, "pwr button");
    /* PWR turned the board on and may still be held; don't count that as a press. */
    s_pwr.pressed = gpio_get_level(PWR_GPIO) == 1;
    /* GPIO3 gives the key, so the PMU needn't latch it. Its IRQ line isn't
     * wired to the ESP32. */
    esp_err_t err = muse_pmu_init(bsp_i2c_get_handle(), false);
#endif
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "PMU unavailable (%s): battery status disabled", esp_err_to_name(err));
        return ESP_OK;
    }
    /* Only DCDC1 (VCC3V3) and ALDO1 (A3V3, for the codecs) feed anything; the
     * schematic leaves the rest unconnected. Waveshare's AXP2101 example and
     * xiaozhi's board turn them off too. */
    err = muse_pmu_keep_rails(BIT(0), BIT(0));
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "unused rails left on (%s)", esp_err_to_name(err));
    }
    return ESP_OK;
}

/* The CO5300 needs even-aligned update windows. */
static void round_area(lv_event_t *e)
{
    lv_area_t *a = lv_event_get_param(e);
    a->x1 &= ~1;
    a->y1 &= ~1;
    a->x2 |= 1;
    a->y2 |= 1;
}

/*
 * bsp_display_start(), less its draw buffers: the BSP's are PSRAM, and every
 * flush from them needs a fresh 46 KB internal DMA bounce buffer, which can't
 * be had once Wi-Fi and BLE are up. The bands go out through two fixed 7 KB
 * internal buffers instead; 9 KB ones left 1 KB free while Wi-Fi joined.
 */
static lv_display_t *display_start(lv_indev_t **touch)
{
    esp_lv_adapter_config_t adapter_cfg = ESP_LV_ADAPTER_DEFAULT_CONFIG();
    adapter_cfg.task_core_id = MUSE_UI_CORE;
    adapter_cfg.task_priority = MUSE_UI_PRIORITY;
    if (esp_lv_adapter_init(&adapter_cfg) != ESP_OK) {
        return NULL;
    }

    esp_lcd_panel_handle_t panel;
    const bsp_display_config_t panel_cfg = {
        .max_transfer_sz = LCD_CHUNK_BYTES,
    };
    if (bsp_display_new(&panel_cfg, &panel, &s_io) != ESP_OK) {
        return NULL;
    }
    const esp_lv_adapter_display_config_t disp_cfg = {
        .panel = panel,
        .panel_io = s_io,
        .profile = {
            .interface = ESP_LV_ADAPTER_PANEL_IF_OTHER,
            .rotation = ESP_LV_ADAPTER_ROTATE_0,
            .hor_res = BSP_LCD_H_RES,
            .ver_res = BSP_LCD_V_RES,
        },
        .tear_avoid_mode = ESP_LV_ADAPTER_TEAR_AVOID_MODE_NONE,
    };
    lv_display_t *disp = muse_lcd_bands_register(disp_cfg, DRAW_BUF_LINES, LCD_CHUNK_BYTES);
    if (!disp) {
        return NULL;
    }
    lv_display_add_event_cb(disp, round_area, LV_EVENT_INVALIDATE_AREA, NULL);

    const bsp_display_cfg_t touch_cfg = {
        .touch_flags = { .mirror_x = 1, .mirror_y = 1 },
    };
    if (bsp_touch_new(&touch_cfg, &s_tp) != ESP_OK) {
        return NULL;
    }
    const esp_lv_adapter_touch_config_t tp_cfg = ESP_LV_ADAPTER_TOUCH_DEFAULT_CONFIG(disp, s_tp);
    *touch = esp_lv_adapter_register_touch(&tp_cfg);
    if (!*touch || esp_lv_adapter_start() != ESP_OK) {
        return NULL;
    }
    return disp;
}

static bool display_lock(int timeout_ms)
{
    return esp_lv_adapter_lock(timeout_ms) == ESP_OK;
}

static void send_brightness(void *level)
{
    /* CO5300 "write display brightness" (0x51), as the BSP sends it. */
    esp_lcd_panel_io_tx_param(s_io, (0x02 << 24) | (0x51 << 8), level, 1);
}

static void set_brightness(int pct)
{
    uint8_t level = (uint8_t)(pct * 255 / 100);
    muse_lcd_bands_run(send_brightness, &level);
}

static void send_sleep(void *sleep)
{
    esp_lcd_panel_io_tx_param(s_io, (0x02 << 24) | ((*(bool *)sleep ? 0x10 : 0x11) << 8), NULL, 0);
}

/* Plain SLPIN/SLPOUT over the QSPI command path. The driver's own sleep also
 * enters deep standby, whose wake pulses the reset line shared with touch. */
static void panel_sleep(bool sleep)
{
    muse_lcd_bands_run(send_sleep, &sleep);
    vTaskDelay(pdMS_TO_TICKS(120));   /* settle before the next command */
}

/*
 * Screen off: LVGL stops, and the CST9217 goes from scanning to deep sleep
 * (command 0xD105), where it only answers its reset line. That line is touch
 * only; the panel's reset is GPIO 1.
 */
static void display_pause(bool pause)
{
    if (pause) {
        esp_lv_adapter_pause(-1);
        esp_lcd_panel_io_tx_param(s_tp->io, 0xD1, (uint8_t[]){ 0x05 }, 1);
    } else {
        gpio_set_level(BSP_LCD_TOUCH_RST, 0);
        vTaskDelay(pdMS_TO_TICKS(10));
        gpio_set_level(BSP_LCD_TOUCH_RST, 1);
        vTaskDelay(pdMS_TO_TICKS(50));   /* as the driver waits after its reset */
        esp_lv_adapter_resume();
    }
}

#if CONFIG_MUSE_OPTIMIZED_EXPERIENCE
static i2c_master_dev_handle_t s_imu;
static atomic_bool s_tapped;
static _Atomic(TaskHandle_t) s_tap_waiter;
static bool s_imu_active, s_imu_failed;
static muse_tilt_t s_tilt;
static int s_threshold=-1;
static bool s_tap_mode;
static void IRAM_ATTR on_tap(void *arg)
{
    (void)arg;
    atomic_store(&s_tapped, true);
    BaseType_t woken = pdFALSE;
    TaskHandle_t waiter = atomic_load(&s_tap_waiter);
    if (waiter) vTaskNotifyGiveFromISR(waiter, &woken);
    if (woken) portYIELD_FROM_ISR();
}
static bool imu_read(uint8_t reg, uint8_t *value)
{
    return i2c_master_transmit_receive(s_imu, &reg, 1, value, 1, 20) == ESP_OK;
}
static bool imu_write(uint8_t reg, uint8_t value)
{
    uint8_t bytes[] = {reg, value};
    return i2c_master_transmit(s_imu, bytes, 2, 20) == ESP_OK;
}
static void imu_delay(unsigned ms) { vTaskDelay(pdMS_TO_TICKS(ms ? ms : 1)); }
static bool imu_start(bool tap,int threshold)
{
    if (!s_imu) {
        i2c_device_config_t cfg = {.dev_addr_length=I2C_ADDR_BIT_LEN_7, .device_address=0x6b, .scl_speed_hz=100000};
        if (i2c_master_bus_add_device(bsp_i2c_get_handle(), &cfg, &s_imu) != ESP_OK) return false;
        gpio_config_t pin = {.pin_bit_mask=1ULL<<21, .mode=GPIO_MODE_INPUT, .intr_type=GPIO_INTR_POSEDGE};
        if (gpio_config(&pin) != ESP_OK || gpio_isr_handler_add(GPIO_NUM_21, on_tap, NULL) != ESP_OK) return false;
    }
    const muse_tap_bus_t bus = {imu_read, imu_write, imu_delay};
    if(tap){if(!muse_tap_configure_threshold(&bus,threshold))return false;}
    else {uint8_t id;if(!imu_read(0,&id)||id!=5||!imu_write(0x08,0)||!imu_write(0x02,0x40)||!imu_write(0x03,0x1c)||!imu_write(0x09,0x80)||!imu_write(0x08,1))return false;}
    s_tilt=(muse_tilt_t){0};
    atomic_store(&s_tapped, false);
    if(tap){gpio_intr_enable(GPIO_NUM_21);gpio_wakeup_enable(GPIO_NUM_21, GPIO_INTR_HIGH_LEVEL);}else{gpio_intr_disable(GPIO_NUM_21);gpio_wakeup_disable(GPIO_NUM_21);}
    return true;
}
static void standby_pause(bool pause)
{
    if (pause) esp_lv_adapter_pause(-1);
    else esp_lv_adapter_resume();
}
static unsigned standby_wake(void)
{
    /* Keep CST9217 scanning in clock mode. Do not replace its driver ISR. */
    bool asleep = muse_state_asleep();
    pocket_settings_t settings;muse_pocket_settings(&settings);
    bool tap = asleep && muse_standby_tap_enabled() && !s_imu_failed;
    bool tilt=asleep && settings.tilt && !s_imu_failed;
    bool want=tap||tilt;
    if(want && (!s_imu_active || s_threshold!=settings.tapThreshold || s_tap_mode!=tap)) {
        s_threshold=settings.tapThreshold;s_tap_mode=tap;
        s_imu_active = imu_start(tap,settings.tapThreshold);
        if (!s_imu_active) {
            s_imu_failed = true;
            if (s_imu) { imu_write(0x08, 0); imu_write(0x09, 0x80); }
            gpio_intr_disable(GPIO_NUM_21);
            gpio_wakeup_disable(GPIO_NUM_21);
            ESP_LOGW(TAG, "tap wake unavailable; buttons still wake");
        }
    } else if (!want && s_imu_active) {
        gpio_intr_disable(GPIO_NUM_21);
        gpio_wakeup_disable(GPIO_NUM_21);
        imu_write(0x08, 0);
        s_imu_active = false;
        atomic_store(&s_tapped, false);
    }
    bool detected = s_imu_active && atomic_exchange(&s_tapped, false);
    if (detected) {
        uint8_t status;
        if (!imu_read(0x2f, &status)) {
            detected = false;
            s_imu_failed = true;
            s_imu_active = false;
            gpio_intr_disable(GPIO_NUM_21);
            gpio_wakeup_disable(GPIO_NUM_21);
            imu_write(0x08, 0);
            ESP_LOGW(TAG, "tap status unavailable; tap wake disabled until reboot");
        } else {
            detected = (status & 2) != 0;
        }
    }
    if(tilt && s_imu_active){uint8_t reg=0x39,values[2];
        if(i2c_master_transmit_receive(s_imu,&reg,1,values,2,20)==ESP_OK){int z=(int16_t)((uint16_t)values[0]|(uint16_t)values[1]<<8);detected |= muse_tilt_update(&s_tilt,z,(uint32_t)(esp_timer_get_time()/1000));
        }else{s_imu_failed=true;s_imu_active=false;imu_write(0x08,0);gpio_intr_disable(GPIO_NUM_21);gpio_wakeup_disable(GPIO_NUM_21);}
    }
    return asleep ? (detected ? 2u : 0u) |
        (muse_standby_enabled() && gpio_get_level(BSP_LCD_TOUCH_INT) == 0 ? 1u : 0u) : 0;
}
#endif

static esp_err_t audio_init(esp_codec_dev_handle_t *spk, esp_codec_dev_handle_t *mic)
{
    *spk = bsp_audio_codec_speaker_init();
    *mic = bsp_audio_codec_microphone_init();
    return *spk && *mic ? ESP_OK : ESP_FAIL;
}

static void set_mic_gain(esp_codec_dev_handle_t mic, int db)
{
    /* ES7210 PGA steps are 3 dB; snap so the UI shows what's applied. */
    db = (db / 3) * 3;
    /* esp_codec_dev rounds 33 dB down to 30; the next real step up is 34.5. */
    esp_codec_dev_set_in_gain(mic, db == 33 ? 34.5f : (float)db);
}

#if CONFIG_MUSE_BOARD_WAVESHARE_S3_175
static unsigned poll_buttons(void)
{
    static unsigned tick;
    unsigned ev = muse_gpio_button_poll(&s_boot);   /* BOOT talks, PWR is aux */
    if (tick++ % PMU_KEY_EVERY == 0) {
        unsigned key = muse_pmu_poll_key();
        ev |= (key & MUSE_PMU_KEY_PRESS ? MUSE_BTN_AUX_PRESS : 0) |
              (key & MUSE_PMU_KEY_RELEASE ? MUSE_BTN_AUX_RELEASE : 0);
    }
    return ev;
}
#else
static unsigned poll_buttons(void)
{
    return muse_gpio_button_poll(&s_pwr) | muse_gpio_button_poll(&s_boot) << 2;   /* BOOT is aux */
}

static void wait_buttons(int timeout_ms)
{
#if CONFIG_MUSE_OPTIMIZED_EXPERIENCE
    atomic_store(&s_tap_waiter, xTaskGetCurrentTaskHandle());
    /* A pulse before we began waiting is retained even after INT1 falls. */
    if (!atomic_load(&s_tapped))
#endif
    muse_gpio_buttons_wait((muse_gpio_button_t *const[]){ &s_pwr, &s_boot }, 2, timeout_ms);
#if CONFIG_MUSE_OPTIMIZED_EXPERIENCE
    atomic_store(&s_tap_waiter, NULL);
#endif
}
#endif

static const muse_board_t s_board = {
#if CONFIG_MUSE_BOARD_WAVESHARE_S3_175
    .name = "Waveshare ESP32-S3-Touch-AMOLED-1.75",
#else
    .name = "Waveshare ESP32-S3-Touch-AMOLED-1.75C",
#endif
    .width = BSP_LCD_H_RES,
    .height = BSP_LCD_V_RES,
    .round = true,
    .touch = true,
    .diagonal_in = 1.75f,
#if CONFIG_MUSE_BOARD_WAVESHARE_S3_175
    .talk_button = "boot",
    .aux_button = "pwr",
    /* The same side buttons as the 1.75C, but BOOT (below) talks. */
    .talk_hint = { LV_ALIGN_CENTER, 153, 129 },
    .aux_hint = { LV_ALIGN_CENTER, 153, -129 },
#else
    .talk_button = "top",
    .aux_button = "bottom",
    /* Side buttons: PWR (talk) above BOOT (sleep/off), on the right. */
    .talk_hint = { LV_ALIGN_CENTER, 153, -129 },    /* 40 degrees above/below 3 o'clock */
    .aux_hint = { LV_ALIGN_CENTER, 153, 129 },
#endif
    .frame_ms = 40,
    .init = init,
    .display_start = display_start,
    .display_lock = display_lock,
    .display_unlock = esp_lv_adapter_unlock,
    .set_brightness = set_brightness,
    .panel_sleep = panel_sleep,
    .display_pause = display_pause,
    .audio_init = audio_init,
    .mic_slot = -1,
    .set_mic_gain = set_mic_gain,
    .poll_buttons = poll_buttons,
#if !CONFIG_MUSE_BOARD_WAVESHARE_S3_175
    .wait_buttons = wait_buttons,   /* the 1.75's PWR is on the PMU, so it's polled */
#endif
    .read_power = muse_pmu_read_power,
    .power_off = muse_pmu_power_off,
#if CONFIG_MUSE_OPTIMIZED_EXPERIENCE
    .standby_pause = standby_pause,
    .standby_wake = standby_wake,
#endif
};

/* Home Link's app_main starts Muse with this board (main/main.c). */
const muse_board_t *muse_board_get(void)
{
    return &s_board;
}
