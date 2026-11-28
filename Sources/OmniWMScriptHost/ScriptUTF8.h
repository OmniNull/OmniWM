// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

#pragma once

#include <cstddef>

namespace omni_detail {
inline size_t utf8Width(const char *bytes, size_t remaining) {
    unsigned char first = static_cast<unsigned char>(bytes[0]);
    if (first < 0x80) { return 1; }
    size_t width = first >= 0xC2 && first <= 0xDF ? 2
        : first >= 0xE0 && first <= 0xEF ? 3
        : first >= 0xF0 && first <= 0xF4 ? 4 : 0;
    if (width == 0 || remaining < width) { return 0; }
    for (size_t index = 1; index < width; index++) {
        unsigned char next = static_cast<unsigned char>(bytes[index]);
        if (next < 0x80 || next > 0xBF) { return 0; }
    }
    unsigned char second = static_cast<unsigned char>(bytes[1]);
    if ((first == 0xE0 && second < 0xA0) || (first == 0xED && second >= 0xA0)
        || (first == 0xF0 && second < 0x90) || (first == 0xF4 && second >= 0x90)) { return 0; }
    return width;
}
}
