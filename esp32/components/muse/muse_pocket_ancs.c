/* SPDX-License-Identifier: Apache-2.0
 * Apple ANCS: bounded discovery and attribute assembly. No notification
 * contents are logged or persisted. Notification actions require an explicit
 * command.
 */
#include "muse_pocket_ancs.h"
#include "esp_timer.h"
#include "host/ble_hs.h"
#include "muse_pocket.h"
#include "nimble/nimble_npl.h"
#include "nimble/nimble_port.h"
#include <stdatomic.h>
#include <string.h>
static const ble_uuid128_t SERVICE = BLE_UUID128_INIT(
    0xd0, 0x00, 0x2d, 0x12, 0x1e, 0x4b, 0x0f, 0xa4, 0x99, 0x4e, 0xce, 0xb5, 0x31, 0xf4, 0x05, 0x79);
static const ble_uuid128_t SOURCE = BLE_UUID128_INIT(
    0xbd, 0x1d, 0xa2, 0x99, 0xe6, 0x25, 0x58, 0x8c, 0xd9, 0x42, 0x01, 0x63, 0x0d, 0x12, 0xbf, 0x9f);
static const ble_uuid128_t DATA = BLE_UUID128_INIT(0xfb, 0x7b, 0x7c, 0xce, 0x6a, 0xb3, 0x44, 0xbe,
                                                   0xb5, 0x4b, 0xd6, 0x24, 0xe9, 0xc6, 0xea, 0x22);
static const ble_uuid128_t CONTROL = BLE_UUID128_INIT(
    0xd9, 0xd9, 0xaa, 0xfd, 0xbd, 0x9b, 0x21, 0x98, 0xa8, 0x49, 0xe1, 0x45, 0xf3, 0xd8, 0xd1, 0x69);
static atomic_bool s_enabled, s_discover, s_ready;
static _Atomic uint16_t s_conn = BLE_HS_CONN_HANDLE_NONE;
static uint16_t s_end, s_source, s_data;
static _Atomic uint16_t s_control;
static struct {
    uint16_t def, val;
} s_chars[12];
static unsigned s_chars_n, s_dsc_index, s_subscriptions;
static uint8_t s_buffer[256];
static size_t s_size;
static atomic_uint s_uid;
static bool s_waiting;
static int64_t s_began;
static struct ble_npl_event s_discovery_event;
static bool s_event_initialized;
static portMUX_TYPE s_mux = portMUX_INITIALIZER_UNLOCKED;
static char s_title[33], s_body[161];
static bool s_message;
static uint32_t s_message_uid;
static int written(uint16_t conn, const struct ble_gatt_error *error, struct ble_gatt_attr *attr,
                   void *arg)
{
    if (conn != atomic_load(&s_conn) || !atomic_load(&s_enabled))
        return 0;
    (void)conn;
    (void)attr;
    (void)arg;
    if (error->status == 0 && ++s_subscriptions == 2)
        atomic_store(&s_ready, true);
    return 0;
}
static int discover_dsc(uint16_t conn, const struct ble_gatt_error *error, uint16_t val,
                        const struct ble_gatt_dsc *dsc, void *arg);
