// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMScriptHost

struct SettingsSourceTable: Sendable {
    struct Item: Sendable {
        let key: String?
        let listIndex: Int?
        let indexToken: Range<Int>?
        let bytes: Range<Int>
        let value: Range<Int>
        let separator: Range<Int>?

        init(_ item: omni_settings_item) {
            key = item.key.data.map {
                String(decoding: UnsafeRawBufferPointer(start: $0, count: item.key.length), as: UTF8.self)
            }
            listIndex = item.list_position == 0 ? nil : item.list_position - 1
            indexToken = item.index_end == 0 ? nil : item.index_begin ..< item.index_end
            bytes = item.begin ..< item.end
            value = item.value_begin ..< item.end
            separator = item.separator == 0 ? nil : item.separator ..< (item.separator + 1)
        }
    }

    let bytes: Range<Int>
    let items: [Item]
}
