/* SPDX-License-Identifier: Apache-2.0 */
#include "pocket_frame.h"
#include <string.h>
static uint16_t u16(const uint8_t *b) { return (uint16_t)(b[0] | b[1] << 8); }
static uint32_t u32(const uint8_t *b)
{
    return (uint32_t)b[0] | (uint32_t)b[1] << 8 | (uint32_t)b[2] << 16 | (uint32_t)b[3] << 24;
}
uint32_t pocket_crc32(const void *bytes, size_t len)
{
    uint32_t crc = 0xffffffff;
    const uint8_t *b = (const uint8_t *)bytes;
    for (size_t i = 0; i < len; i++) {
        crc ^= b[i];
        for (int n = 0; n < 8; n++)
            crc = (crc >> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
    }
    return ~crc;
}
int pocket_frame_receive(pocket_rx_t *r, const uint8_t *p, size_t len, uint32_t now)
{
    if (!r || !p)
        return -1;
    if (len <= POCKET_FRAME_HEADER || p[0] != POCKET_REQUEST || p[1] != 1) {
        *r = {};
        return -1;
    }
    uint16_t id = u16(p + 2), index = u16(p + 4), total = u16(p + 6);
    uint32_t crc = u32(p + 8);
    if (!total || total > 4096 || index >= total) {
        *r = {};
        return -1;
    }
    if (!index) {
        *r = {};
        r->transfer = id;
        r->total = total;
        r->crc = crc;
        r->began_ms = now;
    }
    if (now - r->began_ms > 30000 || id != r->transfer || total != r->total || crc != r->crc ||
        index != r->next || r->size + len - POCKET_FRAME_HEADER > POCKET_FRAME_LIMIT) {
        *r = {};
        return -1;
    }
    memcpy(r->data + r->size, p + POCKET_FRAME_HEADER, len - POCKET_FRAME_HEADER);
    r->size += len - POCKET_FRAME_HEADER;
    r->next++;
    if (r->next != r->total)
        return 0;
    if (pocket_crc32(r->data, r->size) != crc) {
        *r = {};
        return -1;
    }
    return 1;
}
size_t pocket_frame_encode(uint8_t *out, size_t mtu, uint8_t kind, uint16_t id, uint16_t index,
                           const void *bytes, size_t size)
{
    if (!out || !bytes || !size || size > POCKET_FRAME_LIMIT || mtu <= POCKET_FRAME_HEADER)
        return 0;
    size_t stride = mtu - POCKET_FRAME_HEADER, total = (size + stride - 1) / stride;
    if (total > 4096 || index >= total)
        return 0;
    out[0] = kind;
    out[1] = 1;
    uint16_t vals[] = {id, index, (uint16_t)total};
    for (int i = 0; i < 3; i++) {
        out[2 + i * 2] = (uint8_t)vals[i];
        out[3 + i * 2] = (uint8_t)(vals[i] >> 8);
    }
    uint32_t crc = pocket_crc32(bytes, size);
    for (int i = 0; i < 4; i++)
        out[8 + i] = (uint8_t)(crc >> (8 * i));
    size_t at = (size_t)index * stride, n = size - at < stride ? size - at : stride;
    memcpy(out + POCKET_FRAME_HEADER, (const uint8_t *)bytes + at, n);
    return n + POCKET_FRAME_HEADER;
}

bool pocket_json_depth_valid(const uint8_t *bytes, size_t size)
{
    if (!bytes || !size)
        return false;
    unsigned depth = 0;
    bool quoted = false, escaped = false;
    for (size_t i = 0; i < size; i++) {
        uint8_t c = bytes[i];
        if (c == 0)
            return false;
        if (quoted) {
            if (escaped)
                escaped = false;
            else if (c == '\\')
                escaped = true;
            else if (c == '"')
                quoted = false;
        } else if (c == '"')
            quoted = true;
        else if (c == '{' || c == '[') {
            if (++depth > 16)
                return false;
        } else if (c == '}' || c == ']') {
            if (!depth)
                return false;
            depth--;
        }
    }
    return !quoted && depth == 0;
}
