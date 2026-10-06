/* SPDX-License-Identifier: Apache-2.0 */
#pragma once
#include "pocket_model.h"
#include "esp_err.h"
#include "lvgl.h"
#ifdef __cplusplus
extern "C" {
#endif
esp_err_t muse_pocket_init(void);
/* BLE host callbacks: copies input to a bounded queue, never renders/network IO. */
int muse_pocket_write(const uint8_t *data,size_t size);
void muse_pocket_connection(uint16_t handle,bool secure);
void muse_pocket_settings(pocket_settings_t *out);
void muse_pocket_kick(void);
void muse_pocket_tick(void); /* display lock held */
void muse_pocket_notification(uint32_t uid,const char *title,const char *body,bool removed);
bool muse_pocket_relay_ready(void);
bool muse_pocket_relay_recording(const int16_t *pcm,size_t frames);
int16_t *muse_pocket_take_reply(size_t *frames);
void muse_pocket_send_event(const char *event,const char *detail);
void muse_pocket_avatar_build(lv_obj_t *canvas);
bool muse_pocket_avatar_visible(void);
#ifdef __cplusplus
}
#endif
