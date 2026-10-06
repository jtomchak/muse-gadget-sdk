/* SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 jtomchak
 */
#pragma once

#include <stdbool.h>
#include <stdint.h>

/* Input feedback is separate from the voice pipeline's mode: a button press
 * acknowledges intent, not successful recording or delivery. */
void muse_experience_press(bool down, uint32_t now_ms);
bool muse_experience_preparing(uint32_t now_ms);
