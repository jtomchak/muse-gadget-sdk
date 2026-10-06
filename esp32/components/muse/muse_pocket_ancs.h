/* SPDX-License-Identifier: Apache-2.0 */
#pragma once
#include <stdbool.h>
#include <stdint.h>
struct ble_gap_event;
void muse_pocket_ancs_enable(bool enabled);
void muse_pocket_ancs_gap(struct ble_gap_event *event);
bool muse_pocket_ancs_ready(void);
bool muse_pocket_ancs_action(uint32_t uid,unsigned action);
void muse_pocket_ancs_poll(void);
