// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import OmniWMScriptHost

struct ShellValueWriter {
    private(set) var bytes: [UInt8] = []

    mutating func reset() {
        bytes.removeAll(keepingCapacity: true)
    }

    mutating func null() {
        tag(OMNI_VALUE_NIL)
    }

    mutating func bool(_ value: Bool) {
        tag(value ? OMNI_VALUE_TRUE : OMNI_VALUE_FALSE)
    }

    mutating func number(_ value: Double) {
        tag(OMNI_VALUE_NUMBER)
        withUnsafeBytes(of: value) { bytes.append(contentsOf: $0) }
    }

    mutating func string(_ value: String) {
        tag(OMNI_VALUE_STRING)
        key(value)
    }

    mutating func string(bytes value: some Collection<UInt8>) {
        tag(OMNI_VALUE_STRING)
        length(value.count)
        bytes.append(contentsOf: value)
    }

    mutating func encoded(_ value: [UInt8]) {
        bytes.append(contentsOf: value)
    }

    mutating func array(_ count: Int) {
        tag(OMNI_VALUE_ARRAY)
        length(count)
    }

    mutating func map(_ count: Int) {
        tag(OMNI_VALUE_MAP)
        length(count)
    }

    mutating func key(_ name: String) {
        let utf8 = name.utf8
        length(utf8.count)
        bytes.append(contentsOf: utf8)
    }

    private mutating func tag(_ value: omni_value_tag) {
        bytes.append(UInt8(value.rawValue))
    }

    private mutating func length(_ count: Int) {
        withUnsafeBytes(of: UInt32(count)) { bytes.append(contentsOf: $0) }
    }
}
