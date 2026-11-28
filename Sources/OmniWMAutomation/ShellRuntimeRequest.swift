// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

package enum ShellRuntimeLimits {
    package static let keyLimit = 64
    package static let valueLimit = 4096
    package static let countLimit = 64

    package static func isTarget(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= keyLimit
    }

    static func isKey(_ key: String) -> Bool {
        isTarget(key) && key.utf8.allSatisfy {
            switch $0 {
            case UInt8(ascii: "a") ... UInt8(ascii: "z"),
                 UInt8(ascii: "A") ... UInt8(ascii: "Z"),
                 UInt8(ascii: "0") ... UInt8(ascii: "9"),
                 UInt8(ascii: "_"),
                 UInt8(ascii: "-"),
                 UInt8(ascii: "."):
                true
            default:
                false
            }
        }
    }
}

package enum ShellRuntimeRequest: Equatable, Sendable {
    case set(key: String, value: String)
    case unset(key: String)
    case toggle(widget: String)
    case trigger(widget: String, name: String, value: String?)

    package var isValid: Bool {
        switch self {
        case let .set(key, value):
            ShellRuntimeLimits.isKey(key) && value.utf8.count <= ShellRuntimeLimits.valueLimit
        case let .unset(key):
            ShellRuntimeLimits.isKey(key)
        case let .toggle(widget):
            ShellRuntimeLimits.isTarget(widget)
        case let .trigger(widget, name, value):
            ShellRuntimeLimits.isTarget(widget) && !widget.hasPrefix(".") && !widget.contains("/")
                && ShellRuntimeLimits.isKey(name) && (value?.utf8.count ?? 0) <= ShellRuntimeLimits.valueLimit
        }
    }
}
