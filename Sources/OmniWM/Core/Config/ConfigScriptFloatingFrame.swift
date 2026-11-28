// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import OmniWMScriptHost

struct FloatingFrameFields: Equatable, Sendable {
    let x: CGFloat?
    let y: CGFloat?
    let width: CGFloat?
    let height: CGFloat?

    func frame(over base: CGRect?) -> CGRect? {
        if let x, let y, let width, let height { return CGRect(x: x, y: y, width: width, height: height) }
        guard let base else { return nil }
        return CGRect(
            x: x ?? base.origin.x, y: y ?? base.origin.y,
            width: width ?? base.size.width, height: height ?? base.size.height
        )
    }
}

extension FloatingFrameFields {
    init(fields: UnsafeBufferPointer<omni_config_field>) throws(ConfigScriptError) {
        guard !fields.isEmpty else { throw Self.failure("set-floating-frame needs x, y, width or height.") }
        var x: CGFloat?
        var y: CGFloat?
        var width: CGFloat?
        var height: CGFloat?
        for field in fields {
            if field.named("x") {
                x = try Self.number(field)
            } else if field.named("y") {
                y = try Self.number(field)
            } else if field.named("width") {
                width = try Self.size(field)
            } else if field.named("height") {
                height = try Self.size(field)
            } else {
                throw Self.failure("Unknown frame field '\(field.nameText)'.")
            }
        }
        self.init(x: x, y: y, width: width, height: height)
    }

    private static func number(_ field: omni_config_field) throws(ConfigScriptError) -> CGFloat {
        guard field.kind == OMNI_CONFIG_NUMBER, field.number_value.isFinite else {
            throw failure("Frame field '\(field.nameText)' must be a finite number.")
        }
        return CGFloat(field.number_value)
    }

    private static func size(_ field: omni_config_field) throws(ConfigScriptError) -> CGFloat {
        let value = try number(field)
        guard value > 0 else { throw failure("Frame field '\(field.nameText)' must be greater than 0.") }
        return value
    }

    private static func failure(_ message: String) -> ConfigScriptError {
        ConfigScriptError(line: nil, message: message)
    }
}
