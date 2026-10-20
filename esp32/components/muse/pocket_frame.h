/* SPDX-License-Identifier: Apache-2.0 */
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif
#define POCKET_FRAME_LIMIT 24576
#define POCKET_FRAME_HEADER 12
#define POCKET_REQUEST 0xa1
#define POCKET_RESPONSE 0xa2
#define POCKET_EVENT 0xa3
typedef struct { uint8_t data[POCKET_FRAME_LIMIT]; size_t size; uint16_t transfer, total, next; uint32_t crc, began_ms; } pocket_rx_t;
/* 1 complete, 0 more, -1 invalid; malformed input resets partial state. */
int pocket_frame_receive(pocket_rx_t *rx, const uint8_t *packet, size_t len, uint32_t now_ms);
uint32_t pocket_crc32(const void *bytes, size_t len);
size_t pocket_frame_encode(uint8_t *out, size_t mtu, uint8_t kind, uint16_t transfer,
                           uint16_t index, const void *data, size_t size);
bool pocket_json_depth_valid(const uint8_t *bytes,size_t size);
#ifdef __cplusplus
}
#endif