static void next_dsc(void)
{
    while (s_dsc_index < s_chars_n) {
        unsigned i = s_dsc_index++;
        uint16_t val = s_chars[i].val;
        if (val != s_source && val != s_data)
            continue;
        uint16_t end = i + 1 < s_chars_n ? s_chars[i + 1].def - 1 : s_end;
        if (end > val && ble_gattc_disc_all_dscs(s_conn, val, end, discover_dsc, NULL) == 0)
            return;
    }
}
static int discover_dsc(uint16_t conn, const struct ble_gatt_error *error, uint16_t val,
                        const struct ble_gatt_dsc *dsc, void *arg)
{
    if (conn != atomic_load(&s_conn) || !atomic_load(&s_enabled))
        return 0;
    (void)arg;
    if (error->status == 0 && dsc && ble_uuid_u16(&dsc->uuid.u) == 0x2902) {
        (void)val;
        uint8_t enabled[] = {1, 0};
        ble_gattc_write_flat(conn, dsc->handle, enabled, 2, written, NULL);
    } else if (error->status == BLE_HS_EDONE)
        next_dsc();
    return 0;
}
static int discover_chr(uint16_t conn, const struct ble_gatt_error *error,
                        const struct ble_gatt_chr *chr, void *arg)
{
    if (conn != atomic_load(&s_conn) || !atomic_load(&s_enabled))
        return 0;
    (void)conn;
    (void)arg;
    if (error->status == 0 && chr) {
        if (s_chars_n < 12)
            s_chars[s_chars_n++] = (typeof(s_chars[0])){chr->def_handle, chr->val_handle};
        if (!ble_uuid_cmp(&chr->uuid.u, &SOURCE.u))
            s_source = chr->val_handle;
        else if (!ble_uuid_cmp(&chr->uuid.u, &DATA.u))
            s_data = chr->val_handle;
        else if (!ble_uuid_cmp(&chr->uuid.u, &CONTROL.u))
            s_control = chr->val_handle;
    } else if (error->status == BLE_HS_EDONE && s_source && s_data && s_control) {
        s_dsc_index = 0;
        next_dsc();
    }
    return 0;
}
static int discover_svc(uint16_t conn, const struct ble_gatt_error *error,
                        const struct ble_gatt_svc *svc, void *arg)
{
    if (conn != atomic_load(&s_conn) || !atomic_load(&s_enabled))
        return 0;
    (void)arg;
    if (error->status == 0 && svc) {
        s_end = svc->end_handle;
        ble_gattc_disc_all_chrs(conn, svc->start_handle, svc->end_handle, discover_chr, NULL);
    }
    return 0;
}
void muse_pocket_ancs_enable(bool enabled)
{
    bool previous = atomic_exchange(&s_enabled, enabled);
    if (enabled && !previous && s_conn != BLE_HS_CONN_HANDLE_NONE)
        atomic_store(&s_discover, true);
    if (!enabled) {
        atomic_store(&s_ready, false);
        portENTER_CRITICAL(&s_mux);
        s_message = false;
        portEXIT_CRITICAL(&s_mux);
    }
}
bool muse_pocket_ancs_ready(void) { return atomic_load(&s_enabled) && atomic_load(&s_ready); }
static void discover_on_host(struct ble_npl_event *event)
{
    (void)event;
    if (!atomic_load(&s_enabled) || s_conn == BLE_HS_CONN_HANDLE_NONE)
        return;
    s_chars_n = s_subscriptions = 0;
    s_source = s_data = s_control = 0;
    atomic_store(&s_ready, false);
    ble_gattc_disc_svc_by_uuid(s_conn, &SERVICE.u, discover_svc, NULL);
}
void muse_pocket_ancs_poll(void)
{
    if (!s_event_initialized) {
        ble_npl_event_init(&s_discovery_event, discover_on_host, NULL);
        s_event_initialized = true;
    }
    if (atomic_exchange(&s_discover, false))
        ble_npl_eventq_put(nimble_port_get_dflt_eventq(), &s_discovery_event);
    char title[33], body[161];
    bool message;
    uint32_t uid;
    portENTER_CRITICAL(&s_mux);
    message = s_message;
    uid = s_message_uid;
    if (message) {
        memcpy(title, s_title, sizeof(title));
        memcpy(body, s_body, sizeof(body));
        s_message = false;
    }
    portEXIT_CRITICAL(&s_mux);
    if (message && muse_pocket_ancs_ready())
        muse_pocket_notification(uid, title, body, false);
}
bool muse_pocket_ancs_action(uint32_t uid, unsigned action)
{
    if (!muse_pocket_ancs_ready() || action > 1)
        return false;
    uint8_t bytes[] = {2, uid & 255, (uid >> 8) & 255, (uid >> 16) & 255, uid >> 24, action};
    return ble_gattc_write_flat(s_conn, s_control, bytes, sizeof(bytes), NULL, NULL) == 0;
}
static void attributes(void)
{
    if (s_size < 5 || s_buffer[0] != 0)
        return;
    uint32_t uid = (uint32_t)s_buffer[1] | (uint32_t)s_buffer[2] << 8 |
                   (uint32_t)s_buffer[3] << 16 | (uint32_t)s_buffer[4] << 24;
    if (uid != s_uid) {
        s_waiting = false;
        return;
    }
    size_t offset = 5;
    bool title = false, body = false;
    char t[33] = {0}, b[161] = {0};
    while (offset + 3 <= s_size) {
        unsigned attr = s_buffer[offset];
        size_t n = s_buffer[offset + 1] | (size_t)s_buffer[offset + 2] << 8;
        offset += 3;
        if (n > s_size - offset)
            return;
        if (attr == 1) {
            memcpy(t, s_buffer + offset, n < 32 ? n : 32);
            title = true;
        } else if (attr == 3) {
            memcpy(b, s_buffer + offset, n < 160 ? n : 160);
            body = true;
        } else {
            s_waiting = false;
            return;
        }
        offset += n;
    }
    if (title && body && offset == s_size) {
        portENTER_CRITICAL(&s_mux);
        memcpy(s_title, t, sizeof(t));
        memcpy(s_body, b, sizeof(b));
        s_message_uid = uid;
        s_message = true;
        portEXIT_CRITICAL(&s_mux);
        muse_pocket_kick();
        s_waiting = false;
    }
}
void muse_pocket_ancs_gap(struct ble_gap_event *event)
{
    if (event->type == BLE_GAP_EVENT_DISCONNECT) {
        s_conn = BLE_HS_CONN_HANDLE_NONE;
        s_waiting = false;
        portENTER_CRITICAL(&s_mux);
        s_message = false;
        portEXIT_CRITICAL(&s_mux);
        atomic_store(&s_ready, false);
        atomic_store(&s_discover, false);
        return;
    }
    if (event->type == BLE_GAP_EVENT_ENC_CHANGE && event->enc_change.status == 0) {
        struct ble_gap_conn_desc d;
        if (!ble_gap_conn_find(event->enc_change.conn_handle, &d) && d.sec_state.encrypted &&
            d.sec_state.authenticated) {
            s_conn = event->enc_change.conn_handle;
            atomic_store(&s_discover, atomic_load(&s_enabled));
        }
        return;
    }
    if (event->type != BLE_GAP_EVENT_NOTIFY_RX || !atomic_load(&s_enabled) ||
        event->notify_rx.conn_handle != s_conn)
        return;
    if (s_waiting && esp_timer_get_time() - s_began > 5000000)
        s_waiting = false;
    if (event->notify_rx.attr_handle == s_source) {
        uint8_t data[8];
        if (OS_MBUF_PKTLEN(event->notify_rx.om) != 8 ||
            os_mbuf_copydata(event->notify_rx.om, 0, 8, data))
            return;
        if (data[0] == 2 || data[0] > 2 || (data[1] & 4) || s_waiting || !muse_pocket_ancs_ready())
            return;
        s_uid = (uint32_t)data[4] | (uint32_t)data[5] << 8 | (uint32_t)data[6] << 16 |
                (uint32_t)data[7] << 24;
        uint8_t request[] = {0, data[4], data[5], data[6], data[7], 1, 32, 0, 3, 160, 0};
        s_size = 0;
        s_began = esp_timer_get_time();
        s_waiting =
            ble_gattc_write_flat(s_conn, s_control, request, sizeof(request), NULL, NULL) == 0;
    } else if (event->notify_rx.attr_handle == s_data && s_waiting) {
        size_t n = OS_MBUF_PKTLEN(event->notify_rx.om);
        if (n > sizeof(s_buffer) - s_size ||
            os_mbuf_copydata(event->notify_rx.om, 0, n, s_buffer + s_size)) {
            s_waiting = false;
            return;
        }
        s_size += n;
        attributes();
    }
}
